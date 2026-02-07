import Foundation

enum FileOps {
    static func sanitizedBaseName(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.lowercased().hasSuffix(".pdf") {
            out = String(out.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        out = out.components(separatedBy: forbidden).joined(separator: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    static func ensureFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func moveReplacingItem(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            try fm.removeItem(at: to)
        }
        try fm.moveItem(at: from, to: to)
    }

    static func replaceItemAtomically(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } catch {
            try moveReplacingItem(from: source, to: destination)
        }
    }
}
