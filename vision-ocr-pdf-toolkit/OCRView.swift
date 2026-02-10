import SwiftUI
import AppKit
import Vision
import PDFKit
import UniformTypeIdentifiers

struct OCRView: View {

    private enum PreviewMode: String, CaseIterable, Identifiable {
        case original
        case ocr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return "Original"
            case .ocr: return "OCR-Vorschau"
            }
        }
    }

    @State private var inputPDF: URL? = nil

    @State private var isRunning: Bool = false
    @State private var isSaving: Bool = false
    @State private var statusText: String = "Bereit"
    @State private var diagnosticsLog: String = ""

    @State private var lastSavedPDFURL: URL? = nil
    @State private var pendingOCRTempURL: URL? = nil
    @State private var pendingTempDirURL: URL? = nil
    @State private var previewMode: PreviewMode = .original
    @State private var previewReloadToken: UUID = UUID()

    private var canRunVisionOCR: Bool {
        inputPDF != nil && !isRunning && !isSaving
    }

    private var canSave: Bool {
        inputPDF != nil && pendingOCRTempURL != nil && !isRunning && !isSaving
    }

    private var canDiscard: Bool {
        pendingOCRTempURL != nil && !isRunning && !isSaving
    }

    private var previewURL: URL? {
        switch previewMode {
        case .original:
            return inputPDF
        case .ocr:
            return pendingOCRTempURL ?? inputPDF
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }
                    .disabled(isRunning || isSaving)

                Spacer()

                Button("PDF im Finder zeigen") { revealCurrent() }
                    .disabled(inputPDF == nil || isRunning || isSaving)

                Button("OCR Vision starten") {
                    runVisionOCR()
                }
                .disabled(!canRunVisionOCR)

                Button("Speichern") {
                    saveInPlace()
                }
                .disabled(!canSave)

                Button("Speichern als…") {
                    saveAs()
                }
                .disabled(!canSave)

                Button("Verwerfen") {
                    discardPendingOCR()
                }
                .disabled(!canDiscard)
            }

            Group {
                Text("Input PDF:")
                    .font(.headline)

                Text(inputPDF?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(inputPDF == nil ? .secondary : .primary)
            }

            HStack(spacing: 12) {
                Text("Vorschau:")
                    .font(.headline)

                Picker("Vorschau", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .disabled(inputPDF == nil)

                Spacer()
            }

            PDFPreviewRepresentable(url: previewURL, reloadToken: previewReloadToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if previewMode == .ocr && pendingOCRTempURL == nil {
                Text("Noch keine OCR-Vorschau vorhanden. Starte zuerst OCR.")
                    .foregroundStyle(.secondary)
            }

            Text(pendingOCRTempURL == nil ? "Keine ungespeicherten OCR-Änderungen." : "Ungespeicherte OCR-Änderungen vorhanden.")
                .foregroundStyle(pendingOCRTempURL == nil ? .secondary : .primary)

            HStack(spacing: 10) {
                Text("Status: \(statusText)")
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                Button("Diagnoselog kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsLog, forType: .string)
                    appendStatus("Diagnoselog in Zwischenablage kopiert.")
                }
                .disabled(diagnosticsLog.isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 900, minHeight: 760, maxHeight: .infinity)
        .background(AppTheme.panelGradient.ignoresSafeArea())
    }

    // MARK: - UI Actions

    private func pickPDF() {
        guard let selected = FileDialogHelpers.choosePDFs(),
              let first = selected.first
        else {
            statusText = "Keine PDF ausgewählt"
            appendStatus("Keine PDF ausgewählt.")
            return
        }

        if pendingOCRTempURL != nil {
            discardPendingOCR(silent: true)
            appendStatus("Ungespeicherte OCR-Änderungen wurden verworfen.")
        }

        inputPDF = first
        lastSavedPDFURL = nil
        previewMode = .original
        previewReloadToken = UUID()
        statusText = "PDF gewählt"
        appendStatus("PDF gewählt: \(first.lastPathComponent)")
    }

    private func revealCurrent() {
        guard let url = inputPDF ?? lastSavedPDFURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func runVisionOCR() {
        guard let inURL = inputPDF else { return }

        if pendingOCRTempURL != nil {
            discardPendingOCR(silent: true)
        }

        isRunning = true
        statusText = "OCR läuft…"
        diagnosticsLog = "=== Vision OCR ===\n"
        appendStatus("OCR gestartet.")
        lastSavedPDFURL = nil

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionocr-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            isRunning = false
            statusText = "Fehler: Temp-Ordner"
            appendStatus("Temp-Ordner konnte nicht angelegt werden.")
            diagnosticsLog += "\(error)\n"
            return
        }

        let tmpOut = tempDir.appendingPathComponent("ocr_tmp.pdf")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let opts = VisionOCRService.Options(
                    languages: ["de-DE", "en-US"],
                    recognitionLevel: .accurate,
                    usesLanguageCorrection: true,
                    renderScale: 3.0,
                    skipPagesWithExistingText: false,
                    replaceExistingTextLayer: true,
                    debugBandAngleEstimation: false,
                    bandAngleBandCount: 20
                )

                try VisionOCRService.ocrToSearchablePDF(
                    inputPDF: inURL,
                    outputPDF: tmpOut,
                    options: opts,
                    progress: { cur, total in
                        DispatchQueue.main.async { self.statusText = "OCR läuft… Seite \(cur)/\(total)" }
                    },
                    log: { line in
                        DispatchQueue.main.async { self.diagnosticsLog += line + "\n" }
                    }
                )

                DispatchQueue.main.async {
                    self.pendingOCRTempURL = tmpOut
                    self.pendingTempDirURL = tempDir
                    self.previewMode = .ocr
                    self.previewReloadToken = UUID()
                    self.isRunning = false
                    self.statusText = "OCR fertig. Mit Speichern oder Speichern als übernehmen."
                    self.appendStatus("OCR fertig. Änderungen sind noch nicht gespeichert.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.statusText = "Fehler: OCR"
                    self.appendStatus("OCR fehlgeschlagen.")
                    self.diagnosticsLog += "\(error.localizedDescription)\n"
                    self.cleanupTempArtifacts()
                }
            }
        }
    }

    private func saveInPlace() {
        guard let inURL = inputPDF,
              let tmpOut = pendingOCRTempURL else { return }

        isSaving = true
        statusText = "Speichern…"
        appendStatus("Speichern gestartet: \(inURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileOps.replaceItemAtomically(at: inURL, with: tmpOut)

                DispatchQueue.main.async {
                    self.isSaving = false
                    self.lastSavedPDFURL = inURL
                    self.previewMode = .original
                    self.previewReloadToken = UUID()
                    self.statusText = "Gespeichert: \(inURL.lastPathComponent)"
                    self.appendStatus("Originaldatei aktualisiert.")
                    self.cleanupTempArtifacts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusText = "Fehler: Speichern"
                    self.appendStatus("Speichern fehlgeschlagen.")
                    self.diagnosticsLog += "Could not save output: \(error)\n"
                }
            }
        }
    }

    private func saveAs() {
        guard let inURL = inputPDF,
              let tmpOut = pendingOCRTempURL else { return }

        let suggestedName = suggestedSaveAsName(from: inURL)
        guard let saveURL = chooseSaveAsURL(suggestedName: suggestedName, sourceURL: inURL) else {
            statusText = "Speichern als abgebrochen"
            appendStatus("Speichern als abgebrochen.")
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
                    self.lastSavedPDFURL = saveURL
                    self.previewMode = .original
                    self.previewReloadToken = UUID()
                    self.statusText = "Gespeichert als: \(saveURL.lastPathComponent)"
                    self.appendStatus("Neue Datei erstellt.")
                    self.cleanupTempArtifacts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.statusText = "Fehler: Speichern als"
                    self.appendStatus("Speichern als fehlgeschlagen.")
                    self.diagnosticsLog += "Could not save output as new file: \(error)\n"
                }
            }
        }
    }

    private func discardPendingOCR(silent: Bool = false) {
        cleanupTempArtifacts()
        if !silent {
            statusText = "Ungespeicherte OCR-Änderungen verworfen"
            appendStatus("Ungespeicherte OCR-Änderungen verworfen.")
        }
    }

    private func cleanupTempArtifacts() {
        let tempDir = pendingTempDirURL
        pendingOCRTempURL = nil
        pendingTempDirURL = nil
        previewReloadToken = UUID()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func appendStatus(_ line: String) {
        diagnosticsLog += "[status] \(line)\n"
    }

    private func chooseSaveAsURL(suggestedName: String, sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "OCR-PDF speichern als"
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
        return "\(normalized) OCR.pdf"
    }
}

private struct PDFPreviewRepresentable: NSViewRepresentable {
    let url: URL?
    let reloadToken: UUID

    final class Coordinator {
        var lastURL: URL?
        var lastReloadToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = AppTheme.pdfCanvasBackground
        if #available(macOS 13.0, *) {
            // Keep preview interaction focused on navigation/zoom, not text selection heuristics.
            view.isInMarkupMode = true
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        let needsReload = context.coordinator.lastURL != url ||
            context.coordinator.lastReloadToken != reloadToken

        guard needsReload else { return }
        context.coordinator.lastURL = url
        context.coordinator.lastReloadToken = reloadToken

        guard let url else {
            nsView.document = nil
            return
        }

        nsView.document = PDFDocument(url: url)
        nsView.autoScales = true
        nsView.setCurrentSelection(nil, animate: false)
    }
}
