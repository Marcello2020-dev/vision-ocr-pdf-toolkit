import Foundation
import PDFKit

struct MergePipelineService {
    struct PreflightIssue: Sendable {
        enum Kind: Sendable {
            case unreadable
            case passwordProtected
            case emptyOrDefective
        }

        let url: URL
        let kind: Kind

        var localizedReason: String {
            switch kind {
            case .unreadable:
                return "Datei kann nicht gelesen werden."
            case .passwordProtected:
                return "Datei ist passwortgeschützt."
            case .emptyOrDefective:
                return "Datei ist leer oder defekt."
            }
        }
    }

    struct InputPlan: Sendable {
        let index: Int
        let url: URL
        let title: String
        let shouldImportSourceBookmarks: Bool
    }

    struct ProgressUpdate: Sendable {
        let fraction: Double
        let label: String
        let canCancelImmediately: Bool
    }

    enum PipelineError: LocalizedError, Equatable {
        case cancelled
        case unreadableInput(URL)
        case cannotCreateTempDirectory
        case cannotOpenMergedTemp
        case cannotWriteFinalTemp
        case outlineValidationFailed
        case outputSaveFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Merge wurde abgebrochen."
            case .unreadableInput(let url):
                return "PDF konnte nicht gelesen werden: \(url.lastPathComponent)"
            case .cannotCreateTempDirectory:
                return "Temporärer Merge-Ordner konnte nicht erstellt werden."
            case .cannotOpenMergedTemp:
                return "Temporäres Merge-Dokument konnte nicht geöffnet werden."
            case .cannotWriteFinalTemp:
                return "Finale Merge-Datei konnte nicht geschrieben werden."
            case .outlineValidationFailed:
                return "Bookmarks konnten nicht stabil gespeichert werden."
            case .outputSaveFailed(let message):
                return "Merge-Datei konnte nicht gespeichert werden: \(message)"
            }
        }
    }

    private struct PreparedMergeInput: Sendable {
        let title: String
        let pageCount: Int
        let sourceNodes: [PDFKitOutline.SourceNode]
        let preserveSourceTopLevel: Bool
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let check: () -> Bool

        init(check: @escaping () -> Bool) {
            self.check = check
        }

        func isCancelled() -> Bool {
            check()
        }
    }

    private final class ProgressReporter: @unchecked Sendable {
        private let reportImpl: (ProgressUpdate) -> Void

        init(report: @escaping (ProgressUpdate) -> Void) {
            self.reportImpl = report
        }

        func report(_ update: ProgressUpdate) {
            reportImpl(update)
        }
    }

    private final class PreparationState: @unchecked Sendable {
        private let lock = NSLock()
        private var prepared: [PreparedMergeInput?]
        private var firstError: Error?
        private var completed: Int = 0

        init(count: Int) {
            self.prepared = Array(repeating: nil, count: count)
        }

        func hasFailure() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstError != nil
        }

        func recordFailureIfNeeded(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if firstError == nil {
                firstError = error
            }
        }

        func recordPrepared(_ item: PreparedMergeInput, at index: Int) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard firstError == nil else { return nil }
            prepared[index] = item
            completed += 1
            return completed
        }

        func snapshot() -> (prepared: [PreparedMergeInput?], error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (prepared, firstError)
        }
    }

    static func run(
        plans: [InputPlan],
        destination outFile: URL,
        isCancelled: @escaping () -> Bool,
        progress: @escaping (ProgressUpdate) -> Void,
        tempDirectoryCandidates: [URL]? = nil
    ) throws -> URL {
        let cancellation = CancellationProbe(check: isCancelled)
        let progressReporter = ProgressReporter(report: progress)

        try throwIfCancelled(cancellation.isCancelled)
        progressReporter.report(ProgressUpdate(fraction: 0.05, label: "Analysiere PDFs (0/\(plans.count))…", canCancelImmediately: true))
        let preparedInputs = try prepareMergeInputs(plans, cancellation: cancellation, progressReporter: progressReporter)

        try throwIfCancelled(cancellation.isCancelled)
        progressReporter.report(ProgressUpdate(fraction: 0.34, label: "Erstelle Bookmark-Plan…", canCancelImmediately: true))

        var sections: [PDFKitOutline.Section] = []
        sections.reserveCapacity(preparedInputs.count)
        var pageCursor = 1
        let totalPages = max(preparedInputs.reduce(0) { $0 + $1.pageCount }, 1)
        for prepared in preparedInputs {
            sections.append(
                PDFKitOutline.Section(
                    title: prepared.title,
                    startPage: pageCursor,
                    sourceNodes: prepared.sourceNodes,
                    preserveSourceTopLevel: prepared.preserveSourceTopLevel
                )
            )
            pageCursor += prepared.pageCount
        }

        try throwIfCancelled(cancellation.isCancelled)
        let fm = FileManager.default
        let tempDir: URL
        do {
            tempDir = try createTempMergeDirectory(
                fileManager: fm,
                preferredBase: outFile.deletingLastPathComponent(),
                customCandidates: tempDirectoryCandidates
            )
        } catch {
            throw PipelineError.cannotCreateTempDirectory
        }
        defer { try? fm.removeItem(at: tempDir) }

        let mergedTmp = tempDir.appendingPathComponent("merged_tmp.pdf")
        let finalTmp = tempDir.appendingPathComponent("final_tmp.pdf")

        progressReporter.report(ProgressUpdate(fraction: 0.40, label: "Merge Seiten (0/\(totalPages))…", canCancelImmediately: true))
        do {
            try PDFKitMerger.merge(
                plans.map(\.url),
                to: mergedTmp,
                expectedTotalPages: totalPages,
                isCancelled: cancellation.isCancelled,
                onPageMerged: { donePages, totalPages in
                    let p = 0.40 + (Double(donePages) / Double(max(totalPages, 1))) * 0.34
                    progressReporter.report(ProgressUpdate(fraction: p, label: "Merge Seiten (\(donePages)/\(totalPages))…", canCancelImmediately: true))
                }
            )
        } catch is CancellationError {
            throw PipelineError.cancelled
        } catch {
            throw error
        }

        try throwIfCancelled(cancellation.isCancelled)
        progressReporter.report(ProgressUpdate(fraction: 0.78, label: "Wende Bookmarks an…", canCancelImmediately: true))
        guard let mergedDoc = PDFDocument(url: mergedTmp) else {
            throw PipelineError.cannotOpenMergedTemp
        }

        PDFKitOutline.applyOutline(to: mergedDoc, sections: sections)
        let expectedRootCount = PDFKitOutline.expectedRootCount(for: sections)

        progressReporter.report(ProgressUpdate(fraction: 0.86, label: "Schreibe Ergebnis (nicht unterbrechbar)…", canCancelImmediately: false))
        guard mergedDoc.write(to: finalTmp) else {
            throw PipelineError.cannotWriteFinalTemp
        }

        try throwIfCancelled(cancellation.isCancelled)
        progressReporter.report(ProgressUpdate(fraction: 0.92, label: "Validiere Ergebnis…", canCancelImmediately: true))
        guard PDFKitOutline.validateOutlinePersisted(at: finalTmp, expectedCount: expectedRootCount) else {
            throw PipelineError.outlineValidationFailed
        }

        try throwIfCancelled(cancellation.isCancelled)
        progressReporter.report(ProgressUpdate(fraction: 0.96, label: "Speichere Datei (nicht unterbrechbar)…", canCancelImmediately: false))
        do {
            if fm.fileExists(atPath: outFile.path) {
                _ = try fm.replaceItemAt(outFile, withItemAt: finalTmp, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: finalTmp, to: outFile)
            }
        } catch {
            throw PipelineError.outputSaveFailed(error.localizedDescription)
        }

        progressReporter.report(ProgressUpdate(fraction: 1.0, label: "Fertig", canCancelImmediately: true))
        return outFile
    }

    static func preflightIssues(for plans: [InputPlan]) -> [PreflightIssue] {
        plans.compactMap { preflightIssue(for: $0.url) }
    }

    static func cleanupStaleTemporaryMergeFolders(maxAge: TimeInterval = 60 * 60 * 6) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        let now = Date()

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: []
        ) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix(".pdfmerge-") {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]),
                  values.isDirectory == true
            else {
                continue
            }

            let lastTouched = values.contentModificationDate ?? values.creationDate ?? .distantPast
            guard now.timeIntervalSince(lastTouched) >= maxAge else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    private static func createTempMergeDirectory(
        fileManager fm: FileManager,
        preferredBase: URL,
        customCandidates: [URL]? = nil
    ) throws -> URL {
        var candidates: [URL] = []
        if let customCandidates {
            candidates.append(contentsOf: customCandidates)
        }
        candidates.append(fm.temporaryDirectory)
        candidates.append(preferredBase)

        var seen = Set<String>()
        candidates = candidates.filter { base in
            let key = base.standardizedFileURL.path
            return seen.insert(key).inserted
        }

        for base in candidates {
            let dir = base.appendingPathComponent(".pdfmerge-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            } catch {
                continue
            }
        }

        throw PipelineError.cannotCreateTempDirectory
    }

    private static func preflightIssue(for url: URL) -> PreflightIssue? {
        guard let doc = PDFDocument(url: url) else {
            return PreflightIssue(url: url, kind: .unreadable)
        }

        if doc.isLocked {
            return PreflightIssue(url: url, kind: .passwordProtected)
        }

        guard doc.pageCount > 0, doc.page(at: 0) != nil else {
            return PreflightIssue(url: url, kind: .emptyOrDefective)
        }

        return nil
    }

    private static func throwIfCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() {
            throw PipelineError.cancelled
        }
    }

    private static func prepareMergeInputs(
        _ plans: [InputPlan],
        cancellation: CancellationProbe,
        progressReporter: ProgressReporter
    ) throws -> [PreparedMergeInput] {
        try throwIfCancelled(cancellation.isCancelled)

        let total = max(plans.count, 1)
        let state = PreparationState(count: plans.count)

        let workerLimit = max(1, min(plans.count, ProcessInfo.processInfo.activeProcessorCount))
        let queue = OperationQueue()
        queue.name = "merge.prepare.concurrent"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = workerLimit

        for plan in plans {
            queue.addOperation {
                if cancellation.isCancelled() || state.hasFailure() { return }

                guard let doc = PDFDocument(url: plan.url) else {
                    state.recordFailureIfNeeded(PipelineError.unreadableInput(plan.url))
                    return
                }

                let sourceNodes = plan.shouldImportSourceBookmarks ? PDFKitOutline.extractSourceNodes(from: doc) : []
                let preparedItem = PreparedMergeInput(
                    title: plan.title,
                    pageCount: doc.pageCount,
                    sourceNodes: sourceNodes,
                    preserveSourceTopLevel: plan.shouldImportSourceBookmarks && !sourceNodes.isEmpty
                )

                if let localCompleted = state.recordPrepared(preparedItem, at: plan.index) {
                    let p = 0.08 + (Double(localCompleted) / Double(total)) * 0.24
                    progressReporter.report(ProgressUpdate(
                        fraction: p,
                        label: "Analysiere PDFs (\(localCompleted)/\(plans.count))…",
                        canCancelImmediately: true
                    ))
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()

        try throwIfCancelled(cancellation.isCancelled)
        let snapshot = state.snapshot()
        if let firstError = snapshot.error {
            throw firstError
        }

        return try snapshot.prepared.enumerated().map { index, item in
            guard let item else {
                throw PipelineError.unreadableInput(plans[index].url)
            }
            return item
        }
    }
}
