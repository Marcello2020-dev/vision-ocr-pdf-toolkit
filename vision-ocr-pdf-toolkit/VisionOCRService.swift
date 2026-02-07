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

enum VisionOCRService {

    struct Options {
        var languages: [String] = ["de-DE", "en-US"]
        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var usesLanguageCorrection: Bool = true
        var renderScale: CGFloat = 2.0
        var skipPagesWithExistingText: Bool = true

        // Optional diagnostics for local angle model.
        var debugBandAngleEstimation: Bool = false

        // Number of vertical bands used to build local skew interpolation.
        var bandAngleBandCount: Int = 20
    }
    
    private struct OCRBox {
        let text: String
        // Vision-normalized Quad (origin bottom-left)
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
    }

    private struct OCRCandidate {
        let text: String
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
        let bounds: CGRect
        let centerY: CGFloat
        let measuredAngle: CGFloat?
        let isAxisAligned: Bool
    }

    private struct TextGeometryBlock {
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
        let bounds: CGRect
        let center: CGPoint
        let angle: CGFloat
        let confidence: VNConfidence
    }

    private struct OCRPlacement {
        let text: String
        let tl: CGPoint
        let tr: CGPoint
        let br: CGPoint
        let bl: CGPoint
    }

    private struct TextSlice {
        let range: Range<String.Index>
        let startOffset: Int
        let endOffset: Int
    }

    private struct LineAngleSample {
        let yNorm: CGFloat
        let angle: CGFloat
    }

    private struct LocalAngleModel {
        let bandAngles: [CGFloat]

        func angle(atNormalizedY y: CGFloat) -> CGFloat {
            guard !bandAngles.isEmpty else { return 0 }
            if bandAngles.count == 1 { return bandAngles[0] }

            let yc = min(max(y, 0), 1)
            let p = yc * CGFloat(bandAngles.count - 1)
            let i0 = Int(floor(p))
            let i1 = min(bandAngles.count - 1, i0 + 1)
            let t = p - CGFloat(i0)
            return bandAngles[i0] * (1 - t) + bandAngles[i1] * t
        }
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
        artifactsBaseDirectory _: URL? = nil,
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

        let effectiveOptions = options

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

            let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
            let imageToPDF = imageToPDFTransform(
                for: cgPage,
                box: box,
                targetRect: targetRect,
                rotate: cgPage.rotationAngle,
                imageSize: originalSize
            )

            // OCR runs once per page. We do not globally deskew the bitmap.
            // If Vision cannot allocate intermediate buffers on large pages,
            // we retry with a downscaled recognition image (geometry stays normalized).
            let recognitionImage: CGImage
            let observations: [VNRecognizedTextObservation]
            do {
                let maxDimensions: [CGFloat?] = [nil, 1600, 1200, 900, 700]
                var lastError: Error?
                var foundImage: CGImage? = nil
                var foundObservations: [VNRecognizedTextObservation]? = nil

                for maxDim in maxDimensions {
                    let candidateImage: CGImage
                    if let maxDim {
                        guard let scaled = scaleCGImageLanczos(cgImage: cgImage, maxDimension: maxDim)
                                ?? scaleCGImageByRedraw(cgImage: cgImage, maxDimension: maxDim) else {
                            log?("Page \(pageIndex + 1) OCR: could not create fallback image for maxDim=\(Int(maxDim))")
                            continue
                        }
                        candidateImage = scaled
                        log?("Page \(pageIndex + 1) OCR: retry with downscaled image \(scaled.width)x\(scaled.height)")
                    } else {
                        candidateImage = cgImage
                    }

                    do {
                        let obs = try recognizeText(
                            on: candidateImage,
                            options: effectiveOptions,
                            logger: { line in log?("Page \(pageIndex + 1) OCR: \(line)") }
                        )
                        foundImage = candidateImage
                        foundObservations = obs
                        break
                    } catch {
                        lastError = error
                    }
                }

                guard let finalImage = foundImage, let finalObservations = foundObservations else {
                    throw lastError ?? NSError(
                        domain: "VisionOCR",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Vision OCR failed for all fallback scales."]
                    )
                }
                recognitionImage = finalImage
                observations = finalObservations
            }

            let recognitionSize = CGSize(width: recognitionImage.width, height: recognitionImage.height)
            let geometryBlocks = try detectTextGeometry(
                on: recognitionImage,
                logger: { line in log?("Page \(pageIndex + 1) GEO: \(line)") }
            )

            let candidates: [OCRCandidate] = observations.flatMap { obs in
                guard let best = obs.topCandidates(1).first else { return [OCRCandidate]() }
                return Self.buildCandidates(from: best, observation: obs, imageSize: recognitionSize)
            }

            let model = Self.buildLocalAngleModel(
                from: candidates,
                bandCount: max(1, effectiveOptions.bandAngleBandCount)
            )
            let globalGeometryMatches = Self.assignGeometryBlocksGlobally(lines: candidates, blocks: geometryBlocks)

            if effectiveOptions.debugBandAngleEstimation {
                let sampleCount = candidates.compactMap(\.measuredAngle).count
                log?("[Page \(pageIndex + 1)] lines=\(candidates.count), geometryBlocks=\(geometryBlocks.count), local-angle samples=\(sampleCount)")
                for (bandIndex, angle) in model.bandAngles.enumerated() {
                    let deg = Double(angle * 180.0 / .pi)
                    log?(String(format: "  band %02d: %.3f°", bandIndex + 1, deg))
                }

                let geometryDeg = geometryBlocks.map { Double($0.angle * 180.0 / .pi) }.sorted()
                if !geometryDeg.isEmpty {
                    let minDeg = geometryDeg.first ?? 0
                    let maxDeg = geometryDeg.last ?? 0
                    let medDeg = geometryDeg[geometryDeg.count / 2]
                    let gt02 = geometryDeg.filter { abs($0) > 0.2 }.count
                    log?(String(
                        format: "  geometry-angles: count=%d abs>0.2°=%d min=%.3f° med=%.3f° max=%.3f°",
                        geometryDeg.count,
                        gt02,
                        minDeg,
                        medDeg,
                        maxDeg
                    ))
                }
            }

            // Build final OCR placement from: matched geometry angle -> local model fallback.
            var placements: [OCRPlacement] = []
            placements.reserveCapacity(candidates.count)
            var placementAnglesDeg: [Double] = []
            placementAnglesDeg.reserveCapacity(candidates.count)
            var fromGeometryCount = 0
            var fromLocalModelCount = 0

            for (lineIndex, c) in candidates.enumerated() {
                var tl = c.tl
                var tr = c.tr
                var br = c.br
                var bl = c.bl

                let currentAngle = Self.angleFromQuad(
                    tl: tl,
                    tr: tr,
                    br: br,
                    bl: bl,
                    imageSize: recognitionSize
                ) ?? 0

                let targetAngle: CGFloat
                if let blockIndex = globalGeometryMatches[lineIndex] {
                    targetAngle = geometryBlocks[blockIndex].angle
                    fromGeometryCount += 1
                } else {
                    targetAngle = model.angle(atNormalizedY: c.centerY)
                    fromLocalModelCount += 1
                }

                placementAnglesDeg.append(Double(targetAngle * 180.0 / .pi))

                let delta = targetAngle - currentAngle
                if abs(delta) >= (CGFloat.pi / 900.0) { // ~0.2 degrees
                    (tl, tr, br, bl) = Self.rotateNormalizedQuadInImageSpace(
                        tl: tl,
                        tr: tr,
                        br: br,
                        bl: bl,
                        angleRadians: delta,
                        imageSize: originalSize
                    )
                }

                placements.append(OCRPlacement(text: c.text, tl: tl, tr: tr, br: br, bl: bl))
            }

            if effectiveOptions.debugBandAngleEstimation, !placementAnglesDeg.isEmpty {
                let sorted = placementAnglesDeg.sorted()
                let minDeg = sorted.first ?? 0
                let maxDeg = sorted.last ?? 0
                let medDeg = sorted[sorted.count / 2]
                let gt02 = sorted.filter { abs($0) > 0.2 }.count
                log?(String(
                    format: "  placement-angles: count=%d fromGeo=%d fromLocal=%d abs>0.2°=%d min=%.3f° med=%.3f° max=%.3f°",
                    sorted.count,
                    fromGeometryCount,
                    fromLocalModelCount,
                    gt02,
                    minDeg,
                    medDeg,
                    maxDeg
                ))
            }

            let boxes: [OCRBox] = placements.map {
                OCRBox(text: $0.text, tl: $0.tl, tr: $0.tr, br: $0.br, bl: $0.bl)
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
            overlayInvisibleText(boxes, in: ctx, imageSize: originalSize, imageToPDF: imageToPDF)
            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    // MARK: - Vision

    private static func recognizeText(
        on image: CGImage,
        options: Options,
        logger: ((String) -> Void)? = nil
    ) throws -> [VNRecognizedTextObservation] {
        typealias Attempt = (
            level: VNRequestTextRecognitionLevel,
            useLanguageCorrection: Bool,
            languages: [String]?
        )

        let attempts: [Attempt] = [
            (options.recognitionLevel, options.usesLanguageCorrection, options.languages),
            (options.recognitionLevel, false, options.languages),
            (.fast, false, options.languages),
            (.fast, false, nil)
        ]

        var lastError: Error?

        for (idx, attempt) in attempts.enumerated() {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = attempt.level
            request.usesLanguageCorrection = attempt.useLanguageCorrection
            if let langs = attempt.languages, !langs.isEmpty {
                request.recognitionLanguages = langs
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                if idx > 0 {
                    logger?("fallback attempt \(idx + 1) succeeded")
                }
                return request.results ?? []
            } catch {
                lastError = error
                logger?("attempt \(idx + 1) failed: \(error.localizedDescription)")
            }
        }

        throw lastError ?? NSError(
            domain: "VisionOCR",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "VNRecognizeTextRequest failed without a detailed error."]
        )
    }

    // MARK: - Vision geometry blocks

    private static func detectTextGeometry(
        on image: CGImage,
        logger: ((String) -> Void)? = nil
    ) throws -> [TextGeometryBlock] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let raw = request.results ?? []
        guard !raw.isEmpty else {
            logger?("no geometry blocks found")
            return []
        }

        let size = CGSize(width: image.width, height: image.height)
        let blocks: [TextGeometryBlock] = raw.flatMap { obs in
            geometryBlocks(from: obs, imageSize: size)
        }

        return blocks
    }

    private static func bestGeometryBlock(for line: OCRCandidate, blocks: [TextGeometryBlock]) -> TextGeometryBlock? {
        guard !blocks.isEmpty else { return nil }

        var best: (block: TextGeometryBlock, score: CGFloat)? = nil
        for b in blocks {
            guard let score = geometryMatchScore(line: line, block: b) else { continue }

            if let current = best {
                if score > current.score {
                    best = (b, score)
                }
            } else {
                best = (b, score)
            }
        }
        return best?.block
    }

    private static func geometryMatchScore(line: OCRCandidate, block: TextGeometryBlock) -> CGFloat? {
        let lineCenter = CGPoint(x: line.bounds.midX, y: line.bounds.midY)
        let overlap = iou(line.bounds, block.bounds)
        let vOverlap = verticalOverlapRatio(line.bounds, block.bounds)
        let dist = normalizedCenterDistance(lineCenter, block.center)

        let score = overlap * 0.45 + vOverlap * 0.35 + (1 - dist) * 0.20
        let isAcceptable = overlap >= 0.01 || vOverlap >= 0.20 || dist <= 0.18
        return isAcceptable ? score : nil
    }

    private static func assignGeometryBlocksGlobally(lines: [OCRCandidate], blocks: [TextGeometryBlock]) -> [Int: Int] {
        guard !lines.isEmpty, !blocks.isEmpty else { return [:] }

        let n = lines.count
        let m = blocks.count
        let size = max(n, m)
        let unmatchedCost = 0.72

        var cost = Array(repeating: Array(repeating: unmatchedCost, count: size), count: size)

        // Real rows / cols.
        for i in 0..<n {
            for j in 0..<m {
                if let score = geometryMatchScore(line: lines[i], block: blocks[j]) {
                    let s = min(max(score, 0), 1)
                    cost[i][j] = Double(1 - s)
                } else {
                    // Keep these unattractive so dummy assignment wins.
                    cost[i][j] = 1.0
                }
            }
        }

        // Dummy rows absorb unassigned geometry blocks with zero cost.
        if n < size {
            for i in n..<size {
                for j in 0..<size {
                    cost[i][j] = 0
                }
            }
        }

        // Dummy cols absorb unmatched OCR lines.
        if m < size {
            for i in 0..<n {
                for j in m..<size {
                    cost[i][j] = unmatchedCost
                }
            }
        }

        let assignment = hungarianMinCost(cost)
        var out: [Int: Int] = [:]
        out.reserveCapacity(min(n, m))

        for i in 0..<n {
            let j = assignment[i]
            guard j >= 0, j < m else { continue }
            guard let score = geometryMatchScore(line: lines[i], block: blocks[j]) else { continue }
            let assignedCost = 1 - min(max(Double(score), 0), 1)
            if assignedCost <= unmatchedCost {
                out[i] = j
            }
        }

        return out
    }

    private static func hungarianMinCost(_ matrix: [[Double]]) -> [Int] {
        let n = matrix.count
        guard n > 0 else { return [] }

        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: n + 1)
        var p = Array(repeating: 0, count: n + 1)
        var way = Array(repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.greatestFiniteMagnitude, count: n + 1)
            var used = Array(repeating: false, count: n + 1)

            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.greatestFiniteMagnitude
                var j1 = 0

                for j in 1...n where !used[j] {
                    let cur = matrix[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }

                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0

            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignment = Array(repeating: -1, count: n)
        for j in 1...n where p[j] > 0 {
            assignment[p[j] - 1] = j - 1
        }
        return assignment
    }

    private static func axisAlignedBoundsOfQuad(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint
    ) -> CGRect {
        let minX = min(tl.x, tr.x, br.x, bl.x)
        let maxX = max(tl.x, tr.x, br.x, bl.x)
        let minY = min(tl.y, tr.y, br.y, bl.y)
        let maxY = max(tl.y, tr.y, br.y, bl.y)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func geometryBlocks(from observation: VNTextObservation, imageSize: CGSize) -> [TextGeometryBlock] {
        guard let chars = observation.characterBoxes, !chars.isEmpty else {
            return [fallbackGeometryBlock(from: observation, imageSize: imageSize)]
        }

        let rows = clusterCharacterBoxesIntoRows(chars)
        let widthPx = max(1.0, imageSize.width)
        var out: [TextGeometryBlock] = []
        out.reserveCapacity(rows.count)

        for row in rows {
            guard row.count >= 2 else { continue }

            let centers = row.map { characterCenter($0) }
            let rowBounds = boundsOfCharacterBoxes(row)
            if rowBounds.width * widthPx < 14 { continue }

            let angle = estimateRowAngle(row, imageSize: imageSize, centers: centers) ?? 0

            let (tl, tr, br, bl) = quadFromAxisAligned(rowBounds)
            out.append(
                TextGeometryBlock(
                    tl: tl,
                    tr: tr,
                    br: br,
                    bl: bl,
                    bounds: rowBounds,
                    center: CGPoint(x: rowBounds.midX, y: rowBounds.midY),
                    angle: angle,
                    confidence: observation.confidence
                )
            )
        }

        if !out.isEmpty {
            return out
        }

        return [fallbackGeometryBlock(from: observation, imageSize: imageSize)]
    }

    private static func fallbackGeometryBlock(from observation: VNTextObservation, imageSize: CGSize) -> TextGeometryBlock {
        let tl = observation.topLeft
        let tr = observation.topRight
        let br = observation.bottomRight
        let bl = observation.bottomLeft

        let bounds = axisAlignedBoundsOfQuad(tl: tl, tr: tr, br: br, bl: bl)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let angleFromCharacters: CGFloat? = {
            guard let chars = observation.characterBoxes, !chars.isEmpty else { return nil }
            if let byCenters = dominantBaselineAngleFromCharacterBoxes(chars, imageSize: imageSize) {
                return byCenters
            }
            let values: [CGFloat] = chars.compactMap { c in
                angleFromQuad(
                    tl: c.topLeft,
                    tr: c.topRight,
                    br: c.bottomRight,
                    bl: c.bottomLeft,
                    imageSize: imageSize
                )
            }
            return values.isEmpty ? nil : median(values)
        }()

        let angle = angleFromCharacters ?? angleFromQuad(tl: tl, tr: tr, br: br, bl: bl, imageSize: imageSize) ?? 0

        return TextGeometryBlock(
            tl: tl,
            tr: tr,
            br: br,
            bl: bl,
            bounds: bounds,
            center: center,
            angle: angle,
            confidence: observation.confidence
        )
    }

    private static func clusterCharacterBoxesIntoRows(_ chars: [VNRectangleObservation]) -> [[VNRectangleObservation]] {
        struct CharSample {
            let box: VNRectangleObservation
            let center: CGPoint
            let height: CGFloat
        }

        let samples: [CharSample] = chars.map { c in
            let center = characterCenter(c)
            let leftH = hypot(c.topLeft.x - c.bottomLeft.x, c.topLeft.y - c.bottomLeft.y)
            let rightH = hypot(c.topRight.x - c.bottomRight.x, c.topRight.y - c.bottomRight.y)
            return CharSample(box: c, center: center, height: max(0, 0.5 * (leftH + rightH)))
        }

        let positiveHeights = samples.map(\.height).filter { $0 > 0 }
        let medianH = positiveHeights.isEmpty ? 0.01 : median(positiveHeights)
        let rowThreshold = max(0.0012, medianH * 0.70)

        let sorted = samples.sorted { $0.center.y > $1.center.y }
        var rows: [[CharSample]] = []
        var rowMeanY: [CGFloat] = []

        for s in sorted {
            var assigned = false
            for i in 0..<rows.count {
                if abs(s.center.y - rowMeanY[i]) <= rowThreshold {
                    rows[i].append(s)
                    let n = CGFloat(rows[i].count)
                    rowMeanY[i] = rowMeanY[i] + (s.center.y - rowMeanY[i]) / n
                    assigned = true
                    break
                }
            }

            if !assigned {
                rows.append([s])
                rowMeanY.append(s.center.y)
            }
        }

        return rows.map { row in
            row.sorted { $0.center.x < $1.center.x }.map(\.box)
        }
    }

    private static func characterCenter(_ c: VNRectangleObservation) -> CGPoint {
        CGPoint(
            x: (c.topLeft.x + c.topRight.x + c.bottomRight.x + c.bottomLeft.x) * 0.25,
            y: (c.topLeft.y + c.topRight.y + c.bottomRight.y + c.bottomLeft.y) * 0.25
        )
    }

    private static func boundsOfCharacterBoxes(_ chars: [VNRectangleObservation]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for c in chars {
            minX = min(minX, c.topLeft.x, c.topRight.x, c.bottomRight.x, c.bottomLeft.x)
            minY = min(minY, c.topLeft.y, c.topRight.y, c.bottomRight.y, c.bottomLeft.y)
            maxX = max(maxX, c.topLeft.x, c.topRight.x, c.bottomRight.x, c.bottomLeft.x)
            maxY = max(maxY, c.topLeft.y, c.topRight.y, c.bottomRight.y, c.bottomLeft.y)
        }

        if !minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func estimateRowAngle(
        _ row: [VNRectangleObservation],
        imageSize: CGSize,
        centers: [CGPoint]
    ) -> CGFloat? {
        let robust = robustAngleFromOrderedCenters(centers, imageSize: imageSize)
        let ls = angleFromPointCloud(centers, imageSize: imageSize)
        let quadAngles: [CGFloat] = row.compactMap { c in
            angleFromQuad(
                tl: c.topLeft,
                tr: c.topRight,
                br: c.bottomRight,
                bl: c.bottomLeft,
                imageSize: imageSize
            )
        }
        let quadMedian: CGFloat? = quadAngles.isEmpty ? nil : median(quadAngles)

        if let robust, let ls {
            let deltaDeg = abs(Double((robust - ls) * 180.0 / .pi))
            if deltaDeg <= 1.2 {
                return robust * 0.7 + ls * 0.3
            }
            return robust
        }
        return robust ?? ls ?? quadMedian ?? dominantBaselineAngleFromCharacterBoxes(row, imageSize: imageSize)
    }

    private static func robustAngleFromOrderedCenters(_ points: [CGPoint], imageSize: CGSize) -> CGFloat? {
        guard points.count >= 3 else { return angleFromPointCloud(points, imageSize: imageSize) }

        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)
        let px = points.map { CGPoint(x: $0.x * w, y: $0.y * h) }.sorted { $0.x < $1.x }

        var angles: [CGFloat] = []
        var weights: [CGFloat] = []
        angles.reserveCapacity(px.count * (px.count - 1) / 2)
        weights.reserveCapacity(px.count * (px.count - 1) / 2)

        for i in 0..<(px.count - 1) {
            let a = px[i]
            for j in (i + 1)..<px.count {
                let b = px[j]
                let dx = b.x - a.x
                if dx < 3 { continue }
                let dy = b.y - a.y
                let angle = atan2(dy, dx)
                let maxAbsAngle = CGFloat.pi / 4.0
                if abs(angle) > maxAbsAngle { continue }

                // Cap the span weight so one long pair does not dominate everything.
                let wgt = min(dx, 120)
                angles.append(angle)
                weights.append(max(1, wgt))
            }
        }

        guard !angles.isEmpty else {
            return angleFromPointCloud(points, imageSize: imageSize)
        }

        return weightedMedianAngle(angles: angles, weights: weights)
    }

    private static func weightedMedianAngle(angles: [CGFloat], weights: [CGFloat]) -> CGFloat? {
        guard angles.count == weights.count, !angles.isEmpty else { return nil }

        let zipped = zip(angles, weights).sorted { $0.0 < $1.0 }
        let total = zipped.reduce(CGFloat(0)) { $0 + max(0, $1.1) }
        if total <= 0 { return nil }

        var acc: CGFloat = 0
        let half = total * 0.5
        for (a, w) in zipped {
            acc += max(0, w)
            if acc >= half {
                return a
            }
        }
        return zipped.last?.0
    }

    private static func dominantBaselineAngleFromCharacterBoxes(
        _ chars: [VNRectangleObservation],
        imageSize: CGSize
    ) -> CGFloat? {
        guard !chars.isEmpty else { return nil }

        struct Sample {
            let center: CGPoint
            let height: CGFloat
        }

        let samples: [Sample] = chars.map { c in
            let cx = (c.topLeft.x + c.topRight.x + c.bottomRight.x + c.bottomLeft.x) * 0.25
            let cy = (c.topLeft.y + c.topRight.y + c.bottomRight.y + c.bottomLeft.y) * 0.25
            let leftH = hypot(c.topLeft.x - c.bottomLeft.x, c.topLeft.y - c.bottomLeft.y)
            let rightH = hypot(c.topRight.x - c.bottomRight.x, c.topRight.y - c.bottomRight.y)
            return Sample(center: CGPoint(x: cx, y: cy), height: max(0, (leftH + rightH) * 0.5))
        }

        if samples.count < 3 {
            return angleFromPointCloud(samples.map(\.center), imageSize: imageSize)
        }

        let heights = samples.map(\.height).filter { $0 > 0 }
        let medianH = heights.isEmpty ? 0.01 : median(heights)
        let rowThreshold = max(0.0025, medianH * 0.8)

        let sorted = samples.sorted { $0.center.y > $1.center.y }
        var rows: [[CGPoint]] = []
        var rowMeanY: [CGFloat] = []

        for s in sorted {
            var assigned = false
            for i in 0..<rows.count {
                if abs(s.center.y - rowMeanY[i]) <= rowThreshold {
                    rows[i].append(s.center)
                    let n = CGFloat(rows[i].count)
                    rowMeanY[i] = rowMeanY[i] + (s.center.y - rowMeanY[i]) / n
                    assigned = true
                    break
                }
            }

            if !assigned {
                rows.append([s.center])
                rowMeanY.append(s.center.y)
            }
        }

        let widthPx = max(1.0, imageSize.width)
        var bestAngle: CGFloat?
        var bestSpanPx: CGFloat = -1
        var bestCount: Int = 0

        for row in rows {
            guard row.count >= 3 else { continue }
            guard let angle = angleFromPointCloud(row, imageSize: imageSize) else { continue }

            let xs = row.map(\.x)
            guard let minX = xs.min(), let maxX = xs.max() else { continue }
            let spanPx = (maxX - minX) * widthPx
            if spanPx < 10 { continue }

            if spanPx > bestSpanPx || (abs(spanPx - bestSpanPx) < 0.01 && row.count > bestCount) {
                bestSpanPx = spanPx
                bestCount = row.count
                bestAngle = angle
            }
        }

        if let best = bestAngle {
            return best
        }

        return angleFromPointCloud(samples.map(\.center), imageSize: imageSize)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }

        let interArea = inter.width * inter.height
        let union = (a.width * a.height) + (b.width * b.height) - interArea
        if union <= 0 { return 0 }
        return interArea / union
    }

    private static func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let top = min(a.maxY, b.maxY)
        let bottom = max(a.minY, b.minY)
        let h = max(0, top - bottom)
        let minH = min(a.height, b.height)
        if minH <= 0 { return 0 }
        return h / minH
    }

    private static func normalizedCenterDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let d = sqrt(dx * dx + dy * dy)
        let maxNorm: CGFloat = 0.75
        return min(1, d / maxNorm)
    }

    // MARK: - Local line angle model (Vision-only)

    private static func quadFromAxisAligned(_ bb: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let tl = CGPoint(x: bb.minX, y: bb.maxY)
        let tr = CGPoint(x: bb.maxX, y: bb.maxY)
        let br = CGPoint(x: bb.maxX, y: bb.minY)
        let bl = CGPoint(x: bb.minX, y: bb.minY)
        return (tl, tr, br, bl)
    }

    private static func quadCenterY(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) -> CGFloat {
        (tl.y + tr.y + br.y + bl.y) * 0.25
    }

    private static func buildCandidates(
        from recognizedText: VNRecognizedText,
        observation: VNRecognizedTextObservation,
        imageSize: CGSize
    ) -> [OCRCandidate] {
        let text = recognizedText.string
        guard !text.isEmpty else { return [] }

        let fullRange = text.startIndex..<text.endIndex
        let fullRect = try? recognizedText.boundingBox(for: fullRange)

        let baseTL: CGPoint
        let baseTR: CGPoint
        let baseBR: CGPoint
        let baseBL: CGPoint
        if let r = fullRect {
            baseTL = r.topLeft
            baseTR = r.topRight
            baseBR = r.bottomRight
            baseBL = r.bottomLeft
        } else {
            let (qtl, qtr, qbr, qbl) = quadFromAxisAligned(observation.boundingBox)
            baseTL = qtl
            baseTR = qtr
            baseBR = qbr
            baseBL = qbl
        }

        let baseBounds = axisAlignedBoundsOfQuad(tl: baseTL, tr: baseTR, br: baseBR, bl: baseBL)
        let baseMeasuredAngle = estimateLocalLineAngle(
            recognizedText: recognizedText,
            fallbackTL: baseTL,
            fallbackTR: baseTR,
            fallbackBR: baseBR,
            fallbackBL: baseBL,
            imageSize: imageSize
        )

        let segmentCount = desiredSegmentCount(for: text, baseBounds: baseBounds, imageSize: imageSize)
        let slices = textSlices(in: text, desiredCount: segmentCount)

        var out: [OCRCandidate] = []
        out.reserveCapacity(max(1, slices.count))

        for slice in slices {
            let segmentText = String(text[slice.range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if segmentText.isEmpty { continue }

            let segTL: CGPoint
            let segTR: CGPoint
            let segBR: CGPoint
            let segBL: CGPoint

            if let seg = try? recognizedText.boundingBox(for: slice.range) {
                segTL = seg.topLeft
                segTR = seg.topRight
                segBR = seg.bottomRight
                segBL = seg.bottomLeft
            } else {
                let total = max(1, text.count)
                let t0 = CGFloat(slice.startOffset) / CGFloat(total)
                let t1 = CGFloat(slice.endOffset) / CGFloat(total)
                (segTL, segTR, segBR, segBL) = quadSlice(
                    tl: baseTL,
                    tr: baseTR,
                    br: baseBR,
                    bl: baseBL,
                    startFrac: t0,
                    endFrac: t1
                )
            }

            let bounds = axisAlignedBoundsOfQuad(tl: segTL, tr: segTR, br: segBR, bl: segBL)
            if bounds.isEmpty { continue }

            let measured = angleFromQuad(
                tl: segTL,
                tr: segTR,
                br: segBR,
                bl: segBL,
                imageSize: imageSize
            ) ?? baseMeasuredAngle

            out.append(
                OCRCandidate(
                    text: segmentText,
                    tl: segTL,
                    tr: segTR,
                    br: segBR,
                    bl: segBL,
                    bounds: bounds,
                    centerY: quadCenterY(tl: segTL, tr: segTR, br: segBR, bl: segBL),
                    measuredAngle: measured,
                    isAxisAligned: isLikelyAxisAlignedQuad(
                        tl: segTL,
                        tr: segTR,
                        br: segBR,
                        bl: segBL,
                        imageSize: imageSize
                    )
                )
            )
        }

        if !out.isEmpty {
            return out
        }

        return [
            OCRCandidate(
                text: text,
                tl: baseTL,
                tr: baseTR,
                br: baseBR,
                bl: baseBL,
                bounds: baseBounds,
                centerY: quadCenterY(tl: baseTL, tr: baseTR, br: baseBR, bl: baseBL),
                measuredAngle: baseMeasuredAngle,
                isAxisAligned: isLikelyAxisAlignedQuad(
                    tl: baseTL,
                    tr: baseTR,
                    br: baseBR,
                    bl: baseBL,
                    imageSize: imageSize
                )
            )
        ]
    }

    private static func desiredSegmentCount(for text: String, baseBounds: CGRect, imageSize: CGSize) -> Int {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount < 3 { return 1 }

        let widthPx = baseBounds.width * max(1, imageSize.width)
        let n = text.count

        if n > 110 || widthPx > 1250 { return 4 }
        if n > 70 || widthPx > 850 { return 3 }
        if n > 34 || widthPx > 460 { return 2 }
        return 1
    }

    private static func textSlices(in text: String, desiredCount: Int) -> [TextSlice] {
        let total = text.count
        guard total > 0 else { return [] }

        let count = max(1, min(desiredCount, total))
        if count == 1 {
            return [TextSlice(range: text.startIndex..<text.endIndex, startOffset: 0, endOffset: total)]
        }

        let chars = Array(text)
        var boundaries = Array(repeating: 0, count: count + 1)
        boundaries[0] = 0
        boundaries[count] = total
        for i in 1..<count {
            boundaries[i] = (total * i) / count
        }

        for i in 1..<count {
            let target = boundaries[i]
            let lo = max(boundaries[i - 1] + 1, target - 8)
            let hi = min(boundaries[i + 1] - 1, target + 8)
            var best = target
            var bestDist = Int.max

            if lo <= hi {
                for p in lo...hi {
                    if characterIsWhitespace(chars[p]) {
                        let d = abs(p - target)
                        if d < bestDist {
                            bestDist = d
                            best = p
                        }
                    }
                }
            }
            boundaries[i] = best
        }

        for i in 1...count {
            if boundaries[i] <= boundaries[i - 1] {
                boundaries[i] = min(total, boundaries[i - 1] + 1)
            }
        }

        var out: [TextSlice] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            if end <= start { continue }

            let lower = text.index(text.startIndex, offsetBy: start)
            let upper = text.index(text.startIndex, offsetBy: end)
            out.append(TextSlice(range: lower..<upper, startOffset: start, endOffset: end))
        }

        if out.isEmpty {
            out.append(TextSlice(range: text.startIndex..<text.endIndex, startOffset: 0, endOffset: total))
        }
        return out
    }

    private static func characterIsWhitespace(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }

    private static func quadSlice(
        tl: CGPoint,
        tr: CGPoint,
        br: CGPoint,
        bl: CGPoint,
        startFrac: CGFloat,
        endFrac: CGFloat
    ) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let t0 = min(max(startFrac, 0), 1)
        let t1 = min(max(endFrac, 0), 1)
        let lo = min(t0, t1)
        let hi = max(t0, t1)

        let stl = lerp(tl, tr, lo)
        let str = lerp(tl, tr, hi)
        let sbl = lerp(bl, br, lo)
        let sbr = lerp(bl, br, hi)
        return (stl, str, sbr, sbl)
    }

    private static func estimateLocalLineAngle(
        recognizedText: VNRecognizedText,
        fallbackTL: CGPoint,
        fallbackTR: CGPoint,
        fallbackBR: CGPoint,
        fallbackBL: CGPoint,
        imageSize: CGSize
    ) -> CGFloat? {
        let centers = sampledCenters(for: recognizedText)
        if let angle = angleFromPointCloud(centers, imageSize: imageSize) {
            return angle
        }

        return angleFromQuad(
            tl: fallbackTL,
            tr: fallbackTR,
            br: fallbackBR,
            bl: fallbackBL,
            imageSize: imageSize
        )
    }

    private static func sampledCenters(for recognizedText: VNRecognizedText) -> [CGPoint] {
        let s = recognizedText.string
        let n = s.count
        guard n > 0 else { return [] }

        var ranges: [Range<String.Index>] = []
        ranges.reserveCapacity(12)
        ranges.append(s.startIndex..<s.endIndex)

        if n >= 3 {
            let segmentCount = min(10, max(3, n / 5))
            for i in 0..<segmentCount {
                let startOffset = (n * i) / segmentCount
                let endOffset = (n * (i + 1)) / segmentCount
                if endOffset <= startOffset { continue }

                let start = s.index(s.startIndex, offsetBy: startOffset)
                let end = s.index(s.startIndex, offsetBy: endOffset)
                ranges.append(start..<end)
            }
        }

        var points: [CGPoint] = []
        points.reserveCapacity(ranges.count)

        for r in ranges {
            guard let rect = try? recognizedText.boundingBox(for: r) else { continue }
            let cx = (rect.topLeft.x + rect.topRight.x + rect.bottomRight.x + rect.bottomLeft.x) * 0.25
            let cy = (rect.topLeft.y + rect.topRight.y + rect.bottomRight.y + rect.bottomLeft.y) * 0.25
            points.append(CGPoint(x: cx, y: cy))
        }

        // De-duplicate near-identical centers.
        var unique: [CGPoint] = []
        unique.reserveCapacity(points.count)
        for p in points {
            let exists = unique.contains { q in
                abs(q.x - p.x) < 0.001 && abs(q.y - p.y) < 0.001
            }
            if !exists {
                unique.append(p)
            }
        }
        return unique
    }

    private static func angleFromPointCloud(_ points: [CGPoint], imageSize: CGSize) -> CGFloat? {
        guard points.count >= 2 else { return nil }

        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)

        let pixelPoints = points.map { CGPoint(x: $0.x * w, y: $0.y * h) }

        let meanX = pixelPoints.reduce(0.0) { $0 + $1.x } / CGFloat(pixelPoints.count)
        let meanY = pixelPoints.reduce(0.0) { $0 + $1.y } / CGFloat(pixelPoints.count)

        var num: CGFloat = 0
        var den: CGFloat = 0
        for p in pixelPoints {
            let dx = p.x - meanX
            let dy = p.y - meanY
            num += dx * dy
            den += dx * dx
        }

        if den <= 1e-6 {
            if pixelPoints.count == 2 {
                let a = pixelPoints[0]
                let b = pixelPoints[1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                if abs(dx) > 1e-6 {
                    return atan2(dy, dx)
                }
            }
            return nil
        }

        let slope = num / den
        let angle = atan(slope)
        let maxAbsAngle = CGFloat.pi / 4.0
        if abs(angle) > maxAbsAngle {
            return nil
        }
        return angle
    }

    private static func angleFromQuad(
        tl: CGPoint,
        tr: CGPoint,
        br _: CGPoint,
        bl _: CGPoint,
        imageSize: CGSize
    ) -> CGFloat? {
        let w = max(1.0, imageSize.width)
        let h = max(1.0, imageSize.height)
        let dx = (tr.x - tl.x) * w
        let dy = (tr.y - tl.y) * h
        if abs(dx) <= 1e-6 { return nil }

        let angle = atan2(dy, dx)
        let maxAbsAngle = CGFloat.pi / 4.0
        if abs(angle) > maxAbsAngle {
            return nil
        }
        return angle
    }

    private static func buildLocalAngleModel(from candidates: [OCRCandidate], bandCount: Int) -> LocalAngleModel {
        let count = max(1, bandCount)
        let samples: [LineAngleSample] = candidates.compactMap { c in
            guard let angle = c.measuredAngle else { return nil }
            let maxAbsAngle = CGFloat.pi / 4.0
            if abs(angle) > maxAbsAngle { return nil }
            return LineAngleSample(yNorm: c.centerY, angle: angle)
        }

        guard !samples.isEmpty else {
            return LocalAngleModel(bandAngles: Array(repeating: 0, count: count))
        }

        var perBand: [[CGFloat]] = Array(repeating: [], count: count)
        for s in samples {
            let y = min(max(s.yNorm, 0), 1)
            var idx = Int((y * CGFloat(count)).rounded(.down))
            if idx >= count { idx = count - 1 }
            if idx < 0 { idx = 0 }
            perBand[idx].append(s.angle)
        }

        var bandAngles: [CGFloat?] = perBand.map { list in
            guard !list.isEmpty else { return nil }
            return median(list)
        }

        // Fill empty bands by linear interpolation between nearest non-empty neighbors.
        for i in 0..<count where bandAngles[i] == nil {
            var left = i - 1
            while left >= 0, bandAngles[left] == nil { left -= 1 }
            var right = i + 1
            while right < count, bandAngles[right] == nil { right += 1 }

            switch (left >= 0 ? bandAngles[left] : nil, right < count ? bandAngles[right] : nil) {
            case let (l?, r?):
                let t = CGFloat(i - left) / CGFloat(right - left)
                bandAngles[i] = l * (1 - t) + r * t
            case let (l?, nil):
                bandAngles[i] = l
            case let (nil, r?):
                bandAngles[i] = r
            default:
                bandAngles[i] = 0
            }
        }

        // Light smoothing to avoid abrupt band jumps.
        let raw = bandAngles.map { $0 ?? 0 }
        var smooth = raw
        if count >= 3 {
            for i in 0..<count {
                let left = raw[max(0, i - 1)]
                let mid = raw[i]
                let right = raw[min(count - 1, i + 1)]
                smooth[i] = left * 0.25 + mid * 0.5 + right * 0.25
            }
        }

        return LocalAngleModel(bandAngles: smooth)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5
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

    private static func imageToPDFTransform(
        for cgPage: CGPDFPage,
        box: CGPDFBox,
        targetRect: CGRect,
        rotate: Int32,
        imageSize: CGSize
    ) -> CGAffineTransform {
        let t = cgPage.getDrawingTransform(box, rect: targetRect, rotate: rotate, preserveAspectRatio: false)
        let sx = targetRect.width > 0 ? (imageSize.width / targetRect.width) : 1
        let sy = targetRect.height > 0 ? (imageSize.height / targetRect.height) : 1
        let pdfToImage = CGAffineTransform(scaleX: sx, y: sy).concatenating(t)
        return pdfToImage.inverted()
    }

    // MARK: - Invisible text overlay

    private static func overlayInvisibleText(
        _ boxes: [OCRBox],
        in ctx: CGContext,
        imageSize: CGSize,
        imageToPDF: CGAffineTransform
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

            let tl = tlPx.applying(imageToPDF)
            let tr = trPx.applying(imageToPDF)
            let br = brPx.applying(imageToPDF)
            let bl = blPx.applying(imageToPDF)

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

    // MARK: - Image scaling
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

    private static func scaleCGImageByRedraw(cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else { return nil }

        let scale = maxDimension / max(w, h)
        guard scale < 1 else { return cgImage }

        let dstW = max(1, Int((w * scale).rounded()))
        let dstH = max(1, Int((h * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage()
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
} // end of enum VisionOCRService
