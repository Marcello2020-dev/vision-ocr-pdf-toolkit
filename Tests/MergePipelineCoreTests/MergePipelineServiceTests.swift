import XCTest
import Foundation
import PDFKit
import AppKit
@testable import MergePipelineCore

final class MergePipelineServiceTests: XCTestCase {
    func testRunReplacesExistingOutputFileAndEmitsNonInterruptiblePhases() throws {
        let workspace = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputA = workspace.appendingPathComponent("a.pdf")
        let inputB = workspace.appendingPathComponent("b.pdf")
        let output = workspace.appendingPathComponent("merged.pdf")

        try writePDF(to: inputA, pageCount: 1, marker: "A")
        try writePDF(to: inputB, pageCount: 2, marker: "B")
        try writePDF(to: output, pageCount: 1, marker: "OLD")

        var updates: [MergePipelineService.ProgressUpdate] = []
        let plans = [
            MergePipelineService.InputPlan(index: 0, url: inputA, title: "Erste Datei", shouldImportSourceBookmarks: true),
            MergePipelineService.InputPlan(index: 1, url: inputB, title: "Zweite Datei", shouldImportSourceBookmarks: true),
        ]

        _ = try MergePipelineService.run(
            plans: plans,
            destination: output,
            isCancelled: { false },
            progress: { updates.append($0) }
        )

        let merged = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(merged.pageCount, 3)
        XCTAssertEqual(merged.outlineRoot?.numberOfChildren, 2)

        XCTAssertTrue(
            updates.contains(where: { !$0.canCancelImmediately && $0.label.contains("nicht unterbrechbar") }),
            "Es muss mindestens eine nicht-unterbrechbare Phase signalisiert werden."
        )
    }

    func testRunCanBeCancelledDuringPageMerge() throws {
        let workspace = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputA = workspace.appendingPathComponent("cancel-a.pdf")
        let inputB = workspace.appendingPathComponent("cancel-b.pdf")
        let output = workspace.appendingPathComponent("cancel-out.pdf")

        try writePDF(to: inputA, pageCount: 24, marker: "C1")
        try writePDF(to: inputB, pageCount: 24, marker: "C2")

        var cancellationRequested = false
        let plans = [
            MergePipelineService.InputPlan(index: 0, url: inputA, title: "C1", shouldImportSourceBookmarks: true),
            MergePipelineService.InputPlan(index: 1, url: inputB, title: "C2", shouldImportSourceBookmarks: true),
        ]

        XCTAssertThrowsError(
            try MergePipelineService.run(
                plans: plans,
                destination: output,
                isCancelled: { cancellationRequested },
                progress: { update in
                    if update.label.hasPrefix("Merge Seiten") && update.fraction >= 0.50 {
                        cancellationRequested = true
                    }
                }
            )
        ) { error in
            guard let pipelineError = error as? MergePipelineService.PipelineError else {
                XCTFail("Unerwarteter Fehlertyp: \(error)")
                return
            }
            XCTAssertEqual(pipelineError, .cancelled)
        }
    }

    func testRunFailsForUnreadableInput() throws {
        let workspace = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let missing = workspace.appendingPathComponent("does-not-exist.pdf")
        let output = workspace.appendingPathComponent("out.pdf")
        let plans = [
            MergePipelineService.InputPlan(index: 0, url: missing, title: "Missing", shouldImportSourceBookmarks: true),
        ]

        XCTAssertThrowsError(
            try MergePipelineService.run(
                plans: plans,
                destination: output,
                isCancelled: { false },
                progress: { _ in },
                tempDirectoryCandidates: [workspace]
            )
        ) { error in
            guard let pipelineError = error as? MergePipelineService.PipelineError else {
                XCTFail("Unerwarteter Fehlertyp: \(error)")
                return
            }
            guard case .unreadableInput(let badURL) = pipelineError else {
                XCTFail("Erwartet unreadableInput, erhalten: \(pipelineError)")
                return
            }
            XCTAssertEqual(badURL.lastPathComponent, "does-not-exist.pdf")
        }
    }

    func testRunHandlesLargeInputSet() throws {
        let workspace = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let output = workspace.appendingPathComponent("large-merged.pdf")
        let inputCount = 40
        var plans: [MergePipelineService.InputPlan] = []
        plans.reserveCapacity(inputCount)

        for idx in 0..<inputCount {
            let url = workspace.appendingPathComponent("in-\(idx).pdf")
            try writePDF(to: url, pageCount: 1, marker: "L\(idx)")
            plans.append(
                MergePipelineService.InputPlan(
                    index: idx,
                    url: url,
                    title: "Large \(idx)",
                    shouldImportSourceBookmarks: true
                )
            )
        }

        _ = try MergePipelineService.run(
            plans: plans,
            destination: output,
            isCancelled: { false },
            progress: { _ in }
        )

        let merged = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(merged.pageCount, inputCount)
        XCTAssertEqual(merged.outlineRoot?.numberOfChildren, inputCount)
    }

    func testRunFailsWhenDestinationFolderIsReadOnly() throws {
        let workspace = try makeScratchDirectory()
        defer {
            try? setPOSIXPermissions(of: workspace, to: 0o755)
            try? FileManager.default.removeItem(at: workspace)
        }

        let input = workspace.appendingPathComponent("input.pdf")
        try writePDF(to: input, pageCount: 2, marker: "RO")

        let readOnlyDir = workspace.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        let tempRoot = workspace.appendingPathComponent("temp-root", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "ok".write(to: tempRoot.appendingPathComponent("canary.txt"), atomically: true, encoding: .utf8)

        let output = readOnlyDir.appendingPathComponent("out.pdf")
        try writePDF(to: output, pageCount: 1, marker: "OLD")

        try setPOSIXPermissions(of: readOnlyDir, to: 0o555)
        defer { try? setPOSIXPermissions(of: readOnlyDir, to: 0o755) }

        let plans = [
            MergePipelineService.InputPlan(index: 0, url: input, title: "Readonly", shouldImportSourceBookmarks: true),
        ]

        XCTAssertThrowsError(
            try MergePipelineService.run(
                plans: plans,
                destination: output,
                isCancelled: { false },
                progress: { _ in },
                tempDirectoryCandidates: [tempRoot]
            )
        ) { error in
            guard let pipelineError = error as? MergePipelineService.PipelineError else {
                XCTFail("Unerwarteter Fehlertyp: \(error)")
                return
            }
            guard case .outputSaveFailed(let message) = pipelineError else {
                XCTFail("Erwartet outputSaveFailed, erhalten: \(pipelineError)")
                return
            }
            XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Helpers
    private func makeScratchDirectory() throws -> URL {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let root = cwd.appendingPathComponent("_local/test-output", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("merge-regression-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePDF(to url: URL, pageCount: Int, marker: String) throws {
        let doc = PDFDocument()
        for index in 0..<pageCount {
            autoreleasepool {
                let image = NSImage(size: NSSize(width: 420, height: 320))
                image.lockFocus()
                NSColor.white.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 420, height: 320)).fill()

                let text = "\(marker)-\(index + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                    .foregroundColor: NSColor.black,
                ]
                text.draw(at: NSPoint(x: 24, y: 24), withAttributes: attrs)
                image.unlockFocus()

                if let page = PDFPage(image: image) {
                    doc.insert(page, at: doc.pageCount)
                }
            }
        }

        guard doc.write(to: url) else {
            throw NSError(domain: "MergePipelineServiceTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Konnte Test-PDF nicht schreiben: \(url.path)",
            ])
        }
    }

    private func setPOSIXPermissions(of url: URL, to value: Int16) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: value)], ofItemAtPath: url.path)
    }
}
