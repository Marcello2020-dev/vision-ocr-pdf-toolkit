import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct MergeView: View {
    // HIER: deinen kompletten bisherigen ContentView-Inhalt rein
    // also alle @State-Variablen, Helper-Funktionen und var body
    //
    // Tipp: In deinem bisherigen ContentView:
    // - alles zwischen "struct ContentView: View {" und der letzten "}" kopieren
    // - hier einfügen und "ContentView" -> "MergeView" umbenennen
    
    @State private var inputPDFs: [URL] = []
    @State private var outputFolderURL: URL? = nil

    @State private var isRunning: Bool = false
    @State private var logText: String = ""
    @State private var statusText: String = "Bereit"

    // Output name prompt
    @State private var outputBaseName: String = "merged"   // without .pdf

    // Selection (for remove)
    @State private var selection: Set<URL> = []

    // Drag state
    @State private var draggedItem: URL? = nil
    
    @State private var bookmarkTitles: [URL: String] = [:]   // URL -> Bookmark-Titel
    
    @State private var lastMergedPDFURL: URL? = nil         // zuletzt erzeugte Merge-PDF
    
    @State private var showOverwriteAlert: Bool = false
    @State private var pendingMove: (() -> Void)? = nil
    @State private var pendingOverwritePath: String = ""
    @State private var pendingCleanupDirURL: URL? = nil

    private func refreshBookmarksFromFilenames(overwrite: Bool) {
        for u in inputPDFs {
            let current = (bookmarkTitles[u] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if overwrite || current.isEmpty {
                bookmarkTitles[u] = BookmarkTitleBuilder.defaultTitle(for: u)
            }
        }
        statusText = overwrite ? "Bookmarks neu gesetzt" : "Bookmarks ergänzt"
    }
    
    private func suggestedOutputBaseName() -> String {
        guard let first = inputPDFs.first else { return "merged" }

        // Dateiname der #1 (ohne Extension) buchstabenlaut identisch übernehmen
        let base = first.deletingPathExtension().lastPathComponent

        // Vorschlag: "<Dateiname> mit Anlagen"
        return "\(base) mit Anlagen"
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
                

                Spacer()
                
                Button("Merge-PDF im Finder zeigen") { openLastMergedPDF() }
                    .disabled(lastMergedPDFURL == nil || isRunning)

                Button("Merge") {
                    runMergeWithBookmarks(outputBaseName: FileOps.sanitizedBaseName(outputBaseName))
                }
                .disabled(
                    inputPDFs.isEmpty ||
                    outputFolderURL == nil ||
                    isRunning ||
                    FileOps.sanitizedBaseName(outputBaseName).isEmpty
                )
                
                .disabled(inputPDFs.isEmpty || outputFolderURL == nil || isRunning || FileOps.sanitizedBaseName(outputBaseName).isEmpty)
            }

            Text("Input (Reihenfolge = Merge-Reihenfolge; Drag & Drop zum Umsortieren):")
                .font(.headline)

            List(selection: $selection) {
                ForEach(Array(inputPDFs.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {

                        // Große, fette, konsistente Nummer (ändert sich automatisch bei Sort/Drag)
                        Text("\(index + 1).")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 42, alignment: .trailing)

                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TextField("Bookmark", text: Binding(
                            get: { bookmarkTitles[url] ?? BookmarkTitleBuilder.defaultTitle(for: url) },
                            set: { bookmarkTitles[url] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                    }
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

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Output Ordner:")
                        .font(.headline)

                    Spacer()

                    Button("Output Ordner wählen…") { pickOutputFolder() }
                        .disabled(inputPDFs.isEmpty || isRunning)
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
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 720)
        .alert("Datei existiert bereits", isPresented: $showOverwriteAlert) {
            Button("Abbrechen", role: .cancel) {
                // Temp aufräumen (sonst bleibt es liegen)
                if let dir = pendingCleanupDirURL {
                    try? FileManager.default.removeItem(at: dir)
                }
                pendingCleanupDirURL = nil

                pendingMove = nil
                pendingOverwritePath = ""
                statusText = "Abgebrochen"
            }
            Button("Ersetzen", role: .destructive) {
                pendingMove?()
                pendingMove = nil
                pendingOverwritePath = ""
                pendingCleanupDirURL = nil
            }
        } message: {
            Text("Die Datei existiert bereits:\n\(pendingOverwritePath)\n\nMöchtest du sie ersetzen?")
        }
        
        .onChange(of: inputPDFs) { _, _ in
            outputBaseName = suggestedOutputBaseName()
        }
    }

    // MARK: - UI Actions
    private func pickPDFs() {
        guard let selected = FileDialogHelpers.choosePDFs(), !selected.isEmpty else {
            statusText = "Keine PDFs ausgewählt"
            return
        }

        // Nur neue PDFs hinzufügen (keine Duplikate)
        let newOnes = selected.filter { !inputPDFs.contains($0) }
        inputPDFs.append(contentsOf: newOnes)

        // Für neue PDFs Default-Bookmarks setzen
        for u in newOnes {
            if bookmarkTitles[u] == nil {
                bookmarkTitles[u] = BookmarkTitleBuilder.defaultTitle(for: u)
            }
        }

        // Output-Ordner nur dann automatisch setzen, wenn noch keiner gewählt ist
        if outputFolderURL == nil {
            outputFolderURL =
                URLUtils.commonParentFolder(of: inputPDFs)
                ?? inputPDFs.first?.deletingLastPathComponent()
        }

        statusText = "PDFs hinzugefügt: \(newOnes.count)"
    }
    
    private func pickOutputFolder() {
        guard let folder = FileDialogHelpers.chooseFolder() else { return }
        outputFolderURL = folder
        statusText = "Output-Ordner gesetzt"
    }
    
    private func openLastMergedPDF() {
        guard let url = lastMergedPDFURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sortByFilename() {
        inputPDFs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        statusText = "Sortiert nach Dateiname"
    }

    private func removeSelected() {
        let toRemove = selection
        inputPDFs.removeAll { toRemove.contains($0) }
        selection.removeAll()
        statusText = "Entfernt: \(toRemove.count)"
    }
    
    private var selectedSingle: URL? {
        selection.count == 1 ? selection.first : nil
    }

    private func moveSelected(to newIndex: Int) {
        guard let sel = selectedSingle,
              let from = inputPDFs.firstIndex(of: sel) else { return }

        let clamped = max(0, min(inputPDFs.count - 1, newIndex))
        guard clamped != from else { return }

        var arr = inputPDFs
        let item = arr.remove(at: from)
        arr.insert(item, at: clamped)

        inputPDFs = arr
        selection = [item]   // Auswahl bleibt erhalten
    }

    private func moveSelectedBy(_ delta: Int) {
        guard let sel = selectedSingle,
              let from = inputPDFs.firstIndex(of: sel) else { return }
        moveSelected(to: from + delta)
    }

    private func moveSelectedToTop() {
        moveSelected(to: 0)
    }

    private func moveSelectedToBottom() {
        moveSelected(to: inputPDFs.count - 1)
    }

    // MARK: - cpdf Merge
    private func runMergeWithBookmarks(outputBaseName: String) {
        guard let baseOutFolder = outputFolderURL else { return }

        // Final output will be placed later (only on success) into baseOutFolder
        // For now we write into temp, so we don't create empty Merge folders.

        isRunning = true
        statusText = "Merge läuft…"
        logText = ""
        
        func saveFinalPDF(from tmpURL: URL, cleanupDir: URL) {
            // Zielpfad: direkt in den gewählten Output-Ordner (kein Merge-Unterordner)
            let outFile = baseOutFolder
                .appendingPathComponent(outputBaseName)
                .appendingPathExtension("pdf")

            let finalizeMove = {
                do {
                    // Wenn die Temp-Datei weg ist: Ziel NICHT anfassen
                    guard FileManager.default.fileExists(atPath: tmpURL.path) else {
                        self.statusText = "Fehler: Output speichern"
                        self.logText += "Temp-Datei nicht gefunden (zu früh gelöscht?): \(tmpURL.path)\n"
                        return
                    }

                    if FileManager.default.fileExists(atPath: outFile.path) {
                        // Atomarer Replace (kein „löschen dann move“)
                        _ = try FileManager.default.replaceItemAt(
                            outFile,
                            withItemAt: tmpURL,
                            backupItemName: nil,
                            options: []
                        )
                    } else {
                        try FileManager.default.moveItem(at: tmpURL, to: outFile)
                    }

                    self.lastMergedPDFURL = outFile
                    self.statusText = "Fertig: \(outFile.lastPathComponent)"
                    self.logText += "Saved to: \(outFile.path)\n"

                    // Temp erst nach erfolgreichem Speichern löschen
                    try? FileManager.default.removeItem(at: cleanupDir)
                } catch {
                    self.statusText = "Fehler: Output speichern"
                    self.logText += "Could not save output: \(error)\n"
                }
            }

            // Existiert schon? -> Nachfragen statt hart überschreiben
            if FileManager.default.fileExists(atPath: outFile.path) {
                pendingOverwritePath = outFile.path
                pendingCleanupDirURL = cleanupDir
                pendingMove = finalizeMove
                showOverwriteAlert = true
                return
            }

            // Sonst normal speichern
            finalizeMove()
        }

        // Resolve cpdf (robust)
        let cpdfPath = CPDFService.defaultCPDFPath
        logText += "Backend: PDFKit (Merge + Outline)\n"

        // 1) Page counts via PDFKit + build bookmark plan
        var starts: [(title: String, startPage: Int)] = []
        var pageCursor = 1

        for url in inputPDFs {
            guard let doc = PDFDocument(url: url) else {
                isRunning = false
                statusText = "Fehler: PDF nicht lesbar"
                logText += "PDFKit konnte nicht öffnen: \(url.path)\n"
                return
            }

            let rawTitle = (bookmarkTitles[url] ?? BookmarkTitleBuilder.defaultTitle(for: url))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? BookmarkTitleBuilder.defaultTitle(for: url) : rawTitle

            starts.append((title: title, startPage: pageCursor))
            pageCursor += doc.pageCount
        }

        // Temp paths
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdfmerge-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            isRunning = false
            statusText = "Fehler: Temp-Ordner"
            logText += "\(error)\n"
            return
        }

        let mergedTmp = tempDir.appendingPathComponent("merged_tmp.pdf")
        let bookmarksTxt = tempDir.appendingPathComponent("bookmarks.txt")
        let finalTmp = tempDir.appendingPathComponent("final_tmp.pdf")

        // Step 1: Merge via PDFKit
        self.logText += "Step 1: merge (PDFKit) -> \(mergedTmp.lastPathComponent)\n"
        do {
            try PDFKitMerger.merge(inputPDFs, to: mergedTmp)
        } catch {
            self.isRunning = false
            self.statusText = "Fehler: Merge (PDFKit)"
            self.logText += "\(error)\n"
            try? FileManager.default.removeItem(at: tempDir)
            return
        }

        // Step 2: Apply bookmarks via PDFKit
        if let mergedDoc = PDFDocument(url: mergedTmp) {
            self.logText += "Step 2: bookmarks (PDFKit) -> \(finalTmp.lastPathComponent)\n"
            PDFKitOutline.applyOutline(to: mergedDoc, starts: starts)
            if mergedDoc.write(to: finalTmp) && PDFKitOutline.validateOutlinePersisted(at: finalTmp, expectedCount: starts.count) {
                // Success: save finalTmp into Output folder
                self.isRunning = false
                saveFinalPDF(from: finalTmp, cleanupDir: tempDir)
                return
                
            } else {
                self.logText += "PDFKit outline not persisted — fallback to cpdf\n"
            }
        } else {
            self.logText += "PDFKit could not reopen mergedTmp for bookmarks. Falling back to cpdf.\n"
        }
        
        // Step 3: Fallback to cpdf add-bookmarks (create bookmarks.txt only now)
        self.logText += "Fallback: cpdf (add-bookmarks) using: \(cpdfPath)\n"
        
        do {
            try CPDFService.writeBookmarksFile(starts: starts, to: bookmarksTxt)
        } catch {
            self.isRunning = false
            self.statusText = "Fehler: Bookmarks-Datei"
            self.logText += "\(error)\n"
            try? FileManager.default.removeItem(at: tempDir)
            return
        }
        
        let addArgs: [String] = [mergedTmp.path, "-add-bookmarks", bookmarksTxt.path, "-o", finalTmp.path]
        
        CPDFService.run(arguments: addArgs, cpdfPath: cpdfPath) { code2, out2, err2 in
            DispatchQueue.main.async {
                if !out2.isEmpty { self.logText += out2 + "\n" }
                if !err2.isEmpty { self.logText += err2 + "\n" }

                self.isRunning = false

                if code2 != 0 {
                    self.statusText = "Fehler: Bookmarks (cpdf \(code2))"
                    // Cleanup (best-effort)
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }

                // Erfolgsfall: finalTmp -> Output/<name>.pdf
                saveFinalPDF(from: finalTmp, cleanupDir: tempDir)
            }
        }
    }
}

