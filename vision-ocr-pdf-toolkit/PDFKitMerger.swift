import Foundation
import PDFKit

enum PDFKitMergeError: Error {
    case unreadableInput(URL)
    case writeFailed(URL)
}

extension PDFKitMergeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadableInput(let url):
            return "PDF konnte nicht geöffnet werden: \(url.lastPathComponent)"
        case .writeFailed(let url):
            return "Merge-Ausgabe konnte nicht geschrieben werden: \(url.lastPathComponent)"
        }
    }
}

struct PDFKitMerger {
    static func merge(
        _ inputs: [URL],
        to outURL: URL,
        isCancelled: (() -> Bool)? = nil,
        onInputMerged: ((Int, Int) -> Void)? = nil
    ) throws {
        let out = PDFDocument()
        var insertIndex = 0

        for (inputIndex, u) in inputs.enumerated() {
            if isCancelled?() == true {
                throw CancellationError()
            }
            guard let doc = PDFDocument(url: u) else { throw PDFKitMergeError.unreadableInput(u) }
            for i in 0..<doc.pageCount {
                if isCancelled?() == true {
                    throw CancellationError()
                }
                if let page = doc.page(at: i) {
                    out.insert(page, at: insertIndex)
                    insertIndex += 1
                }
            }
            onInputMerged?(inputIndex + 1, inputs.count)
        }

        if isCancelled?() == true {
            throw CancellationError()
        }
        if !out.write(to: outURL) { throw PDFKitMergeError.writeFailed(outURL) }
    }
}
