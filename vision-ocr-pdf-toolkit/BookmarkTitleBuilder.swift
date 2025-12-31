import Foundation

struct BookmarkTitleBuilder {
    static func defaultTitle(for url: URL) -> String {
        var s = url.deletingPathExtension().lastPathComponent

        if let t = bookmarkTitleFromDocFilename(s) {
            return t
        }

        if let r = s.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        s = s.replacingOccurrences(of: "_", with: " ")

        let hyphenCount = s.filter { $0 == "-" }.count
        let spaceCount  = s.filter { $0 == " " }.count

        if hyphenCount >= 2 && spaceCount == 0 {
            s = s.replacingOccurrences(of: "-", with: " ")
        } else if hyphenCount >= 4 && hyphenCount > spaceCount {
            s = s.replacingOccurrences(of: "-", with: " ")
        }

        s = s.replacingOccurrences(
            of: #"^\s*(?:\d{4}[ ._-]?\d{2}[ ._-]?\d{2}|\d{8})(?:[ T._-]?\d{2}[ ._-]?\d{2}(?:[ ._-]?\d{2})?)?\s+"#,
            with: "",
            options: .regularExpression
        )

        s = s.replacingOccurrences(
            of: #"^\s*\d{2}[ ._-]\d{2}[ ._-]\d{4}\s+"#,
            with: "",
            options: .regularExpression
        )

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return s.isEmpty ? "Dokument" : s
    }

    private static func bookmarkTitleFromDocFilename(_ base: String) -> String? {
        let pattern = #"^doc\d{6}(\d{14})$"#

        guard let r = base.range(of: pattern, options: .regularExpression) else { return nil }
        let ts = String(base[r]).replacingOccurrences(of: #"^doc\d{6}"#, with: "", options: .regularExpression)

        guard ts.count == 14 else { return nil }

        let yyyy = ts.prefix(4)
        let mm   = ts.dropFirst(4).prefix(2)
        let dd   = ts.dropFirst(6).prefix(2)
        let hh   = ts.dropFirst(8).prefix(2)
        let min  = ts.dropFirst(10).prefix(2)
        let ss   = ts.dropFirst(12).prefix(2)

        return "Dokument \(dd).\(mm).\(yyyy) \(hh):\(min):\(ss)"
    }
}
