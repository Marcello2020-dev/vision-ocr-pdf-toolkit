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
    
    @State private var ocrmypdfAvailable: Bool = false
    
    @State private var afterVision: (() -> Void)? = nil
    
    private var canRunOCREngineCommon: Bool {
        guard inputPDF != nil else { return false }
        guard outputFolderURL != nil else { return false }
        return !isRunning && !FileOps.sanitizedBaseName(outputBaseName).isEmpty
    }

    private var canRunOCRMyPDF: Bool {
        canRunOCREngineCommon && ocrmypdfAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }
                    .disabled(isRunning)

                Spacer()

                Button("OCR-PDF im Finder zeigen") { revealLast() }
                    .disabled(lastOCRPDFURL == nil || isRunning)

                Button("OCR VisionKit starten") {
                    logText = ""
                    logText += "=== Vision OCR ===\n"
                    logText += "ocrmypdf available: \(ocrmypdfAvailable) (\(OCRMyPDFService.defaultPath))\n\n"
                    startOCR()
                }                .disabled(inputPDF == nil || outputFolderURL == nil || isRunning || FileOps.sanitizedBaseName(outputBaseName).isEmpty)
                
                Button("OCR ocrmypdf starten") {
                    logText = ""
                    logText += "=== OCRmyPDF (Tesseract) ===\n"
                    runOCRMyPDF()
                }
                .disabled(!canRunOCRMyPDF)
                
                Button("OCR beide starten") {
                    logText = ""
                    logText += "=== OCR beide starten ===\n"
                    logText += "ocrmypdf available: \(ocrmypdfAvailable) (\(OCRMyPDFService.defaultPath))\n\n"

                    // Kette: nach Vision automatisch OCRmyPDF starten
                    afterVision = {
                        self.logText += "\n=== OCRmyPDF (2/2) ===\n"
                        self.runOCRMyPDF()
                    }

                    logText += "=== Vision (1/2) ===\n"
                    runBothOCR()
                }
                .disabled(!canRunOCREngineCommon)
                
                Button("Deskew → Vision") {
                    logText = ""
                    logText += "=== Deskew → Vision (OCRmyPDF ohne OCR, dann Vision Textlayer) ===\n"
                    logText += "ocrmypdf available: \(ocrmypdfAvailable) (\(OCRMyPDFService.defaultPath))\n\n"
                    runDeskewThenVision()
                }
                .disabled(!canRunOCRMyPDF)
                
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
        .onAppear {
            let available = OCRMyPDFService.isAvailable
            ocrmypdfAvailable = available
            logText += "ocrmypdf available: \(available) (\(OCRMyPDFService.defaultPath))\n"
        }
        .alert("Datei existiert bereits", isPresented: $showOverwriteAlert) {
            Button("Abbrechen", role: .cancel) {
                pendingWork = nil
                pendingOverwritePath = ""
                afterVision = nil          // <-- wichtig: "beide" Kette stoppen
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

    private func startOCR() {
        guard let inURL = inputPDF, outputFolderURL != nil else { return }
        guard let outFile = outURL(forEngineSuffix: "(Vision)") else { return }

        let run = {
            self.isRunning = true
            self.statusText = "OCR läuft…"
            // Header kommt vom Button (pro Run)
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
                        renderScale: 2.0,
                        skipPagesWithExistingText: true
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

                        // Falls "beide" aktiv: jetzt OCRmyPDF starten
                        let cont = self.afterVision
                        self.afterVision = nil
                        cont?()
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
    
    private func runOCRMyPDF() {
        guard let inputURL = inputPDF else { return }
        guard let finalOutURL = outURL(forEngineSuffix: "(OCRmyPDF)") else { return }

        let run = {
            self.isRunning = true
            self.statusText = "OCR läuft… (OCRmyPDF)"
            self.lastOCRPDFURL = nil

            // Temp first → dann ins Ziel verschieben
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ocrmypdf-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                self.isRunning = false
                self.statusText = "Fehler: Temp-Ordner"
                self.logText += "\(error)\n"
                return
            }

            let tmpOut = tempDir.appendingPathComponent("ocr_tmp.pdf")

            self.logText += "Backend: OCRmyPDF\n"
            self.logText += "Input: \(inputURL.path)\n"
            self.logText += "Temp: \(tmpOut.path)\n"
            self.logText += "Output: \(finalOutURL.path)\n"
            self.logText += "ocrmypdf: \(OCRMyPDFService.defaultPath)\n"

            // Argumente: deutsch+englisch; skip-text = überspringt Seiten mit vorhandenem Textlayer
            // Optional: --force-ocr erzwingt OCR auch bei vorhandenem Text (zum Vergleichen ggf. interessant)
            let args: [String] = [
                "--skip-text",
                "--deskew",
                "-l", "deu+eng",
                inputURL.path,
                tmpOut.path
            ]

            self.logText += "Args: \(args.joined(separator: " "))\n"
            
            OCRMyPDFService.run(arguments: args) { code, out, err in
                DispatchQueue.main.async {
                    if !out.isEmpty { self.logText += out + "\n" }
                    if !err.isEmpty { self.logText += err + "\n" }

                    if code != 0 {
                        self.isRunning = false
                        self.statusText = "Fehler: OCRmyPDF (Exit \(code))"
                        try? FileManager.default.removeItem(at: tempDir)
                        return
                    }

                    do {
                        if FileManager.default.fileExists(atPath: finalOutURL.path) {
                            try FileManager.default.removeItem(at: finalOutURL)
                        }
                        try FileManager.default.moveItem(at: tmpOut, to: finalOutURL)

                        self.lastOCRPDFURL = finalOutURL
                        self.statusText = "Fertig: \(finalOutURL.lastPathComponent)"
                        self.logText += "Saved to: \(finalOutURL.path)\n"
                    } catch {
                        self.statusText = "Fehler: Output speichern"
                        self.logText += "Could not save output: \(error)\n"
                    }

                    self.isRunning = false
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }
        }

        if FileManager.default.fileExists(atPath: finalOutURL.path) {
            pendingOverwritePath = finalOutURL.path
            pendingWork = run
            showOverwriteAlert = true
            return
        }

        run()
    }
    
    private func runDeskewThenVision() {
        guard let inputURL = inputPDF else { return }
        guard let outFile = outURL(forEngineSuffix: "(Vision+Deskew)") else { return }

        let run = {
            self.isRunning = true
            self.lastOCRPDFURL = nil
            self.statusText = "Deskew läuft… (OCRmyPDF)"

            // Temp dir für beide Schritte
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("deskew-vision-\(UUID().uuidString)", isDirectory: true)

            func cleanup() {
                try? FileManager.default.removeItem(at: tempDir)
            }

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                self.isRunning = false
                self.statusText = "Fehler: Temp-Ordner"
                self.logText += "\(error)\n"
                return
            }

            let tmpDeskewPDF = tempDir.appendingPathComponent("deskew.pdf")
            let tmpVisionOut = tempDir.appendingPathComponent("vision.pdf")

            self.logText += "Backend 1/2: OCRmyPDF (Deskew-only, kein OCR)\n"
            self.logText += "Input: \(inputURL.path)\n"
            self.logText += "Temp deskew: \(tmpDeskewPDF.path)\n"
            self.logText += "Final: \(outFile.path)\n"
            self.logText += "ocrmypdf: \(OCRMyPDFService.defaultPath)\n\n"

            // OCRmyPDF: nur Vorverarbeitung (Deskew/Rotate), KEIN Textlayer:
            // tesseract-timeout=0 -> kein OCR-Lauf
            let argsDeskewOnly: [String] = [
                "--output-type", "pdf",
                "--tesseract-timeout=0",
                "--rotate-pages",
                "--deskew",
                inputURL.path,
                tmpDeskewPDF.path
            ]

            OCRMyPDFService.run(arguments: argsDeskewOnly) { code, out, err in
                DispatchQueue.main.async {
                    if !out.isEmpty { self.logText += out + "\n" }
                    if !err.isEmpty { self.logText += err + "\n" }

                    if code != 0 {
                        self.isRunning = false
                        self.statusText = "Fehler: Deskew (Exit \(code))"
                        cleanup()
                        return
                    }

                    self.logText += "\nBackend 2/2: Vision (Textlayer)\n"
                    self.statusText = "OCR läuft… (Vision)"
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let opts = VisionOCRService.Options(
                            languages: ["de-DE", "en-US"],
                            recognitionLevel: .accurate,
                            usesLanguageCorrection: true,
                            renderScale: 2.0,
                            skipPagesWithExistingText: true
                        )

                        try VisionOCRService.ocrToSearchablePDF(
                            inputPDF: tmpDeskewPDF,
                            outputPDF: tmpVisionOut,
                            options: opts,
                            progress: { cur, total in
                                DispatchQueue.main.async {
                                    self.statusText = "OCR läuft… (Vision) Seite \(cur)/\(total)"
                                }
                            },
                            log: { line in
                                DispatchQueue.main.async {
                                    self.logText += line + "\n"
                                }
                            }
                        )

                        DispatchQueue.main.async {
                            do {
                                if FileManager.default.fileExists(atPath: outFile.path) {
                                    try FileManager.default.removeItem(at: outFile)
                                }
                                try FileManager.default.moveItem(at: tmpVisionOut, to: outFile)

                                self.lastOCRPDFURL = outFile
                                self.statusText = "Fertig: \(outFile.lastPathComponent)"
                                self.logText += "Saved to: \(outFile.path)\n"
                            } catch {
                                self.statusText = "Fehler: Output speichern"
                                self.logText += "Could not save output: \(error)\n"
                            }

                            self.isRunning = false
                            cleanup()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.isRunning = false
                            self.statusText = "Fehler: Vision OCR"
                            self.logText += "\(error.localizedDescription)\n"
                            cleanup()
                        }
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
    
    private func runBothOCR() {
        guard canRunOCREngineCommon else { return }

        // Wenn OCRmyPDF nicht verfügbar ist, trotzdem Vision laufen lassen.
        if !ocrmypdfAvailable {
            logText += "\nHinweis: OCRmyPDF nicht verfügbar – starte nur Vision.\n"
            startOCR()
            return
        }

        // Kette: nach Vision automatisch OCRmyPDF starten
        afterVision = {
            self.logText += "\n=== OCRmyPDF (2/2) ===\n"
            self.runOCRMyPDF()
        }

        logText += "\n=== Vision OCR (1/2) ===\n"
        startOCR()
    }
    
    private func baseForOCR() -> String {
        // Nimm den User-Text als Basis, aber sanitize
        FileOps.sanitizedBaseName(outputBaseName)
    }

    private func outURL(forEngineSuffix suffix: String) -> URL? {
        guard let outFolder = outputFolderURL else { return nil }
        let base = baseForOCR()
        guard !base.isEmpty else { return nil }
        return outFolder
            .appendingPathComponent("\(base) \(suffix)")
            .appendingPathExtension("pdf")
    }
}
