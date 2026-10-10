import Foundation
import AppKit
import PDFKit
import SwiftUI

/// Utility for detecting, extracting, and importing PDF annotations/highlights as study notebook cards.
public final class PDFHighlightImporter: @unchecked Sendable {

    /// Represents a raw extracted highlight from a PDF document.
    public struct ExtractedHighlight: @unchecked Sendable {
        public let id: UUID
        public let pageIndex: Int
        public let bounds: CGRect
        public let text: String
        public let note: String
        public let color: NSColor
        public let colorIndex: Int
        public let lineRects: [HighlightRect]
        public let annotation: PDFAnnotation

        public init(
            id: UUID = UUID(),
            pageIndex: Int,
            bounds: CGRect,
            text: String,
            note: String = "",
            color: NSColor,
            colorIndex: Int,
            lineRects: [HighlightRect],
            annotation: PDFAnnotation
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
            self.note = note
            self.color = color
            self.colorIndex = colorIndex
            self.lineRects = lineRects
            self.annotation = annotation
        }
    }

    /// Fast scan to check if a PDF document contains any highlight annotations or notes.
    public static func hasHighlights(in document: PDFDocument) -> Bool {
        for pageIdx in 0..<document.pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            for annot in page.annotations {
                let type = annot.type ?? ""
                if type == "Highlight" || type == "Underline" || type == "StrikeOut" {
                    return true
                }
                if let contents = annot.contents?.trimmingCharacters(in: .whitespacesAndNewlines), !contents.isEmpty {
                    return true
                }
            }
        }
        return false
    }

    /// Returns the total count of highlight annotations and notes in the PDF document.
    public static func countHighlights(in document: PDFDocument) -> Int {
        var count = 0
        for pageIdx in 0..<document.pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            for annot in page.annotations {
                let type = annot.type ?? ""
                if type == "Highlight" || type == "Underline" || type == "StrikeOut" {
                    count += 1
                } else if let contents = annot.contents?.trimmingCharacters(in: .whitespacesAndNewlines), !contents.isEmpty {
                    count += 1
                }
            }
        }
        return count
    }

    /// RGB components container for color distance calculations.
    public struct ColorRGB: Hashable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public init?(color: NSColor) {
            guard let rgb = color.usingColorSpace(.deviceRGB) ?? color.usingColorSpace(.sRGB) else { return nil }
            self.r = Double(rgb.redComponent)
            self.g = Double(rgb.greenComponent)
            self.b = Double(rgb.blueComponent)
        }
    }

    /// Converts RGB components (0...1) to HSV (h: 0..<360, s: 0...1, v: 0...1).
    public static func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var h: Double = 0.0
        if delta > 1e-5 {
            if maxV == r {
                h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxV == g {
                h = 60.0 * (((b - r) / delta) + 2.0)
            } else {
                h = 60.0 * (((r - g) / delta) + 4.0)
            }
            if h < 0 { h += 360.0 }
        }
        let s = maxV > 1e-5 ? delta / maxV : 0.0
        return (h, s, maxV)
    }

    /// Circular shortest angular distance between two hues in degrees [0...180].
    public static func hueDifference(_ h1: Double, _ h2: Double) -> Double {
        let d = abs(h1 - h2).truncatingRemainder(dividingBy: 360.0)
        return d > 180.0 ? 360.0 - d : d
    }

    /// Perceptual color distance heavily weighted by hue angle, suitable for highlight annotations.
    public static func perceptualDistance(c1: (r: Double, g: Double, b: Double), c2: (r: Double, g: Double, b: Double)) -> Double {
        let (h1, s1, v1) = rgbToHsv(r: c1.r, g: c1.g, b: c1.b)
        let (h2, s2, v2) = rgbToHsv(r: c2.r, g: c2.g, b: c2.b)

        let isGray1 = s1 < 0.08
        let isGray2 = s2 < 0.08

        if isGray1 || isGray2 {
            if isGray1 && isGray2 {
                return abs(v1 - v2)
            }
            return 10.0 + abs(v1 - v2)
        }

        let hDiff = hueDifference(h1, h2) / 180.0
        let sDiff = abs(s1 - s2)
        let vDiff = abs(v1 - v2)

        return (hDiff * hDiff * 5.0) + (sDiff * sDiff * 0.5) + (vDiff * vDiff * 0.5)
    }

    /// Checks if two NSColors represent the same highlight color pen in the PDF.
    public static func isSamePDFColor(_ c1: NSColor, _ c2: NSColor) -> Bool {
        guard let rgb1 = ColorRGB(color: c1), let rgb2 = ColorRGB(color: c2) else {
            return false
        }
        let dist = perceptualDistance(c1: (rgb1.r, rgb1.g, rgb1.b), c2: (rgb2.r, rgb2.g, rgb2.b))
        return dist <= 0.04
    }

    /// Solves minimum weight bipartite matching (Hungarian algorithm) for assigning N clusters to M palette colors (M >= N).
    /// Guarantees that each cluster gets a unique, collision-free palette index.
    public static func minCostBipartiteMatching(costs: [[Double]]) -> [Int] {
        let n = costs.count
        guard n > 0 else { return [] }
        let m = costs[0].count
        guard m >= n else { return [] }

        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: m + 1)
        var p = Array(repeating: 0, count: m + 1)
        var way = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m {
                    if !used[j] {
                        let cur = costs[i0 - 1][j - 1] - u[i0] - v[j]
                        if cur < minv[j] {
                            minv[j] = cur
                            way[j] = j0
                        }
                        if minv[j] < delta {
                            delta = minv[j]
                            j1 = j
                        }
                    }
                }
                for j in 0...m {
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

        var result = Array(repeating: -1, count: n)
        for j in 1...m {
            if p[j] > 0 && p[j] <= n {
                result[p[j] - 1] = j - 1
            }
        }
        return result
    }

    /// Maps a single NSColor to the closest MarginNoteTheme pastel colorIndex (0...15) based on perceptual color distance.
    public static func colorIndex(for color: NSColor) -> Int {
        guard let rgb = ColorRGB(color: color) else { return 0 }
        let palValues = MarginNoteTheme.paletteRGBValues

        var bestIdx = 0
        var bestDist = Double.infinity

        for (idx, pRGB) in palValues.enumerated() {
            let dist = perceptualDistance(
                c1: (rgb.r, rgb.g, rgb.b),
                c2: (pRGB.r, pRGB.g, pRGB.b)
            )
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }

    /// Color cluster structure representing distinct highlight colors used across a PDF document.
    public struct PDFColorCluster: Sendable {
        public var r: Double
        public var g: Double
        public var b: Double
        public var count: Int
    }

    /// Analyzes all highlight annotations across the PDF document and produces an optimal,
    /// collision-free mapping from PDF colors to MarginGraph's 16 pastel palette colors.
    /// Different highlight colors in the PDF are mapped to distinct colors in our program whenever possible.
    public static func buildDocumentColorMapping(for document: PDFDocument) -> @Sendable (NSColor) -> Int {
        var clusters: [PDFColorCluster] = []

        for pageIdx in 0..<document.pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            for annot in page.annotations {
                let type = annot.type ?? ""
                guard type == "Highlight" || type == "Underline" || type == "StrikeOut" ||
                      (annot.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
                    continue
                }
                guard let rgb = ColorRGB(color: annot.color) else { continue }

                // Check if color belongs to an existing cluster (threshold 0.035)
                var matchedIdx: Int?
                for (cIdx, cluster) in clusters.enumerated() {
                    let dist = perceptualDistance(c1: (rgb.r, rgb.g, rgb.b), c2: (cluster.r, cluster.g, cluster.b))
                    if dist <= 0.035 {
                        matchedIdx = cIdx
                        break
                    }
                }

                if let idx = matchedIdx {
                    clusters[idx].count += 1
                    let total = Double(clusters[idx].count)
                    clusters[idx].r = (clusters[idx].r * (total - 1.0) + rgb.r) / total
                    clusters[idx].g = (clusters[idx].g * (total - 1.0) + rgb.g) / total
                    clusters[idx].b = (clusters[idx].b * (total - 1.0) + rgb.b) / total
                } else {
                    clusters.append(PDFColorCluster(r: rgb.r, g: rgb.g, b: rgb.b, count: 1))
                }
            }
        }

        guard !clusters.isEmpty else {
            return { colorIndex(for: $0) }
        }

        // Sort clusters by frequency descending
        clusters.sort { $0.count > $1.count }

        let palValues = MarginNoteTheme.paletteRGBValues
        let totalPaletteCount = palValues.count // 16

        // Up to 16 clusters can have strictly distinct palette assignments
        let distinctClusterCount = min(clusters.count, totalPaletteCount)
        let topClusters = Array(clusters.prefix(distinctClusterCount))

        var costMatrix: [[Double]] = []
        for cluster in topClusters {
            var row: [Double] = []
            for pal in palValues {
                let dist = perceptualDistance(c1: (cluster.r, cluster.g, cluster.b), c2: (pal.r, pal.g, pal.b))
                row.append(dist)
            }
            costMatrix.append(row)
        }

        let assignment = minCostBipartiteMatching(costs: costMatrix)

        var clusterToPalette: [Int: Int] = [:]
        for (clusterIdx, palIdx) in assignment.enumerated() {
            clusterToPalette[clusterIdx] = palIdx
        }

        // For any clusters beyond 16 (rare edge case), fall back to closest individual palette match
        if clusters.count > totalPaletteCount {
            for clusterIdx in totalPaletteCount..<clusters.count {
                let cluster = clusters[clusterIdx]
                var bestPal = 0
                var bestDist = Double.infinity
                for (pIdx, pal) in palValues.enumerated() {
                    let d = perceptualDistance(c1: (cluster.r, cluster.g, cluster.b), c2: (pal.r, pal.g, pal.b))
                    if d < bestDist {
                        bestDist = d
                        bestPal = pIdx
                    }
                }
                clusterToPalette[clusterIdx] = bestPal
            }
        }

        let finalClusters = clusters
        let finalMapping = clusterToPalette

        return { color in
            guard let rgb = ColorRGB(color: color) else { return 0 }

            var bestClusterIdx = 0
            var bestClusterDist = Double.infinity
            for (cIdx, cluster) in finalClusters.enumerated() {
                let d = perceptualDistance(c1: (rgb.r, rgb.g, rgb.b), c2: (cluster.r, cluster.g, cluster.b))
                if d < bestClusterDist {
                    bestClusterDist = d
                    bestClusterIdx = cIdx
                }
            }

            if bestClusterDist <= 0.05, let palIdx = finalMapping[bestClusterIdx] {
                return palIdx
            }

            return colorIndex(for: color)
        }
    }

    /// Cleans and joins text runs within a single physical line, removing spurious newlines emitted by PDFKit
    /// between adjacent text runs, and properly attaching punctuation (quotes, periods, commas, etc.).
    public static func cleanPhysicalLineText(from selection: PDFSelection?) -> String {
        guard let selection = selection else { return "" }
        let rawStr = selection.string ?? ""
        guard !rawStr.isEmpty else { return "" }

        // Split by all forms of line breaks (LF, CR, CRLF)
        let rawChunks = rawStr.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !rawChunks.isEmpty else { return "" }
        if rawChunks.count == 1 {
            return rawChunks[0]
        }

        var result = ""
        let noSpaceBeforeChars: Set<Character> = [
            "’", "'", "”", "\"", ")", "]", "}", "）", "】", "」", "』",
            ",", ".", ";", ":", "!", "?", "…", "%", "°", "–", "—"
        ]

        for chunk in rawChunks {
            if result.isEmpty {
                result = chunk
            } else {
                let firstChar = chunk.first!
                if noSpaceBeforeChars.contains(firstChar) {
                    result += chunk
                } else if result.hasSuffix("‘") || result.hasSuffix("“") || result.hasSuffix("(") || result.hasSuffix("[") || result.hasSuffix("（") || result.hasSuffix("【") {
                    result += chunk
                } else {
                    result += " " + chunk
                }
            }
        }
        return result
    }

    /// Extracts exact line rectangles and text from an annotation, using quadrilateralPoints when available
    /// to avoid bounding box expansion, overlap contamination, and accidental link interception.
    public static func extractAnnotationLineRectsAndText(
        annotation: PDFAnnotation,
        on page: PDFPage,
        pageIndex: Int,
        document: PDFDocument
    ) -> (text: String, lineRects: [HighlightRect]) {
        if let quads = annotation.quadrilateralPoints, !quads.isEmpty {
            var maxPtX: CGFloat = 0
            var maxPtY: CGFloat = 0
            for ptVal in quads {
                let pt = ptVal.pointValue
                maxPtX = max(maxPtX, pt.x)
                maxPtY = max(maxPtY, pt.y)
            }
            let isRelative = (maxPtX <= annotation.bounds.width + 2.0 && maxPtY <= annotation.bounds.height + 2.0)

            var rawLines: [(rect: CGRect, text: String)] = []
            for q in 0..<(quads.count / 4) {
                let p1 = quads[q * 4].pointValue
                let p2 = quads[q * 4 + 1].pointValue
                let p3 = quads[q * 4 + 2].pointValue
                let p4 = quads[q * 4 + 3].pointValue

                let minX = min(p1.x, p2.x, p3.x, p4.x)
                let maxX = max(p1.x, p2.x, p3.x, p4.x)
                let minY = min(p1.y, p2.y, p3.y, p4.y)
                let maxY = max(p1.y, p2.y, p3.y, p4.y)

                let pageX = isRelative ? annotation.bounds.origin.x + minX : minX
                let pageY = isRelative ? annotation.bounds.origin.y + minY : minY
                let width = maxX - minX
                let height = maxY - minY
                let lineBox = CGRect(x: pageX, y: pageY, width: width, height: height)

                // Get selection for this line with small epsilon
                let sel = page.selection(for: lineBox.insetBy(dx: -0.5, dy: -0.5))
                let text = cleanPhysicalLineText(from: sel)
                if !text.isEmpty {
                    rawLines.append((rect: lineBox, text: text))
                }
            }

            // Sort lines in reading order (top-to-bottom: descending Y, ascending X)
            let sortedLines = rawLines.sorted { l1, l2 in
                if abs(l1.rect.maxY - l2.rect.maxY) > 4.0 {
                    return l1.rect.maxY > l2.rect.maxY
                }
                return l1.rect.minX < l2.rect.minX
            }

            let highlightRects = sortedLines.map {
                HighlightRect(
                    page: pageIndex,
                    x: $0.rect.origin.x,
                    y: $0.rect.origin.y,
                    width: $0.rect.width,
                    height: $0.rect.height
                )
            }

            // Group lines and preserve paragraph breaks
            let physicalLines = sortedLines.map {
                PDFHighlightResolver.PhysicalLine(text: $0.text, bounds: $0.rect, page: page)
            }
            let formattedText = PDFHighlightResolver.buildParagraphs(
                from: physicalLines,
                fallbackRaw: sortedLines.map(\.text).joined(separator: " ")
            )

            return (text: formattedText, lineRects: highlightRects)
        }

        // Fallback for annotations without quadrilateral points
        var extractedText = ""
        var lineRects: [HighlightRect] = []

        if let sel = page.selection(for: annotation.bounds) {
            extractedText = PDFHighlightResolver.normalizeExcerptParagraphs(sel)
            lineRects = PDFHighlightResolver.lineRects(from: sel, document: document)
        }

        if extractedText.isEmpty, let rawStr = page.selection(for: annotation.bounds)?.string {
            extractedText = PDFHighlightResolver.normalizeExcerptParagraphs(rawStr)
        }

        if lineRects.isEmpty {
            lineRects = [
                HighlightRect(
                    page: pageIndex,
                    x: annotation.bounds.origin.x,
                    y: annotation.bounds.origin.y,
                    width: annotation.bounds.width,
                    height: annotation.bounds.height
                )
            ]
        }

        return (text: extractedText, lineRects: lineRects)
    }

    /// Extracts all highlight annotations from the PDF in document reading order,
    /// using optimal document-wide color mapping to preserve distinct colors without collisions.
    public static func extractHighlights(from document: PDFDocument) -> [ExtractedHighlight] {
        var results: [ExtractedHighlight] = []
        let documentColorMap = buildDocumentColorMapping(for: document)

        for pageIdx in 0..<document.pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            let annots = page.annotations.filter { annot in
                let type = annot.type ?? ""
                return type == "Highlight" || type == "Underline" || type == "StrikeOut" ||
                    (annot.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }

            // Sort on the page in top-to-bottom reading order (y descending, x ascending)
            let sortedAnnots = annots.sorted { a1, a2 in
                if abs(a1.bounds.maxY - a2.bounds.maxY) > 5.0 {
                    return a1.bounds.maxY > a2.bounds.maxY
                }
                return a1.bounds.minX < a2.bounds.minX
            }

            for annot in sortedAnnots {
                let note = annot.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let color = annot.color
                let colorIdx = documentColorMap(color)

                let (extractedText, lineRects) = extractAnnotationLineRectsAndText(
                    annotation: annot,
                    on: page,
                    pageIndex: pageIdx,
                    document: document
                )

                results.append(ExtractedHighlight(
                    pageIndex: pageIdx,
                    bounds: annot.bounds,
                    text: extractedText,
                    note: note,
                    color: color,
                    colorIndex: colorIdx,
                    lineRects: lineRects,
                    annotation: annot
                ))
            }
        }

        return results
    }

    /// Determines whether the text in a region between highlights represents an ignorable link, footnote citation, or whitespace.
    public static func isIgnorableBetweenText(
        _ text: String,
        rect: CGRect,
        on page: PDFPage
    ) -> Bool {
        let ignorableChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑‒–—"))
        let trimmed = text.trimmingCharacters(in: ignorableChars)
        if trimmed.isEmpty { return true }

        // 1. Footnote citation regex: digits, bracketed digits, parens, footnote symbols (*, †, ‡, §)
        // e.g. "19", "20", "[20]", "(20)", "19, 20", "19–21", "*", "†"
        let citationPattern = #"^\[?(\d+|[a-zA-Z]|\*|\†|\‡|\§)([\s,–—\-\.]+(\d+|[a-zA-Z]|\*|\†|\‡|\§))*\]?$"#
        if trimmed.range(of: citationPattern, options: .regularExpression) != nil && trimmed.count <= 25 {
            return true
        }

        // 2. Link annotations: check if a link annotation covers/intersects this gap
        let linkAnnots = page.annotations.filter { annot in
            annot.type == "Link" || annot.url != nil || annot.destination != nil || annot.action != nil
        }
        for link in linkAnnots {
            if rect.insetBy(dx: -4.0, dy: -4.0).intersects(link.bounds) {
                let linkText = page.selection(for: link.bounds)?.string?.trimmingCharacters(in: ignorableChars) ?? ""
                if linkText.isEmpty || trimmed == linkText || linkText.contains(trimmed) || trimmed.contains(linkText) {
                    return true
                }
            }
        }

        return false
    }

    /// Determines whether two adjacent highlights in reading order are consecutive:
    /// 1. Have the same color pen in the PDF and map to the same palette color
    /// 2. Have no unhighlighted body text between them on the same page (whitespace, early line breaks,
    ///    and footnote links/citations are allowed), or flow continuously across adjacent pages.
    public static func areConsecutive(
        h1: ExtractedHighlight,
        h2: ExtractedHighlight,
        in document: PDFDocument
    ) -> Bool {
        // 1. Same color check:
        // Must match mapped palette index AND must be the same color pen in the PDF
        guard h1.colorIndex == h2.colorIndex else { return false }
        guard isSamePDFColor(h1.color, h2.color) else { return false }

        let ignorableChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑‒–—"))

        // 2. Case A: Same page
        if h1.pageIndex == h2.pageIndex {
            guard let page = document.page(at: h1.pageIndex) else { return false }
            let rects1 = h1.lineRects.isEmpty ? [HighlightRect(page: h1.pageIndex, x: h1.bounds.minX, y: h1.bounds.minY, width: h1.bounds.width, height: h1.bounds.height)] : h1.lineRects
            let rects2 = h2.lineRects.isEmpty ? [HighlightRect(page: h2.pageIndex, x: h2.bounds.minX, y: h2.bounds.minY, width: h2.bounds.width, height: h2.bounds.height)] : h2.lineRects

            guard let lastLine1 = rects1.last, let firstLine2 = rects2.first else { return false }

            let crop = page.bounds(for: .cropBox)
            let lastRect1 = CGRect(x: lastLine1.x, y: lastLine1.y, width: lastLine1.width, height: lastLine1.height)
            let firstRect2 = CGRect(x: firstLine2.x, y: firstLine2.y, width: firstLine2.width, height: firstLine2.height)
            let maxLineH = max(lastRect1.height, firstRect2.height)

            // Direct line proximity check: line 1 must be on the same line or above line 2
            guard lastRect1.minY >= firstRect2.minY - 4.0 else { return false }

            // Subcase A1: Same physical line
            if abs(lastRect1.minY - firstRect2.minY) <= 4.0 {
                // In reading order, firstRect2 must be to the right of lastRect1
                guard firstRect2.minX >= lastRect1.maxX - 4.0 else { return false }
                let gapRect = CGRect(
                    x: lastRect1.maxX,
                    y: min(lastRect1.minY, firstRect2.minY),
                    width: max(0, firstRect2.minX - lastRect1.maxX),
                    height: maxLineH
                )
                let gapText = page.selection(for: gapRect)?.string ?? ""
                if gapRect.width <= 25.0 || isIgnorableBetweenText(gapText, rect: gapRect, on: page) {
                    return true
                }
                return false
            }

            // Subcase A2: Line 2 is below Line 1
            let dy = lastRect1.minY - firstRect2.minY
            // Limit vertical separation to reasonable line / paragraph spacing (up to ~3.5 lines)
            guard dy <= maxLineH * 3.5 else { return false }

            // Check if there is any unhighlighted body text between lastRect1 and firstRect2:
            // 1. After lastRect1 on line 1 (early line break area)
            let restOfLine1 = CGRect(
                x: lastRect1.maxX,
                y: lastRect1.minY,
                width: max(0, crop.maxX - lastRect1.maxX),
                height: lastRect1.height
            )
            // 2. Intermediate gap between lines (if any body lines exist between them)
            let gapBetweenLines = CGRect(
                x: crop.minX,
                y: firstRect2.maxY,
                width: crop.width,
                height: max(0, lastRect1.minY - firstRect2.maxY)
            )
            // 3. Before firstRect2 on line 2 (indent / leading text area)
            let startOfLine2 = CGRect(
                x: crop.minX,
                y: firstRect2.minY,
                width: max(0, firstRect2.minX - crop.minX),
                height: firstRect2.height
            )

            let textRest1 = page.selection(for: restOfLine1)?.string ?? ""
            let textGap = page.selection(for: gapBetweenLines)?.string ?? ""
            let textStart2 = page.selection(for: startOfLine2)?.string ?? ""

            if isIgnorableBetweenText(textRest1, rect: restOfLine1, on: page) &&
               isIgnorableBetweenText(textGap, rect: gapBetweenLines, on: page) &&
               isIgnorableBetweenText(textStart2, rect: startOfLine2, on: page) {
                return true
            }

            return false
        }

        // 3. Case B: Cross-page adjacency (Page P and Page P + 1)
        if h2.pageIndex == h1.pageIndex + 1 {
            guard let p1 = document.page(at: h1.pageIndex),
                  let p2 = document.page(at: h2.pageIndex) else { return false }
            let crop1 = p1.bounds(for: .cropBox)
            let crop2 = p2.bounds(for: .cropBox)

            let rects1 = h1.lineRects.isEmpty ? [HighlightRect(page: h1.pageIndex, x: h1.bounds.minX, y: h1.bounds.minY, width: h1.bounds.width, height: h1.bounds.height)] : h1.lineRects
            let rects2 = h2.lineRects.isEmpty ? [HighlightRect(page: h2.pageIndex, x: h2.bounds.minX, y: h2.bounds.minY, width: h2.bounds.width, height: h2.bounds.height)] : h2.lineRects

            guard let last1 = rects1.last, let first2 = rects2.first else { return false }
            let lastRect1 = CGRect(x: last1.x, y: last1.y, width: last1.width, height: last1.height)
            let firstRect2 = CGRect(x: first2.x, y: first2.y, width: first2.width, height: first2.height)

            // Check 1: Rest of line 1 on page 1
            let rest1 = CGRect(x: lastRect1.maxX, y: lastRect1.minY, width: max(0, crop1.maxX - lastRect1.maxX), height: lastRect1.height)
            let textRest1 = p1.selection(for: rest1)?.string ?? ""
            guard isIgnorableBetweenText(textRest1, rect: rest1, on: p1) else { return false }

            // Check 2: Area below h1 on page 1 (excluding page footer/page numbers)
            let boxBelow = CGRect(x: crop1.minX, y: crop1.minY, width: crop1.width, height: max(0, lastRect1.minY - crop1.minY))
            let textBelow = p1.selection(for: boxBelow)?.string?.trimmingCharacters(in: ignorableChars) ?? ""
            let isOnlyFooter = textBelow.isEmpty || Int(textBelow) != nil || textBelow.count <= 6

            // Check 3: Area above h2 on page 2 (excluding page header/chapter titles)
            let boxAbove = CGRect(x: crop2.minX, y: firstRect2.maxY, width: crop2.width, height: max(0, crop2.maxY - firstRect2.maxY))
            let textAbove = p2.selection(for: boxAbove)?.string?.trimmingCharacters(in: ignorableChars) ?? ""
            let isOnlyHeader = textAbove.isEmpty || Int(textAbove) != nil || textAbove.count <= 6

            // Check 4: Leading text before h2 on its first line
            let start2 = CGRect(x: crop2.minX, y: firstRect2.minY, width: max(0, firstRect2.minX - crop2.minX), height: firstRect2.height)
            let textStart2 = p2.selection(for: start2)?.string ?? ""
            guard isIgnorableBetweenText(textStart2, rect: start2, on: p2) else { return false }

            return isOnlyFooter && isOnlyHeader
        }

        return false
    }

    /// Determines whether there is a paragraph boundary between two consecutive highlights.
    public static func isParagraphBreakBetween(
        prev: ExtractedHighlight,
        next: ExtractedHighlight
    ) -> Bool {
        if prev.text.hasSuffix("\n") || next.text.hasPrefix("\n") {
            return true
        }

        guard let last1 = prev.lineRects.last, let first2 = next.lineRects.first else {
            return false
        }

        let prevText = prev.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closingChars = CharacterSet(charactersIn: "”\"'’)]}）】」』”’")
        let cleanPunct = prevText.trimmingCharacters(in: closingChars)
        let endsWithPunct = cleanPunct.hasSuffix(".") || cleanPunct.hasSuffix("!") || cleanPunct.hasSuffix("?") ||
                            cleanPunct.hasSuffix(";") || cleanPunct.hasSuffix(":") ||
                            cleanPunct.hasSuffix("。") || cleanPunct.hasSuffix("！") || cleanPunct.hasSuffix("？")

        // Subcase 1: Same page
        if prev.pageIndex == next.pageIndex {
            // Same physical line -> never a paragraph break
            if abs(last1.y - first2.y) <= 4.0 {
                return false
            }

            // Line 2 is below Line 1
            if last1.y > first2.y + 4.0 {
                let allWidths = (prev.lineRects + next.lineRects).map(\.width)
                let maxLineWidth = allWidths.max() ?? 400.0

                let isShortLine = last1.width < maxLineWidth - 35.0
                let isNextIndented = first2.x > last1.x + 8.0
                let isVerticalGap = (last1.y - first2.y) > max(last1.height, first2.height) * 1.35

                if endsWithPunct && (isShortLine || isNextIndented || isVerticalGap) {
                    return true
                }
            }
        } else if next.pageIndex == prev.pageIndex + 1 {
            // Cross-page: if prev ends with sentence punctuation and was a short line
            let allWidths = (prev.lineRects + next.lineRects).map(\.width)
            let maxLineWidth = allWidths.max() ?? 400.0
            let isShortLine = last1.width < maxLineWidth - 35.0

            if endsWithPunct && isShortLine {
                return true
            }
        }

        return false
    }

    /// Clusters consecutive highlights together into merged groups.
    public static func groupConsecutiveHighlights(
        _ highlights: [ExtractedHighlight],
        in document: PDFDocument
    ) -> [[ExtractedHighlight]] {
        var clusters: [[ExtractedHighlight]] = []

        for h in highlights {
            if let lastCluster = clusters.last,
               let lastH = lastCluster.last,
               areConsecutive(h1: lastH, h2: h, in: document) {
                clusters[clusters.count - 1].append(h)
            } else {
                clusters.append([h])
            }
        }

        return clusters
    }

    /// Turns clusters of extracted highlights into NoteCard models for a study notebook topic.
    public static func buildCards(
        from clusters: [[ExtractedHighlight]],
        topicId: UUID,
        bookMD5: String
    ) -> [NoteCard] {
        var cards: [NoteCard] = []

        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }

            // Join text with hyphenation, sentence, and paragraph awareness
            var joinedText = ""
            let noSpaceBeforeChars: Set<Character> = [
                "’", "'", "”", "\"", ")", "]", "}", "）", "】", "」", "』",
                ",", ".", ";", ":", "!", "?", "…", "%", "°", "–", "—"
            ]

            for (idx, part) in cluster.enumerated() {
                let partText = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !partText.isEmpty else { continue }

                if idx == 0 {
                    joinedText = partText
                } else {
                    let prevPart = cluster[idx - 1]
                    let isParagraphBreak = isParagraphBreakBetween(prev: prevPart, next: part)

                    if isParagraphBreak {
                        joinedText += "\n\n" + partText
                    } else if joinedText.hasSuffix("-") && !joinedText.hasSuffix("--") {
                        joinedText = String(joinedText.dropLast()) + partText
                    } else if joinedText.hasSuffix("\n") || partText.hasPrefix("\n") {
                        joinedText += partText
                    } else {
                        if let firstChar = partText.first, noSpaceBeforeChars.contains(firstChar) {
                            joinedText += partText
                        } else if joinedText.hasSuffix("‘") || joinedText.hasSuffix("“") || joinedText.hasSuffix("(") || joinedText.hasSuffix("[") {
                            joinedText += partText
                        } else {
                            joinedText += " " + partText
                        }
                    }
                }
            }

            // Combine user notes/comments
            let notes = cluster
                .map { $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let combinedNotes = Array(Set(notes)).joined(separator: "\n\n")

            // Collect all line rects
            let allRects = PDFHighlightResolver.sortInReadingOrder(cluster.flatMap(\.lineRects))

            // Build excerpt segments for multi-part highlights
            let segments: [ExcerptSegment] = cluster.map { part in
                ExcerptSegment(
                    id: UUID(),
                    text: part.text,
                    rects: part.lineRects
                )
            }

            let card = NoteCard(
                id: UUID(),
                topicId: topicId,
                bookMD5: bookMD5,
                title: "",
                highlightText: joinedText,
                notesText: combinedNotes,
                startPage: first.pageIndex,
                endPage: last.pageIndex,
                startPos: CGPoint(x: first.bounds.origin.x, y: first.bounds.origin.y),
                endPos: CGPoint(x: last.bounds.maxX, y: last.bounds.maxY),
                colorIndex: first.colorIndex,
                highlightRects: allRects,
                excerptSegments: segments.count > 1 ? segments : []
            )

            cards.append(card)
        }

        return cards
    }


    /// High-level function to import highlights from a PDF document into the database.
    @discardableResult
    public static func importHighlights(
        from document: PDFDocument,
        for docModel: Document,
        topicId: UUID,
        shouldMerge: Bool,
        database: Database
    ) throws -> [NoteCard] {
        let extracted = extractHighlights(from: document)
        guard !extracted.isEmpty else { return [] }

        let clusters: [[ExtractedHighlight]]
        if shouldMerge {
            clusters = groupConsecutiveHighlights(extracted, in: document)
        } else {
            clusters = extracted.map { [$0] }
        }

        let cards = buildCards(from: clusters, topicId: topicId, bookMD5: docModel.md5)

        // Clean up any existing cards for this document before inserting new ones
        // (prevents duplication when user deletes and reimports the same document)
        try database.deleteCardsForDocument(md5: docModel.md5)

        for card in cards {
            try database.insertCard(card)
        }

        return cards
    }
}
