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
import CoreImage
import Accelerate
import ImageIO
import UniformTypeIdentifiers

enum VisionOCRService {

    struct Options {
        var languages: [String] = ["de-DE", "en-US"]
        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var usesLanguageCorrection: Bool = true
        var renderScale: CGFloat = 2.0
        var skipPagesWithExistingText: Bool = true
        var enableDeskewPreprocessing: Bool = true

        // NEU:
        /// Unterhalb dieser Schwelle wird nicht gedreht. Default 0.0 = keine Deadzone.
        var minDeskewDegrees: Double = 0.0
        /// Schutzgrenze gegen völlig absurde Schätzungen.
        var maxDeskewDegrees: Double = 30.0

        // Debug / Prototyping: bandbasierte Winkelmessung (nur Logging, noch keine Anwendung)
        /// Wenn true: Seite wird in Bänder zerlegt und pro Band wird ein Deskew-Winkel (Grad) aus dem Bildsignal geschätzt
        /// (Radon-ähnlicher Score). Dient zum Debuggen/Validieren der neuen Architektur.
        var debugBandAngleEstimation: Bool = false

        /// Anzahl Bänder (z. B. 20).
        var bandAngleBandCount: Int = 20

        /// Suchbereich in Grad (z. B. -8..+8).
        var bandAngleSearchRangeDegrees: ClosedRange<Double> = (-8.0)...(8.0)

        /// Schrittweite in Grad.
        var bandAngleStepDegrees: Double = 0.25

        /// Downscale-Breite für die Messung (Performance).
        var bandAngleDownscaleMaxWidth: Int = 900

        /// Pixel gilt als „Ink“, wenn Grauwert < threshold (0..255). Wenn threshold == 0 wird Otsu verwendet.
        var bandAngleInkThreshold: UInt8 = 220

        /// Mindestanzahl Ink-Samples pro Band, sonst „empty“ (carry last).
        var bandAngleMinInkSamples: Int = 250

        /// Sampling-Strides für Ink-Zählung (z. B. 2 => jeden 2. Pixel). Ink-Minimum wird intern auf volle Auflösung hochgerechnet.
        var bandAngleSampleStride: Int = 2

        // Debug: Band-Images export (zum visuellen Prüfen der Band-Slices)
        /// Wenn true: schreibt pro Page/Band Debug-PNGs (raw + optional binarized) in ein Verzeichnis.
        var debugBandImageExport: Bool = false

        /// Zielverzeichnis für Debug-PNGs. Wenn nil: wird ein Temp-Ordner erzeugt.
        var debugBandImageExportDirectory: URL? = nil

        /// Wenn true: exportiert zusätzlich das binarisierte Band (ink==255, background==0).
        var debugBandImageExportIncludeBinarized: Bool = true

        /// Wenn true: exportiert das rohe Band (Crop aus dem downscaled Work-Image).
        var debugBandImageExportIncludeRaw: Bool = true

        /// Wenn true: schreibt Band-Infos (Page/Band, y-Range, ink≈, Winkel, Score) als Overlay direkt ins exportierte PNG.
        var debugBandImageExportAnnotateAngle: Bool = true

        // Band-Median Fallback für globalen Skew (wenn Projection nahe 0° bleibt)
        /// Wenn true: Nutzt Band-Median als Fallback, wenn die globale Projection-Schätzung nahe 0° ist.
        var useBandMedianFallbackForSkew: Bool = true

        /// Projection gilt als „nahe 0°“, wenn |proj| <= dieser Schwelle (Grad).
        var bandMedianFallbackIfAbsProjectionBelowDegrees: Double = 0.25

        /// Band-Median wird nur genommen, wenn |median| >= dieser Schwelle (Grad).
        var bandMedianFallbackMinAbsDegrees: Double = 0.5

        /// Outlier-Filter: Bandwinkel, die weiter als diese Abweichung (Grad) vom Median liegen, werden verworfen.
        var bandMedianFallbackOutlierMaxDeviationDegrees: Double = 2.0

        /// Mindestanzahl nicht-leerer Bänder für einen stabilen Median.
        var bandMedianFallbackMinNonEmptyBands: Int = 4
    }
    
    private struct OCRBox {
        let text: String
        // Vision-normalized Quad (origin bottom-left)
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
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
        /// Base directory for debug artifacts (band PNGs etc.).
        /// If nil, we try to choose a stable directory automatically.
        artifactsBaseDirectory: URL? = nil,
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

        var effectiveOptions = options
        let debugBandContext: (dir: URL, pdfBaseName: String)? = {
            guard effectiveOptions.debugBandAngleEstimation else { return nil }

            let outDir = outputPDF.deletingLastPathComponent()
            let pdfBaseName: String
            if isProbablyTemporaryDirectory(outDir) {
                pdfBaseName = inputPDF.deletingPathExtension().lastPathComponent
            } else {
                pdfBaseName = outputPDF.deletingPathExtension().lastPathComponent
            }

            // Pick a stable base directory for debug artifacts.
            let artifactsBase: URL
            if let base = artifactsBaseDirectory {
                artifactsBase = base
            } else if isProbablyTemporaryDirectory(outDir) {
                artifactsBase = inputPDF.deletingLastPathComponent()
                log?("band-export: outputPDF is in a temp directory; using inputPDF folder for artifacts: \(artifactsBase.path)")
            } else {
                artifactsBase = outDir
            }

            let debugBandBaseDir = artifactsBase.appendingPathComponent("Bandbilder", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: debugBandBaseDir, withIntermediateDirectories: true)
                log?("band-export: writing PNGs to \(debugBandBaseDir.path)")
            } catch {
                log?("band-export: FAILED to create dir: \(debugBandBaseDir.path) -> \(error)")
            }
            return (debugBandBaseDir, pdfBaseName)
        }()

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
            if effectiveOptions.skipPagesWithExistingText {
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
            guard let cgImage = render(page: cgPage, box: box, targetRect: targetRect, rotate: cgPage.rotationAngle, scale: effectiveOptions.renderScale) else {
                throw OCRError.cannotRenderPage(pageIndex + 1)
            }

            // Optional: band-based measurement for diagnostics.
            if effectiveOptions.debugBandAngleEstimation, let debugBandContext {
                log?(String(
                    format: "[Page %d] Band-Angles (Top→Bottom) – bands=%d, search=%.2f°..%.2f°, step=%.2f°, downscaleW=%d",
                    pageIndex + 1,
                    effectiveOptions.bandAngleBandCount,
                    effectiveOptions.bandAngleSearchRangeDegrees.lowerBound,
                    effectiveOptions.bandAngleSearchRangeDegrees.upperBound,
                    effectiveOptions.bandAngleStepDegrees,
                    effectiveOptions.bandAngleDownscaleMaxWidth
                ))

                let angles = Self.measureDeskewAnglesByBands(
                    cgImage: cgImage,
                    options: effectiveOptions,
                    pageNumber: pageIndex + 1,
                    exportDirectory: debugBandContext.dir,
                    pdfBaseName: debugBandContext.pdfBaseName,
                    logger: log
                )

                for (i, a) in angles.enumerated() {
                    log?(String(format: "  band %02d: %.3f°", i + 1, a))
                }
            }

            // 1) optional deskew für OCR (Original-PDF bleibt unverändert)
            let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
            let (ocrImage, appliedSkew): (CGImage, CGFloat)
            if effectiveOptions.enableDeskewPreprocessing {
                (ocrImage, appliedSkew) = Self.deskewForOCRIfNeeded(
                    cgImage: cgImage,
                    options: effectiveOptions,
                    logger: { line in log?("Page \(pageIndex + 1) skew: \(line)") }
                )
            } else {
                log?("Page \(pageIndex + 1) skew: disabled (enableDeskewPreprocessing=false)")
                (ocrImage, appliedSkew) = (cgImage, 0)
            }

            // 2) OCR genau einmal ausführen
            let observations = try recognizeText(on: ocrImage, options: effectiveOptions)

            // Vision can occasionally return axis-aligned quads even on skewed pages.
            // If no deskew was applied, we recover line tilt from a robust global estimate
            // and use it as fallback for those axis-aligned boxes only.
            let axisAlignedFallbackAngle: CGFloat = {
                guard appliedSkew == 0 else { return 0 }
                guard let estimated = Self.estimateSkewAngleRadians(
                    cgImage: ocrImage,
                    options: effectiveOptions,
                    logger: nil
                ) else { return 0 }

                let deg = Double(estimated * 180.0 / .pi)
                guard abs(deg) >= 0.25 else { return 0 }
                log?(String(format: "Page %d skew: overlay fallback for axis-aligned boxes = %.3f°", pageIndex + 1, deg))
                return estimated
            }()

            // 3) Beobachtungen -> OCRBox (Quad am Ende immer bezogen aufs ORIGINALBILD)
            let boxes: [OCRBox] = observations.compactMap { obs in
                guard let best = obs.topCandidates(1).first else { return nil }

                // Versuche ein rotierbares Quad aus VNRecognizedText zu holen (Preview-Pfad)
                let fullRange = best.string.startIndex..<best.string.endIndex
                let rectObs: VNRectangleObservation? = (try? best.boundingBox(for: fullRange))

                // Fallback: axis-aligned bbox -> Quad daraus bauen
                func quadFromAxisAligned(_ bb: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
                    let tl = CGPoint(x: bb.minX, y: bb.maxY)
                    let tr = CGPoint(x: bb.maxX, y: bb.maxY)
                    let br = CGPoint(x: bb.maxX, y: bb.minY)
                    let bl = CGPoint(x: bb.minX, y: bb.minY)
                    return (tl, tr, br, bl)
                }

                var tl: CGPoint
                var tr: CGPoint
                var br: CGPoint
                var bl: CGPoint

                if let r = rectObs {
                    tl = r.topLeft
                    tr = r.topRight
                    br = r.bottomRight
                    bl = r.bottomLeft
                } else {
                    let (qtl, qtr, qbr, qbl) = quadFromAxisAligned(obs.boundingBox)
                    tl = qtl; tr = qtr; br = qbr; bl = qbl
                }

                // Wenn deskew angewandt wurde: Quad zurück in ORIGINAL-Koordinaten rotieren
                if appliedSkew != 0 {
                    tl = Self.mapNormalizedPointFromDeskewedToOriginal(tl, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    tr = Self.mapNormalizedPointFromDeskewedToOriginal(tr, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    br = Self.mapNormalizedPointFromDeskewedToOriginal(br, skewAngleRadians: appliedSkew, imageSize: originalSize)
                    bl = Self.mapNormalizedPointFromDeskewedToOriginal(bl, skewAngleRadians: appliedSkew, imageSize: originalSize)
                } else if axisAlignedFallbackAngle != 0,
                          Self.isLikelyAxisAlignedQuad(tl: tl, tr: tr, br: br, bl: bl, imageSize: originalSize) {
                    (tl, tr, br, bl) = Self.rotateNormalizedQuadInImageSpace(
                        tl: tl,
                        tr: tr,
                        br: br,
                        bl: bl,
                        angleRadians: axisAlignedFallbackAngle,
                        imageSize: originalSize
                    )
                }

                return OCRBox(text: best.string, tl: tl, tr: tr, br: br, bl: bl)
            }

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
            overlayInvisibleText(boxes, in: ctx, targetRect: targetRect, imageSize: originalSize, renderScale: effectiveOptions.renderScale)
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
        _ boxes: [OCRBox],
        in ctx: CGContext,
        targetRect: CGRect,
        imageSize: CGSize,
        renderScale: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 10.0, nil)

        ctx.saveGState()
        ctx.setTextDrawingMode(.fill)

        // Unsichtbar (aber im PDF auswählbar)
        ctx.setAlpha(0.0)

        for b in boxes {

            // Normalized -> pixel (Vision coords, origin bottom-left)
            func toPixel(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
            }

            let tlPx = toPixel(b.tl)
            let trPx = toPixel(b.tr)
            let brPx = toPixel(b.br)
            let blPx = toPixel(b.bl)

            // Pixel -> PDF (page coords): y-flip + /renderScale
            func toPDF(_ p: CGPoint) -> CGPoint {
                CGPoint(
                    x: p.x / renderScale + targetRect.origin.x,
                    y: (imageSize.height - p.y) / renderScale + targetRect.origin.y
                )
            }

            let tl = toPDF(tlPx)
            let tr = toPDF(trPx)
            let br = toPDF(brPx)
            let bl = toPDF(blPx)

            // Baseline: bl -> br
            let vx = br.x - bl.x
            let vy = br.y - bl.y
            let angle = atan2(vy, vx)

            let targetW = hypot(vx, vy)
            let leftH  = hypot(tl.x - bl.x, tl.y - bl.y)
            let rightH = hypot(tr.x - br.x, tr.y - br.y)
            let targetH = 0.5 * (leftH + rightH)

            if targetW <= 1 || targetH <= 1 { continue }

            // CTLine mit Basis-Font (wir skalieren gleich auf targetW/targetH)
            let attr: [CFString: Any] = [
                kCTFontAttributeName: font
            ]
            let attributed = CFAttributedStringCreate(nil, b.text as CFString, attr as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineH = max(1, ascent + descent)

            if lineW <= 1 { continue }

            let sx = targetW / lineW
            let sy = targetH / lineH

            ctx.saveGState()
            ctx.setAlpha(0.0)

            // Transformation: an bl setzen, drehen, skalieren
            ctx.translateBy(x: bl.x, y: bl.y)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: sx, y: sy)

            // Baseline: leicht nach oben (descent), damit Text nicht "absäuft"
            ctx.textPosition = CGPoint(x: 0, y: descent)

            CTLineDraw(line, ctx)
            ctx.restoreGState()
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

    /// Heuristic: detect macOS temp/work directories that are commonly cleaned up after the run.
    private static func isProbablyTemporaryDirectory(_ url: URL) -> Bool {
        let p = url.path
        // Common temp roots on macOS
        if p.hasPrefix("/tmp/") { return true }
        if p.contains("/var/folders/") { return true }
        if p.contains("/private/var/folders/") { return true }
        if p.contains("/T/visionocr-") { return true }
        if p.contains("/TemporaryItems/") { return true }
        return false
    }
    
    private static func deskewForOCRIfNeeded(
        cgImage: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) -> (CGImage, CGFloat) {
        // Winkel schätzen (radians); 0 wenn nicht zuverlässig
        guard let angle = estimateSkewAngleRadians(cgImage: cgImage, options: options, logger: logger) else {
            logger?("estimate=nil (zu wenig/kein Text) -> no deskew")
            return (cgImage, 0)
        }

        let absA = abs(angle)
        let deg = Double(angle * 180.0 / .pi)

        // LOG mit mehr Auflösung
        logger?(String(format: "estimate=%.6f rad (%.3f°)", Double(angle), deg))

        let minA = options.minDeskewDegrees * .pi / 180.0
        if Double(absA) < minA {
            logger?(String(format: "below threshold (<%.3f°) -> no deskew", options.minDeskewDegrees))
            return (cgImage, 0)
        }

        let maxA = options.maxDeskewDegrees * .pi / 180.0
        if Double(absA) > maxA {
            logger?(String(format: "above threshold (>%.1f°) -> no deskew", options.maxDeskewDegrees))
            return (cgImage, 0)
        }

        if let rotated = rotateImageKeepingExtent(cgImage: cgImage, radians: -angle) {
            logger?(String(format: "applied deskew: rotate by %.3f°", -deg))
            return (rotated, angle)
        }
        return (cgImage, 0)
    }

    // MARK: - Bandbasierte Winkelmessung (Radon-ähnlicher Score; Debug/Prototyp)


    /// Liefert pro Band den „Deskew“-Winkel in Grad (d. h. der Winkel, um den man dieses Band drehen würde, um Textzeilen horizontal auszurichten).
    private static func measureDeskewAnglesByBands(
        cgImage: CGImage,
        options: Options,
        pageNumber: Int,
        exportDirectory: URL,
        pdfBaseName: String,
        logger: ((String) -> Void)? = nil
    ) -> [Double] {

        let bandCount = max(1, options.bandAngleBandCount)
        let searchRange = options.bandAngleSearchRangeDegrees
        let step = max(0.01, options.bandAngleStepDegrees)

        // Downscale nach Breite (Performance, stabiler als Pixel-Sampling)
        var workImage = cgImage
        if cgImage.width > options.bandAngleDownscaleMaxWidth,
           let scaled = scaleCGImageLanczosToWidth(cgImage: cgImage, targetWidth: CGFloat(options.bandAngleDownscaleMaxWidth)) {
            workImage = scaled
        }

        // Always-on: export directory for band PNGs (per page subfolder)
        let pageDir = exportDirectory.appendingPathComponent(
            String(format: "%@_p%03d", pdfBaseName, pageNumber),
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        } catch {
            logger?("band-export: FAILED to create page dir: \(error)")
        }

        do {
            var gray = try makePlanar8Gray(from: workImage)
            defer { if let d = gray.data { Darwin.free(d) } }

            // Binarize: ink==255, background==0
            // If bandAngleInkThreshold == 0: use Otsu; otherwise use the provided fixed threshold.
            let t: UInt8 = (options.bandAngleInkThreshold == 0) ? otsuThreshold(gray) : options.bandAngleInkThreshold
            binarizeToInk255(gray: &gray, threshold: t)

            let w = Int(gray.width)
            let h = Int(gray.height)
            let srcRB = Int(gray.rowBytes)

            let bandHBase = max(1, h / bandCount)

            var results: [Double] = []
            results.reserveCapacity(bandCount)
            var lastNonEmpty: Double? = nil

            for band in 0..<bandCount {
                let y0 = band * bandHBase
                let y1 = (band == bandCount - 1) ? h : min(h, (band + 1) * bandHBase)
                let bh = max(1, y1 - y0)

                let cropRect = CGRect(x: 0, y: y0, width: w, height: bh)

                // Bandbuffer (kopiert), damit Rotation sauber läuft
                var bandBuf = VImageBufferBox(width: w, height: bh, fill: 0)
                defer { bandBuf.deallocate() }

                let sp = gray.data!.assumingMemoryBound(to: UInt8.self)
                let dp = bandBuf.buf.data!.assumingMemoryBound(to: UInt8.self)
                let dstRB = Int(bandBuf.buf.rowBytes)

                for y in 0..<bh {
                    let srow = sp.advanced(by: (y0 + y) * srcRB)
                    let drow = dp.advanced(by: y * dstRB)
                    memcpy(drow, srow, w)
                }

                let stride = max(1, options.bandAngleSampleStride)
                let inkSampled = inkCountSampled(bandBuf.buf, stride: stride)
                // Scale sampled count back to an estimate for full resolution so the minInkSamples threshold remains comparable.
                let inkEstimated = inkSampled * stride * stride

                if inkEstimated < options.bandAngleMinInkSamples {
                    let a = lastNonEmpty ?? 0.0
                    results.append(a)
                    logger?(String(format: "  band %02d y=[%d..%d) ink≈%d (sampled=%d stride=%d) -> empty -> carry %.3f°", band + 1, y0, y1, inkEstimated, inkSampled, stride, a))

                    do {
                        let infoLines: [String] = [
                            String(format: "p%03d band %02d", pageNumber, band + 1),
                            String(format: "y=[%d..%d)  ink≈%d (empty)", y0, y1, inkEstimated),
                            String(format: "angle carry: %+.3f°", a)
                        ]

                        if let cropped = workImage.cropping(to: cropRect) {
                            let outImg = annotateDebugImage(cropped, lines: infoLines) ?? cropped
                            let fn = String(format: "%@_p%03d_band%02d_raw.png", pdfBaseName, pageNumber, band + 1)
                            let ok = writePNG(outImg, to: pageDir.appendingPathComponent(fn))
                            if !ok { logger?("band-export: FAILED write \(fn)") }
                        } else {
                            logger?("band-export: crop failed for raw band \(band + 1)")
                        }

                        if let bandImg = makeCGImageCopyFromPlanar8(bandBuf.buf) {
                            let outImg = annotateDebugImage(bandImg, lines: infoLines) ?? bandImg
                            let fn = String(format: "%@_p%03d_band%02d_bin.png", pdfBaseName, pageNumber, band + 1)
                            let ok = writePNG(outImg, to: pageDir.appendingPathComponent(fn))
                            if !ok { logger?("band-export: FAILED write \(fn)") }
                        } else {
                            logger?("band-export: makeCGImageCopyFromPlanar8 failed for band \(band + 1)")
                        }
                    }

                    continue
                }

                let (bestDeg, bestScore) = bestAngleRadonForBand(
                    bandInk: bandBuf.buf,
                    searchMinDeg: searchRange.lowerBound,
                    searchMaxDeg: searchRange.upperBound,
                    stepDeg: step,
                    padFrac: 0.18
                )

                do {
                    let infoLines: [String] = [
                        String(format: "p%03d band %02d", pageNumber, band + 1),
                        String(format: "y=[%d..%d)  ink≈%d", y0, y1, inkEstimated),
                        String(format: "angle: %+.3f°", bestDeg),
                        String(format: "score: %.3e", bestScore)
                    ]

                    if let cropped = workImage.cropping(to: cropRect) {
                        let outImg = annotateDebugImage(cropped, lines: infoLines) ?? cropped
                        let fn = String(format: "%@_p%03d_band%02d_raw.png", pdfBaseName, pageNumber, band + 1)
                        let ok = writePNG(outImg, to: pageDir.appendingPathComponent(fn))
                        if !ok { logger?("band-export: FAILED write \(fn)") }
                    } else {
                        logger?("band-export: crop failed for raw band \(band + 1)")
                    }

                    if let bandImg = makeCGImageCopyFromPlanar8(bandBuf.buf) {
                        let outImg = annotateDebugImage(bandImg, lines: infoLines) ?? bandImg
                        let fn = String(format: "%@_p%03d_band%02d_bin.png", pdfBaseName, pageNumber, band + 1)
                        let ok = writePNG(outImg, to: pageDir.appendingPathComponent(fn))
                        if !ok { logger?("band-export: FAILED write \(fn)") }
                    } else {
                        logger?("band-export: makeCGImageCopyFromPlanar8 failed for band \(band + 1)")
                    }
                }

                results.append(bestDeg)
                lastNonEmpty = bestDeg
                logger?(String(format: "  band %02d y=[%d..%d) ink≈%d best=%+.3f° score=%.3e", band + 1, y0, y1, inkEstimated, bestDeg, bestScore))
            }

            return results

        } catch {
            logger?("band-angle: vImage pipeline failed: \(error)")
            return Array(repeating: 0.0, count: bandCount)
        }
    }

    private static func estimateSkewAngleRadians(
        cgImage: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) -> CGFloat? {

        // Optional: downscale für Performance (z.B. max 1400px)
        let maxDim: CGFloat = 1400
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        var workImage = cgImage

        if max(w, h) > maxDim,
           let scaled = scaleCGImageLanczos(cgImage: cgImage, maxDimension: maxDim) {
            workImage = scaled
            logger?("skew: downscale to \(workImage.width)x\(workImage.height)")
        }

        // 1) Primary: projection/Radon-like (works even when Vision returns axis-aligned boxes)
        if let proj = estimateSkewAngleRadiansByProjection(cgImage: workImage, logger: logger) {
            let projDeg = Double(proj * 180.0 / .pi)

            if options.useBandMedianFallbackForSkew,
               abs(projDeg) <= options.bandMedianFallbackIfAbsProjectionBelowDegrees,
               let bm = estimateSkewAngleRadiansByBandMedian(cgImage: workImage, options: options, logger: logger) {

                let bmDeg = Double(bm * 180.0 / .pi)
                if abs(bmDeg) >= options.bandMedianFallbackMinAbsDegrees {
                    logger?(String(format: "skew: fallback -> use band-median %.3f° (projection %.3f°)", bmDeg, projDeg))
                    return bm
                } else {
                    logger?(String(format: "skew: band-median %.3f° below minAbs %.3f° -> keep projection %.3f°",
                                  bmDeg, options.bandMedianFallbackMinAbsDegrees, projDeg))
                }
            }

            return proj
        }

        // 2) Fallback: Vision geometry (may be 0 / nil on some inputs / OS revisions)
        return estimateSkewAngleRadiansFromVision(cgImage: workImage, logger: logger)
    }

    private static func estimateSkewAngleRadiansByProjection(
        cgImage: CGImage,
        logger: ((String) -> Void)? = nil
    ) -> CGFloat? {
        do {
            var gray = try makePlanar8Gray(from: cgImage)
            defer { if let d = gray.data { Darwin.free(d) } }

            // Otsu + binär: ink==255, background==0
            let t = otsuThreshold(gray)
            binarizeToInk255(gray: &gray, threshold: t)

            let ink = inkCount(gray)
            // Heuristic: if there is almost no ink, deskew is meaningless
            if ink < 200 {
                logger?("skew(rad): too little ink (\(ink)) -> nil")
                return nil
            }

            // Coarse-to-fine search to keep runtime reasonable
            let coarse = bestAngleRadonForBand(
                bandInk: gray,
                searchMinDeg: -8.0,
                searchMaxDeg: 8.0,
                stepDeg: 0.5,
                padFrac: 0.18
            )

            let fineMin = max(-8.0, coarse.bestDeg - 1.0)
            let fineMax = min(8.0, coarse.bestDeg + 1.0)
            let fine = bestAngleRadonForBand(
                bandInk: gray,
                searchMinDeg: fineMin,
                searchMaxDeg: fineMax,
                stepDeg: 0.1,
                padFrac: 0.18
            )

            logger?(String(format: "skew(rad): otsu=%d ink=%d coarse=%+.2f° fine=%+.2f° score=%.3e",
                           Int(t), ink, coarse.bestDeg, fine.bestDeg, fine.bestScore))

            return CGFloat(fine.bestDeg * Double.pi / 180.0)
        } catch {
            logger?("skew(rad): vImage projection failed: \(error)")
            return nil
        }
    }

    private static func estimateSkewAngleRadiansFromVision(
        cgImage: CGImage,
        logger: ((String) -> Void)? = nil
    ) -> CGFloat? {

        // Winkel aus RecognizeText + Quad-Geometrie ziehen (Preview-nahe)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        func run(_ level: VNRequestTextRecognitionLevel, minHeight: Float) -> [VNRecognizedTextObservation] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = level
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["de-DE", "en-US"]
            req.minimumTextHeight = minHeight

            do {
                try handler.perform([req])
                return req.results ?? []
            } catch {
                logger?("skew: VNRecognizeTextRequest(\(level)) failed: \(error.localizedDescription)")
                return []
            }
        }

        // Pass 1: schnell, aber nicht zu streng (Fax/Scan!)
        var results = run(.fast, minHeight: 0.004)

        // Pass 2: falls zu wenig/leer -> accurate, ohne Mindesthöhe
        if results.isEmpty {
            results = run(.accurate, minHeight: 0.0)
        }

        guard !results.isEmpty else {
            logger?("skew: no recognized text observations")
            return nil
        }

        let W = CGFloat(cgImage.width)
        let H = CGFloat(cgImage.height)

        var angles: [CGFloat] = []
        angles.reserveCapacity(256)

        for obs in results {
            guard let best = obs.topCandidates(1).first else { continue }
            let fullRange = best.string.startIndex..<best.string.endIndex
            guard let rect = try? best.boundingBox(for: fullRange) else { continue }

            let dx = (rect.topRight.x - rect.topLeft.x) * W
            let dy = (rect.topRight.y - rect.topLeft.y) * H
            if abs(dx) < 1e-6 { continue }

            let a = atan2(dy, dx)
            if abs(a) < (.pi / 2.0) {
                angles.append(a)
            }
        }

        guard angles.count >= 4 else {
            logger?("skew: too few angle samples (\(angles.count)) -> nil")
            return nil
        }

        // =========================
        // Sofortdiagnose (Signalqualität)
        // =========================
        let degSamples = angles.map { Double($0 * 180.0 / .pi) }
        let small = degSamples.filter { abs($0) < 0.5 }.count
        let pct = Int((Double(small) / Double(max(1, degSamples.count))) * 100.0)

        let mean = degSamples.reduce(0.0, +) / Double(degSamples.count)
        let varSum = degSamples.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let stdev = sqrt(varSum / Double(max(1, degSamples.count - 1)))

        // Sortieren + robuste Kennwerte
        angles.sort()
        let n = angles.count

        func q(_ p: Double) -> CGFloat {
            let idx = Int(Double(n - 1) * p)
            return angles[max(0, min(n - 1, idx))]
        }

        let minA = angles.first ?? 0
        let maxA = angles.last ?? 0
        let p10  = q(0.10)
        let med  = angles[n / 2]
        let p90  = q(0.90)

        logger?(
            String(
                format: "skew: angle-signal count=%d | <0.5°=%d (%d%%) | stdev=%.3f° | min=%.2f° p10=%.2f° med=%.2f° p90=%.2f° max=%.2f°",
                n,
                small,
                pct,
                stdev,
                Double(minA * 180.0 / .pi),
                Double(p10  * 180.0 / .pi),
                Double(med  * 180.0 / .pi),
                Double(p90  * 180.0 / .pi),
                Double(maxA * 180.0 / .pi)
            )
        )

        if stdev < 0.01 {
            logger?("skew: NOTE: angle signal too flat (stdev < 0.01°) -> nil")
            return nil
        }

        return med
    }

    private static func rotateImageKeepingExtent(cgImage: CGImage, radians: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)

        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)

        // clamp -> rotate -> crop: kein „leerer“ Rand durch Rotation
        let rotated = ci.clampedToExtent().transformed(by: t).cropped(to: extent)

        let ctx = CIContext(options: nil)
        return ctx.createCGImage(rotated, from: extent)
    }

    private static func scaleCGImageLanczos(cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = maxDimension / max(w, h)
        guard scale < 1 else { return cgImage }

        let ci = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        let rect = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        return ctx.createCGImage(out, from: rect)
    }

    private static func scaleCGImageLanczosToWidth(cgImage: CGImage, targetWidth: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }

        let scale = targetWidth / w
        guard scale < 1 else { return cgImage }

        let ci = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        let rect = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        return ctx.createCGImage(out, from: rect)
    }
    
    private static func mapNormalizedPointFromDeskewedToOriginal(
        _ p: CGPoint,
        skewAngleRadians: CGFloat,
        imageSize: CGSize
    ) -> CGPoint {
        let W = imageSize.width
        let H = imageSize.height

        // normalized -> pixel (Vision coords)
        let px = p.x * W
        let py = p.y * H

        let c = CGPoint(x: W / 2.0, y: H / 2.0)
        let ca = cos(skewAngleRadians)
        let sa = sin(skewAngleRadians)

        // deskewed -> original: rotate by +skewAngle around center
        let x = px - c.x
        let y = py - c.y
        let xr = x * ca - y * sa
        let yr = x * sa + y * ca

        let outX = xr + c.x
        let outY = yr + c.y

        // clamp + back to normalized
        let clampedX = min(max(outX, 0), W)
        let clampedY = min(max(outY, 0), H)

        return CGPoint(x: clampedX / W, y: clampedY / H)
    }
    
    private static func mapNormalizedRectFromDeskewedToOriginal(
        _ rect: CGRect,
        skewAngleRadians: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        let W = imageSize.width
        let H = imageSize.height

        // rect (normalized) -> pixel rect (Vision coords, origin bottom-left)
        let r = VNImageRectForNormalizedRect(rect, Int(W), Int(H))

        let corners = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY)
        ]

        let c = CGPoint(x: W / 2.0, y: H / 2.0)
        let ca = cos(skewAngleRadians)
        let sa = sin(skewAngleRadians)

        func rotBack(_ p: CGPoint) -> CGPoint {
            // deskewed -> original: rotate by +skewAngle around center
            let x = p.x - c.x
            let y = p.y - c.y
            let xr = x * ca - y * sa
            let yr = x * sa + y * ca
            return CGPoint(x: xr + c.x, y: yr + c.y)
        }

        let pts = corners.map(rotBack)
        let minX = pts.map(\.x).min() ?? 0
        let maxX = pts.map(\.x).max() ?? 0
        let minY = pts.map(\.y).min() ?? 0
        let maxY = pts.map(\.y).max() ?? 0

        var mapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        mapped = mapped.intersection(CGRect(x: 0, y: 0, width: W, height: H))

        // pixel -> normalized (Vision coords)
        return CGRect(
            x: mapped.origin.x / W,
            y: mapped.origin.y / H,
            width: mapped.size.width / W,
            height: mapped.size.height / H
        )
    }

    private static func isLikelyAxisAlignedQuad(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint,
        imageSize: CGSize,
        maxAbsBaselineDegrees: Double = 0.25
    ) -> Bool {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        let tlPx = CGPoint(x: tl.x * w, y: tl.y * h)
        let trPx = CGPoint(x: tr.x * w, y: tr.y * h)
        let brPx = CGPoint(x: br.x * w, y: br.y * h)
        let blPx = CGPoint(x: bl.x * w, y: bl.y * h)

        let vx = brPx.x - blPx.x
        let vy = brPx.y - blPx.y
        guard abs(vx) > 1e-6 else { return false }

        let baselineDeg = Double(atan2(vy, vx) * 180.0 / .pi)
        if abs(baselineDeg) > maxAbsBaselineDegrees {
            return false
        }

        // Optional secondary check: top edge follows the same near-horizontal trend.
        let tvx = trPx.x - tlPx.x
        let tvy = trPx.y - tlPx.y
        if abs(tvx) <= 1e-6 { return false }
        let topDeg = Double(atan2(tvy, tvx) * 180.0 / .pi)
        return abs(topDeg) <= maxAbsBaselineDegrees
    }

    private static func rotateNormalizedQuadInImageSpace(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint,
        angleRadians: CGFloat,
        imageSize: CGSize
    ) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        func toPixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * w, y: p.y * h)
        }

        func toNormalized(_ p: CGPoint) -> CGPoint {
            let cx = min(max(p.x, 0), w)
            let cy = min(max(p.y, 0), h)
            return CGPoint(x: cx / w, y: cy / h)
        }

        let tlPx = toPixel(tl)
        let trPx = toPixel(tr)
        let brPx = toPixel(br)
        let blPx = toPixel(bl)

        let c = CGPoint(
            x: (tlPx.x + trPx.x + brPx.x + blPx.x) * 0.25,
            y: (tlPx.y + trPx.y + brPx.y + blPx.y) * 0.25
        )

        let ca = cos(angleRadians)
        let sa = sin(angleRadians)

        func rotate(_ p: CGPoint) -> CGPoint {
            let x = p.x - c.x
            let y = p.y - c.y
            return CGPoint(
                x: (x * ca - y * sa) + c.x,
                y: (x * sa + y * ca) + c.y
            )
        }

        return (
            toNormalized(rotate(tlPx)),
            toNormalized(rotate(trPx)),
            toNormalized(rotate(brPx)),
            toNormalized(rotate(blPx))
        )
    }
    
    // MARK: - Debug image export helpers

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        // Ensure stable output: overwrite existing files from previous runs.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Creates a CGImage by copying bytes from a planar 8-bit vImage buffer.
    /// Safe for debug export (does not retain the original buffer memory).
    private static func makeCGImageCopyFromPlanar8(_ buf: vImage_Buffer) -> CGImage? {
        let w = Int(buf.width)
        let h = Int(buf.height)
        let rb = Int(buf.rowBytes)
        let byteCount = rb * h
        guard let src = buf.data else { return nil }

        let data = Data(bytes: src, count: byteCount) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }

        let cs = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: rb,
            space: cs,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Returns a copy of `image` with a small text overlay (top-left). Used for band debug exports.
    private static func annotateDebugImage(_ image: CGImage, lines: [String]) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .none

        // Base image
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard !lines.isEmpty else { return ctx.makeImage() }

        // Adaptive overlay sizing: band slices can be very short (e.g. ~30–60 px height).
        // We therefore size font/padding primarily from available HEIGHT so all lines (incl. angle) fit.
        let padX: CGFloat = 2
        let padY: CGFloat = 2
        let lineGap: CGFloat = 1

        let lineCount = max(1, lines.count)
        // Conservative estimate so the full block fits even with asc/desc.
        let maxFontByHeight = (CGFloat(h) - 2 * padY - CGFloat(max(0, lineCount - 1)) * lineGap) / CGFloat(lineCount) * 0.85
        let maxFontByWidth = CGFloat(w) * 0.04
        let fontSize: CGFloat = max(4, min(10, min(maxFontByHeight, maxFontByWidth)))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)

        // Build CTLines + measure
        var metrics: [(line: CTLine, w: CGFloat, h: CGFloat, asc: CGFloat, desc: CGFloat)] = []
        metrics.reserveCapacity(lines.count)

        var maxW: CGFloat = 0
        var totalH: CGFloat = 0

        for s in lines {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            let asStr = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(asStr)
            var asc: CGFloat = 0
            var desc: CGFloat = 0
            var lead: CGFloat = 0
            let lw = CGFloat(CTLineGetTypographicBounds(ctLine, &asc, &desc, &lead))
            let lh = max(1, asc + desc)
            metrics.append((ctLine, lw, lh, asc, desc))
            maxW = max(maxW, lw)
            totalH += lh
        }
        totalH += lineGap * CGFloat(max(0, lines.count - 1))

        // Background box (top-left)
        let boxW = maxW + 2 * padX
        let boxH = totalH + 2 * padY
        // Clamp to image bounds (small bands can be shorter than the overlay box).
        let x0: CGFloat = 0
        let y0: CGFloat = max(0, CGFloat(h) - boxH)

        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(CGRect(x: x0, y: y0, width: boxW, height: boxH))

        // Draw lines from top to bottom inside the box
        var baselineY = y0 + boxH - padY - (metrics.first?.asc ?? 0)
        for (idx, m) in metrics.enumerated() {
            ctx.textPosition = CGPoint(x: x0 + padX, y: baselineY)
            CTLineDraw(m.line, ctx)
            if idx < metrics.count - 1 {
                baselineY -= (m.h + lineGap)
            }
        }

        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: - Radon / Projection-based deskew helpers (band-level)

    private struct VImageBufferBox {
        var buf: vImage_Buffer

        init(width: Int, height: Int, fill: UInt8 = 0) {
            buf = vImage_Buffer()
            let err = vImageBuffer_Init(&buf, vImagePixelCount(height), vImagePixelCount(width), 8, vImage_Flags(kvImageNoFlags))
            precondition(err == kvImageNoError, "vImageBuffer_Init failed: \(err)")
            memset(buf.data, Int32(fill), Int(buf.rowBytes) * height)
        }

        mutating func deallocate() {
            if let d = buf.data {
                Darwin.free(d)
                buf.data = nil
            }
        }
    }

    private static func makePlanar8Gray(from cgImage: CGImage) throws -> vImage_Buffer {
        let cs = CGColorSpaceCreateDeviceGray()

        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: Unmanaged.passUnretained(cs),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var src = vImage_Buffer()
        let err = vImageBuffer_InitWithCGImage(&src, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            throw NSError(
                domain: "VisionOCR",
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "vImageBuffer_InitWithCGImage failed: \(err)"]
            )
        }
        return src
    }

    private static func otsuThreshold(_ gray: vImage_Buffer) -> UInt8 {
        var hist = [vImagePixelCount](repeating: 0, count: 256)

        hist.withUnsafeMutableBufferPointer { hp in
            guard let hptr = hp.baseAddress else { return }
            var g = gray // локале var, weil vImage API einen inout-Pointer will
            _ = vImageHistogramCalculation_Planar8(&g, hptr, vImage_Flags(kvImageNoFlags))
        }

        let total = Double(gray.width * gray.height)
        var sumAll = 0.0
        for t in 0..<256 { sumAll += Double(t) * Double(hist[t]) }

        var sumB = 0.0
        var wB = 0.0
        var wF = 0.0

        var maxVar = -1.0
        var bestT = 180

        for t in 0..<256 {
            wB += Double(hist[t])
            if wB == 0 { continue }
            wF = total - wB
            if wF == 0 { break }

            sumB += Double(t) * Double(hist[t])

            let mB = sumB / wB
            let mF = (sumAll - sumB) / wF

            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > maxVar {
                maxVar = between
                bestT = t
            }
        }
        return UInt8(bestT)
    }
    /// Binarize: ink = 255 (black), background = 0 (white) or vice versa.
    /// Here: we want "ink == 255" for fast counting.
    private static func binarizeToInk255(gray: inout vImage_Buffer, threshold t: UInt8) {
        // gray contains 0..255 with 0=black. We map: pixel < t -> ink(255), else background(0)
        let w = Int(gray.width)
        let h = Int(gray.height)
        let rb = Int(gray.rowBytes)
        let p = gray.data!.assumingMemoryBound(to: UInt8.self)

        for y in 0..<h {
            let row = p.advanced(by: y * rb)
            for x in 0..<w {
                row[x] = (row[x] < t) ? 255 : 0
            }
        }
    }

    /// Re-binarize an already (mostly) binary buffer after geometric transforms.
    /// vImageRotate_Planar8 may introduce gray levels due to resampling; we restore strict 0/255.
    /// Assumes background is near 0 and ink is near 255.
    private static func rebinarizeToInk255(_ buf: inout vImage_Buffer, threshold t: UInt8 = 128) {
        let w = Int(buf.width)
        let h = Int(buf.height)
        let rb = Int(buf.rowBytes)
        let p = buf.data!.assumingMemoryBound(to: UInt8.self)

        for y in 0..<h {
            let row = p.advanced(by: y * rb)
            for x in 0..<w {
                row[x] = (row[x] >= t) ? 255 : 0
            }
        }
    }

    /// Count ink pixels (ink==255)
    private static func inkCount(_ buf: vImage_Buffer) -> Int {
        let w = Int(buf.width)
        let h = Int(buf.height)
        let rb = Int(buf.rowBytes)
        let p = buf.data!.assumingMemoryBound(to: UInt8.self)

        var c = 0
        for y in 0..<h {
            let row = p.advanced(by: y * rb)
            for x in 0..<w {
                if row[x] == 255 { c += 1 }
            }
        }
        return c
    }

    /// Count ink pixels (ink==255) using a sampling stride (>= 1) to speed up checks.
    private static func inkCountSampled(_ buf: vImage_Buffer, stride: Int) -> Int {
        let s = max(1, stride)
        let w = Int(buf.width)
        let h = Int(buf.height)
        let rb = Int(buf.rowBytes)
        let p = buf.data!.assumingMemoryBound(to: UInt8.self)

        var c = 0
        var y = 0
        while y < h {
            let row = p.advanced(by: y * rb)
            var x = 0
            while x < w {
                if row[x] == 255 { c += 1 }
                x += s
            }
            y += s
        }
        return c
    }

    /// Score: variance of horizontal projection, normalized by mean.
    /// Higher => text lines more horizontal (peaky row-sums).
    private static func projectionVarianceScore(_ buf: vImage_Buffer) -> Double {
        let h = Int(buf.height)
        let rb = Int(buf.rowBytes)
        let p = buf.data!.assumingMemoryBound(to: UInt8.self)

        var sum = 0.0
        var sumSq = 0.0

        for y in 0..<h {
            let row = p.advanced(by: y * rb)
            var rowInk = 0
            for x in 0..<Int(buf.width) {
                if row[x] == 255 { rowInk += 1 }
            }
            let d = Double(rowInk)
            sum += d
            sumSq += d * d
        }

        let n = Double(h)
        let mean = sum / n
        let variance = max(0.0, (sumSq / n) - (mean * mean))
        return variance / (mean + 1e-6)
    }

    /// Copy centered crop (cx,cy) from src into dst (same size as dst)
    private static func copyCenterCrop(src: vImage_Buffer, dst: inout vImage_Buffer) {
        let srcW = Int(src.width), srcH = Int(src.height)
        let dstW = Int(dst.width), dstH = Int(dst.height)

        let x0 = max(0, (srcW - dstW) / 2)
        let y0 = max(0, (srcH - dstH) / 2)

        let srcRB = Int(src.rowBytes)
        let dstRB = Int(dst.rowBytes)

        let sp = src.data!.assumingMemoryBound(to: UInt8.self)
        let dp = dst.data!.assumingMemoryBound(to: UInt8.self)

        for y in 0..<dstH {
            let srow = sp.advanced(by: (y0 + y) * srcRB + x0)
            let drow = dp.advanced(by: y * dstRB)
            memcpy(drow, srow, dstW)
        }
    }

    /// Best angle for a binarized band (ink==255), robust against clipping via padding + center-crop.
    private static func bestAngleRadonForBand(
        bandInk: vImage_Buffer,
        searchMinDeg: Double,
        searchMaxDeg: Double,
        stepDeg: Double,
        padFrac: Double = 0.18
    ) -> (bestDeg: Double, bestScore: Double) {

        let w = Int(bandInk.width), h = Int(bandInk.height)
        let padW = Int(Double(w) * (1.0 + 2.0 * padFrac))
        let padH = Int(Double(h) * (1.0 + 2.0 * padFrac))

        var padded = VImageBufferBox(width: padW, height: padH, fill: 0)      // background = 0
        var rotated = VImageBufferBox(width: padW, height: padH, fill: 0)
        var cropped = VImageBufferBox(width: w, height: h, fill: 0)

        defer {
            padded.deallocate(); rotated.deallocate(); cropped.deallocate()
        }

        // Put band into center of padded
        do {
            let x0 = (padW - w) / 2
            let y0 = (padH - h) / 2
            let srcRB = Int(bandInk.rowBytes)
            let dstRB = Int(padded.buf.rowBytes)

            let sp = bandInk.data!.assumingMemoryBound(to: UInt8.self)
            let dp = padded.buf.data!.assumingMemoryBound(to: UInt8.self)

            for y in 0..<h {
                let srow = sp.advanced(by: y * srcRB)
                let drow = dp.advanced(by: (y0 + y) * dstRB + x0)
                memcpy(drow, srow, w)
            }
        }

        var bestDeg = 0.0
        var bestScore = -Double.infinity

        var angle = searchMinDeg
        while angle <= searchMaxDeg + 1e-9 {
            let rad = angle * Double.pi / 180.0

            let bg: Pixel_8 = 0
            let err = vImageRotate_Planar8(
                &padded.buf,
                &rotated.buf,
                nil,
                Float(rad),
                bg,
                vImage_Flags(kvImageBackgroundColorFill)
            )

            if err == kvImageNoError {
                copyCenterCrop(src: rotated.buf, dst: &cropped.buf)

                // IMPORTANT: rotation introduces gray levels; restore strict 0/255 before scoring.
                rebinarizeToInk255(&cropped.buf, threshold: 128)

                let s = projectionVarianceScore(cropped.buf)
                if s > bestScore {
                    bestScore = s
                    bestDeg = angle
                }
            } else {
                // If rotate fails for some reason, ignore angle
                // (should not happen in normal conditions)
            }

            angle += stepDeg
        }

        return (bestDeg, bestScore)
    }

    /// Band-Median Fallback: Schätzt den globalen Skew aus dem Median der Bandwinkel (nur nicht-leere Bänder,
    /// mit Outlier-Filter). Rückgabe in Radians oder nil.
    private static func estimateSkewAngleRadiansByBandMedian(
        cgImage: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) -> CGFloat? {

        let bandCount = max(1, options.bandAngleBandCount)
        let searchRange = options.bandAngleSearchRangeDegrees
        let step = max(0.01, options.bandAngleStepDegrees)

        // Downscale nach Breite (Performance)
        var workImage = cgImage
        if cgImage.width > options.bandAngleDownscaleMaxWidth,
           let scaled = scaleCGImageLanczosToWidth(cgImage: cgImage, targetWidth: CGFloat(options.bandAngleDownscaleMaxWidth)) {
            workImage = scaled
        }

        do {
            var gray = try makePlanar8Gray(from: workImage)
            defer { if let d = gray.data { Darwin.free(d) } }

            // Binarize: ink==255, background==0
            let t: UInt8 = (options.bandAngleInkThreshold == 0) ? otsuThreshold(gray) : options.bandAngleInkThreshold
            binarizeToInk255(gray: &gray, threshold: t)

            let w = Int(gray.width)
            let h = Int(gray.height)
            let srcRB = Int(gray.rowBytes)

            let bandHBase = max(1, h / bandCount)
            let stride = max(1, options.bandAngleSampleStride)

            var nonEmptyAnglesDeg: [Double] = []
            nonEmptyAnglesDeg.reserveCapacity(bandCount)

            for band in 0..<bandCount {
                let y0 = band * bandHBase
                let y1 = (band == bandCount - 1) ? h : min(h, (band + 1) * bandHBase)
                let bh = max(1, y1 - y0)

                // Bandbuffer (kopiert), damit Rotation sauber läuft
                var bandBuf = VImageBufferBox(width: w, height: bh, fill: 0)
                defer { bandBuf.deallocate() }

                let sp = gray.data!.assumingMemoryBound(to: UInt8.self)
                let dp = bandBuf.buf.data!.assumingMemoryBound(to: UInt8.self)
                let dstRB = Int(bandBuf.buf.rowBytes)

                for y in 0..<bh {
                    let srow = sp.advanced(by: (y0 + y) * srcRB)
                    let drow = dp.advanced(by: y * dstRB)
                    memcpy(drow, srow, w)
                }

                let inkSampled = inkCountSampled(bandBuf.buf, stride: stride)
                let inkEstimated = inkSampled * stride * stride

                if inkEstimated < options.bandAngleMinInkSamples {
                    continue
                }

                let (bestDeg, _) = bestAngleRadonForBand(
                    bandInk: bandBuf.buf,
                    searchMinDeg: searchRange.lowerBound,
                    searchMaxDeg: searchRange.upperBound,
                    stepDeg: step,
                    padFrac: 0.18
                )

                nonEmptyAnglesDeg.append(bestDeg)
            }

            guard nonEmptyAnglesDeg.count >= max(2, options.bandMedianFallbackMinNonEmptyBands) else {
                logger?("skew(band): too few non-empty bands (\(nonEmptyAnglesDeg.count)) -> nil")
                return nil
            }

            // Median helper
            func median(_ xs: [Double]) -> Double {
                let s = xs.sorted()
                let n = s.count
                if n % 2 == 1 { return s[n / 2] }
                return 0.5 * (s[n / 2 - 1] + s[n / 2])
            }

            let m0 = median(nonEmptyAnglesDeg)

            // Outlier filter around median
            let maxDev = options.bandMedianFallbackOutlierMaxDeviationDegrees
            let filtered = nonEmptyAnglesDeg.filter { abs($0 - m0) <= maxDev }

            guard filtered.count >= max(2, options.bandMedianFallbackMinNonEmptyBands) else {
                logger?(String(format: "skew(band): filtered too small (%d/%d) (median=%.3f°, maxDev=%.2f°) -> nil",
                              filtered.count, nonEmptyAnglesDeg.count, m0, maxDev))
                return nil
            }

            let m = median(filtered)

            // Logging summary
            let minA = filtered.min() ?? m
            let maxA = filtered.max() ?? m
            logger?(String(format: "skew(band): nonEmpty=%d filtered=%d median=%.3f° range=[%.3f°..%.3f°]",
                          nonEmptyAnglesDeg.count, filtered.count, m, minA, maxA))

            return CGFloat(m * Double.pi / 180.0)

        } catch {
            logger?("skew(band): vImage pipeline failed: \(error)")
            return nil
        }
    }

} // end of enum VisionOCRService
