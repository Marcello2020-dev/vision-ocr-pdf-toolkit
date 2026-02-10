import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PageToolsView: View {
    private enum InsertMode: String, CaseIterable, Identifiable {
        case atStart
        case beforeSelection
        case afterSelection
        case atEnd

        var id: String { rawValue }

        var title: String {
            switch self {
            case .atStart: return "Ganz am Anfang"
            case .beforeSelection: return "Vor Auswahl"
            case .afterSelection: return "Nach Auswahl"
            case .atEnd: return "Ans Ende"
            }
        }
    }

    private static let thumbSize = CGSize(width: 170, height: 220)
    @Environment(\.undoManager) private var undoManager

    @State private var sourceURL: URL? = nil
    @State private var workingDoc: PDFDocument? = nil
    @State private var workingTempURL: URL? = nil
    @State private var workingTempDirURL: URL? = nil
    @State private var selection: Set<Int> = []
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var draggedPageIndex: Int? = nil
    @State private var dropTargetIndex: Int? = nil
    @State private var insertMode: InsertMode = .afterSelection

    @State private var statusText: String = "Bereit"
    @State private var statusLines: [String] = []

    @State private var splitChunkSize: Int = 1

    private struct Row: Identifiable {
        let index: Int
        let rotation: Int
        let formatLabel: String

        var id: Int { index }
    }

    private struct UndoSnapshot {
        let pdfData: Data
        let selection: Set<Int>
    }

    private var rows: [Row] {
        guard let doc = workingDoc else { return [] }
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let rect = page.bounds(for: .mediaBox)
            return Row(
                index: i,
                rotation: page.rotation,
                formatLabel: pageFormatLabel(for: rect)
            )
        }
    }

    private var selectedSingle: Int? {
        selection.count == 1 ? selection.first : nil
    }

    private var canEdit: Bool {
        workingDoc != nil
    }

    private var canSaveInPlace: Bool {
        sourceURL != nil && workingDoc != nil && workingTempDirURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }

                Button("Speichern") { saveInPlace() }
                    .disabled(!canSaveInPlace)

                Button("Speichern als…") { saveAsEditedDocument() }
                    .disabled(!canEdit)

                Spacer()

                Button("Links drehen") { rotateSelected(by: -90) }
                    .disabled(selection.isEmpty)

                Button("Rechts drehen") { rotateSelected(by: 90) }
                    .disabled(selection.isEmpty)

                Button("Löschen") { deleteSelectedPages() }
                    .disabled(selection.isEmpty)

                Button("Extrahieren…") { extractSelectedPages() }
                    .disabled(selection.isEmpty)
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Seiten verschieben") {
                    HStack(spacing: 8) {
                        Button("⇈") { moveSelectedToTop() }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("↑1") { moveSelectedBy(-1) }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("↓1") { moveSelectedBy(1) }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("⇊") { moveSelectedToBottom() }
                            .disabled(selectedSingle == nil || rows.count < 2)
                    }
                }

                GroupBox("Seiten einfügen") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Position", selection: $insertMode) {
                            ForEach(InsertMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)

                        Button("Seiten einfügen…") { insertPages() }
                            .disabled(!canEdit)
                    }
                }

                GroupBox("Splitten") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(value: $splitChunkSize, in: 1...500) {
                            Text("Alle \(splitChunkSize) Seiten")
                        }
                        .frame(width: 180)

                        Button("Splitten…") { splitDocument() }
                            .disabled(!canEdit || rows.isEmpty)
                    }
                }

                Spacer(minLength: 0)
            }

            Group {
                Text("Quelle:")
                    .font(.headline)
                Text(sourceURL?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(sourceURL == nil ? .secondary : .primary)
            }

            Text("Seitenvorschau (Cmd-Click für Mehrfachauswahl):")
                .font(.headline)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(rows) { row in
                        PageThumbnailCard(
                            image: thumbnails[row.index],
                            pageNumber: row.index + 1,
                            rotation: row.rotation,
                            formatLabel: row.formatLabel,
                            isSelected: selection.contains(row.index),
                            isDropTarget: dropTargetIndex == row.index
                        )
                        .onDrag {
                            draggedPageIndex = row.index
                            return NSItemProvider(object: NSString(string: "\(row.index)"))
                        }
                        .onDrop(
                            of: [UTType.plainText, UTType.text],
                            delegate: PageCardDropDelegate(
                                targetIndex: row.index,
                                draggedIndex: $draggedPageIndex,
                                dropTargetIndex: $dropTargetIndex,
                                performMove: { from, to in
                                    handleDropMove(from: from, to: to)
                                }
                            )
                        )
                        .onTapGesture {
                            handlePageSelectionTap(row.index)
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 360)

            VStack(alignment: .leading, spacing: 6) {
                Text("Status:")
                    .font(.headline)
                Text(statusText)
                if !statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(14)
        .frame(minWidth: 900, minHeight: 720)
        .background(AppTheme.panelGradient.ignoresSafeArea())
    }

    private func pickPDF() {
        guard let picked = FileDialogHelpers.choosePDFs(title: "PDF für Seitentools wählen"),
              let first = picked.first
        else {
            statusText = "Keine PDF ausgewählt"
            appendStatus(statusText)
            return
        }

        cleanupWorkingTemp()

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("pagetools-\(UUID().uuidString)", isDirectory: true)
        let tempPDF = tempDir.appendingPathComponent("working.pdf")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try fm.copyItem(at: first, to: tempPDF)
        } catch {
            statusText = "Temp-Arbeitsdatei konnte nicht erstellt werden"
            appendStatus(statusText)
            appendStatus(error.localizedDescription)
            return
        }

        guard let doc = PDFDocument(url: tempPDF) else {
            statusText = "PDF konnte nicht geöffnet werden"
            appendStatus(statusText)
            cleanupWorkingTemp()
            return
        }

        sourceURL = first
        workingDoc = doc
        workingTempURL = tempPDF
        workingTempDirURL = tempDir
        refreshThumbnails()
        selection = doc.pageCount > 0 ? [0] : []
        statusText = "Geladen: \(first.lastPathComponent) (\(doc.pageCount) Seiten)"
        appendStatus(statusText)
        appendStatus("Arbeitskopie aktiv, Original bleibt unverändert bis Speichern.")
    }

    private func handlePageSelectionTap(_ index: Int) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            if selection.contains(index) {
                selection.remove(index)
            } else {
                selection.insert(index)
            }
        } else {
            selection = [index]
        }
    }

    private func rotateSelected(by delta: Int) {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted()
        guard !selected.isEmpty else { return }
        guard let before = captureUndoSnapshot() else { return }

        for idx in selected {
            guard let page = doc.page(at: idx) else { continue }
            var next = (page.rotation + delta) % 360
            if next < 0 { next += 360 }
            page.rotation = next
        }

        refreshThumbnails()
        statusText = "\(selected.count) Seite(n) gedreht"
        appendStatus(statusText)

        if let after = captureUndoSnapshot() {
            registerUndoTransition(actionName: "Seiten drehen", undoSnapshot: before, redoSnapshot: after)
        }
    }

    private func deleteSelectedPages() {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted(by: >)
        guard !selected.isEmpty else { return }
        guard let before = captureUndoSnapshot() else { return }

        for idx in selected {
            if idx >= 0 && idx < doc.pageCount {
                doc.removePage(at: idx)
            }
        }

        if doc.pageCount == 0 {
            selection = []
        } else {
            let fallback = min(selected.last ?? 0, doc.pageCount - 1)
            selection = [fallback]
        }

        refreshThumbnails()
        statusText = "\(selected.count) Seite(n) gelöscht"
        appendStatus(statusText)

        if let after = captureUndoSnapshot() {
            registerUndoTransition(actionName: "Seiten löschen", undoSnapshot: before, redoSnapshot: after)
        }
    }

    private func extractSelectedPages() {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted()
        guard !selected.isEmpty else { return }

        let out = PDFDocument()
        for idx in selected {
            guard let page = doc.page(at: idx),
                  let copy = page.copy() as? PDFPage
            else { continue }
            out.insert(copy, at: out.pageCount)
        }

        guard out.pageCount > 0 else {
            statusText = "Keine Seiten extrahiert"
            appendStatus(statusText)
            return
        }

        let base = sourceBaseName()
        guard let saveURL = chooseSaveURL(suggestedName: "\(base) Extract.pdf") else {
            statusText = "Extrahieren abgebrochen"
            appendStatus(statusText)
            return
        }

        guard out.write(to: saveURL) else {
            statusText = "Extrahieren fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        statusText = "Extrahiert: \(saveURL.lastPathComponent)"
        appendStatus(statusText)
    }

    private func saveInPlace() {
        guard let sourceURL,
              let doc = workingDoc,
              let tempDir = workingTempDirURL,
              let workURL = workingTempURL
        else { return }

        let stagedURL = tempDir.appendingPathComponent("save-staged.pdf")
        let fm = FileManager.default
        if fm.fileExists(atPath: stagedURL.path) {
            try? fm.removeItem(at: stagedURL)
        }

        guard doc.write(to: stagedURL) else {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        do {
            try FileOps.replaceItemAtomically(at: sourceURL, with: stagedURL)
            _ = doc.write(to: workURL)
            statusText = "Gespeichert (atomar): \(sourceURL.lastPathComponent)"
            appendStatus(statusText)
        } catch {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            appendStatus(error.localizedDescription)
        }
    }

    private func saveAsEditedDocument() {
        guard let doc = workingDoc else { return }
        let base = sourceBaseName()
        guard let saveURL = chooseSaveURL(suggestedName: "\(base) Pages.pdf") else {
            statusText = "Speichern abgebrochen"
            appendStatus(statusText)
            return
        }

        guard doc.write(to: saveURL) else {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        statusText = "Gespeichert: \(saveURL.lastPathComponent)"
        appendStatus(statusText)
    }

    private func insertPages() {
        guard let doc = workingDoc else { return }
        guard let before = captureUndoSnapshot() else { return }
        guard let urls = FileDialogHelpers.choosePDFs(title: "PDF(s) zum Einfügen wählen"),
              !urls.isEmpty
        else {
            statusText = "Einfügen abgebrochen"
            appendStatus(statusText)
            return
        }

        var pagesToInsert: [PDFPage] = []
        pagesToInsert.reserveCapacity(64)
        for url in urls {
            guard let src = PDFDocument(url: url) else { continue }
            for i in 0..<src.pageCount {
                guard let page = src.page(at: i),
                      let copy = page.copy() as? PDFPage
                else { continue }
                pagesToInsert.append(copy)
            }
        }

        guard !pagesToInsert.isEmpty else {
            statusText = "Keine Seiten zum Einfügen gefunden"
            appendStatus(statusText)
            return
        }

        let insertionIndex = resolvedInsertionIndex(for: doc)
        for (offset, page) in pagesToInsert.enumerated() {
            doc.insert(page, at: insertionIndex + offset)
        }

        selection = Set(insertionIndex..<(insertionIndex + pagesToInsert.count))
        refreshThumbnails()
        statusText = "\(pagesToInsert.count) Seite(n) eingefügt"
        appendStatus(statusText)

        if let after = captureUndoSnapshot() {
            registerUndoTransition(actionName: "Seiten einfügen", undoSnapshot: before, redoSnapshot: after)
        }
    }

    private func splitDocument() {
        guard let doc = workingDoc else { return }
        guard doc.pageCount > 0 else { return }
        guard let outFolder = FileDialogHelpers.chooseFolder(title: "Output-Ordner für Split wählen") else {
            statusText = "Splitten abgebrochen"
            appendStatus(statusText)
            return
        }

        let chunk = max(1, splitChunkSize)
        let base = sourceBaseName()
        let fm = FileManager.default

        var part = 1
        for start in stride(from: 0, to: doc.pageCount, by: chunk) {
            let end = min(start + chunk, doc.pageCount)
            let outDoc = PDFDocument()
            for i in start..<end {
                guard let page = doc.page(at: i),
                      let copy = page.copy() as? PDFPage
                else { continue }
                outDoc.insert(copy, at: outDoc.pageCount)
            }

            let fileName = "\(base)_part_\(String(format: "%03d", part)).pdf"
            let outURL = outFolder.appendingPathComponent(fileName)
            if fm.fileExists(atPath: outURL.path) {
                try? fm.removeItem(at: outURL)
            }
            guard outDoc.write(to: outURL) else {
                statusText = "Splitten fehlgeschlagen"
                appendStatus("Fehler bei \(fileName)")
                return
            }

            part += 1
        }

        statusText = "Split fertig: \(part - 1) Datei(en)"
        appendStatus(statusText)
    }

    private func moveSelectedBy(_ delta: Int) {
        guard let idx = selectedSingle else { return }
        let target = idx + delta
        movePage(from: idx, to: target)
    }

    private func moveSelectedToTop() {
        guard let idx = selectedSingle else { return }
        movePage(from: idx, to: 0)
    }

    private func moveSelectedToBottom() {
        guard let idx = selectedSingle, let doc = workingDoc else { return }
        movePage(from: idx, to: doc.pageCount - 1)
    }

    private func handleDropMove(from: Int, to: Int) {
        if selection.count > 1 && selection.contains(from) {
            moveSelectedBlock(draggedFrom: from, to: to)
        } else {
            movePage(from: from, to: to)
        }
    }

    private func moveSelectedBlock(draggedFrom from: Int, to target: Int) {
        guard let doc = workingDoc else { return }
        guard let before = captureUndoSnapshot() else { return }

        let moving = selection.sorted()
        guard moving.count > 1 else {
            movePage(from: from, to: target)
            return
        }
        guard moving.contains(from) else {
            movePage(from: from, to: target)
            return
        }
        guard !moving.contains(target) else { return }

        var pages: [PDFPage] = []
        pages.reserveCapacity(moving.count)
        for idx in moving {
            guard idx >= 0, idx < doc.pageCount, let page = doc.page(at: idx) else { return }
            pages.append(page)
        }

        for idx in moving.reversed() {
            doc.removePage(at: idx)
        }

        let removedBeforeTarget = moving.filter { $0 < target }.count
        let movingDown = from < target
        var insertion = target - removedBeforeTarget + (movingDown ? 1 : 0)
        insertion = min(max(insertion, 0), doc.pageCount)

        for (offset, page) in pages.enumerated() {
            doc.insert(page, at: insertion + offset)
        }

        selection = Set(insertion..<(insertion + pages.count))
        refreshThumbnails()
        statusText = "\(pages.count) Seiten verschoben"
        appendStatus(statusText)

        if let after = captureUndoSnapshot() {
            registerUndoTransition(actionName: "Seiten verschieben", undoSnapshot: before, redoSnapshot: after)
        }
    }

    private func movePage(from: Int, to: Int) {
        guard let doc = workingDoc else { return }
        guard from >= 0, from < doc.pageCount else { return }
        guard to >= 0, to < doc.pageCount else { return }
        guard from != to else { return }
        guard let page = doc.page(at: from) else { return }
        guard let before = captureUndoSnapshot() else { return }

        doc.removePage(at: from)
        let destination = min(max(to, 0), doc.pageCount)
        doc.insert(page, at: destination)
        selection = [destination]

        refreshThumbnails()
        statusText = "Seite verschoben: \(from + 1) → \(destination + 1)"
        appendStatus(statusText)

        if let after = captureUndoSnapshot() {
            registerUndoTransition(actionName: "Seite verschieben", undoSnapshot: before, redoSnapshot: after)
        }
    }

    private func resolvedInsertionIndex(for doc: PDFDocument) -> Int {
        switch insertMode {
        case .atStart:
            return 0
        case .beforeSelection:
            return min(selection.min() ?? 0, doc.pageCount)
        case .afterSelection:
            let maxSel = (selection.max() ?? (doc.pageCount - 1))
            return min(maxSel + 1, doc.pageCount)
        case .atEnd:
            return doc.pageCount
        }
    }

    private func refreshThumbnails() {
        guard let doc = workingDoc else {
            thumbnails = [:]
            return
        }
        var next: [Int: NSImage] = [:]
        next.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let img = page.thumbnail(of: Self.thumbSize, for: .mediaBox)
            next[i] = img
        }
        thumbnails = next
    }

    private func cleanupWorkingTemp() {
        workingDoc = nil
        sourceURL = nil
        selection = []
        thumbnails = [:]

        if let dir = workingTempDirURL {
            try? FileManager.default.removeItem(at: dir)
        }

        workingTempURL = nil
        workingTempDirURL = nil
    }

    private func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "PDF speichern"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = sourceURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func sourceBaseName() -> String {
        guard let sourceURL else { return "document" }
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let sanitized = FileOps.sanitizedBaseName(raw)
        return sanitized.isEmpty ? "document" : sanitized
    }

    private func pageFormatLabel(for rect: CGRect) -> String {
        let mmPerPoint = 25.4 / 72.0
        let widthMM = Double(rect.width) * mmPerPoint
        let heightMM = Double(rect.height) * mmPerPoint

        let short = min(widthMM, heightMM)
        let long = max(widthMM, heightMM)
        let orientation = rect.width >= rect.height ? "Querformat" : "Hochformat"

        let dinA: [(name: String, w: Double, h: Double)] = [
            ("A0", 841, 1189),
            ("A1", 594, 841),
            ("A2", 420, 594),
            ("A3", 297, 420),
            ("A4", 210, 297),
            ("A5", 148, 210),
            ("A6", 105, 148)
        ]

        var bestName = "Unbekannt"
        var bestDelta = Double.greatestFiniteMagnitude

        for fmt in dinA {
            let s = min(fmt.w, fmt.h)
            let l = max(fmt.w, fmt.h)
            let delta = abs(short - s) + abs(long - l)
            if delta < bestDelta {
                bestDelta = delta
                bestName = fmt.name
            }
        }

        if bestDelta <= 12.0 {
            return "\(bestName) \(orientation)"
        }

        return "Format unbekannt"
    }

    private func appendStatus(_ line: String) {
        statusLines.append(line)
        if statusLines.count > 5 {
            statusLines.removeFirst(statusLines.count - 5)
        }
    }

    private func captureUndoSnapshot() -> UndoSnapshot? {
        guard let doc = workingDoc, let data = doc.dataRepresentation() else { return nil }
        return UndoSnapshot(pdfData: data, selection: selection)
    }

    private func restoreUndoSnapshot(_ snapshot: UndoSnapshot) {
        guard let restored = PDFDocument(data: snapshot.pdfData) else { return }
        workingDoc = restored

        if restored.pageCount == 0 {
            selection = []
        } else {
            let valid = snapshot.selection.filter { $0 >= 0 && $0 < restored.pageCount }
            selection = valid.isEmpty ? [0] : Set(valid)
        }

        refreshThumbnails()
        statusText = "Bearbeitungsstand wiederhergestellt"
        appendStatus(statusText)
    }

    private func registerUndoTransition(
        actionName: String,
        undoSnapshot: UndoSnapshot,
        redoSnapshot: UndoSnapshot
    ) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: UndoActionTarget.shared) { _ in
            self.restoreUndoSnapshot(undoSnapshot)
            self.registerUndoTransition(
                actionName: actionName,
                undoSnapshot: redoSnapshot,
                redoSnapshot: undoSnapshot
            )
            manager.setActionName(actionName)
        }
        manager.setActionName(actionName)
    }
}

private struct PageThumbnailCard: View {
    let image: NSImage?
    let pageNumber: Int
    let rotation: Int
    let formatLabel: String
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailCell(image: image)
                .frame(width: 170, height: 220)

            HStack(spacing: 6) {
                Text("Seite \(pageNumber)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(rotation)°")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(formatLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTarget ? Color.accentColor.opacity(0.2) : (isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTarget ? Color.accentColor : (isSelected ? Color.accentColor : Color.secondary.opacity(0.35)),
                    lineWidth: isDropTarget ? 3 : (isSelected ? 2 : 1)
                )
        )
        .contentShape(Rectangle())
    }
}

private struct PageCardDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    @Binding var dropTargetIndex: Int?
    let performMove: (_ from: Int, _ to: Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText, UTType.text])
    }

    func dropEntered(info: DropInfo) {
        dropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let fallback = draggedIndex
        dropTargetIndex = nil
        draggedIndex = nil

        let providers = info.itemProviders(for: [UTType.plainText, UTType.text])
        if let provider = providers.first {
            provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let s = item as? NSString,
                      let from = Int(s as String),
                      from != targetIndex
                else { return }
                DispatchQueue.main.async {
                    performMove(from, targetIndex)
                }
            }
            return true
        }

        if let from = fallback, from != targetIndex {
            performMove(from, targetIndex)
            return true
        }

        return false
    }
}

private struct ThumbnailCell: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
    }
}
