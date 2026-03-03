import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct MergeView: View {
    private struct SourceOutlineStats {
        let topLevelCount: Int
        let totalCount: Int
    }

    private struct UndoSnapshot {
        let inputPDFs: [URL]
        let selection: Set<URL>
        let bookmarkTitles: [URL: String]
        let sourceOutlineStatsByURL: [URL: SourceOutlineStats]
        let includeSourceBookmarksByURL: [URL: Bool]
    }

    @Environment(\.undoManager) private var undoManager

    @State private var inputPDFs: [URL] = []

    @State private var isRunning: Bool = false

    // Selection (for remove)
    @State private var selection: Set<URL> = []

    // Drag state
    @State private var draggedItem: URL? = nil
    
    @State private var bookmarkTitles: [URL: String] = [:]   // URL -> Bookmark-Titel
    @State private var sourceOutlineStatsByURL: [URL: SourceOutlineStats] = [:]
    @State private var includeSourceBookmarksByURL: [URL: Bool] = [:]
    
    @State private var lastMergedPDFURL: URL? = nil         // zuletzt erzeugte Merge-PDF
    @State private var suppressInputPDFsOnChange: Bool = false
    @State private var waitCursorPushed: Bool = false
    @State private var mergeWorkItem: DispatchWorkItem? = nil
    @State private var mergeCancellationRequested: Bool = false
    @State private var mergeProgressValue: Double = 0
    @State private var mergeProgressLabel: String = ""
    @State private var mergeProgressCanCancelImmediately: Bool = true
    @State private var mergeErrorMessage: String? = nil
    @State private var mergeErrorDetails: String? = nil
    @State private var showMergeErrorAlert: Bool = false

    private func refreshBookmarksFromFilenames(overwrite: Bool) {
        let before = captureUndoSnapshot()
        for u in inputPDFs {
            let current = (bookmarkTitles[u] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if overwrite || current.isEmpty {
                bookmarkTitles[u] = BookmarkTitleBuilder.defaultTitle(for: u)
            }
        }
        registerUndoTransition(actionName: "Bookmarks aktualisieren", before: before, after: captureUndoSnapshot())
    }

    private func setSourceBookmarkImportForAll(_ enabled: Bool) {
        let before = captureUndoSnapshot()
        for url in inputPDFs {
            includeSourceBookmarksByURL[url] = enabled
        }
        registerUndoTransition(actionName: "Quell-Bookmarks umschalten", before: before, after: captureUndoSnapshot())
    }

    private func syncPerFileStateWithInputs() {
        let valid = Set(inputPDFs)

        bookmarkTitles = bookmarkTitles.filter { valid.contains($0.key) }
        sourceOutlineStatsByURL = sourceOutlineStatsByURL.filter { valid.contains($0.key) }
        includeSourceBookmarksByURL = includeSourceBookmarksByURL.filter { valid.contains($0.key) }

        for url in inputPDFs {
            if bookmarkTitles[url] == nil {
                bookmarkTitles[url] = BookmarkTitleBuilder.defaultTitle(for: url)
            }
            if includeSourceBookmarksByURL[url] == nil {
                includeSourceBookmarksByURL[url] = true
            }
        }
    }

    private func refreshSourceOutlineStats(for urls: [URL]) {
        for url in urls {
            guard sourceOutlineStatsByURL[url] == nil else { continue }
            guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else {
                sourceOutlineStatsByURL[url] = SourceOutlineStats(topLevelCount: 0, totalCount: 0)
                continue
            }

            let topLevelCount = root.numberOfChildren
            let sourceNodes = PDFKitOutline.extractSourceNodes(from: doc)
            let totalCount = PDFKitOutline.countNodes(sourceNodes)
            sourceOutlineStatsByURL[url] = SourceOutlineStats(topLevelCount: topLevelCount, totalCount: totalCount)
        }
    }

    private func sourceOutlineDescription(for url: URL) -> String {
        guard let stats = sourceOutlineStatsByURL[url] else {
            return "Quell-Bookmarks werden analysiert…"
        }
        if stats.totalCount == 0 {
            return "Keine bestehenden Quell-Bookmarks"
        }
        let enabled = includeSourceBookmarksByURL[url] ?? true
        if enabled {
            return "Bestehende Quell-Bookmarks: \(stats.totalCount) (\(stats.topLevelCount) Top-Level), werden unverändert übernommen"
        }
        return "Bestehende Quell-Bookmarks: \(stats.totalCount) (\(stats.topLevelCount) Top-Level), Übernahme deaktiviert"
    }

    private func sourceHasBookmarks(_ url: URL) -> Bool {
        (sourceOutlineStatsByURL[url]?.totalCount ?? 0) > 0
    }

    private func usesSourceBookmarksAsTopLevel(_ url: URL) -> Bool {
        (includeSourceBookmarksByURL[url] ?? true) && sourceHasBookmarks(url)
    }

    private var allSourceBookmarksEnabled: Bool {
        guard !inputPDFs.isEmpty else { return false }
        return inputPDFs.allSatisfy { includeSourceBookmarksByURL[$0] ?? true }
    }

    private func suggestedOutputBaseName() -> String {
        guard let first = inputPDFs.first else { return "merged" }

        // Dateiname der #1 (ohne Extension) buchstabenlaut identisch übernehmen
        let base = first.deletingPathExtension().lastPathComponent

        // Vorschlag: "<Dateiname> mit Anlagen"
        return "\(base) mit Anlagen"
    }

    private var waitCursor: NSCursor {
        if let image = NSImage(named: NSImage.Name("NSWaitCursor")) {
            return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
        }
        return .operationNotAllowed
    }

    private func syncWaitCursor(with running: Bool) {
        if running {
            guard !waitCursorPushed else { return }
            waitCursor.push()
            waitCursorPushed = true
            return
        }

        guard waitCursorPushed else { return }
        NSCursor.pop()
        waitCursorPushed = false
    }

    private func cancelMerge() {
        guard let mergeWorkItem, !mergeCancellationRequested else { return }
        mergeCancellationRequested = true
        mergeWorkItem.cancel()
        mergeProgressLabel = mergeProgressCanCancelImmediately
            ? "Abbruch wird abgeschlossen…"
            : "Abbruch angefordert – warte auf Dateizugriff…"
    }

    private func setMergeProgress(_ value: Double, _ label: String, canCancelImmediately: Bool = true) {
        mergeProgressValue = min(max(value, 0), 1)
        mergeProgressCanCancelImmediately = canCancelImmediately
        if mergeCancellationRequested && label != "Abgebrochen" && label != "Fertig" {
            mergeProgressLabel = canCancelImmediately
                ? "Abbruch wird abgeschlossen…"
                : "Abbruch angefordert – warte auf Dateizugriff…"
            return
        }
        mergeProgressLabel = label
    }

    private func failMerge(with error: Error) {
        if let pipelineError = error as? MergePipelineService.PipelineError, case .cancelled = pipelineError {
            mergeErrorMessage = nil
            mergeErrorDetails = nil
            return
        }
        if error is CancellationError {
            mergeErrorMessage = nil
            mergeErrorDetails = nil
            return
        }

        if let pipelineError = error as? MergePipelineService.PipelineError {
            mergeErrorMessage = pipelineError.errorDescription ?? "Merge ist fehlgeschlagen."
        } else if let localized = error as? LocalizedError, let description = localized.errorDescription {
            mergeErrorMessage = description
        } else {
            mergeErrorMessage = "Merge ist fehlgeschlagen."
        }

        let nsError = error as NSError
        mergeErrorDetails = """
        \(String(reflecting: type(of: error)))
        domain=\(nsError.domain) code=\(nsError.code)
        \(nsError.localizedDescription)
        """
        showMergeErrorAlert = true
    }

    private func copyMergeErrorDetailsToPasteboard() {
        guard let mergeErrorDetails else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mergeErrorDetails, forType: .string)
    }

    private func presentPreflightIssues(_ issues: [MergePipelineService.PreflightIssue]) {
        guard !issues.isEmpty else { return }

        let sorted = issues.sorted { lhs, rhs in
            lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        let count = sorted.count
        mergeErrorMessage = count == 1
            ? "1 Eingabe-PDF kann nicht gemerged werden."
            : "\(count) Eingabe-PDFs können nicht gemerged werden."

        let lines = sorted.map { issue in
            "\(issue.url.lastPathComponent): \(issue.localizedReason)"
        }
        mergeErrorDetails = lines.joined(separator: "\n")
        showMergeErrorAlert = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {
                Button("PDFs auswählen…") { pickPDFs() }

                Button("Sortieren (Dateiname)") { sortByFilename() }
                    .disabled(inputPDFs.count < 2)

                Button("Entfernen") { removeSelected() }
                    .disabled(selection.isEmpty)
                
                // Move buttons (nur aktiv, wenn genau 1 Datei selektiert ist)
                Button("⇈") { moveSelectedToTop() }
                    .disabled(selectedSingle == nil || inputPDFs.count < 2 || isRunning)

                Button("↑1") { moveSelectedBy(-1) }
                    .disabled(selectedSingle == nil || inputPDFs.count < 2 || isRunning)

                Button("↓1") { moveSelectedBy(1) }
                    .disabled(selectedSingle == nil || inputPDFs.count < 2 || isRunning)

                Button("⇊") { moveSelectedToBottom() }
                    .disabled(selectedSingle == nil || inputPDFs.count < 2 || isRunning)
                
                Button("Bookmarks zurücksetzen") { refreshBookmarksFromFilenames(overwrite: true) }
                    .disabled(inputPDFs.isEmpty || isRunning)

                Button(allSourceBookmarksEnabled ? "Quell-Bookmarks alle aus" : "Quell-Bookmarks alle an") {
                    setSourceBookmarkImportForAll(!allSourceBookmarksEnabled)
                }
                .disabled(inputPDFs.isEmpty || isRunning)

                Spacer()
                
                Button("Merge-PDF im Finder zeigen") { openLastMergedPDF() }
                    .disabled(lastMergedPDFURL == nil || isRunning)

                if isRunning {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: mergeProgressValue, total: 1.0)
                            .frame(width: 180)

                        Text(mergeProgressLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Button(mergeCancellationRequested ? "Abbrechen…" : "Abbrechen", role: .destructive) {
                        cancelMerge()
                    }
                    .disabled(mergeCancellationRequested)
                }

                Button("Merge") {
                    runMergeWithBookmarks()
                }
                .disabled(
                    inputPDFs.isEmpty || isRunning
                )
            }

            if let mergeErrorMessage, !isRunning {
                HStack(spacing: 10) {
                    Label(mergeErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    if mergeErrorDetails != nil {
                        Button("Details kopieren") {
                            copyMergeErrorDetailsToPasteboard()
                        }
                        .font(.caption2)
                    }
                }
            }

            Text("Input & Bookmark-Regeln (Reihenfolge = Merge-Reihenfolge; Drag & Drop zum Umsortieren):")
                .font(.headline)

            List(selection: $selection) {
                ForEach(Array(inputPDFs.enumerated()), id: \.element) { index, url in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("\(index + 1).")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 42, alignment: .trailing)

                            Text(url.lastPathComponent)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle("Quell-Bookmarks übernehmen", isOn: Binding(
                                get: { includeSourceBookmarksByURL[url] ?? true },
                                set: { includeSourceBookmarksByURL[url] = $0 }
                            ))
                            .toggleStyle(.switch)
                            .font(.caption)
                            .frame(width: 220, alignment: .trailing)
                        }

                        Text(sourceOutlineDescription(for: url))
                            .font(.caption)
                            .foregroundStyle((sourceOutlineStatsByURL[url]?.totalCount ?? 0) > 0 ? .secondary : .tertiary)
                            .padding(.leading, 52)

                        HStack(spacing: 10) {
                            Text("Merge-Buchmark:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)

                            TextField("Bookmark", text: Binding(
                                get: { bookmarkTitles[url] ?? BookmarkTitleBuilder.defaultTitle(for: url) },
                                set: { bookmarkTitles[url] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(usesSourceBookmarksAsTopLevel(url))
                        }
                        .padding(.leading, 52)

                        if usesSourceBookmarksAsTopLevel(url) {
                            Text("Kein neuer Top-Bookmark: bestehende Quell-Bookmarks bleiben oberste Ebene.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 52)
                        }
                    }
                    .padding(.vertical, 4)
                    .onDrag {
                        draggedItem = url
                        return NSItemProvider(object: url as NSURL)
                    }
                    .onDrop(of: [UTType.fileURL], delegate: PDFDropDelegate(
                        item: url,
                        items: $inputPDFs,
                        draggedItem: $draggedItem
                    ))
                }
            }
            .frame(minHeight: 320)
            .scrollContentBackground(.hidden)

        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 720)
        .background(AppTheme.panelGradient.ignoresSafeArea())
        .onChange(of: inputPDFs) { _, _ in
            if suppressInputPDFsOnChange { return }
            syncPerFileStateWithInputs()
            refreshSourceOutlineStats(for: inputPDFs)
        }
        .onChange(of: isRunning) { _, running in
            syncWaitCursor(with: running)
        }
        .alert("Merge fehlgeschlagen", isPresented: $showMergeErrorAlert) {
            if mergeErrorDetails != nil {
                Button("Details kopieren") {
                    copyMergeErrorDetailsToPasteboard()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(mergeErrorMessage ?? "Unbekannter Fehler")
        }
        .onDisappear {
            syncWaitCursor(with: false)
            mergeWorkItem?.cancel()
            mergeWorkItem = nil
            mergeCancellationRequested = false
            mergeProgressCanCancelImmediately = true
            isRunning = false
        }
    }

    // MARK: - UI Actions
    private func pickPDFs() {
        let before = captureUndoSnapshot()
        guard let selected = FileDialogHelpers.choosePDFs(), !selected.isEmpty else {
            return
        }

        // Nur neue PDFs hinzufügen (keine Duplikate)
        let newOnes = selected.filter { !inputPDFs.contains($0) }
        inputPDFs.append(contentsOf: newOnes)

        syncPerFileStateWithInputs()
        refreshSourceOutlineStats(for: newOnes)

        if !newOnes.isEmpty {
            registerUndoTransition(actionName: "PDFs hinzufügen", before: before, after: captureUndoSnapshot())
        }
    }
    
    private func openLastMergedPDF() {
        guard let url = lastMergedPDFURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sortByFilename() {
        let before = captureUndoSnapshot()
        inputPDFs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        registerUndoTransition(actionName: "PDF-Liste sortieren", before: before, after: captureUndoSnapshot())
    }

    private func removeSelected() {
        let before = captureUndoSnapshot()
        let toRemove = selection
        inputPDFs.removeAll { toRemove.contains($0) }
        selection.removeAll()
        syncPerFileStateWithInputs()
        if !toRemove.isEmpty {
            registerUndoTransition(actionName: "PDFs entfernen", before: before, after: captureUndoSnapshot())
        }
    }
    
    private var selectedSingle: URL? {
        selection.count == 1 ? selection.first : nil
    }

    private func moveSelected(to newIndex: Int) {
        let before = captureUndoSnapshot()
        guard let sel = selectedSingle,
              let from = inputPDFs.firstIndex(of: sel) else { return }

        let clamped = max(0, min(inputPDFs.count - 1, newIndex))
        guard clamped != from else { return }

        var arr = inputPDFs
        let item = arr.remove(at: from)
        arr.insert(item, at: clamped)

        inputPDFs = arr
        selection = [item]   // Auswahl bleibt erhalten
        registerUndoTransition(actionName: "PDF-Reihenfolge ändern", before: before, after: captureUndoSnapshot())
    }

    private func moveSelectedBy(_ delta: Int) {
        guard let sel = selectedSingle,
              let from = inputPDFs.firstIndex(of: sel) else { return }
        moveSelected(to: from + delta)
    }

    private func captureUndoSnapshot() -> UndoSnapshot {
        UndoSnapshot(
            inputPDFs: inputPDFs,
            selection: selection,
            bookmarkTitles: bookmarkTitles,
            sourceOutlineStatsByURL: sourceOutlineStatsByURL,
            includeSourceBookmarksByURL: includeSourceBookmarksByURL
        )
    }

    private func restoreUndoSnapshot(_ snapshot: UndoSnapshot) {
        suppressInputPDFsOnChange = true
        inputPDFs = snapshot.inputPDFs
        selection = snapshot.selection
        bookmarkTitles = snapshot.bookmarkTitles
        sourceOutlineStatsByURL = snapshot.sourceOutlineStatsByURL
        includeSourceBookmarksByURL = snapshot.includeSourceBookmarksByURL
        suppressInputPDFsOnChange = false
    }

    private func registerUndoTransition(actionName: String, before: UndoSnapshot, after: UndoSnapshot) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: UndoActionTarget.shared) { _ in
            self.restoreUndoSnapshot(before)
            self.registerUndoTransition(actionName: actionName, before: after, after: before)
            manager.setActionName(actionName)
        }
        manager.setActionName(actionName)
    }

    private func moveSelectedToTop() {
        moveSelected(to: 0)
    }

    private func moveSelectedToBottom() {
        moveSelected(to: inputPDFs.count - 1)
    }

    private func chooseOutputPDFURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Merge-PDF speichern als"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.pdf]

        let suggestedBase = FileOps.sanitizedBaseName(suggestedOutputBaseName())
        let fallbackBase = suggestedBase.isEmpty ? "merged" : suggestedBase
        panel.nameFieldStringValue = "\(fallbackBase).pdf"
        panel.directoryURL = URLUtils.commonParentFolder(of: inputPDFs) ?? inputPDFs.first?.deletingLastPathComponent()

        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - PDFKit Merge
    private func runMergeWithBookmarks() {
        guard !isRunning else { return }
        guard let outFile = chooseOutputPDFURL() else {
            return
        }

        let plans: [MergePipelineService.InputPlan] = inputPDFs.enumerated().map { index, url in
            let rawTitle = (bookmarkTitles[url] ?? BookmarkTitleBuilder.defaultTitle(for: url))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? BookmarkTitleBuilder.defaultTitle(for: url) : rawTitle

            return MergePipelineService.InputPlan(
                index: index,
                url: url,
                title: title,
                shouldImportSourceBookmarks: includeSourceBookmarksByURL[url] ?? true
            )
        }

        mergeErrorMessage = nil
        mergeErrorDetails = nil
        showMergeErrorAlert = false

        let preflightIssues = MergePipelineService.preflightIssues(for: plans)
        if !preflightIssues.isEmpty {
            presentPreflightIssues(preflightIssues)
            return
        }

        mergeWorkItem?.cancel()
        mergeCancellationRequested = false
        setMergeProgress(0.01, "Vorbereitung…", canCancelImmediately: true)
        isRunning = true

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem(qos: .userInitiated) {
            let progress: (MergePipelineService.ProgressUpdate) -> Void = { update in
                DispatchQueue.main.async {
                    guard self.isRunning else { return }
                    self.setMergeProgress(update.fraction, update.label, canCancelImmediately: update.canCancelImmediately)
                }
            }

            do {
                let savedURL = try MergePipelineService.run(
                    plans: plans,
                    destination: outFile,
                    isCancelled: { workItem.isCancelled },
                    progress: progress
                )

                if workItem.isCancelled {
                    throw MergePipelineService.PipelineError.cancelled
                }

                DispatchQueue.main.async {
                    guard !workItem.isCancelled else {
                        self.isRunning = false
                        self.mergeWorkItem = nil
                        self.mergeCancellationRequested = false
                        self.setMergeProgress(0, "Abgebrochen", canCancelImmediately: true)
                        return
                    }

                    self.lastMergedPDFURL = savedURL
                    self.isRunning = false
                    self.mergeWorkItem = nil
                    self.mergeCancellationRequested = false
                    self.setMergeProgress(1, "Fertig", canCancelImmediately: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.mergeWorkItem = nil

                    if let pipelineError = error as? MergePipelineService.PipelineError, case .cancelled = pipelineError {
                        self.mergeCancellationRequested = false
                        self.setMergeProgress(0, "Abgebrochen", canCancelImmediately: true)
                        return
                    }
                    if error is CancellationError {
                        self.mergeCancellationRequested = false
                        self.setMergeProgress(0, "Abgebrochen", canCancelImmediately: true)
                        return
                    }

                    self.mergeCancellationRequested = false
                    self.setMergeProgress(0, "", canCancelImmediately: true)
                    self.failMerge(with: error)
                }
            }
        }

        mergeWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}
