import Foundation
import PDFKit

struct PDFMergeService {
    static func mergePDFsWithPDFKit(_ inputs: [URL], to outURL: URL) throws {
        let out = PDFDocument()
        for u in inputs {
            guard let doc = PDFDocument(url: u) else {
                throw NSError(domain: "Merge", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDFKit konnte nicht öffnen: \(u.lastPathComponent)"])
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: out.pageCount)
                }
            }
        }
        guard out.write(to: outURL) else {
            throw NSError(domain: "Merge", code: 2, userInfo: [NSLocalizedDescriptionKey: "PDFKit write(to:) fehlgeschlagen"])
        }
    }

    static func applyOutlineWithPDFKit(to doc: PDFDocument, starts: [(title: String, startPage: Int)]) {
        let root = PDFOutline()
        doc.outlineRoot = root

        for s in starts {
            let title = sanitizeBookmarkTitleForPDFKit(s.title)
            let pageIndex = max(0, s.startPage - 1)
            guard let page = doc.page(at: pageIndex) else { continue }

            let item = PDFOutline()
            item.label = title

            let h = page.bounds(for: .mediaBox).height
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: h))

            root.insertChild(item, at: root.numberOfChildren)
        }
    }

    private static func sanitizeBookmarkTitleForPDFKit(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
