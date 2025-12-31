//
//  CPDFService.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 28.12.25.
//


import Foundation

enum CPDFService {

    static let defaultCPDFPath = "/opt/homebrew/bin/cpdf"

    enum CPDFError: Error, LocalizedError {
        case cannotWriteBookmarksFile(URL)

        var errorDescription: String? {
            switch self {
            case .cannotWriteBookmarksFile(let url):
                return "Konnte Bookmarks-Datei nicht schreiben: \(url.path)"
            }
        }
    }

    /// Runs cpdf with arguments. Returns terminationStatus, stdout, stderr.
    static func run(arguments: [String],
                    cpdfPath: String = defaultCPDFPath,
                    completion: @escaping (Int32, String, String) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cpdfPath)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            completion(127, "", "cpdf start failed: \(error)")
            return
        }

        proc.terminationHandler = { p in
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""

            completion(p.terminationStatus, out, err)
        }
    }

    /// Writes a cpdf bookmarks text file (format: level "Title" page open)
    static func writeBookmarksFile(starts: [(title: String, startPage: Int)],
                                   to bookmarksTxt: URL) throws {
        func sanitizeBookmarkTitle(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\"", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []
        lines.reserveCapacity(starts.count)

        for s in starts {
            let title = sanitizeBookmarkTitle(s.title)
            lines.append(#"0 "\#(title)" \#(s.startPage) open"#)
        }

        let content = lines.joined(separator: "\n") + "\n"

        do {
            try content.write(to: bookmarksTxt, atomically: true, encoding: .utf8)
        } catch {
            throw CPDFError.cannotWriteBookmarksFile(bookmarksTxt)
        }
    }
}