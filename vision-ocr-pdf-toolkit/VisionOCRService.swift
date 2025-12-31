//
//  VisionOCRService.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 29.12.25.
//


import Foundation
import PDFKit
import Vision
import CoreGraphics
import CoreText

enum VisionOCRService {

    struct Options {
        var languages: [String] = ["de-DE", "en-US"]
        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var usesLanguageCorrection: Bool = true
        /// Render scale relative to PDF points (72 dpi). 2.0–3.0 is a good practical range.
        var renderScale: CGFloat = 2.0
        /// If true, pages that already contain extractable text are skipped.
        var skipPagesWithExistingText: Bool = true
    }

    enum OCRError: Error, LocalizedError {
        case cannotOpenPDF
        case cannotCreateOutputContext
        case cannotGetPage(Int)
        case cannotRenderPage(Int)

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF: return "PDF konnte nicht geöffnet werden."
            case .cannotCreateOutputContext: return "Output-PDF konnte nicht erzeugt werden."
            case .cannotGetPage(let i): return "PDF-Seite \(i) konnte nicht gelesen werden."
            case .cannotRenderPage(let i): return "PDF-Seite \(i) konnte nicht gerendert werden."
            }
        }
    }

    /// Creates a searchable PDF by drawing original pages and overlaying invisible recognized text.
    static func ocrToSearchablePDF(
        inputPDF: URL,
        outputPDF: URL,
        options: Options = Options(),
        progress: @escaping (_ currentPage: Int, _ totalPages: Int) -> Void,
        log: ((_ line: String) -> Void)? = nil
    ) throws {

        guard let doc = PDFDocument(url: inputPDF) else { throw OCRError.cannotOpenPDF }
        let total = doc.pageCount
        guard total > 0 else { throw OCRError.cannotOpenPDF }

        guard let consumer = CGDataConsumer(url: outputPDF as CFURL) else {
            throw OCRError.cannotCreateOutputContext
        }

        // We create a PDF context with per-page beginPDFPage(mediaBox) calls.
        // Wichtig: nicht "Letter" hardcoden – sonst kann oben/unten Inhalt fehlen.
        guard let firstRef = doc.page(at: 0)?.pageRef else { throw OCRError.cannotGetPage(1) }

        let firstChosen = bestBox(for: firstRef)
        var firstRect = firstRef.getBoxRect(firstChosen)
        if firstRect.isEmpty { firstRect = firstRef.getBoxRect(.cropBox) }
        if firstRect.isEmpty { firstRect = CGRect(x: 0, y: 0, width: 612, height: 792) } // letzter Fallback

        var dummyBox = CGRect(x: 0, y: 0, width: firstRect.width, height: firstRect.height)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &dummyBox, nil) else {
            throw OCRError.cannotCreateOutputContext
        }

        for pageIndex in 0..<total {
            progress(pageIndex + 1, total)

            guard let page = doc.page(at: pageIndex), let cgPage = page.pageRef else {
                throw OCRError.cannotGetPage(pageIndex + 1)
            }

            // Robust: nimm die größte sinnvolle Box (Faxe/Scans haben oft eine "falsche" MediaBox)
            let box: CGPDFBox = bestBox(for: cgPage)
            var pageBox = cgPage.getBoxRect(box)

            // Fallbacks (nur zur Sicherheit)
            if pageBox.isEmpty { pageBox = cgPage.getBoxRect(.cropBox) }
            if pageBox.isEmpty { pageBox = cgPage.getBoxRect(.mediaBox) }

            let mb = cgPage.getBoxRect(.mediaBox)
            let cb = cgPage.getBoxRect(.cropBox)
            log?("Page \(pageIndex + 1): chosen=\(boxName(box)) rotation=\(cgPage.rotationAngle) mediaBox=\(mb) cropBox=\(cb)")
            
            let targetRect = CGRect(x: 0, y: 0, width: pageBox.width, height: pageBox.height)

            // Optional: skip if page already has text
            if options.skipPagesWithExistingText {
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !existing.isEmpty {
                    // Still copy the page into output (no OCR overlay)
                    let pageInfo: [CFString: Any] = [
                        kCGPDFContextMediaBox: targetRect,
                        kCGPDFContextCropBox:  targetRect,
                        kCGPDFContextTrimBox:  targetRect,
                        kCGPDFContextBleedBox: targetRect,
                        kCGPDFContextArtBox:   targetRect
                    ]
                    ctx.beginPDFPage(pageInfo as CFDictionary)
                    drawPDFPage(cgPage, into: ctx, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle)
                    ctx.endPDFPage()
                    continue
                }
            }

            // Render image for OCR
            guard let cgImage = render(page: cgPage, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle, scale: options.renderScale) else {
                throw OCRError.cannotRenderPage(pageIndex + 1)
            }

            // Run Vision OCR
            let observations = try recognizeText(on: cgImage, options: options)

            // Write output page: original content + invisible text
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: targetRect,
                kCGPDFContextCropBox:  targetRect,
                kCGPDFContextTrimBox:  targetRect,
                kCGPDFContextBleedBox: targetRect,
                kCGPDFContextArtBox:   targetRect
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            drawPDFPage(cgPage, into: ctx, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle)
            overlayInvisibleText(observations, in: ctx, targetRect: targetRect, imageSize: CGSize(width: cgImage.width, height: cgImage.height), renderScale: options.renderScale)
            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    // MARK: - Vision

    private static func recognizeText(on image: CGImage, options: Options) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = options.languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return request.results ?? []
    }

    // MARK: - Rendering

    private static func drawPDFPage(_ cgPage: CGPDFPage, into ctx: CGContext, box: CGPDFBox, targetRect: CGRect, rotate: Int32) {
        ctx.saveGState()
        // Use CGPDFPage’s drawing transform to map page space into our targetRect.
        let t = cgPage.getDrawingTransform(box, rect: targetRect, rotate: rotate, preserveAspectRatio: false)
        ctx.concatenate(t)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
    }

    private static func render(page cgPage: CGPDFPage, box: CGPDFBox, targetRect: CGRect, rotate: Int32, scale: CGFloat) -> CGImage? {
        let widthPx  = max(1, Int((targetRect.width  * scale).rounded(.up)))
        let heightPx = max(1, Int((targetRect.height * scale).rounded(.up)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let bm = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        bm.interpolationQuality = .high

        // White background
        bm.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bm.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        // Map PDF into bitmap
        bm.saveGState()
        bm.scaleBy(x: scale, y: scale)
        let t = cgPage.getDrawingTransform(box, rect: targetRect, rotate: rotate, preserveAspectRatio: false)
        bm.concatenate(t)
        bm.drawPDFPage(cgPage)
        bm.restoreGState()

        return bm.makeImage()
    }

    // MARK: - Invisible text overlay

    private static func overlayInvisibleText(
        _ observations: [VNRecognizedTextObservation],
        in ctx: CGContext,
        targetRect: CGRect,
        imageSize: CGSize,
        renderScale: CGFloat
    ) {
        guard !observations.isEmpty else { return }

        ctx.saveGState()

        // Critical: invisible text that remains selectable/searchable.
        ctx.setTextDrawingMode(.invisible)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))

        // Use a stable font; size will be adapted per box.
        let baseFontName = "Helvetica"

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let s = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }

            // Vision boundingBox is normalized to the image.
            let bb = obs.boundingBox

            let rectPx = CGRect(
                x: bb.minX * imageSize.width,
                y: bb.minY * imageSize.height,
                width: bb.width * imageSize.width,
                height: bb.height * imageSize.height
            )

            // Convert pixels -> PDF points (because image was rendered at renderScale)
            let rectPt = CGRect(
                x: rectPx.minX / renderScale,
                y: rectPx.minY / renderScale,
                width: rectPx.width / renderScale,
                height: rectPx.height / renderScale
            )

            // Clamp into page
            let r = rectPt.intersection(targetRect)
            if r.isEmpty { continue }

            // Heuristic font size from box height.
            let fontSize = max(6, min(72, r.height * 0.90))
            let ctFont = CTFontCreateWithName(baseFontName as CFString, fontSize, nil)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: ctFont
            ]
            let attr = NSAttributedString(string: s, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)

            // Baseline approx inside box.
            let baseline = CGPoint(x: r.minX, y: r.minY + (r.height * 0.15))
            ctx.textPosition = baseline
            CTLineDraw(line, ctx)
        }

        ctx.restoreGState()
    }
    
    // MARK: - Box selection (avoid cropping / wrong page size)

    private static func bestBox(for page: CGPDFPage) -> CGPDFBox {
        let candidates: [CGPDFBox] = [.mediaBox, .cropBox, .trimBox, .bleedBox, .artBox]

        var best: (box: CGPDFBox, area: CGFloat) = (.mediaBox, 0)

        for b in candidates {
            let r = page.getBoxRect(b)
            if r.isEmpty { continue }
            let area = abs(r.width * r.height)
            if area > best.area {
                best = (b, area)
            }
        }
        return best.box
    }

    private static func boxName(_ b: CGPDFBox) -> String {
        switch b {
        case .mediaBox: return "mediaBox"
        case .cropBox:  return "cropBox"
        case .trimBox:  return "trimBox"
        case .bleedBox: return "bleedBox"
        case .artBox:   return "artBox"
        @unknown default: return "unknown"
        }
    }
    
}
