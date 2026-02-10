import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct RedactionView: View {
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case original
        case redacted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Original"
            case .redacted: return "Geschwärzt"
            }
        }
    }

    struct RedactionMark: Identifiable {
        let id = UUID()
        let pageIndex: Int
        let rect: CGRect
    }

    @Environment(\.undoManager) private var undoManager

    @State private var inputPDF: URL? = nil
    @State private var pendingRedactedTempURL: URL? = nil
    @State private var pendingTempDirURL: URL? = nil
    @State private var redactions: [RedactionMark] = []

    @State private var isRunning: Bool = false
    @State private var isSaving: Bool = false
    @State private var drawModeEnabled: Bool = true
    @State private var statusText: String = "Bereit"
    @State private var statusLines: [String] = []

    @State private var previewMode: PreviewMode = .original
    @State private var previewReloadToken: UUID = UUID()

    private var previewURL: URL? {
        switch previewMode {
        case .original:
            return inputPDF
        case .redacted:
            return pendingRedactedTempURL ?? inputPDF
        }
    }

    private var canApply: Bool {
        inputPDF != nil && !redactions.isEmpty && !isRunning && !isSaving
    }

    private var canSave: Bool {
        inputPDF != nil && pendingRedactedTempURL != nil && !isRunning && !isSaving
    }

    private var canDiscard: Bool {
        pendingRedactedTempURL != nil && !isRunning && !isSaving
    }

    private var canEditMarks: Bool {
        inputPDF != nil && !isRunning && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }
                    .disabled(isRunning || isSaving)

                Button("Schwärzung anwenden") { runRedaction() }
                    .disabled(!canApply)

                Button("Speichern") { saveInPlace() }
                    .disabled(!canSave)

                Button("Speichern als…") { saveAs() }
                    .disabled(!canSave)

                Button("Verwerfen") { discardPendingResult() }
                    .disabled(!canDiscard)

                Spacer()

                Toggle("Zeichenmodus", isOn: $drawModeEnabled)
                    .toggleStyle(.switch)
                    .disabled(!canEditMarks)
            }

            HStack(spacing: 10) {
                Button("Letzte Markierung entfernen") { removeLastMark() }
                    .disabled(!canEditMarks || redactions.isEmpty)

                Button("Alle Markierungen entfernen") { clearMarks() }
                    .disabled(!canEditMarks || redactions.isEmpty)

                Text("Markierungen: \(redactions.count)")
                    .font(.callout)
                    .foregroundStyle(redactions.isEmpty ? .secondary : .primary)

                Spacer()

                Picker("Vorschau", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .disabled(inputPDF == nil)
            }

            Group {
                Text("Input PDF:")
                    .font(.headline)
                Text(inputPDF?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(inputPDF == nil ? .secondary : .primary)
            }

            RedactionPDFPreviewRepresentable(
                url: previewURL,
                reloadToken: previewReloadToken,
                redactions: redactions,
                drawEnabled: drawModeEnabled,
                onCreateRedaction: { pageIndex, pageRect in
                    addMark(pageIndex: pageIndex, rect: pageRect)
                },
                onCreateRedactionsFromSelection: { marks in
                    addMarksFromSelection(marks)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if previewMode == .redacted && pendingRedactedTempURL == nil {
                Text("Noch keine geschwärzte Vorschau vorhanden. Zuerst Schwärzung anwenden.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("Status: \(statusText)")
                    .font(.callout)
                    .lineLimit(1)

                Spacer()
            }

            if !statusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 900, minHeight: 760, maxHeight: .infinity)
        .background(AppTheme.panelGradient.ignoresSafeArea())
    }

    private func pickPDF() {
        guard let selected = FileDialogHelpers.choosePDFs(title: "PDF für Schwärzung wählen"),
              let first = selected.first
        else {
            statusText = "Keine PDF ausgewählt"
            appendStatus(statusText)
            return
        }

        inputPDF = first
        redactions.removeAll()
        cleanupPendingArtifacts()
        previewMode = .original
        previewReloadToken = UUID()
        statusText = "PDF gewählt"
        appendStatus("PDF gewählt: \(first.lastPathComponent)")
    }

    private func addMark(pageIndex: Int, rect: CGRect) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        let before = redactions
        invalidatePendingResult(silent: true)
        redactions.append(RedactionMark(pageIndex: pageIndex, rect: rect.standardized))
        statusText = "Markierung hinzugefügt (Seite \(pageIndex + 1))"
        appendStatus(statusText)
        registerRedactionUndo(actionName: "Schwärzungsmarkierung", undoMarks: before, redoMarks: redactions)
    }

    private func addMarksFromSelection(_ marks: [(Int, CGRect)]) {
        guard !marks.isEmpty else { return }

        let before = redactions
        invalidatePendingResult(silent: true)

        var inserted = 0
        for (pageIndex, rect) in marks {
            let standardized = rect.standardized
            guard standardized.width >= 2, standardized.height >= 2 else { continue }

            let duplicate = redactions.contains {
                $0.pageIndex == pageIndex && $0.rect.approxEquals(standardized, tolerance: 0.7)
            }
            if !duplicate {
                redactions.append(RedactionMark(pageIndex: pageIndex, rect: standardized))
                inserted += 1
            }
        }

        guard inserted > 0 else {
            statusText = "Textauswahl enthält keine neuen Markierungen"
            appendStatus(statusText)
            return
        }

        if inserted == 1 {
            statusText = "1 Markierung aus Textauswahl hinzugefügt"
        } else {
            statusText = "\(inserted) Markierungen aus Textauswahl hinzugefügt"
        }
        appendStatus(statusText)
        registerRedactionUndo(actionName: "Textauswahl markieren", undoMarks: before, redoMarks: redactions)
    }

    private func removeLastMark() {
        guard !redactions.isEmpty else { return }
        let before = redactions
        invalidatePendingResult(silent: true)
        _ = redactions.popLast()
        statusText = "Letzte Markierung entfernt"
        appendStatus(statusText)
        registerRedactionUndo(actionName: "Schwärzungsmarkierung entfernen", undoMarks: before, redoMarks: redactions)
    }

    private func clearMarks() {
        guard !redactions.isEmpty else { return }
        let before = redactions
        invalidatePendingResult(silent: true)
        redactions.removeAll()
        statusText = "Alle Markierungen entfernt"
        appendStatus(statusText)
        registerRedactionUndo(actionName: "Schwärzungsmarkierungen löschen", undoMarks: before, redoMarks: redactions)
    }

    private func runRedaction() {
        guard let inURL = inputPDF, !redactions.isEmpty else { return }

        if pendingRedactedTempURL != nil {
            invalidatePendingResult(silent: true)
        }

        isRunning = true
        statusText = "Schwärzung läuft…"
        appendStatus("Schwärzung gestartet.")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionredaction-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            isRunning = false
            statusText = "Fehler: Temp-Ordner"
            appendStatus("Temp-Ordner konnte nicht angelegt werden.")
            appendStatus(error.localizedDescription)
            return
        }

        let tmpOut = tempDir.appendingPathComponent("redacted_tmp.pdf")
        let marks = redactions.map { PDFRedactionService.RedactionMark(pageIndex: $0.pageIndex, rect: $0.rect) }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PDFRedactionService.applyPermanentRedactions(
                    inputPDF: inURL,
                    outputPDF: tmpOut,
                    redactions: marks,
                    options: PDFRedactionService.Options(renderScale: 2.5),
                    progress: { current, total in
                        DispatchQueue.main.async {
                            self.statusText = "Schwärzung läuft… Seite \(current)/\(total)"
                        }
                    },
                    log: { line in
                        DispatchQueue.main.async {
                            self.appendStatus(line)
                        }
                    }
                )

                DispatchQueue.main.async {
                    self.pendingTempDirURL = tempDir
                    self.pendingRedactedTempURL = tmpOut
                    self.previewMode = .redacted
                    self.previewReloadToken = UUID()
                    self.isRunning = false
                    self.statusText = "Schwärzung fertig. Mit Speichern oder Speichern als übernehmen."
                    self.appendStatus("Schwärzung fertig.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.statusText = "Fehler: Schwärzung"
                    self.appendStatus("Schwärzung fehlgeschlagen.")
                    self.appendStatus(error.localizedDescription)
                    self.cleanupPendingArtifacts()
                }
            }
        }
    }

    private func saveInPlace() {
        guard let sourceURL = inputPDF, let tmpOut = pendingRedactedTempURL else { return }

        isSaving = true
        statusText = "Speichern…"
        appendStatus("Speichern gestartet: \(sourceURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileOps.replaceItemAtomically(at: sourceURL, with: tmpOut)

                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusText = "Gespeichert: \(sourceURL.lastPathComponent)"
                    self.appendStatus("Datei atomar ersetzt.")
                    self.redactions.removeAll()
                    self.previewMode = .original
                    self.previewReloadToken = UUID()
                    self.cleanupPendingArtifacts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusText = "Fehler: Speichern"
                    self.appendStatus("Speichern fehlgeschlagen.")
                    self.appendStatus(error.localizedDescription)
                }
            }
        }
    }

    private func saveAs() {
        guard let sourceURL = inputPDF, let tmpOut = pendingRedactedTempURL else { return }

        let suggestedName = suggestedSaveAsName(from: sourceURL)
        guard let saveURL = chooseSaveAsURL(suggestedName: suggestedName, sourceURL: sourceURL) else {
            statusText = "Speichern als abgebrochen"
            appendStatus(statusText)
            return
        }

        isSaving = true
        statusText = "Speichern als…"
        appendStatus("Speichern als gestartet: \(saveURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileOps.copyItemAtomically(from: tmpOut, to: saveURL)

                DispatchQueue.main.async {
                    self.isSaving = false
                    self.inputPDF = saveURL
                    self.statusText = "Gespeichert als: \(saveURL.lastPathComponent)"
                    self.appendStatus("Neue Datei erstellt.")
                    self.redactions.removeAll()
                    self.previewMode = .original
                    self.previewReloadToken = UUID()
                    self.cleanupPendingArtifacts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusText = "Fehler: Speichern als"
                    self.appendStatus("Speichern als fehlgeschlagen.")
                    self.appendStatus(error.localizedDescription)
                }
            }
        }
    }

    private func discardPendingResult() {
        invalidatePendingResult(silent: false)
    }

    private func invalidatePendingResult(silent: Bool) {
        if pendingRedactedTempURL == nil {
            return
        }
        cleanupPendingArtifacts()
        previewMode = .original
        if !silent {
            statusText = "Ungespeicherte Schwärzung verworfen"
            appendStatus(statusText)
        }
    }

    private func cleanupPendingArtifacts() {
        let dir = pendingTempDirURL
        pendingRedactedTempURL = nil
        pendingTempDirURL = nil
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func appendStatus(_ line: String) {
        statusLines.append(line)
        if statusLines.count > 5 {
            statusLines.removeFirst(statusLines.count - 5)
        }
    }

    private func applyRedactionMarks(_ marks: [RedactionMark], status: String) {
        cleanupPendingArtifacts()
        redactions = marks
        previewMode = .original
        statusText = status
        appendStatus(status)
    }

    private func registerRedactionUndo(
        actionName: String,
        undoMarks: [RedactionMark],
        redoMarks: [RedactionMark]
    ) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: UndoActionTarget.shared) { _ in
            self.applyRedactionMarks(undoMarks, status: "Rückgängig: \(actionName)")
            self.registerRedactionUndo(
                actionName: actionName,
                undoMarks: redoMarks,
                redoMarks: undoMarks
            )
            manager.setActionName(actionName)
        }
        manager.setActionName(actionName)
    }

    private func chooseSaveAsURL(suggestedName: String, sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Geschwärzte PDF speichern als"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func suggestedSaveAsName(from sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let base = FileOps.sanitizedBaseName(raw)
        let normalized = base.isEmpty ? "document" : base
        return "\(normalized) redacted.pdf"
    }
}

private struct RedactionPDFPreviewRepresentable: NSViewRepresentable {
    let url: URL?
    let reloadToken: UUID
    let redactions: [RedactionView.RedactionMark]
    let drawEnabled: Bool
    let onCreateRedaction: (_ pageIndex: Int, _ pageRect: CGRect) -> Void
    let onCreateRedactionsFromSelection: (_ marks: [(Int, CGRect)]) -> Void

    final class Coordinator {
        var lastURL: URL?
        var lastReloadToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RedactionDrawingPDFView {
        let view = RedactionDrawingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = AppTheme.pdfCanvasBackground
        view.displayBox = .cropBox
        return view
    }

    func updateNSView(_ nsView: RedactionDrawingPDFView, context: Context) {
        let previousURL = context.coordinator.lastURL
        let didURLChange = previousURL != url
        let didTokenChange = context.coordinator.lastReloadToken != reloadToken
        let needsReload = didURLChange || didTokenChange

        if needsReload {
            let preserveViewport = shouldPreserveViewport(from: previousURL, to: url, didTokenChange: didTokenChange)
            let viewport = preserveViewport ? nsView.captureViewportState() : nil

            context.coordinator.lastURL = url
            context.coordinator.lastReloadToken = reloadToken
            if let url {
                nsView.document = PDFDocument(url: url)
                nsView.autoScales = true
                nsView.setCurrentSelection(nil, animate: false)
                if let viewport {
                    DispatchQueue.main.async {
                        nsView.restoreViewportState(viewport)
                    }
                }
            } else {
                nsView.document = nil
            }
        }

        nsView.drawEnabled = drawEnabled
        nsView.onCreateRedaction = onCreateRedaction
        nsView.onCreateRedactionsFromSelection = onCreateRedactionsFromSelection
        syncPreviewAnnotations(in: nsView, marks: redactions)
    }

    private func shouldPreserveViewport(from previousURL: URL?, to nextURL: URL?, didTokenChange: Bool) -> Bool {
        guard previousURL != nil else { return false }
        if didTokenChange, let previousURL, let nextURL, previousURL == nextURL { return true }
        guard let previousURL, let nextURL else { return false }
        if previousURL == nextURL { return true }

        // Preserve when switching between original and generated redaction preview.
        let tempName = "redacted_tmp.pdf"
        return previousURL.lastPathComponent == tempName || nextURL.lastPathComponent == tempName
    }

    private func syncPreviewAnnotations(in pdfView: RedactionDrawingPDFView, marks: [RedactionView.RedactionMark]) {
        guard let document = pdfView.document else { return }

        let prefix = RedactionDrawingPDFView.previewAnnotationPrefix
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.contents?.hasPrefix(prefix) == true {
                page.removeAnnotation(annotation)
            }
        }

        for mark in marks {
            guard let page = document.page(at: mark.pageIndex) else { continue }
            let bounds = page.bounds(for: pdfView.displayBox)
            let clipped = mark.rect.intersection(bounds)
            if clipped.isNull || clipped.isEmpty { continue }

            let annotation = PDFAnnotation(bounds: clipped, forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 1.5
            annotation.border = border
            annotation.color = NSColor.systemRed.withAlphaComponent(0.95)
            annotation.interiorColor = NSColor.systemRed.withAlphaComponent(0.20)
            annotation.contents = "\(prefix)\(mark.id.uuidString)"
            page.addAnnotation(annotation)
        }
    }
}

private final class RedactionDrawingPDFView: PDFView {
    static let previewAnnotationPrefix = "__vision_redaction_preview__"
    static let draftAnnotationPrefix = "__vision_redaction_draft__"

    var drawEnabled: Bool = false {
        didSet {
            if !drawEnabled {
                clearDragState()
            }
        }
    }

    var onCreateRedaction: ((_ pageIndex: Int, _ pageRect: CGRect) -> Void)?
    var onCreateRedactionsFromSelection: ((_ marks: [(Int, CGRect)]) -> Void)?

    struct ViewportState {
        let pageIndex: Int
        let xRatio: CGFloat
        let yRatio: CGFloat
    }

    private var dragStartViewPoint: CGPoint?
    private var dragCurrentViewPoint: CGPoint?
    private weak var dragPage: PDFPage?
    private var dragPreviewAnnotation: PDFAnnotation?

    override func mouseDown(with event: NSEvent) {
        guard drawEnabled else {
            super.mouseDown(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            clearDragState()
            return
        }

        dragPage = page
        dragStartViewPoint = viewPoint
        dragCurrentViewPoint = viewPoint
        updateDragPreviewAnnotation(with: viewPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawEnabled, dragStartViewPoint != nil else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        dragCurrentViewPoint = current
        updateDragPreviewAnnotation(with: current)
    }

    override func mouseUp(with event: NSEvent) {
        guard drawEnabled else {
            super.mouseUp(with: event)
            createRedactionsFromCurrentSelectionIfNeeded()
            return
        }

        defer {
            clearDragState()
        }

        guard let page = dragPage,
              let startView = dragStartViewPoint
        else { return }

        let endView = convert(event.locationInWindow, from: nil)
        updateDragPreviewAnnotation(with: endView)
        let startPage = convert(startView, to: page)
        let endPage = convert(endView, to: page)

        var pageRect = CGRect(
            x: min(startPage.x, endPage.x),
            y: min(startPage.y, endPage.y),
            width: abs(endPage.x - startPage.x),
            height: abs(endPage.y - startPage.y)
        )

        let pageBounds = page.bounds(for: displayBox)
        pageRect = pageRect.intersection(pageBounds).standardized
        if pageRect.isNull || pageRect.isEmpty || pageRect.width < 2 || pageRect.height < 2 {
            return
        }

        guard let document = document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }

        onCreateRedaction?(pageIndex, pageRect)
    }

    private func createRedactionsFromCurrentSelectionIfNeeded() {
        guard let selection = currentSelection, let document else { return }

        let marks = selectionMarks(from: selection, in: document)
        guard !marks.isEmpty else { return }

        onCreateRedactionsFromSelection?(marks)
        setCurrentSelection(nil, animate: false)
    }

    private func selectionMarks(from selection: PDFSelection, in document: PDFDocument) -> [(Int, CGRect)] {
        uniqueSelectionMarks(lineMarks(from: selection, in: document))
    }

    private func lineMarks(from selection: PDFSelection, in document: PDFDocument) -> [(Int, CGRect)] {
        var marks: [(Int, CGRect)] = []

        for segment in selection.selectionsByLine() {
            for page in segment.pages {
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound else { continue }

                var rect = segment.bounds(for: page).standardized
                rect = rect.intersection(page.bounds(for: displayBox)).standardized
                guard !rect.isNull, !rect.isEmpty, rect.width >= 1, rect.height >= 1 else { continue }

                marks.append((pageIndex, rect))
            }
        }

        if !marks.isEmpty { return marks }

        for page in selection.pages {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }

            var rect = selection.bounds(for: page).standardized
            rect = rect.intersection(page.bounds(for: displayBox)).standardized
            guard !rect.isNull, !rect.isEmpty, rect.width >= 1, rect.height >= 1 else { continue }

            marks.append((pageIndex, rect))
        }

        return marks
    }

    private func uniqueSelectionMarks(_ marks: [(Int, CGRect)], tolerance: CGFloat = 0.5) -> [(Int, CGRect)] {
        var unique: [(Int, CGRect)] = []
        unique.reserveCapacity(marks.count)

        for candidate in marks {
            let isDuplicate = unique.contains { existing in
                existing.0 == candidate.0 && existing.1.approxEquals(candidate.1, tolerance: tolerance)
            }
            if !isDuplicate {
                unique.append(candidate)
            }
        }
        return unique
    }

    private func updateDragPreviewAnnotation(with endViewPoint: CGPoint) {
        guard let page = dragPage,
              let startView = dragStartViewPoint
        else { return }

        let startPage = convert(startView, to: page)
        let endPage = convert(endViewPoint, to: page)

        var pageRect = CGRect(
            x: min(startPage.x, endPage.x),
            y: min(startPage.y, endPage.y),
            width: abs(endPage.x - startPage.x),
            height: abs(endPage.y - startPage.y)
        )
        pageRect = pageRect.intersection(page.bounds(for: displayBox)).standardized

        if pageRect.isNull || pageRect.isEmpty || pageRect.width < 0.5 || pageRect.height < 0.5 {
            removeDragPreviewAnnotation()
            return
        }

        if let existing = dragPreviewAnnotation {
            existing.bounds = pageRect
            return
        }

        let annotation = PDFAnnotation(bounds: pageRect, forType: .square, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        annotation.color = NSColor.systemRed.withAlphaComponent(0.95)
        annotation.interiorColor = NSColor.systemRed.withAlphaComponent(0.22)
        annotation.contents = "\(Self.draftAnnotationPrefix)\(UUID().uuidString)"
        page.addAnnotation(annotation)
        dragPreviewAnnotation = annotation
    }

    private func removeDragPreviewAnnotation() {
        guard let annotation = dragPreviewAnnotation else { return }
        dragPage?.removeAnnotation(annotation)
        dragPreviewAnnotation = nil
    }

    private func clearDragState() {
        removeDragPreviewAnnotation()
        dragPage = nil
        dragStartViewPoint = nil
        dragCurrentViewPoint = nil
    }

    func captureViewportState() -> ViewportState? {
        guard let document else { return nil }

        let viewportRect = self.bounds
        let topLeft = CGPoint(
            x: viewportRect.minX + 1.0,
            y: isFlipped ? (viewportRect.minY + 1.0) : (viewportRect.maxY - 1.0)
        )
        guard let page = page(for: topLeft, nearest: true) else { return nil }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        let pageBounds = page.bounds(for: displayBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let pagePoint = convert(topLeft, to: page)
        let xRatio = min(max((pagePoint.x - pageBounds.minX) / pageBounds.width, 0), 1)
        let yRatio = min(max((pagePoint.y - pageBounds.minY) / pageBounds.height, 0), 1)

        return ViewportState(pageIndex: pageIndex, xRatio: xRatio, yRatio: yRatio)
    }

    func restoreViewportState(_ state: ViewportState) {
        restoreViewportStateOnce(state)
        DispatchQueue.main.async { [weak self] in
            self?.restoreViewportStateOnce(state)
        }
    }

    private func restoreViewportStateOnce(_ state: ViewportState) {
        guard let document,
              let page = document.page(at: state.pageIndex)
        else { return }

        let pageBounds = page.bounds(for: displayBox)
        let point = CGPoint(
            x: pageBounds.minX + pageBounds.width * state.xRatio,
            y: pageBounds.minY + pageBounds.height * state.yRatio
        )
        go(to: PDFDestination(page: page, at: point))
    }
}

private extension CGRect {
    func approxEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance &&
        abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}
