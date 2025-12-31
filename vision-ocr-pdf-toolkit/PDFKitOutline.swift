import Foundation
import PDFKit
import CoreGraphics

struct PDFKitOutline {
    static func applyOutline(to mergedDoc: PDFDocument, starts: [(title: String, startPage: Int)]) {
        let root = PDFOutline()
        root.isOpen = true

        for (idx, s) in starts.enumerated() {
            let item = PDFOutline()
            item.label = s.title
            item.isOpen = true

            let pageIndex = max(0, s.startPage - 1)
            if let page = mergedDoc.page(at: pageIndex) {
                let bounds = page.bounds(for: .mediaBox)
                let top = CGPoint(x: 0, y: bounds.height)
                item.destination = PDFDestination(page: page, at: top)
            }

            root.insertChild(item, at: idx)
        }

        mergedDoc.outlineRoot = root
    }

    static func validateOutlinePersisted(at url: URL, expectedCount: Int) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        guard let root = doc.outlineRoot else { return false }
        return root.numberOfChildren == expectedCount
    }
}
