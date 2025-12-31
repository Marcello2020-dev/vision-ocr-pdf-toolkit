import Foundation
import PDFKit

enum PDFKitMergeError: Error { case unreadableInput(URL); case writeFailed(URL) }

struct PDFKitMerger {
    static func merge(_ inputs: [URL], to outURL: URL) throws {
        let out = PDFDocument()
        var insertIndex = 0

        for u in inputs {
            guard let doc = PDFDocument(url: u) else { throw PDFKitMergeError.unreadableInput(u) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: insertIndex)
                    insertIndex += 1
                }
            }
        }

        if !out.write(to: outURL) { throw PDFKitMergeError.writeFailed(outURL) }
    }
}
