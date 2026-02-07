import SwiftUI
import AppKit
import Vision

struct OCRView: View {

    @State private var inputPDF: URL? = nil
    @State private var outputFolderURL: URL? = nil

    @State private var outputBaseName: String = ""
    @State private var isRunning: Bool = false
    @State private var statusText: String = "Bereit"
    @State private var logText: String = ""

    @State private var lastOCRPDFURL: URL? = nil

    // Overwrite prompt (single-file MVP)
    @State private var showOverwriteAlert: Bool = false
    @State private var pendingOverwritePath: String = ""
    @State private var pendingWork: (() -> Void)? = nil

    private var canRunVisionOCR: Bool {
        guard inputPDF != nil else { return false }
        guard outputFolderURL != nil else { return false }
        guard !FileOps.sanitizedBaseName(outputBaseName).isEmpty else { return false }
        return !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }
                    .disabled(isRunning)

                Spacer()

                Button("OCR-PDF im Finder zeigen") { revealLast() }
                    .disabled(lastOCRPDFURL == nil || isRunning)

                Button("OCR Vision starten") {
                    runVisionOCR()
                }
                .disabled(!canRunVisionOCR)
            }

            Group {
                Text("Input PDF:")
                    .font(.headline)

                Text(inputPDF?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(inputPDF == nil ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output Ordner:")
                        .font(.headline)
                    Spacer()
                    Button("Output Ordner wählen…") { pickOutputFolder() }
                        .disabled(inputPDF == nil || isRunning)
                }

                Text(outputFolderURL?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(outputFolderURL == nil ? .secondary : .primary)

                HStack(spacing: 10) {
                    Text("Output-Dateiname:")
                        .font(.headline)

                    TextField("", text: $outputBaseName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                    Text(".pdf")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Status:")
                    .font(.headline)
                Text(statusText)

                TextEditor(text: $logText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 720)
        .alert("Datei existiert bereits", isPresented: $showOverwriteAlert) {
            Button("Abbrechen", role: .cancel) {
                pendingWork = nil
                pendingOverwritePath = ""
                statusText = "Abgebrochen"
            }
            Button("Ersetzen", role: .destructive) {
                pendingWork?()
                pendingWork = nil
                pendingOverwritePath = ""
            }
        } message: {
            Text("Die Datei existiert bereits:\n\(pendingOverwritePath)\n\nMöchtest du sie ersetzen?")
        }
    }

    // MARK: - UI Actions

    private func pickPDF() {
        guard let selected = FileDialogHelpers.choosePDFs(),
              let first = selected.first
        else {
            statusText = "Keine PDF ausgewählt"
            return
        }

        inputPDF = first

        // Default output folder: parent of selected PDF
        if outputFolderURL == nil {
            outputFolderURL = first.deletingLastPathComponent()
        }

        // Suggested output name: "<Originalname> OCR"
        let base = first.deletingPathExtension().lastPathComponent
        outputBaseName = "\(base) OCR"

        statusText = "PDF gewählt"
    }

    private func pickOutputFolder() {
        guard let folder = FileDialogHelpers.chooseFolder() else { return }
        outputFolderURL = folder
        statusText = "Output-Ordner gesetzt"
    }

    private func revealLast() {
        guard let url = lastOCRPDFURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func runVisionOCR() {
        guard let inURL = inputPDF else { return }
        guard let outFile = outURL() else { return }

        let run = {
            self.isRunning = true
            self.statusText = "OCR läuft…"
            self.logText = ""
            self.logText += "=== Vision OCR ===\n"
            self.lastOCRPDFURL = nil

            // Write to temp first, then move into place on success.
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("visionocr-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                self.isRunning = false
                self.statusText = "Fehler: Temp-Ordner"
                self.logText += "\(error)\n"
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
                        skipPagesWithExistingText: true,
                        enableDeskewPreprocessing: true,
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
                            DispatchQueue.main.async { self.logText += line + "\n" }
                        }
                    )

                    DispatchQueue.main.async {
                        do {
                            if FileManager.default.fileExists(atPath: outFile.path) {
                                try FileManager.default.removeItem(at: outFile)
                            }
                            try FileManager.default.moveItem(at: tmpOut, to: outFile)

                            self.lastOCRPDFURL = outFile
                            self.statusText = "Fertig: \(outFile.lastPathComponent)"
                            self.logText += "Backend: Vision (VNRecognizeTextRequest)\n"
                            self.logText += "Saved to: \(outFile.path)\n"
                        } catch {
                            self.statusText = "Fehler: Output speichern"
                            self.logText += "Could not save output: \(error)\n"
                        }

                        self.isRunning = false
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.statusText = "Fehler: OCR"
                        self.logText += "\(error.localizedDescription)\n"
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                }
            }
        }

        // Ask before overwrite
        if FileManager.default.fileExists(atPath: outFile.path) {
            pendingOverwritePath = outFile.path
            pendingWork = run
            showOverwriteAlert = true
            return
        }

        run()
    }

    private func outURL() -> URL? {
        guard let outFolder = outputFolderURL else { return nil }
        let base = FileOps.sanitizedBaseName(outputBaseName)
        guard !base.isEmpty else { return nil }
        return outFolder
            .appendingPathComponent(base)
            .appendingPathExtension("pdf")
    }
}
