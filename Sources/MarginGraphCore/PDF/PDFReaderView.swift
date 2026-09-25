import SwiftUI
import AppKit
import PDFKit
import QuartzCore

public enum PDFSelectionTool: String, CaseIterable, Identifiable, Sendable {
    case textSelection
    case rectMarquee

    public var id: String { rawValue }
}

public enum PDFReaderDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case singlePage
    case continuous

    public var id: String { rawValue }
}

public struct PDFJumpTarget: Equatable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var bounds: CGRect

    public init(id: UUID = UUID(), pageIndex: Int, bounds: CGRect) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
    }

    public static func == (lhs: PDFJumpTarget, rhs: PDFJumpTarget) -> Bool {
        lhs.id == rhs.id && lhs.pageIndex == rhs.pageIndex && lhs.bounds == rhs.bounds
    }
}

public final class DottedLineAnnotation: PDFAnnotation {
    public var lineStartPoint: CGPoint = .zero
    public var lineEndPoint: CGPoint = .zero
    public var strokeColor: NSColor = MarginNoteTheme.nsCursorColor
    public var strokeLineWidth: CGFloat = 2.5
    public var dashPattern: [CGFloat] = [2.5, 3.5]

    public override init(bounds: CGRect, forType type: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]?) {
        super.init(bounds: bounds, forType: type, withProperties: properties)
        self.color = MarginNoteTheme.nsCursorColor
        self.interiorColor = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.color = MarginNoteTheme.nsCursorColor
        self.interiorColor = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
    }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(strokeLineWidth)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: dashPattern)
        context.beginPath()

        let clip = context.boundingBoxOfClipPath
        let isLocalSpace = clip.origin.x < 1.0 && clip.origin.y < 1.0 && (lineStartPoint.x > clip.maxX || lineStartPoint.y > clip.maxY)
        let p1 = isLocalSpace ? CGPoint(x: lineStartPoint.x - bounds.origin.x, y: lineStartPoint.y - bounds.origin.y) : lineStartPoint
        let p2 = isLocalSpace ? CGPoint(x: lineEndPoint.x - bounds.origin.x, y: lineEndPoint.y - bounds.origin.y) : lineEndPoint

        context.move(to: p1)
        context.addLine(to: p2)
        context.strokePath()
        context.restoreGState()
    }
}

public final class CursorHandleAnnotation: PDFAnnotation {
    public var isStart: Bool = true
    public var fillColor: NSColor = MarginNoteTheme.nsCursorColor {
        didSet {
            self.color = fillColor
            self.interiorColor = fillColor
        }
    }
    public var stemWidth: CGFloat = 2.0
    public var stemHeight: CGFloat = 16.0
    public var knobRadius: CGFloat = 3.2

    public override init(bounds: CGRect, forType type: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]?) {
        super.init(bounds: bounds, forType: .square, withProperties: properties)
        self.color = fillColor
        self.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.color = fillColor
        self.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
    }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // Selection cursors are rendered exclusively by SelectionCursorOverlayView directly in view space.
        // This guarantees handles are never obscured by PDF text, scanned bitmaps, OCR layers, or highlight annotations,
        // and eliminates PDFKit annotation tile clipping and subpixel shift artifacts.
    }
}

public typealias KnobAnnotation = CursorHandleAnnotation

/// Native AppKit overlay that renders selection cursor handles on top of the PDFView.
/// Because it sits above PDFView's documentView/scrollview, it can NEVER be obscured
/// by PDF page content, scanned bitmaps, OCR layers, or highlight annotations.
final class SelectionCursorOverlayView: NSView {
    weak var pdfView: InteractivePDFView?

    struct HandleState {
        var page: PDFPage
        var point: CGPoint // page coordinates (center of line)
        var lineHeight: CGFloat
        var color: NSColor
        var isStart: Bool
    }

    private var startHandle: HandleState?
    private var endHandle: HandleState?

    init(pdfView: InteractivePDFView) {
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Transparent to mouse events so InteractivePDFView receives all clicks and drags
        return nil
    }

    func setHandle(page: PDFPage, point: CGPoint, lineHeight: CGFloat, color: NSColor, isStart: Bool) {
        let handle = HandleState(
            page: page,
            point: point,
            lineHeight: lineHeight,
            color: color,
            isStart: isStart
        )
        if isStart {
            startHandle = handle
        } else {
            endHandle = handle
        }
        needsDisplay = true
    }

    func clear() {
        if startHandle != nil || endHandle != nil {
            startHandle = nil
            endHandle = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pdfView, let doc = pdfView.document else { return }

        let visiblePages = pdfView.visiblePages
        guard !visiblePages.isEmpty else { return }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for handle in [startHandle, endHandle].compactMap({ $0 }) {
            guard visiblePages.contains(handle.page) else { continue }

            let dims = InteractivePDFView.handleDimensions(for: handle.lineHeight, scale: pdfView.scaleFactor)
            let stemHeight = dims.stemHeight
            let stemWidth = dims.stemWidth
            let knobRadius = dims.knobRadius

            let centerPage = handle.point
            let topPage = CGPoint(x: centerPage.x, y: centerPage.y + stemHeight / 2)
            let bottomPage = CGPoint(x: centerPage.x, y: centerPage.y - stemHeight / 2)

            let centerView = pdfView.convert(centerPage, from: handle.page)
            let topView = pdfView.convert(topPage, from: handle.page)
            let bottomView = pdfView.convert(bottomPage, from: handle.page)

            let stemMinY = min(topView.y, bottomView.y)
            let stemMaxY = max(topView.y, bottomView.y)
            let stemCenterX = centerView.x

            // For start handle, knob is at the top of the stem; for end handle, knob is at the bottom of the stem
            let knobCenterY = handle.isStart ? (topView.y >= bottomView.y ? stemMaxY : stemMinY)
                                             : (topView.y >= bottomView.y ? stemMinY : stemMaxY)
            let knobCenter = CGPoint(x: stemCenterX, y: knobCenterY)

            ctx.saveGState()
            ctx.setFillColor(handle.color.cgColor)

            let path = CGMutablePath()
            let stemRect = CGRect(
                x: stemCenterX - stemWidth / 2,
                y: stemMinY,
                width: stemWidth,
                height: max(1.0, stemMaxY - stemMinY)
            )
            path.addRect(stemRect)

            let knobRect = CGRect(
                x: knobCenter.x - knobRadius,
                y: knobCenter.y - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )
            path.addEllipse(in: knobRect)

            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

public enum PDFHighlightResolver {
    public static func sortInReadingOrder(_ rects: [HighlightRect]) -> [HighlightRect] {
        rects.sorted { r1, r2 in
            if r1.page != r2.page {
                return r1.page < r2.page
            }
            if abs(r1.y - r2.y) > 4.0 {
                return r1.y > r2.y
            }
            return r1.x < r2.x
        }
    }

    public static func deduplicate(_ rects: [HighlightRect]) -> [HighlightRect] {
        var seen = Set<String>()
        var result: [HighlightRect] = []
        for r in rects {
            let key = "\(r.page)_\(Int((r.y / 2).rounded()))_\(Int((r.x / 4).rounded()))_\(Int((r.width / 4).rounded()))"
            if seen.insert(key).inserted {
                result.append(r)
            }
        }
        return sortInReadingOrder(result)
    }

    public static func clampToLine(on page: PDFPage, point: CGPoint) -> CGPoint {
        guard let full = page.selection(for: page.bounds(for: .cropBox)) else { return point }
        let lines = full.selectionsByLine()
        guard !lines.isEmpty else { return point }

        var bestLine: PDFSelection?
        var minDy = CGFloat.infinity
        for line in lines {
            let b = line.bounds(for: page)
            if point.y >= b.minY - 4 && point.y <= b.maxY + 4 {
                bestLine = line
                break
            }
            let dy = abs(b.midY - point.y)
            if dy < minDy {
                minDy = dy
                bestLine = line
            }
        }
        if let bestLine {
            let b = bestLine.bounds(for: page)
            let clampedX = min(max(point.x, b.minX + 2), b.maxX - 2)
            return CGPoint(x: clampedX, y: b.midY)
        }
        return point
    }

    public static func expandBlockRectsIfNeeded(_ rects: [HighlightRect], in document: PDFDocument) -> [HighlightRect] {
        var result: [HighlightRect] = []
        for r in rects {
            guard r.page >= 0, r.page < document.pageCount,
                  let page = document.page(at: r.page) else {
                result.append(r)
                continue
            }
            // If the rect is tall enough to contain multiple lines (height > 20), extract individual text lines
            if r.height > 20.0 {
                let box = CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: -2, dy: -2)
                if let sel = page.selection(for: box) {
                    let subLines = lineRects(from: sel, document: document)
                    if subLines.count > 1 || (subLines.count == 1 && subLines[0].height < r.height * 0.7) {
                        result.append(contentsOf: subLines)
                        continue
                    }
                }
            }
            result.append(r)
        }
        return sortInReadingOrder(result)
    }

    public static func selection(
        in document: PDFDocument,
        startPage: Int,
        startPoint: CGPoint,
        endPage: Int,
        endPoint: CGPoint
    ) -> PDFSelection? {
        guard startPage >= 0, startPage < document.pageCount,
              endPage >= 0, endPage < document.pageCount,
              let pStart = document.page(at: startPage),
              let pEnd = document.page(at: endPage) else { return nil }

        if startPage == endPage {
            let clampedStart = clampToLine(on: pStart, point: startPoint)
            let clampedEnd = clampToLine(on: pStart, point: endPoint)
            let isForward: Bool
            if abs(clampedStart.y - clampedEnd.y) > 6 {
                isForward = clampedStart.y > clampedEnd.y
            } else {
                isForward = clampedStart.x <= clampedEnd.x
            }
            let pA = isForward ? clampedStart : clampedEnd
            let pB = isForward ? clampedEnd : clampedStart
            return pStart.selection(from: pA, to: pB)
        }

        let forward = startPage < endPage
        let firstPage = forward ? pStart : pEnd
        let firstPoint = forward ? startPoint : endPoint
        let lastPage = forward ? pEnd : pStart
        let lastPoint = forward ? endPoint : startPoint
        let idxFirst = forward ? startPage : endPage
        let idxLast = forward ? endPage : startPage

        let clampedStart = clampToLine(on: firstPage, point: firstPoint)
        let clampedEnd = clampToLine(on: lastPage, point: lastPoint)

        var endOfFirstPage = CGPoint(x: firstPage.bounds(for: .cropBox).maxX - 5, y: firstPage.bounds(for: .cropBox).minY + 5)
        if let fullFirst = firstPage.selection(for: firstPage.bounds(for: .cropBox)),
           let lastLine = fullFirst.selectionsByLine().last {
            let lb = lastLine.bounds(for: firstPage)
            endOfFirstPage = CGPoint(x: lb.maxX - 2, y: lb.midY)
        }

        guard let selFirst = firstPage.selection(from: clampedStart, to: endOfFirstPage),
              let combined = selFirst.copy() as? PDFSelection else {
            return nil
        }

        if idxLast > idxFirst + 1 {
            for midIdx in (idxFirst + 1)..<idxLast {
                guard let midPage = document.page(at: midIdx) else { continue }
                if let fullSel = midPage.selection(for: midPage.bounds(for: .cropBox)) {
                    combined.add(fullSel)
                }
            }
        }

        var startOfLastPage = CGPoint(x: lastPage.bounds(for: .cropBox).minX + 5, y: lastPage.bounds(for: .cropBox).maxY - 5)
        if let fullLast = lastPage.selection(for: lastPage.bounds(for: .cropBox)),
           let firstLine = fullLast.selectionsByLine().first {
            let fb = firstLine.bounds(for: lastPage)
            startOfLastPage = CGPoint(x: fb.minX + 2, y: fb.midY)
        }

        if let selLast = lastPage.selection(from: startOfLastPage, to: clampedEnd) {
            combined.add(selLast)
        }

        return combined
    }

    public struct PhysicalLine {
        public var text: String
        public var bounds: CGRect
        public var page: PDFPage

        public init(text: String, bounds: CGRect, page: PDFPage) {
            self.text = text
            self.bounds = bounds
            self.page = page
        }
    }

    public static func groupPhysicalLines(_ selections: [PDFSelection]) -> [PhysicalLine] {
        var rawChunks: [(page: PDFPage, bounds: CGRect, text: String)] = []
        for sel in selections {
            guard let p = sel.pages.first, let t = sel.string else { continue }
            let b = sel.bounds(for: p)
            rawChunks.append((page: p, bounds: b, text: t))
        }

        var lines: [PhysicalLine] = []
        for chunk in rawChunks {
            if let idx = lines.lastIndex(where: {
                $0.page === chunk.page && abs($0.bounds.midY - chunk.bounds.midY) < 3.0
            }) {
                var line = lines[idx]
                let leftToRight = line.bounds.minX <= chunk.bounds.minX
                let firstText = leftToRight ? line.text : chunk.text
                let secondText = leftToRight ? chunk.text : line.text

                let joinedText: String
                if firstText.hasSuffix("-") && !firstText.hasSuffix("--") {
                    joinedText = firstText + secondText
                } else if firstText.hasSuffix(" ") || secondText.hasPrefix(" ") {
                    joinedText = firstText + secondText
                } else {
                    joinedText = firstText + " " + secondText
                }

                line.text = joinedText
                line.bounds = line.bounds.union(chunk.bounds)
                lines[idx] = line
            } else {
                lines.append(PhysicalLine(text: chunk.text, bounds: chunk.bounds, page: chunk.page))
            }
        }
        return lines
    }

    public static func buildParagraphs(from lines: [PhysicalLine], fallbackRaw: String) -> String {
        guard !lines.isEmpty else { return normalizeExcerptParagraphs(fallbackRaw) }

        let minXs = lines.map { $0.bounds.minX }.sorted()
        let baseMinX = minXs[Int(Double(minXs.count) * 0.2)]
        let maxXs = lines.map { $0.bounds.maxX }.sorted()
        let baseMaxX = maxXs[Int(Double(maxXs.count) * 0.8)]

        var dyList: [CGFloat] = []
        for i in 1..<lines.count {
            if lines[i].page === lines[i-1].page {
                let dy = lines[i-1].bounds.midY - lines[i].bounds.midY
                if dy > 5 && dy < 60 {
                    dyList.append(dy)
                }
            }
        }
        let normalDy = dyList.sorted().isEmpty ? 18.0 : dyList.sorted()[dyList.count / 2]

        var paragraphs: [String] = []
        var currentLines: [String] = []

        func flush() {
            if !currentLines.isEmpty {
                paragraphs.append(currentLines.joined(separator: " "))
                currentLines.removeAll()
            }
        }

        for i in 0..<lines.count {
            let line = lines[i]
            let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                flush()
                continue
            }

            if i > 0 {
                let prev = lines[i - 1]
                let prevText = prev.text.trimmingCharacters(in: .whitespacesAndNewlines)

                var isNewParagraph = false

                // 1. Check vertical gap
                if line.page === prev.page {
                    let dy = prev.bounds.midY - line.bounds.midY
                    if dy > normalDy * 1.42 {
                        isNewParagraph = true
                    }
                }

                // 2. Check bullet / numbered list
                let isBullet = raw.hasPrefix("- ") || raw.hasPrefix("* ") || raw.hasPrefix("• ") || raw.hasPrefix("· ")
                let isNumbered = raw.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) != nil
                if isBullet || isNumbered {
                    isNewParagraph = true
                }

                // 3. Check indent + short previous line + sentence end
                let prevEndsWithPunct = prevText.hasSuffix(".") || prevText.hasSuffix("!") || prevText.hasSuffix("?") || prevText.hasSuffix("”") || prevText.hasSuffix("\"")
                let prevEndedShort = prev.bounds.maxX < baseMaxX - 22.0
                let currIndented = line.bounds.minX > baseMinX + 10.0

                if prevEndsWithPunct && prevEndedShort && currIndented {
                    isNewParagraph = true
                }

                if isNewParagraph {
                    flush()
                }
            }

            if let last = currentLines.last, last.hasSuffix("-") && !last.hasSuffix("--") {
                currentLines[currentLines.count - 1] = String(last.dropLast()) + raw
            } else {
                currentLines.append(raw)
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    public static func normalizeExcerptParagraphs(_ selection: PDFSelection) -> String {
        let lines = selection.selectionsByLine()
        let rawText = selection.string ?? ""

        guard !lines.isEmpty else {
            return normalizeExcerptParagraphs(rawText)
        }

        let physicalLines = groupPhysicalLines(lines)
        return buildParagraphs(from: physicalLines, fallbackRaw: rawText)
    }

    public static func normalizeExcerptParagraphs(_ rawText: String) -> String {
        let blocks = rawText.components(separatedBy: "\n\n")
        var normalizedBlocks: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var current: [String] = []
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }

                let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.hasPrefix("· ")
                let isNumbered = line.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) != nil

                if (isBullet || isNumbered) && !current.isEmpty {
                    normalizedBlocks.append(current.joined(separator: " "))
                    current.removeAll()
                }

                if let last = current.last, last.hasSuffix("-") {
                    current[current.count - 1] = String(last.dropLast()) + line
                } else {
                    current.append(line)
                }
            }
            if !current.isEmpty {
                normalizedBlocks.append(current.joined(separator: " "))
            }
        }
        return normalizedBlocks.joined(separator: "\n\n")
    }

    nonisolated(unsafe) private static var resolvedLineRectsCache: [UUID: [HighlightRect]] = [:]

    public static func invalidateLineRectsCache(for cardID: UUID? = nil) {
        if let cardID {
            resolvedLineRectsCache.removeValue(forKey: cardID)
        } else {
            resolvedLineRectsCache.removeAll()
        }
    }

    public static func lineRects(for card: NoteCard, in document: PDFDocument) -> [HighlightRect] {
        let segRects = card.effectiveSegments.flatMap(\.rects).filter {
            $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
        }
        if !segRects.isEmpty {
            return expandBlockRectsIfNeeded(deduplicate(segRects), in: document)
        }

        let stored = card.highlightRects.filter {
            $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
        }
        if !stored.isEmpty {
            return expandBlockRectsIfNeeded(deduplicate(stored), in: document)
        }

        if let cached = resolvedLineRectsCache[card.id], !cached.isEmpty {
            return cached
        }

        if let startPageIdx = card.startPage,
           let start = card.startPos,
           let end = card.endPos,
           startPageIdx >= 0,
           startPageIdx < document.pageCount {
            let endPageIdx = card.endPage ?? startPageIdx
            if endPageIdx >= 0, endPageIdx < document.pageCount {
                if let selection = selection(in: document, startPage: startPageIdx, startPoint: start, endPage: endPageIdx, endPoint: end) {
                    let resolved = lineRects(from: selection, document: document)
                    if !resolved.isEmpty {
                        let result = sortInReadingOrder(deduplicate(resolved))
                        resolvedLineRectsCache[card.id] = result
                        return result
                    }
                }
            }
        }

        if !card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let matches = document.findString(card.highlightText, withOptions: [.caseInsensitive])
            let expectedPage = card.startPage
            let preferred = expectedPage.map { expected in
                matches.filter { selection in
                    selection.pages.contains { document.index(for: $0) == expected }
                }
            } ?? matches

            let candidates = preferred.isEmpty ? matches : preferred
            let resolved = candidates.flatMap { selection in
                lineRects(from: selection, document: document)
            }
            if !resolved.isEmpty {
                let result = deduplicate(resolved)
                resolvedLineRectsCache[card.id] = result
                return result
            }
        }

        return []
    }

    public static func lineRects(forPhrase phrase: String, in card: NoteCard, in document: PDFDocument) -> [HighlightRect] {
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        // If card already has emphasisRects and only 1 emphasis phrase, use stored rects directly
        if card.emphasisList.count <= 1 && !card.emphasisRects.isEmpty {
            let single = (card.emphasisList.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if single.isEmpty || single == clean || single.components(separatedBy: .whitespacesAndNewlines).joined() == clean.components(separatedBy: .whitespacesAndNewlines).joined() {
                return card.emphasisRects
            }
        }

        let cardLines = lineRects(for: card, in: document)
        let targetPages = Array(Set(cardLines.map(\.page))).sorted()
        let pagesToSearch = !targetPages.isEmpty ? targetPages : (card.startPage.map { [$0] } ?? Array(0..<document.pageCount))

        var allRects: [HighlightRect] = []

        // 1. Single-page search on each candidate page
        for pageIdx in pagesToSearch {
            guard let page = document.page(at: pageIdx), let pageStr = page.string else { continue }
            let cardLinesOnPage = cardLines.filter { $0.page == pageIdx }

            var matchedRanges: [NSRange] = []
            if let r = pageStr.range(of: clean, options: .caseInsensitive) {
                matchedRanges.append(NSRange(r, in: pageStr))
            } else {
                let tokens = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                if !tokens.isEmpty {
                    let pattern = tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:-\s*|\s+)"#)
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                        let nsRange = NSRange(pageStr.startIndex..<pageStr.endIndex, in: pageStr)
                        let matches = regex.matches(in: pageStr, options: [], range: nsRange)
                        for m in matches {
                            matchedRanges.append(m.range)
                        }
                    }
                }
            }

            for nsRange in matchedRanges {
                guard let sel = page.selection(for: nsRange) else { continue }
                let rects = lineRects(from: sel, document: document)
                guard !rects.isEmpty else { continue }

                if !cardLinesOnPage.isEmpty {
                    let overlaps = rects.contains { r in
                        let rBox = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                        return cardLinesOnPage.contains { c in
                            let cBox = CGRect(x: c.x, y: c.y, width: c.width, height: c.height).insetBy(dx: -4, dy: -4)
                            return cBox.intersects(rBox)
                        }
                    }
                    guard overlaps else { continue }
                }

                allRects.append(contentsOf: rects)
            }
        }

        if !allRects.isEmpty {
            return deduplicate(allRects)
        }

        // 2. Multi-page phrase matching if pagesToSearch spans >= 2 pages
        let tokens = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if tokens.count >= 2 && pagesToSearch.count >= 2 {
            for i in 0..<(pagesToSearch.count - 1) {
                let p1Idx = pagesToSearch[i]
                let p2Idx = pagesToSearch[i + 1]
                guard let page1 = document.page(at: p1Idx), let str1 = page1.string,
                      let page2 = document.page(at: p2Idx), let str2 = page2.string else { continue }

                var low = 1
                var high = tokens.count - 1
                var bestSplit: Int? = nil

                func matchesPrefix(_ count: Int) -> NSRange? {
                    let sub = Array(tokens[0..<count])
                    let pat = sub.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:-\s*|\s+)"#)
                    guard let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
                    let full = NSRange(str1.startIndex..<str1.endIndex, in: str1)
                    return rx.matches(in: str1, options: [], range: full).last?.range
                }

                func matchesSuffix(from start: Int) -> NSRange? {
                    let sub = Array(tokens[start...])
                    let pat = sub.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:-\s*|\s+)"#)
                    guard let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
                    let full = NSRange(str2.startIndex..<str2.endIndex, in: str2)
                    return rx.matches(in: str2, options: [], range: full).first?.range
                }

                while low <= high {
                    let mid = (low + high) / 2
                    if matchesPrefix(mid) != nil {
                        bestSplit = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }

                if let split = bestSplit,
                   let r1 = matchesPrefix(split),
                   let r2 = matchesSuffix(from: split) {
                    if let s1 = page1.selection(for: r1),
                       let s2 = page2.selection(for: r2) {
                        let rects1 = lineRects(from: s1, document: document)
                        let rects2 = lineRects(from: s2, document: document)
                        if !rects1.isEmpty && !rects2.isEmpty {
                            return deduplicate(rects1 + rects2)
                        }
                    }
                }
            }
        }

        if !card.emphasisRects.isEmpty {
            return card.emphasisRects
        }

        return []
    }

    public static func rangesOfPhrase(_ phrase: String, in text: String) -> [Range<String.Index>] {
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !text.isEmpty else { return [] }

        func matchTokens(from input: String) -> [Range<String.Index>] {
            var found: [Range<String.Index>] = []
            let tokens = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if !tokens.isEmpty {
                var tokenPatterns: [String] = []
                for t in tokens {
                    if t.hasSuffix("-") && t.count > 1 {
                        let base = String(t.dropLast())
                        tokenPatterns.append("(?:" + NSRegularExpression.escapedPattern(for: t) + "|" + NSRegularExpression.escapedPattern(for: base) + ")")
                    } else {
                        tokenPatterns.append(NSRegularExpression.escapedPattern(for: t))
                    }
                }
                let pattern = tokenPatterns.joined(separator: #"(?:-\s*|\s+)"#)
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
                    let matches = regex.matches(in: text, options: [], range: fullRange)
                    for m in matches {
                        if let r = Range(m.range, in: text) {
                            found.append(r)
                        }
                    }
                }
            }
            return found
        }

        var result = matchTokens(from: clean)
        if result.isEmpty {
            let normalized = normalizeExcerptParagraphs(clean)
            if normalized != clean {
                result = matchTokens(from: normalized)
            }
        }
        if result.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let r = text.range(of: clean, options: .caseInsensitive, range: searchRange) {
                result.append(r)
                if r.upperBound < text.endIndex {
                    searchRange = r.upperBound..<text.endIndex
                } else {
                    break
                }
            }
        }
        return result
    }

    static func lineRects(from selection: PDFSelection, document: PDFDocument) -> [HighlightRect] {
        var result: [HighlightRect] = []
        let lines = selection.selectionsByLine()
        for line in lines {
            for page in line.pages {
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound else { continue }
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                result.append(HighlightRect(
                    page: pageIndex,
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height
                ))
            }
        }
        return deduplicate(result)
    }

    public static func createHighlightAnnotation(bounds: CGRect, color: NSColor, contents: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        annotation.contents = contents
        return annotation
    }
}

public struct PDFReaderView: NSViewRepresentable {
    public var manager: PDFDocumentManager
    public var displayMode: PDFReaderDisplayMode
    public var tool: PDFSelectionTool
    public var highlightColor: NSColor
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var activeToolbarOwner: ToolbarOwner
    public var jumpTarget: PDFJumpTarget?
    @Binding public var currentPageIndex: Int
    public var initialPageOffsetY: CGFloat = 0
    public var onPositionChanged: ((Int, CGFloat) -> Void)? = nil
    public var onExcerpt: ((PDFExcerpt) -> Void)?
    public var onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)?
    public var onEditCard: ((UUID) -> Void)?
    public var onChangeCardColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onSelectCard: ((UUID?) -> Void)?
    public var onUpdateCardHighlight: ((UUID, UUID?, String, [HighlightRect], CGPoint, CGPoint) -> Void)?
    public var onDeleteSegment: ((UUID, UUID) -> Void)?
    public var onAsTitle: ((UUID, String) -> Void)?
    public var onAddToComments: ((UUID, String) -> Void)?
    public var onMerge: ((UUID, String, [HighlightRect]) -> Void)?
    public var onEmphasize: ((UUID, String, [HighlightRect]) -> Void)?
    public var onDeleteEmphasis: ((UUID, String, [HighlightRect]) -> Void)?
    public var onScroll: (() -> Void)?
    public var searchQuery: String = ""
    public var searchMatchIndex: Int = 0
    public var onSearchResultCount: ((Int) -> Void)? = nil

    public init(
        manager: PDFDocumentManager,
        displayMode: PDFReaderDisplayMode = .continuous,
        tool: PDFSelectionTool = .textSelection,
        highlightColor: NSColor = .systemYellow,
        cards: [NoteCard] = [],
        selectedCardID: UUID? = nil,
        activeToolbarOwner: ToolbarOwner = .none,
        jumpTarget: PDFJumpTarget? = nil,
        currentPageIndex: Binding<Int> = .constant(0),
        initialPageOffsetY: CGFloat = 0,
        searchQuery: String = "",
        searchMatchIndex: Int = 0,
        onSearchResultCount: ((Int) -> Void)? = nil,
        onPositionChanged: ((Int, CGFloat) -> Void)? = nil,
        onExcerpt: ((PDFExcerpt) -> Void)? = nil,
        onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)? = nil,
        onEditCard: ((UUID) -> Void)? = nil,
        onChangeCardColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onDeleteSegment: ((UUID, UUID) -> Void)? = nil,
        onSelectCard: ((UUID?) -> Void)? = nil,
        onUpdateCardHighlight: ((UUID, UUID?, String, [HighlightRect], CGPoint, CGPoint) -> Void)? = nil,
        onAsTitle: ((UUID, String) -> Void)? = nil,
        onAddToComments: ((UUID, String) -> Void)? = nil,
        onMerge: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onEmphasize: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onDeleteEmphasis: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onScroll: (() -> Void)? = nil
    ) {
        self.manager = manager
        self.displayMode = displayMode
        self.tool = tool
        self.highlightColor = highlightColor
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.activeToolbarOwner = activeToolbarOwner
        self.jumpTarget = jumpTarget
        self._currentPageIndex = currentPageIndex
        self.initialPageOffsetY = initialPageOffsetY
        self.searchQuery = searchQuery
        self.searchMatchIndex = searchMatchIndex
        self.onSearchResultCount = onSearchResultCount
        self.onPositionChanged = onPositionChanged
        self.onExcerpt = onExcerpt
        self.onCreateCardWithColor = onCreateCardWithColor
        self.onEditCard = onEditCard
        self.onChangeCardColor = onChangeCardColor
        self.onDeleteCard = onDeleteCard
        self.onDeleteSegment = onDeleteSegment
        self.onSelectCard = onSelectCard
        self.onUpdateCardHighlight = onUpdateCardHighlight
        self.onAsTitle = onAsTitle
        self.onAddToComments = onAddToComments
        self.onMerge = onMerge
        self.onEmphasize = onEmphasize
        self.onDeleteEmphasis = onDeleteEmphasis
        self.onScroll = onScroll
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.focusRingType = .none
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 0.25, left: 0, bottom: 0.25, right: 0)
        view.backgroundColor = NSColor(white: 0.92, alpha: 1.0)
        view.document = manager.document
        view.onPositionChanged = onPositionChanged
        if currentPageIndex > 0 || initialPageOffsetY > 1 {
            view.restorePosition(pageIndex: currentPageIndex, pageOffsetY: initialPageOffsetY)
            context.coordinator.lastPageIndex = currentPageIndex
        }
        configure(view)
        context.coordinator.setupObserver(for: view)
        return view
    }

    static func highlightsEqual(_ a: [NoteCard], _ b: [NoteCard]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            let ca = a[i]
            let cb = b[i]
            if ca.id != cb.id ||
               ca.colorIndex != cb.colorIndex ||
               ca.highlightRects != cb.highlightRects ||
               ca.emphasisRects != cb.emphasisRects ||
               ca.emphasisList != cb.emphasisList ||
               ca.startPage != cb.startPage ||
               ca.highlightText != cb.highlightText ||
               ca.excerptSegments != cb.excerptSegments {
                return false
            }
        }
        return true
    }

    public func updateNSView(_ view: InteractivePDFView, context: Context) {
        context.coordinator.parent = self
        view.onPositionChanged = onPositionChanged
        if view.document !== manager.document {
            view.clearHandles()
            view.clearPendingSelection()
            view.selectedSegmentID = nil
            view.hideToolbar()
            view.document = manager.document
            context.coordinator.setupObserver(for: view)
            view.restorePosition(pageIndex: currentPageIndex, pageOffsetY: initialPageOffsetY)
            context.coordinator.lastPageIndex = currentPageIndex
        }

        view.displayMode = displayMode == .continuous ? .singlePageContinuous : .singlePage
        view.pageBreakMargins = NSEdgeInsets(top: 0.25, left: 0, bottom: 0.25, right: 0)
        view.backgroundColor = NSColor(white: 0.92, alpha: 1.0)
        view.applySubtlePageSeparators()
        view.autoScales = true
        configure(view)
        let cardsChanged = !Self.highlightsEqual(context.coordinator.lastCards, cards) ||
                           context.coordinator.lastDocument !== view.document
        let selectionChanged = context.coordinator.lastSelectedCardID != selectedCardID
        let toolbarOwnerChanged = context.coordinator.lastToolbarOwner != activeToolbarOwner

        if cardsChanged {
            context.coordinator.lastCards = cards
            context.coordinator.lastDocument = view.document
            context.coordinator.lastSelectedCardID = selectedCardID
            context.coordinator.lastToolbarOwner = activeToolbarOwner
            applyBaseHighlights(to: view)
            applyActiveSelection(to: view)
        } else if selectionChanged || toolbarOwnerChanged {
            context.coordinator.lastSelectedCardID = selectedCardID
            context.coordinator.lastToolbarOwner = activeToolbarOwner
            applyActiveSelection(to: view)
        }

        let isNewJump = (context.coordinator.lastJump != jumpTarget && jumpTarget != nil)
        if isNewJump, let jumpTarget {
            context.coordinator.lastJump = jumpTarget
            context.coordinator.lastPageIndex = jumpTarget.pageIndex
            if currentPageIndex != jumpTarget.pageIndex {
                DispatchQueue.main.async {
                    self.currentPageIndex = jumpTarget.pageIndex
                }
            }
            jump(view, to: jumpTarget)
        } else if context.coordinator.lastPageIndex != currentPageIndex {
            context.coordinator.lastPageIndex = currentPageIndex
            if let page = view.document?.page(at: currentPageIndex) {
                view.go(to: page)
            }
        }

        if context.coordinator.lastSearchQuery != searchQuery || context.coordinator.lastSearchMatchIndex != searchMatchIndex {
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastSearchMatchIndex = searchMatchIndex
            if !searchQuery.isEmpty, let doc = view.document {
                let matches = doc.findString(searchQuery, withOptions: [.caseInsensitive])
                onSearchResultCount?(matches.count)
                if !matches.isEmpty {
                    let safeIdx = min(max(0, searchMatchIndex), matches.count - 1)
                    let match = matches[safeIdx]
                    view.setCurrentSelection(match, animate: true)
                    view.go(to: match)
                }
            } else {
                onSearchResultCount?(0)
                view.clearSelection()
            }
        }
    }

    private func configure(_ view: InteractivePDFView) {
        view.selectionTool = tool
        view.marqueeColor = highlightColor
        view.cards = cards
        view.selectedCardID = selectedCardID
        view.activeToolbarOwner = activeToolbarOwner
        view.bookMD5 = manager.md5
        view.excerptHandler = { excerpt in
            onExcerpt?(excerpt)
        }
        view.createCardWithColorHandler = onCreateCardWithColor
        view.editCardHandler = onEditCard
        view.changeCardColorHandler = onChangeCardColor
        view.deleteCardHandler = onDeleteCard
        view.deleteSegmentHandler = onDeleteSegment
        view.selectCardHandler = onSelectCard
        view.updateCardHighlightHandler = onUpdateCardHighlight
        view.asTitleHandler = onAsTitle
        view.addToCommentsHandler = onAddToComments
        view.mergeHandler = onMerge
        view.emphasizeHandler = onEmphasize
        view.deleteEmphasisHandler = onDeleteEmphasis
        view.onScroll = onScroll
        view.excerptFactory = { pageIndex, bounds, text in
            PDFExcerpt(
                bookMD5: manager.md5,
                pageIndex: pageIndex,
                bounds: bounds,
                text: text,
                croppedImageData: manager.crop(pageIndex: pageIndex, bounds: bounds)
            )
        }
    }

    private func applyBaseHighlights(to view: InteractivePDFView) {
        guard let document = view.document else { return }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents == "MarginGraph-card-highlight"
                || annotation.contents == "MarginGraph-card-emphasis" {
                page.removeAnnotation(annotation)
            }
        }

        for card in cards {
            if let bookMD5 = card.bookMD5, !bookMD5.isEmpty {
                let matchesBook = bookMD5 == manager.md5 ||
                    bookMD5.hasPrefix(manager.md5) ||
                    manager.md5.hasPrefix(bookMD5)
                guard matchesBook else { continue }
            }

            let lineRects = PDFHighlightResolver.lineRects(for: card, in: document)
            guard !lineRects.isEmpty else { continue }

            let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
            for line in lineRects {
                guard let page = document.page(at: line.page) else { continue }
                let rect = CGRect(x: line.x, y: line.y, width: line.width, height: line.height)
                let annotation = PDFHighlightResolver.createHighlightAnnotation(
                    bounds: rect,
                    color: accent.withAlphaComponent(0.65),
                    contents: "MarginGraph-card-highlight"
                )
                page.addAnnotation(annotation)
            }

            // Draw thick blue dotted underline for emphasized text in this card
            var drawnEmphasisKeys = Set<String>()

            let addDottedLine = { (line: HighlightRect) in
                let key = "\(line.page)_\(Int(line.y))_\(Int(line.x))_\(Int(line.width))"
                if drawnEmphasisKeys.insert(key).inserted {
                    if let page = document.page(at: line.page) {
                        let lineY = line.y - 1.0
                        let startPt = CGPoint(x: line.x, y: lineY)
                        let endPt = CGPoint(x: line.x + line.width, y: lineY)
                        let annot = DottedLineAnnotation(
                            bounds: CGRect(x: line.x - 2, y: lineY - 3, width: line.width + 4, height: 6),
                            forType: .square,
                            withProperties: nil
                        )
                        annot.lineStartPoint = startPt
                        annot.lineEndPoint = endPt
                        annot.strokeColor = MarginNoteTheme.nsCursorColor
                        annot.color = MarginNoteTheme.nsCursorColor
                        annot.strokeLineWidth = 2.5
                        annot.dashPattern = [2.5, 3.5]
                        annot.contents = "MarginGraph-card-emphasis"
                        page.addAnnotation(annot)
                    }
                }
            }

            if !card.emphasisRects.isEmpty {
                for line in card.emphasisRects {
                    addDottedLine(line)
                }
            } else {
                for phrase in card.emphasisList {
                    let rects = PDFHighlightResolver.lineRects(forPhrase: phrase, in: card, in: document)
                    for line in rects {
                        addDottedLine(line)
                    }
                }
            }
        }
        view.layoutDocumentView()
        view.setNeedsDisplay(view.bounds)
    }

    private func applyActiveSelection(to view: InteractivePDFView) {
        guard let document = view.document else { return }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.contents == "MarginGraph-active-highlight"
                || annotation.contents?.contains("handle") == true
                || annotation.contents == "MarginGraph-drag-highlight"
                || annotation.contents == "MarginGraph-target-bracket"
                || annotation.contents == "MarginGraph-jump" {
                page.removeAnnotation(annotation)
            }
        }

        if let selected = cards.first(where: { isActive(card: $0) }) {
            let matchingSegments = selected.effectiveSegments.filter { seg in
                seg.rects.contains { $0.page >= 0 && $0.page < document.pageCount }
            }
            let segment = matchingSegments.first(where: { $0.id == view.selectedSegmentID }) ?? matchingSegments.first
            let lineRects: [HighlightRect]
            if let segment, !segment.rects.isEmpty {
                lineRects = PDFHighlightResolver.expandBlockRectsIfNeeded(segment.rects, in: document)
            } else {
                lineRects = PDFHighlightResolver.lineRects(for: selected, in: document)
            }
            let accent = NSColor(MarginNoteTheme.cardColors(for: selected.colorIndex).accent)
            view.clearHandles()
            view.installHandleAnnotations(for: selected, lineRects: lineRects, accent: accent)
            if activeToolbarOwner == .pdf {
                view.updateToolbarPosition()
            } else {
                view.hideToolbar()
            }
        } else if view.hasPendingSelection {
            view.updateToolbarPosition()
        } else {
            view.clearHandles()
            view.hideToolbar()
        }
        view.setNeedsDisplay(view.bounds)
    }

    private func isActive(card: NoteCard) -> Bool {
        guard let selectedCardID else { return false }
        guard card.id == selectedCardID else { return false }
        if let bookMD5 = card.bookMD5, !bookMD5.isEmpty {
            let b1 = bookMD5.lowercased()
            let b2 = manager.md5.lowercased()
            let matches = b1 == b2 || b1.hasPrefix(b2) || b2.hasPrefix(b1)
            guard matches else { return false }
        }
        return true
    }

    private func jump(_ view: InteractivePDFView, to target: PDFJumpTarget) {
        view.scrollToCenter(target: target, animated: true)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: PDFReaderView
        var lastJump: PDFJumpTarget?
        var lastPageIndex: Int = 0
        var lastCards: [NoteCard] = []
        var lastSelectedCardID: UUID?
        var lastToolbarOwner: ToolbarOwner = .none
        weak var lastDocument: PDFDocument?
        var observer: NSObjectProtocol?
        var lastSearchQuery: String = ""
        var lastSearchMatchIndex: Int = 0

        init(_ parent: PDFReaderView) {
            self.parent = parent
            self.lastPageIndex = 0
        }

        func setupObserver(for view: InteractivePDFView) {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let doc = view.document, let current = view.currentPage else { return }
                    let idx = doc.index(for: current)
                    if idx != NSNotFound {
                        if self.parent.currentPageIndex != idx {
                            self.lastPageIndex = idx
                            self.parent.currentPageIndex = idx
                            self.parent.onScroll?()
                        }
                        if !view.isRestoringPosition {
                            if let pos = view.currentVisiblePosition() {
                                self.parent.onPositionChanged?(pos.pageIndex, pos.pageOffsetY)
                            } else {
                                self.parent.onPositionChanged?(idx, 0)
                            }
                        }
                    }
                }
            }
        }
    }

    public static func dismantleNSView(_ nsView: InteractivePDFView, coordinator: Coordinator) {
        nsView.removeScrollObserver()
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }
    }
}

public final class InteractivePDFView: PDFView {
    public var onPositionChanged: ((Int, CGFloat) -> Void)?
    internal var isRestoringPosition: Bool = false
    private var pendingRestorePosition: (pageIndex: Int, pageOffsetY: CGFloat)? = nil
    private var lastScrollPositionUpdateTime: TimeInterval = 0
    private var scrollPositionDebounceWorkItem: DispatchWorkItem? = nil
    var selectionTool: PDFSelectionTool = .textSelection
    var marqueeColor: NSColor = .systemYellow
    var bookMD5: String = ""
    var excerptHandler: ((PDFExcerpt) -> Void)?
    var excerptFactory: ((Int, CGRect, String) -> PDFExcerpt)?
    var createCardWithColorHandler: ((PDFExcerpt, Int) -> Void)?
    var editCardHandler: ((UUID) -> Void)?
    var changeCardColorHandler: ((UUID, Int) -> Void)?
    var deleteCardHandler: ((UUID) -> Void)?
    var deleteSegmentHandler: ((UUID, UUID) -> Void)?
    var cards: [NoteCard] = []
    var selectedCardID: UUID?
    public var selectedSegmentID: UUID?
    var activeToolbarOwner: ToolbarOwner = .none
    var selectCardHandler: ((UUID?) -> Void)?
    var updateCardHighlightHandler: ((UUID, UUID?, String, [HighlightRect], CGPoint, CGPoint) -> Void)?
    var asTitleHandler: ((UUID, String) -> Void)?
    var addToCommentsHandler: ((UUID, String) -> Void)?
    var mergeHandler: ((UUID, String, [HighlightRect]) -> Void)?
    var emphasizeHandler: ((UUID, String, [HighlightRect]) -> Void)?
    var deleteEmphasisHandler: ((UUID, String, [HighlightRect]) -> Void)?

    struct EmphasisHitInfo: Equatable {
        let cardID: UUID
        let text: String
        let rects: [HighlightRect]
        let hitLine: HighlightRect
    }
    var selectedEmphasisPhrase: EmphasisHitInfo? {
        didSet {
            if selectedEmphasisPhrase == nil {
                clearEmphasisSelectionHighlight()
            }
        }
    }
    var targetCardID: UUID?

    private struct HoldTracker {
        let initialSelectedCardID: UUID?
        let cardHitID: UUID?
        let page: PDFPage
        let pagePoint: CGPoint
        let viewPoint: CGPoint
        var timer: Timer?
        var didTrigger: Bool = false
    }
    private var holdTracker: HoldTracker?

    private var dragStart: (page: PDFPage, point: CGPoint)?
    private var dragLayer: CAShapeLayer?

    struct PendingSelection {
        var selection: PDFSelection
        var text: String
        var rects: [HighlightRect]
        var startPage: PDFPage
        var startPoint: CGPoint
        var endPage: PDFPage
        var endPoint: CGPoint
    }
    private var pendingSelection: PendingSelection?
    var hasPendingSelection: Bool { pendingSelection != nil }

    final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
        private var trackingAreaRef: NSTrackingArea?

        override func resetCursorRects() {
            super.resetCursorRects()
            discardCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }

        override func cursorUpdate(with event: NSEvent) {
            if NSCursor.current != .pointingHand {
                NSCursor.arrow.set()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .activeAlways,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseMoved(with event: NSEvent) {
            if NSCursor.current != .pointingHand {
                NSCursor.arrow.set()
            }
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            NSCursor.arrow.set()
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            window?.resetCursorRects()
        }
    }

    private var toolbarHostingView: ToolbarHostingView<AnyView>?
    private var selectionCursorOverlay: SelectionCursorOverlayView?

    private func ensureSelectionCursorOverlay() {
        if selectionCursorOverlay == nil {
            let overlay = SelectionCursorOverlayView(pdfView: self)
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: nil)
            selectionCursorOverlay = overlay
        } else if let overlay = selectionCursorOverlay, overlay.superview !== self {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        if let toolbar = toolbarHostingView, toolbar.superview === self {
            addSubview(toolbar, positioned: .above, relativeTo: nil)
        }
    }
    private var scrollObserver: NSObjectProtocol?
    var onScroll: (() -> Void)?
    private var lastClipOrigin: CGPoint? = nil

    private struct HandleDrag {
        var cardID: UUID? // nil for pendingSelection
        var segmentID: UUID?
        var movingStart: Bool
        var startPage: PDFPage
        var startPoint: CGPoint
        var endPage: PDFPage
        var endPoint: CGPoint
        var grabOffset: CGPoint
        var latestSelection: PDFSelection?
    }
    private var handleDrag: HandleDrag?

    private var pdfScrollView: NSScrollView? {
        subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
    }

    public var activeScrollView: NSScrollView? {
        pdfScrollView ?? documentView?.enclosingScrollView
    }

    public func scrollToCenter(target: PDFJumpTarget, animated: Bool = true) {
        guard let doc = document,
              target.pageIndex >= 0 && target.pageIndex < doc.pageCount,
              let page = doc.page(at: target.pageIndex) else { return }

        // Always navigate to page first so that PDFKit loads/renders that page
        go(to: page)

        // If target bounds are empty or near-zero, treat as page jump (show top of page)
        if target.bounds.width <= 2 || target.bounds.height <= 2 {
            return
        }

        layoutDocumentView()

        guard let docView = documentView,
              let scrollView = activeScrollView else {
            return
        }
        let clipView = scrollView.contentView

        // If view has not finished layout (e.g. view just mounted or sheet dismissing), retry shortly
        if clipView.bounds.height <= 10 || docView.bounds.height <= 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scrollToCenter(target: target, animated: animated)
            }
            return
        }

        // The top line of the note in page coordinates is target.bounds.maxY
        let topPointInPage = CGPoint(x: target.bounds.midX, y: target.bounds.maxY)
        let topPointInView = convert(topPointInPage, from: page)
        let topPointInDoc = docView.convert(topPointInView, from: self)

        let viewHeight = clipView.bounds.height
        let targetScrollY = topPointInDoc.y - viewHeight / 2.0
        let minY = docView.bounds.minY
        let maxY = max(minY, docView.bounds.maxY - viewHeight)
        let clampedScrollY = min(maxY, max(minY, targetScrollY))
        let targetPoint = NSPoint(x: clipView.bounds.origin.x, y: clampedScrollY)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(targetPoint)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clipView)
            }
        } else {
            clipView.scroll(to: targetPoint)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.focusRingType = .none
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.focusRingType = .none
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.type == .scrollWheel {
            super.scrollWheel(with: event)
        }
        onScroll?()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let toolbar = toolbarHostingView, !toolbar.isHidden {
            let p = toolbar.convert(point, from: self)
            if toolbar.bounds.contains(p) {
                return toolbar.hitTest(p) ?? toolbar
            }
        }
        return super.hitTest(point)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupScrollObserver()
            if let pending = pendingRestorePosition {
                pendingRestorePosition = nil
                restorePosition(pageIndex: pending.pageIndex, pageOffsetY: pending.pageOffsetY)
            }
        } else {
            removeScrollObserver()
            hideToolbar()
        }
    }

    public func currentVisiblePosition() -> (pageIndex: Int, pageOffsetY: CGFloat)? {
        guard let doc = document, doc.pageCount > 0 else { return nil }
        let topPointInView = NSPoint(x: bounds.midX, y: isFlipped ? bounds.minY + 5 : bounds.maxY - 5)
        guard let page = self.page(for: topPointInView, nearest: true) else {
            if let current = self.currentPage {
                let idx = doc.index(for: current)
                return (idx, 0)
            }
            return nil
        }
        let idx = doc.index(for: page)
        guard idx != NSNotFound else { return nil }
        let pointInPage = convert(topPointInView, to: page)
        let pageBounds = page.bounds(for: .cropBox)
        let offsetY = max(0, pageBounds.maxY - pointInPage.y)
        return (idx, offsetY)
    }

    public func restorePosition(pageIndex: Int, pageOffsetY: CGFloat) {
        guard let doc = document, pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return }

        if pageOffsetY <= 1 {
            isRestoringPosition = true
            go(to: page)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.isRestoringPosition = false
            }
            return
        }

        layoutDocumentView()
        guard let scrollView = activeScrollView,
              let docView = documentView else {
            isRestoringPosition = true
            go(to: page)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.isRestoringPosition = false
            }
            return
        }
        let clipView = scrollView.contentView
        if clipView.bounds.height <= 10 || docView.bounds.height <= 10 {
            pendingRestorePosition = (pageIndex, pageOffsetY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                if let pending = self?.pendingRestorePosition {
                    self?.pendingRestorePosition = nil
                    self?.restorePosition(pageIndex: pending.pageIndex, pageOffsetY: pending.pageOffsetY)
                }
            }
            return
        }

        isRestoringPosition = true
        let pageBounds = page.bounds(for: .cropBox)
        let targetY = max(pageBounds.minY, pageBounds.maxY - pageOffsetY)
        let dest = PDFDestination(page: page, at: CGPoint(x: pageBounds.minX, y: targetY))
        go(to: dest)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.isRestoringPosition = false
        }
    }

    public func applySubtlePageSeparators() {
        guard let docView = documentView else { return }
        for subview in docView.subviews {
            if let layer = subview.layer {
                layer.shadowOpacity = 0
                layer.shadowRadius = 0
                layer.borderWidth = 0
            }
            if let sublayers = subview.layer?.sublayers {
                for sublayer in sublayers {
                    sublayer.shadowOpacity = 0
                    sublayer.shadowRadius = 0
                    sublayer.borderWidth = 0
                }
            }
        }
    }

    private func setupScrollObserver() {
        removeScrollObserver()
        guard let clipView = pdfScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.toolbarHostingView?.isHidden == false {
                    self.updateToolbarPosition()
                }
                self.selectionCursorOverlay?.needsDisplay = true
                if let clip = self.pdfScrollView?.contentView {
                    let currentOrigin = clip.bounds.origin
                    if let last = self.lastClipOrigin {
                        if currentOrigin != last {
                            self.lastClipOrigin = currentOrigin
                            self.onScroll?()
                            if !self.isRestoringPosition {
                                let now = CACurrentMediaTime()
                                if now - self.lastScrollPositionUpdateTime > 0.25 {
                                    self.lastScrollPositionUpdateTime = now
                                    if let pos = self.currentVisiblePosition() {
                                        self.onPositionChanged?(pos.pageIndex, pos.pageOffsetY)
                                    }
                                }
                                self.scrollPositionDebounceWorkItem?.cancel()
                                let item = DispatchWorkItem { [weak self] in
                                    guard let self, !self.isRestoringPosition else { return }
                                    if let pos = self.currentVisiblePosition() {
                                        self.onPositionChanged?(pos.pageIndex, pos.pageOffsetY)
                                    }
                                }
                                self.scrollPositionDebounceWorkItem = item
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: item)
                            }
                        }
                    } else {
                        self.lastClipOrigin = currentOrigin
                    }
                }
            }
        }
    }

    func removeScrollObserver() {
        scrollPositionDebounceWorkItem?.cancel()
        scrollPositionDebounceWorkItem = nil
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
    }

    public override func layout() {
        super.layout()
        if scrollObserver == nil && window != nil {
            setupScrollObserver()
        }
        applySubtlePageSeparators()
        if let overlay = selectionCursorOverlay {
            overlay.frame = bounds
            overlay.needsDisplay = true
        }
        updateToolbarPosition()
    }

    public override func layoutDocumentView() {
        super.layoutDocumentView()
        applySubtlePageSeparators()
    }

    func updateToolbarPosition() {
        guard activeToolbarOwner == .pdf else {
            hideToolbar()
            return
        }
        if let emp = selectedEmphasisPhrase,
           let doc = document,
           let page = doc.page(at: emp.hitLine.page) {
            showEmphasisToolbar(phrase: emp.text, page: page, lineRect: emp.hitLine)
        } else if let pending = pendingSelection {
            let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
            let startHeight = CGFloat(pending.rects.first?.height ?? 16)
            let endHeight = CGFloat(pending.rects.last?.height ?? 16)
            showToolbar(
                mode: .create,
                targetPage: pending.endPage,
                endPoint: pending.endPoint,
                endLineHeight: endHeight,
                startPage: pending.startPage,
                startPoint: pending.startPoint,
                startLineHeight: startHeight,
                hasTargetCard: targetCardID != nil,
                isWithinTargetHighlight: isWithin
            )
        } else if let cardID = selectedCardID,
                  let card = cards.first(where: { $0.id == cardID }),
                  let doc = document {
            let segment = card.effectiveSegments.first(where: { $0.id == selectedSegmentID }) ?? card.effectiveSegments.first
            let rects = (segment?.rects.isEmpty == false) ? segment!.rects : PDFHighlightResolver.lineRects(for: card, in: doc)
            if let first = rects.first, let last = rects.last,
               let firstPage = doc.page(at: first.page),
               let lastPage = doc.page(at: last.page) {
                let startPt = endpoint(for: first, start: true)
                let endPt = endpoint(for: last, start: false)
                showToolbar(
                    mode: .edit(colorIndex: card.colorIndex),
                    targetPage: lastPage,
                    endPoint: endPt,
                    endLineHeight: CGFloat(last.height),
                    startPage: firstPage,
                    startPoint: startPt,
                    startLineHeight: CGFloat(first.height),
                    hasTargetCard: true,
                    isWithinTargetHighlight: true
                )
            } else {
                hideToolbar()
            }
        } else {
            hideToolbar()
        }
    }

    private static var toolbarSizeCache: [String: CGSize] = [:]

    private func measuredToolbarSize(
        for mode: PDFPopoverMode,
        hasTargetCard: Bool,
        isWithinTargetHighlight: Bool
    ) -> CGSize {
        let key: String
        switch mode {
        case .create:
            key = "create_\(hasTargetCard)_\(isWithinTargetHighlight)"
        case .edit:
            key = "edit"
        case .emphasisSelection:
            key = "emphasis"
        }
        if let cached = Self.toolbarSizeCache[key] {
            return cached
        }
        let measureView = PDFPopoverToolbarView(
            mode: mode,
            arrowOffset: 20,
            isArrowFlipped: false,
            hasTargetCard: hasTargetCard,
            isWithinTargetHighlight: isWithinTargetHighlight
        )
        let measured = NSHostingView(rootView: measureView).fittingSize
        let safeSize = CGSize(width: max(measured.width, 240.0), height: max(measured.height, 46.0))
        Self.toolbarSizeCache[key] = safeSize
        return safeSize
    }

    private func showToolbar(
        mode: PDFPopoverMode,
        targetPage: PDFPage?,
        endPoint: CGPoint,
        endLineHeight: CGFloat = 16.0,
        startPage: PDFPage? = nil,
        startPoint: CGPoint? = nil,
        startLineHeight: CGFloat? = nil,
        hasTargetCard: Bool = false,
        isWithinTargetHighlight: Bool = false
    ) {
        guard let targetPage else { hideToolbar(); return }

        let measuredSize = measuredToolbarSize(
            for: mode,
            hasTargetCard: hasTargetCard,
            isWithinTargetHighlight: isWithinTargetHighlight
        )
        let toolbarWidth = measuredSize.width
        let toolbarHeight = measuredSize.height

        let endDims = Self.handleDimensions(for: endLineHeight, scale: self.scaleFactor)
        let stemHeight = endDims.stemHeight
        let knobSize = endDims.knobSize

        // Bottom of the upside-down knob head in page coordinates
        let knobBottomPage = CGPoint(x: endPoint.x, y: endPoint.y - stemHeight / 2 - knobSize)
        let knobBottomView = convert(knobBottomPage, from: targetPage)
        let knobXView = knobBottomView.x

        var x = knobXView - toolbarWidth / 2.0
        let minX: CGFloat = 10.0
        let maxX: CGFloat = max(minX, bounds.width - toolbarWidth - 18.0)
        x = max(minX, min(x, maxX))

        let arrowOffset = max(14, min(knobXView - x - 7, toolbarWidth - 28))

        let marginFromKnob: CGFloat = 6.0
        let spaceBelow = knobBottomView.y - marginFromKnob - toolbarHeight
        let fitsBelow = spaceBelow >= 10.0

        let sPage = startPage ?? targetPage
        let sPt = startPoint ?? endPoint
        let startDims = Self.handleDimensions(for: startLineHeight ?? endLineHeight, scale: self.scaleFactor)
        let sHeight = startDims.stemHeight
        let sKnobSize = startDims.knobSize
        let knobTopPage = CGPoint(x: sPt.x, y: sPt.y + sHeight / 2 + sKnobSize)
        let knobTopView = convert(knobTopPage, from: sPage)

        let spaceAbove = bounds.height - (knobTopView.y + marginFromKnob + toolbarHeight)
        let fitsAbove = spaceAbove >= 10.0

        let isArrowFlipped: Bool
        var y: CGFloat

        if fitsBelow {
            isArrowFlipped = false
            y = knobBottomView.y - marginFromKnob - toolbarHeight
        } else if fitsAbove {
            isArrowFlipped = true
            y = knobTopView.y + marginFromKnob
        } else {
            if spaceAbove >= spaceBelow {
                isArrowFlipped = true
                y = knobTopView.y + marginFromKnob
            } else {
                isArrowFlipped = false
                y = knobBottomView.y - marginFromKnob - toolbarHeight
            }
        }

        // Strict vertical clamping inside view bounds
        let minY: CGFloat = 8.0
        let maxY: CGFloat = max(minY, bounds.height - toolbarHeight - 8.0)
        y = max(minY, min(y, maxY))

        let toolbarView = PDFPopoverToolbarView(
            mode: mode,
            arrowOffset: arrowOffset,
            isArrowFlipped: isArrowFlipped,
            onCopy: { [weak self] in
                self?.handleToolbarCopy()
            },
            onSelectColor: { [weak self] colorIdx in
                self?.handleToolbarColor(colorIdx)
            },
            onEdit: { [weak self] in
                self?.handleToolbarEdit()
            },
            onDelete: { [weak self] in
                self?.handleToolbarDelete()
            },
            onEmphasize: { [weak self] in
                self?.handleToolbarEmphasize()
            },
            onAsTitle: { [weak self] in
                self?.handleToolbarAsTitle()
            },
            onAddToComments: { [weak self] in
                self?.handleToolbarAddToComments()
            },
            onMerge: { [weak self] in
                self?.handleToolbarMerge()
            },
            onResearch: { [weak self] in
                self?.handleToolbarResearch()
            },
            onComment: { [weak self] in
                if let id = self?.selectedCardID {
                    self?.editCardHandler?(id)
                }
            },
            onTag: { [weak self] in
                if let id = self?.selectedCardID {
                    self?.editCardHandler?(id)
                }
            },
            hasTargetCard: hasTargetCard,
            isWithinTargetHighlight: isWithinTargetHighlight
        )

        let frame = CGRect(x: x, y: y, width: toolbarWidth, height: toolbarHeight)
        if let existing = toolbarHostingView {
            existing.rootView = AnyView(toolbarView)
            existing.frame = frame
            existing.isHidden = false
            addSubview(existing, positioned: .above, relativeTo: nil)
            window?.resetCursorRects()
        } else {
            let hosting = ToolbarHostingView(rootView: AnyView(toolbarView))
            hosting.frame = frame
            addSubview(hosting, positioned: .above, relativeTo: nil)
            toolbarHostingView = hosting
            window?.resetCursorRects()
        }
    }

    func hideToolbar() {
        toolbarHostingView?.isHidden = true
        window?.resetCursorRects()
    }

    func showEmphasisToolbar(phrase: String, page: PDFPage, lineRect: HighlightRect) {
        setupScrollObserver()
        let toolbarWidth: CGFloat = 120.0
        let toolbarHeight: CGFloat = 36.0

        let topCenterPage = CGPoint(x: lineRect.x + lineRect.width / 2.0, y: lineRect.y + lineRect.height)
        let topCenterView = convert(topCenterPage, from: page)

        var x = topCenterView.x - toolbarWidth / 2.0
        let minX: CGFloat = 10.0
        let maxX: CGFloat = max(minX, bounds.width - toolbarWidth - 18.0)
        x = max(minX, min(x, maxX))

        let arrowOffset = max(14, min(topCenterView.x - x - 7, toolbarWidth - 28))

        let fitsAbove = (topCenterView.y + 6.0 + toolbarHeight) <= (bounds.height - 10.0)
        let isArrowFlipped = fitsAbove

        var y: CGFloat
        if fitsAbove {
            y = topCenterView.y + 6.0
        } else {
            let bottomCenterPage = CGPoint(x: lineRect.x + lineRect.width / 2.0, y: lineRect.y)
            let bottomCenterView = convert(bottomCenterPage, from: page)
            y = bottomCenterView.y - toolbarHeight - 6.0
        }
        let minY: CGFloat = 8.0
        let maxY: CGFloat = max(minY, bounds.height - toolbarHeight - 8.0)
        y = max(minY, min(y, maxY))

        let toolbarView = PDFPopoverToolbarView(
            mode: .emphasisSelection(phrase: phrase),
            arrowOffset: arrowOffset,
            isArrowFlipped: isArrowFlipped,
            onResearch: { [weak self] in
                self?.handleToolbarResearch()
            },
            onDeleteEmphasis: { [weak self] in
                self?.handleDeleteEmphasis()
            }
        )

        let frame = CGRect(x: x, y: y, width: toolbarWidth, height: toolbarHeight)
        if let existing = toolbarHostingView {
            existing.rootView = AnyView(toolbarView)
            existing.frame = frame
            existing.isHidden = false
            addSubview(existing, positioned: .above, relativeTo: nil)
            window?.resetCursorRects()
        } else {
            let hosting = ToolbarHostingView(rootView: AnyView(toolbarView))
            hosting.frame = frame
            addSubview(hosting, positioned: .above, relativeTo: nil)
            toolbarHostingView = hosting
            window?.resetCursorRects()
        }
    }

    func renderEmphasisSelectionHighlight(_ emp: EmphasisHitInfo) {
        clearEmphasisSelectionHighlight()
        clearHandles()
        guard let document else { return }
        for r in emp.rects {
            guard let page = document.page(at: r.page) else { continue }
            let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let annot = PDFHighlightResolver.createHighlightAnnotation(
                bounds: rect,
                color: MarginNoteTheme.nsCursorColor.withAlphaComponent(0.35),
                contents: "MarginGraph-emphasis-selected-highlight"
            )
            page.addAnnotation(annot)
        }
        if let first = emp.rects.first, let last = emp.rects.last,
           let firstPage = document.page(at: first.page),
           let lastPage = document.page(at: last.page) {
            let startPt = endpoint(for: first, start: true)
            let endPt = endpoint(for: last, start: false)
            addHandle(to: firstPage, at: startPt, lineHeight: CGFloat(first.height), accent: MarginNoteTheme.nsCursorColor, isStart: true)
            addHandle(to: lastPage, at: endPt, lineHeight: CGFloat(last.height), accent: MarginNoteTheme.nsCursorColor, isStart: false)
        }
        setNeedsDisplay(bounds)
    }

    func clearEmphasisSelectionHighlight() {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annot in page.annotations where annot.contents == "MarginGraph-emphasis-selected-highlight" {
                page.removeAnnotation(annot)
            }
        }
        setNeedsDisplay(bounds)
    }

    private func handleDeleteEmphasis() {
        guard let emp = selectedEmphasisPhrase else { return }
        deleteEmphasisHandler?(emp.cardID, emp.text, emp.rects)

        if let doc = document {
            for r in emp.rects {
                guard let page = doc.page(at: r.page) else { continue }
                let rBox = CGRect(x: r.x - 4, y: r.y - 4, width: r.width + 8, height: r.height + 8)
                let annotsToRemove = page.annotations.filter { annot in
                    (annot is DottedLineAnnotation || annot.contents == "MarginGraph-card-emphasis") &&
                    annot.bounds.intersects(rBox)
                }
                for annot in annotsToRemove {
                    page.removeAnnotation(annot)
                }
            }
        }

        if let idx = cards.firstIndex(where: { $0.id == emp.cardID }) {
            var card = cards[idx]
            card.emphasisList.removeAll { empItem in
                empItem == emp.text ||
                empItem.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty } ==
                emp.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            }
            card.emphasisRects.removeAll { r in
                emp.rects.contains { e in
                    e.page == r.page && abs(e.y - r.y) < 2.0 && abs(e.x - r.x) < 4.0
                }
            }
            cards[idx] = card
        }

        clearEmphasisSelectionHighlight()
        selectedEmphasisPhrase = nil
        updateToolbarPosition()
        setNeedsDisplay(bounds)
    }

    private func handleToolbarResearch() {
        let textToSearch: String
        if let emp = selectedEmphasisPhrase {
            textToSearch = emp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let pending = pendingSelection {
            textToSearch = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let cardID = selectedCardID, let card = cards.first(where: { $0.id == cardID }) {
            textToSearch = (!card.highlightText.isEmpty ? card.highlightText : card.title).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return
        }
        guard !textToSearch.isEmpty else { return }
        if let encoded = textToSearch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleToolbarCopy() {
        if let pending = pendingSelection {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pending.text, forType: .string)
            clearPendingSelection()
            clearBrackets()
            hideToolbar()
            if let targetID = targetCardID, let card = cards.first(where: { $0.id == targetID }), let doc = document {
                let rects = PDFHighlightResolver.lineRects(for: card, in: doc)
                let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
                installHandleAnnotations(for: card, lineRects: rects, accent: accent)
            }
            targetCardID = nil
        } else if let cardID = selectedCardID, let card = cards.first(where: { $0.id == cardID }) {
            NSPasteboard.general.clearContents()
            let content = !card.highlightText.isEmpty ? card.highlightText : (!card.notesText.isEmpty ? card.notesText : card.title)
            NSPasteboard.general.setString(content, forType: .string)
        }
    }

    private func handleToolbarColor(_ colorIdx: Int) {
        clearBrackets()
        targetCardID = nil
        if let pending = pendingSelection, let document {
            let startPageIdx = pageIndex(of: pending.startPage, in: document) ?? 0
            let bounds = pending.selection.bounds(for: pending.startPage)
            let excerpt = PDFExcerpt(
                bookMD5: bookMD5,
                pageIndex: startPageIdx,
                bounds: bounds,
                text: pending.text,
                croppedImageData: nil
            )
            clearPendingSelection()
            hideToolbar()
            createCardWithColorHandler?(excerpt, colorIdx)
        } else if let cardID = selectedCardID {
            changeCardColorHandler?(cardID, colorIdx)
            if let idx = cards.firstIndex(where: { $0.id == cardID }) {
                cards[idx].colorIndex = colorIdx
            }
            if let doc = document, let card = cards.first(where: { $0.id == cardID }) {
                let rects = PDFHighlightResolver.lineRects(for: card, in: doc)
                let accent = NSColor(MarginNoteTheme.cardColors(for: colorIdx).accent)
                clearHandles()
                installHandleAnnotations(for: card, lineRects: rects, accent: accent)
            }
            updateToolbarPosition()
        }
    }

    private func handleToolbarAsTitle() {
        guard let targetID = targetCardID ?? selectedCardID else { return }
        let text: String
        if let pending = pendingSelection {
            text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let card = cards.first(where: { $0.id == targetID }) {
            text = (!card.highlightText.isEmpty ? card.highlightText : card.title).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return
        }
        guard !text.isEmpty else { return }
        asTitleHandler?(targetID, text)
        clearPendingSelection()
        clearBrackets()
        hideToolbar()
        if let card = cards.first(where: { $0.id == targetID }), let doc = document {
            let rects = PDFHighlightResolver.lineRects(for: card, in: doc)
            let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
            installHandleAnnotations(for: card, lineRects: rects, accent: accent)
        }
        targetCardID = nil
    }

    private func handleToolbarAddToComments() {
        guard let targetID = targetCardID ?? selectedCardID else { return }
        let text: String
        if let pending = pendingSelection {
            text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let card = cards.first(where: { $0.id == targetID }) {
            text = (!card.highlightText.isEmpty ? card.highlightText : card.title).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return
        }
        guard !text.isEmpty else { return }
        addToCommentsHandler?(targetID, text)
        clearPendingSelection()
        clearBrackets()
        hideToolbar()
        if let card = cards.first(where: { $0.id == targetID }), let doc = document {
            let rects = PDFHighlightResolver.lineRects(for: card, in: doc)
            let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
            installHandleAnnotations(for: card, lineRects: rects, accent: accent)
        }
        targetCardID = nil
    }

    private func handleToolbarMerge() {
        guard let targetID = targetCardID ?? selectedCardID else { return }
        guard let pending = pendingSelection else { return }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        mergeHandler?(targetID, text, pending.rects)
        clearPendingSelection()
        clearBrackets()
        hideToolbar()
        targetCardID = nil
    }

    private func handleToolbarEmphasize() {
        guard let targetID = targetCardID ?? selectedCardID else { return }
        let text: String
        let rects: [HighlightRect]
        if let pending = pendingSelection {
            text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
            rects = pending.rects
        } else if let card = cards.first(where: { $0.id == targetID }) {
            text = card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines)
            rects = card.highlightRects
        } else {
            return
        }
        guard !text.isEmpty else { return }
        emphasizeHandler?(targetID, text, rects)

        // Immediately add DottedLineAnnotation to the PDF view for instant visual feedback
        for line in rects {
            guard let doc = document, let page = doc.page(at: line.page) else { continue }
            let lineY = line.y - 1.0
            let startPt = CGPoint(x: line.x, y: lineY)
            let endPt = CGPoint(x: line.x + line.width, y: lineY)
            let annot = DottedLineAnnotation(
                bounds: CGRect(x: line.x - 2, y: lineY - 3, width: line.width + 4, height: 6),
                forType: .square,
                withProperties: nil
            )
            annot.lineStartPoint = startPt
            annot.lineEndPoint = endPt
            annot.strokeColor = MarginNoteTheme.nsCursorColor
            annot.color = MarginNoteTheme.nsCursorColor
            annot.strokeLineWidth = 2.5
            annot.dashPattern = [2.5, 3.5]
            annot.contents = "MarginGraph-card-emphasis"
            page.addAnnotation(annot)
        }

        // Update local in-memory card immediately so redraw won't drop emphasis
        if let idx = cards.firstIndex(where: { $0.id == targetID }) {
            var updated = cards[idx]
            if !updated.emphasisList.contains(text) {
                updated.emphasisList.append(text)
            }
            for r in rects {
                if !updated.emphasisRects.contains(where: { $0.page == r.page && abs($0.y - r.y) < 1.0 && abs($0.x - r.x) < 2.0 && abs($0.width - r.width) < 2.0 }) {
                    updated.emphasisRects.append(r)
                }
            }
            cards[idx] = updated
        }

        clearPendingSelection()
        clearBrackets()
        hideToolbar()
        if let card = cards.first(where: { $0.id == targetID }), let doc = document {
            let segment = card.effectiveSegments.first(where: { $0.id == selectedSegmentID }) ?? card.effectiveSegments.first
            let handleRects = (segment?.rects.isEmpty == false) ? segment!.rects : PDFHighlightResolver.lineRects(for: card, in: doc)
            let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
            installHandleAnnotations(for: handleRects, accent: accent)
        }
        targetCardID = nil
        setNeedsDisplay(bounds)
    }

    private func handleToolbarEdit() {
        if let cardID = selectedCardID {
            editCardHandler?(cardID)
        }
    }

    private func handleToolbarDelete() {
        if let cardID = selectedCardID {
            let toDelete = cardID
            let segID = selectedSegmentID
            selectedCardID = nil
            selectedSegmentID = nil
            clearHandles()
            clearBrackets()
            hideToolbar()
            if let card = cards.first(where: { $0.id == toDelete }),
               card.effectiveSegments.count > 1,
               let segID {
                deleteSegmentHandler?(toDelete, segID)
            } else {
                deleteCardHandler?(toDelete)
            }
        }
    }

    func clearPendingSelection() {
        guard let document else { pendingSelection = nil; return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents == "MarginGraph-pending-highlight"
                || annotation.contents == "MarginGraph-pending-handle-start"
                || annotation.contents == "MarginGraph-pending-handle-end"
                || annotation.contents == "MarginGraph-pending-handle-knob-start"
                || annotation.contents == "MarginGraph-pending-handle-knob-end" {
                page.removeAnnotation(annotation)
            }
        }
        pendingSelection = nil
        setNeedsDisplay(bounds)
    }

    func checkIfPendingWithinTarget(_ pending: PendingSelection, targetCardID: UUID?) -> Bool {
        guard let targetCardID, let targetCard = cards.first(where: { $0.id == targetCardID }) else { return false }
        let trimmedPending = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPending.isEmpty else { return false }

        if targetCard.highlightText.contains(trimmedPending) {
            return true
        }

        guard let document else { return false }
        let targetRects = PDFHighlightResolver.lineRects(for: targetCard, in: document)
        for pRect in pending.rects {
            let matching = targetRects.contains { tRect in
                tRect.page == pRect.page &&
                abs(tRect.y - pRect.y) < 6.0 &&
                pRect.x >= tRect.x - 5.0 &&
                (pRect.x + pRect.width) <= (tRect.x + tRect.width + 5.0)
            }
            if !matching { return false }
        }
        return !pending.rects.isEmpty
    }

    func installBracketAnnotations(for card: NoteCard) {
        clearBrackets()
        guard let document else { return }
        let rects = PDFHighlightResolver.lineRects(for: card, in: document)
        guard let first = rects.first, let last = rects.last,
              let firstPage = document.page(at: first.page),
              let lastPage = document.page(at: last.page) else { return }

        let bracketColor = MarginNoteTheme.nsCursorColor
        let thickness: CGFloat = 2.5
        let armLength: CGFloat = 12.0

        // Top-left bracket: ┌ on firstPage
        let startTopArm = PDFAnnotation(
            bounds: CGRect(x: first.x, y: first.y + first.height - thickness, width: armLength, height: thickness),
            forType: .square,
            withProperties: nil
        )
        startTopArm.color = bracketColor
        startTopArm.interiorColor = bracketColor
        startTopArm.contents = "MarginGraph-target-bracket"
        firstPage.addAnnotation(startTopArm)

        let startLeftArm = PDFAnnotation(
            bounds: CGRect(x: first.x, y: first.y + first.height - armLength, width: thickness, height: armLength),
            forType: .square,
            withProperties: nil
        )
        startLeftArm.color = bracketColor
        startLeftArm.interiorColor = bracketColor
        startLeftArm.contents = "MarginGraph-target-bracket"
        firstPage.addAnnotation(startLeftArm)

        // Bottom-right bracket: ┘ on lastPage
        let endBottomArm = PDFAnnotation(
            bounds: CGRect(x: (first.page == last.page && first.y == last.y) ? (last.x + last.width - armLength) : (last.x + last.width - armLength), y: last.y, width: armLength, height: thickness),
            forType: .square,
            withProperties: nil
        )
        endBottomArm.color = bracketColor
        endBottomArm.interiorColor = bracketColor
        endBottomArm.contents = "MarginGraph-target-bracket"
        lastPage.addAnnotation(endBottomArm)

        let endRightArm = PDFAnnotation(
            bounds: CGRect(x: last.x + last.width - thickness, y: last.y, width: thickness, height: armLength),
            forType: .square,
            withProperties: nil
        )
        endRightArm.color = bracketColor
        endRightArm.interiorColor = bracketColor
        endRightArm.contents = "MarginGraph-target-bracket"
        lastPage.addAnnotation(endRightArm)

        setNeedsDisplay(bounds)
    }

    func clearBrackets() {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents == "MarginGraph-target-bracket" {
                page.removeAnnotation(annotation)
            }
        }
        setNeedsDisplay(bounds)
    }

    private func renderPendingHighlight(_ pending: PendingSelection) {
        clearPendingSelection()
        self.pendingSelection = pending
        guard let document else { return }

        let lightBlue = NSColor(srgbRed: 209/255.0, green: 220/255.0, blue: 235/255.0, alpha: 0.85)
        for line in pending.rects {
            guard let page = document.page(at: line.page) else { continue }
            let rect = CGRect(x: line.x, y: line.y, width: line.width, height: line.height)
            let annotation = PDFHighlightResolver.createHighlightAnnotation(
                bounds: rect,
                color: lightBlue,
                contents: "MarginGraph-pending-highlight"
            )
            page.addAnnotation(annotation)
        }

        if let first = pending.rects.first, let last = pending.rects.last {
            addHandle(
                to: pending.startPage,
                at: pending.startPoint,
                lineHeight: CGFloat(first.height),
                accent: lightBlue,
                isStart: true,
                isPending: true
            )
            addHandle(
                to: pending.endPage,
                at: pending.endPoint,
                lineHeight: CGFloat(last.height),
                accent: lightBlue,
                isStart: false,
                isPending: true
            )
        }
        setNeedsDisplay(bounds)
    }

    private func triggerHoldSelection() {
        guard var tracker = holdTracker, !tracker.didTrigger else { return }
        tracker.didTrigger = true
        holdTracker = tracker

        guard let document else { return }
        let page = tracker.page
        let pagePoint = tracker.pagePoint

        guard let wordSel = page.selectionForWord(at: pagePoint) ?? page.selection(for: NSRange(location: max(0, page.characterIndex(at: pagePoint)), length: 1)),
              let str = wordSel.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let rects = PDFHighlightResolver.lineRects(from: wordSel, document: document)
        guard let first = rects.first, let last = rects.last else { return }

        targetCardID = tracker.initialSelectedCardID
        clearHandles()
        hideToolbar()

        if let targetID = targetCardID, let targetCard = cards.first(where: { $0.id == targetID }) {
            installBracketAnnotations(for: targetCard)
        }

        let canonicalStart = endpoint(for: first, start: true)
        let canonicalEnd = endpoint(for: last, start: false)
        let text = PDFHighlightResolver.normalizeExcerptParagraphs(wordSel)

        let pending = PendingSelection(
            selection: wordSel,
            text: text,
            rects: rects,
            startPage: page,
            startPoint: canonicalStart,
            endPage: page,
            endPoint: canonicalEnd
        )
        renderPendingHighlight(pending)
        let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
        showToolbar(
            mode: .create,
            targetPage: page,
            endPoint: canonicalEnd,
            endLineHeight: CGFloat(rects.last?.height ?? 16),
            startPage: page,
            startPoint: canonicalStart,
            startLineHeight: CGFloat(rects.first?.height ?? 16),
            hasTargetCard: targetCardID != nil,
            isWithinTargetHighlight: isWithin
        )

        handleDrag = HandleDrag(
            cardID: nil,
            segmentID: nil,
            movingStart: false,
            startPage: page,
            startPoint: canonicalStart,
            endPage: page,
            endPoint: canonicalEnd,
            grabOffset: .zero,
            latestSelection: wordSel
        )
    }

    public override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        Swift.print("[MouseDown] viewPoint=\(viewPoint) toolbarHidden=\(toolbarHostingView?.isHidden ?? true) toolbarFrame=\(toolbarHostingView?.frame ?? .zero)")

        // If click is inside floating toolbar, let toolbar handle it
        if let toolbar = toolbarHostingView, !toolbar.isHidden {
            let pInToolbar = toolbar.convert(viewPoint, from: self)
            Swift.print("[MouseDown] pInToolbar=\(pInToolbar) toolbarBounds=\(toolbar.bounds)")
            if toolbar.bounds.contains(pInToolbar) {
                if selectedEmphasisPhrase != nil {
                    if pInToolbar.x >= 70 {
                        handleDeleteEmphasis()
                    } else {
                        handleToolbarResearch()
                    }
                    return
                }
                return
            }
        }

        guard let page = page(for: viewPoint, nearest: true) else {
            holdTracker?.timer?.invalidate()
            holdTracker = nil
            clearPendingSelection()
            clearBrackets()
            selectedEmphasisPhrase = nil
            targetCardID = nil
            selectedCardID = nil
            activeToolbarOwner = .none
            selectCardHandler?(nil)
            clearHandles()
            hideToolbar()
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)

        if selectionTool == .textSelection,
           beginHandleDragIfNeeded(page: page, point: pagePoint) {
            selectedEmphasisPhrase = nil
            holdTracker?.timer?.invalidate()
            holdTracker = nil
            return
        }

        // Double-click shortcut: immediately select word and show creation toolbar
        if event.clickCount >= 2, selectionTool == .textSelection {
            holdTracker?.timer?.invalidate()
            holdTracker = nil
            selectedEmphasisPhrase = nil
            if let wordSel = page.selectionForWord(at: pagePoint),
               let str = wordSel.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let document {
                let rects = PDFHighlightResolver.lineRects(from: wordSel, document: document)
                if let first = rects.first, let last = rects.last {
                    targetCardID = selectedCardID
                    clearHandles()
                    hideToolbar()

                    if let targetID = targetCardID, let targetCard = cards.first(where: { $0.id == targetID }) {
                        installBracketAnnotations(for: targetCard)
                    }

                    let canonicalStart = endpoint(for: first, start: true)
                    let canonicalEnd = endpoint(for: last, start: false)
                    let text = PDFHighlightResolver.normalizeExcerptParagraphs(wordSel)

                    let pending = PendingSelection(
                        selection: wordSel,
                        text: text,
                        rects: rects,
                        startPage: page,
                        startPoint: canonicalStart,
                        endPage: page,
                        endPoint: canonicalEnd
                    )
                    renderPendingHighlight(pending)
                    let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                    showToolbar(
                        mode: .create,
                        targetPage: page,
                        endPoint: canonicalEnd,
                        endLineHeight: CGFloat(rects.last?.height ?? 16),
                        startPage: page,
                        startPoint: canonicalStart,
                        startLineHeight: CGFloat(rects.first?.height ?? 16),
                        hasTargetCard: targetCardID != nil,
                        isWithinTargetHighlight: isWithin
                    )
                    return
                }
            }
        }

        if selectionTool == .textSelection {
            let hitInfo = cardHitSegment(on: page, at: pagePoint)
            let initialTargetID = selectedCardID ?? hitInfo?.card.id

            if let (card, segment) = hitInfo {
                if let hitEmphasis = emphasisHit(in: card, on: page, at: pagePoint) {
                    clearPendingSelection()
                    clearBrackets()
                    targetCardID = nil
                    selectedCardID = card.id
                    selectedSegmentID = segment.id
                    activeToolbarOwner = .pdf
                    selectCardHandler?(card.id)
                    selectedEmphasisPhrase = hitEmphasis
                    renderEmphasisSelectionHighlight(hitEmphasis)
                    if let doc = document, let p = doc.page(at: hitEmphasis.hitLine.page) {
                        showEmphasisToolbar(phrase: hitEmphasis.text, page: p, lineRect: hitEmphasis.hitLine)
                    }
                    return
                }

                selectedEmphasisPhrase = nil
                clearEmphasisSelectionHighlight()
                clearPendingSelection()
                clearBrackets()
                targetCardID = nil
                selectedCardID = card.id
                selectedSegmentID = segment.id
                activeToolbarOwner = .pdf
                selectCardHandler?(card.id)
                if let document {
                    let rawRects = (segment.rects.isEmpty == false) ? segment.rects : PDFHighlightResolver.lineRects(for: card, in: document)
                    let rects = PDFHighlightResolver.expandBlockRectsIfNeeded(rawRects, in: document)
                    let accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
                    clearHandles()
                    installHandleAnnotations(for: card, lineRects: rects, accent: accent)
                }
                updateToolbarPosition()
            }

            // Arm click-and-hold tracker: if held, triggerHoldSelection will turn targetCard into brackets!
            holdTracker?.timer?.invalidate()
            var tracker = HoldTracker(
                initialSelectedCardID: initialTargetID,
                cardHitID: hitInfo?.card.id,
                page: page,
                pagePoint: pagePoint,
                viewPoint: viewPoint
            )
            tracker.timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.triggerHoldSelection()
                }
            }
            holdTracker = tracker
            return
        }

        // Blank area outside any note or handle in rectMarquee mode
        holdTracker?.timer?.invalidate()
        holdTracker = nil
        clearPendingSelection()
        clearBrackets()
        selectedEmphasisPhrase = nil
        targetCardID = nil
        selectedCardID = nil
        activeToolbarOwner = .none
        selectCardHandler?(nil)
        clearHandles()
        hideToolbar()

        guard selectionTool == .rectMarquee else {
            super.mouseDown(with: event)
            return
        }

        dragStart = (page, pagePoint)
        installDragLayer()
    }

    public override func mouseDragged(with event: NSEvent) {
        if let tracker = holdTracker, !tracker.didTrigger {
            let currentView = convert(event.locationInWindow, from: nil)
            let dist = hypot(currentView.x - tracker.viewPoint.x, currentView.y - tracker.viewPoint.y)
            if dist > 4.0 {
                tracker.timer?.invalidate()
                triggerHoldSelection()
            }
        }

        if var handleDrag {
            let currentView = convert(event.locationInWindow, from: nil)
            guard let currentPage = page(for: currentView, nearest: true) else { return }
            let rawCurrentPoint = convert(currentView, to: currentPage)
            let currentPoint = CGPoint(
                x: rawCurrentPoint.x - handleDrag.grabOffset.x,
                y: rawCurrentPoint.y - handleDrag.grabOffset.y
            )
            if handleDrag.movingStart {
                handleDrag.startPage = currentPage
                handleDrag.startPoint = currentPoint
            } else {
                handleDrag.endPage = currentPage
                handleDrag.endPoint = currentPoint
            }

            if let selection = makeMultiPageSelection(
                from: handleDrag.startPage, at: handleDrag.startPoint,
                to: handleDrag.endPage, at: handleDrag.endPoint
            ), let doc = document {
                let rects = PDFHighlightResolver.lineRects(from: selection, document: doc)
                if let first = rects.first, let last = rects.last,
                   let firstPage = doc.page(at: first.page),
                   let lastPage = doc.page(at: last.page) {
                    let startPt = endpoint(for: first, start: true)
                    let endPt = endpoint(for: last, start: false)
                    handleDrag.latestSelection = selection
                    if let cardID = handleDrag.cardID {
                        renderLiveHighlight(
                            selection,
                            cardID: cardID,
                            startPoint: startPt,
                            endPoint: endPt,
                            startHeight: CGFloat(first.height),
                            endHeight: CGFloat(last.height),
                            startPage: firstPage,
                            endPage: lastPage
                        )
                        hideToolbar()
                    } else {
                        // Pending selection drag
                        let text = PDFHighlightResolver.normalizeExcerptParagraphs(selection)
                        let pending = PendingSelection(
                            selection: selection,
                            text: text,
                            rects: rects,
                            startPage: firstPage,
                            startPoint: startPt,
                            endPage: lastPage,
                            endPoint: endPt
                        )
                        renderPendingHighlight(pending)
                        hideToolbar()
                    }
                }
            }
            self.handleDrag = handleDrag
            return
        }

        guard selectionTool == .rectMarquee, let start = dragStart else {
            super.mouseDragged(with: event)
            return
        }

        let currentView = convert(event.locationInWindow, from: nil)
        let currentPage = convert(currentView, to: start.page)
        let rect = normalizedRect(from: start.point, to: currentPage)
        dragLayer?.path = CGPath(rect: convert(rect, from: start.page), transform: nil)
    }

    public override func mouseUp(with event: NSEvent) {
        let tracker = holdTracker
        holdTracker?.timer?.invalidate()
        holdTracker = nil

        if let handleDrag {
            defer {
                clearLiveHighlight()
                self.handleDrag = nil
            }
            let currentView = convert(event.locationInWindow, from: nil)
            guard let currentPage = page(for: currentView, nearest: true) else { return }
            let rawCurrentPoint = convert(currentView, to: currentPage)
            let currentPoint = CGPoint(
                x: rawCurrentPoint.x - handleDrag.grabOffset.x,
                y: rawCurrentPoint.y - handleDrag.grabOffset.y
            )
            let startPage = handleDrag.movingStart ? currentPage : handleDrag.startPage
            let startPoint = handleDrag.movingStart ? currentPoint : handleDrag.startPoint
            let endPage = handleDrag.movingStart ? handleDrag.endPage : currentPage
            let endPoint = handleDrag.movingStart ? handleDrag.endPoint : currentPoint

            guard let document,
                  let selection = makeMultiPageSelection(from: startPage, at: startPoint, to: endPage, at: endPoint) ?? handleDrag.latestSelection
            else { return }

            let rects = PDFHighlightResolver.lineRects(from: selection, document: document)
            guard !rects.isEmpty else { return }

            let canonicalStart = endpoint(for: rects.first!, start: true)
            let canonicalEnd = endpoint(for: rects.last!, start: false)
            let normalizedText = PDFHighlightResolver.normalizeExcerptParagraphs(selection)

            if let cardID = handleDrag.cardID {
                updateCardHighlightHandler?(
                    cardID,
                    handleDrag.segmentID,
                    normalizedText,
                    rects,
                    canonicalStart,
                    canonicalEnd
                )
                showToolbar(
                    mode: .edit(colorIndex: cards.first(where: { $0.id == cardID })?.colorIndex ?? 0),
                    targetPage: endPage,
                    endPoint: canonicalEnd,
                    endLineHeight: CGFloat(rects.last?.height ?? 16),
                    startPage: startPage,
                    startPoint: canonicalStart,
                    startLineHeight: CGFloat(rects.first?.height ?? 16)
                )
            } else {
                let pending = PendingSelection(
                    selection: selection,
                    text: normalizedText,
                    rects: rects,
                    startPage: startPage,
                    startPoint: canonicalStart,
                    endPage: endPage,
                    endPoint: canonicalEnd
                )
                renderPendingHighlight(pending)
                let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                showToolbar(
                    mode: .create,
                    targetPage: endPage,
                    endPoint: canonicalEnd,
                    endLineHeight: CGFloat(rects.last?.height ?? 16),
                    startPage: startPage,
                    startPoint: canonicalStart,
                    startLineHeight: CGFloat(rects.first?.height ?? 16),
                    hasTargetCard: targetCardID != nil,
                    isWithinTargetHighlight: isWithin
                )
            }
            return
        }

        if selectionTool == .rectMarquee, let start = dragStart {
            let currentView = convert(event.locationInWindow, from: nil)
            let end = convert(currentView, to: start.page)
            let bounds = normalizedRect(from: start.point, to: end)
            cleanupDragLayer()
            dragStart = nil

            if bounds.width > 2,
               bounds.height > 2,
               let document,
               let pageIndex = pageIndex(of: start.page, in: document),
               let factory = excerptFactory {
                let rawText = start.page.selection(for: bounds)?.string ?? ""
                let text = PDFHighlightResolver.normalizeExcerptParagraphs(rawText)
                excerptHandler?(factory(pageIndex, bounds, text))
            }
            return
        }

        if let tracker {
            if tracker.didTrigger {
                // Hold selection triggered and installed pending selection!
                return
            } else if tracker.cardHitID == nil {
                // Quick click without hold on empty space: clear selection
                clearPendingSelection()
                clearBrackets()
                targetCardID = nil
                selectedCardID = nil
                activeToolbarOwner = .none
                selectCardHandler?(nil)
                clearHandles()
                hideToolbar()
            }
            return
        }

        super.mouseUp(with: event)

        guard selectionTool == .textSelection,
              let selection = currentSelection,
              let str = selection.string,
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document else { return }

        // Clear PDFKit system selection highlight
        clearSelection()

        let rects = PDFHighlightResolver.lineRects(from: selection, document: document)
        guard let first = rects.first, let last = rects.last,
              let firstPage = document.page(at: first.page),
              let lastPage = document.page(at: last.page) else { return }

        let startPoint = endpoint(for: first, start: true)
        let endPoint = endpoint(for: last, start: false)
        let normalizedText = PDFHighlightResolver.normalizeExcerptParagraphs(selection)

        if let targetID = targetCardID, let targetCard = cards.first(where: { $0.id == targetID }) {
            installBracketAnnotations(for: targetCard)
        } else {
            clearHandles()
        }

        let pending = PendingSelection(
            selection: selection,
            text: normalizedText,
            rects: rects,
            startPage: firstPage,
            startPoint: startPoint,
            endPage: lastPage,
            endPoint: endPoint
        )
        renderPendingHighlight(pending)
        let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
        showToolbar(
            mode: .create,
            targetPage: lastPage,
            endPoint: endPoint,
            endLineHeight: CGFloat(last.height),
            startPage: firstPage,
            startPoint: startPoint,
            startLineHeight: CGFloat(first.height),
            hasTargetCard: targetCardID != nil,
            isWithinTargetHighlight: isWithin
        )
    }

    public override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let toolbar = toolbarHostingView, !toolbar.isHidden, toolbar.frame.contains(viewPoint) {
            // Hovering over floating toolbar popover
            // Prevent PDFView from setting NSCursor.iBeam!
            if NSCursor.current != .pointingHand {
                NSCursor.arrow.set()
            }
            return
        }
        super.mouseMoved(with: event)
    }

    public override func cursorUpdate(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let toolbar = toolbarHostingView, !toolbar.isHidden, toolbar.frame.contains(viewPoint) {
            if NSCursor.current != .pointingHand {
                NSCursor.arrow.set()
            }
            return
        }
        super.cursorUpdate(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            return super.menu(for: event)
        }
        let pagePoint = convert(viewPoint, to: page)

        let hit = cardHitSegment(on: page, at: pagePoint)
        let resolvedCard = hit?.card ?? (selectedCardID.flatMap { id in cards.first(where: { $0.id == id }) })
        let resolvedSegment = hit?.segment ?? resolvedCard.flatMap { c in c.effectiveSegments.first(where: { $0.id == selectedSegmentID }) ?? c.effectiveSegments.first }

        if let card = resolvedCard {
            let menu = NSMenu(title: "Note")

            let copyContentItem = NSMenuItem(title: "Copy Note Content", action: #selector(copyNoteContentAction(_:)), keyEquivalent: "")
            copyContentItem.target = self
            copyContentItem.representedObject = card
            menu.addItem(copyContentItem)

            let copyTitleItem = NSMenuItem(title: "Copy Note Title", action: #selector(copyNoteTitleAction(_:)), keyEquivalent: "")
            copyTitleItem.target = self
            copyTitleItem.representedObject = card
            menu.addItem(copyTitleItem)

            menu.addItem(NSMenuItem.separator())

            let editItem = NSMenuItem(title: "Edit Note", action: #selector(editNoteAction(_:)), keyEquivalent: "")
            editItem.target = self
            editItem.representedObject = card
            menu.addItem(editItem)

            if card.effectiveSegments.count > 1, let seg = resolvedSegment {
                let deleteSegItem = NSMenuItem(title: "Delete Excerpt Segment", action: #selector(deleteSegmentAction(_:)), keyEquivalent: "")
                deleteSegItem.target = self
                deleteSegItem.representedObject = [card.id.uuidString, seg.id.uuidString]
                menu.addItem(deleteSegItem)
            }

            let deleteItem = NSMenuItem(title: "Delete Note", action: #selector(deleteNoteAction(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = card
            menu.addItem(deleteItem)

            return menu
        }

        return super.menu(for: event)
    }

    @objc private func copyNoteContentAction(_ sender: NSMenuItem) {
        guard let card = sender.representedObject as? NoteCard else { return }
        NSPasteboard.general.clearContents()
        let content = !card.highlightText.isEmpty ? card.highlightText : (!card.notesText.isEmpty ? card.notesText : card.title)
        NSPasteboard.general.setString(content, forType: .string)
    }

    @objc private func copyNoteTitleAction(_ sender: NSMenuItem) {
        guard let card = sender.representedObject as? NoteCard else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.title, forType: .string)
    }

    @objc private func editNoteAction(_ sender: NSMenuItem) {
        guard let card = sender.representedObject as? NoteCard else { return }
        editCardHandler?(card.id)
    }

    @objc private func deleteSegmentAction(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String],
              arr.count == 2,
              let cardID = UUID(uuidString: arr[0]),
              let segID = UUID(uuidString: arr[1]) else { return }
        deleteSegmentHandler?(cardID, segID)
    }

    @objc private func deleteNoteAction(_ sender: NSMenuItem) {
        guard let card = sender.representedObject as? NoteCard else { return }
        deleteCardHandler?(card.id)
    }

    static func clampToLine(on page: PDFPage, point: CGPoint) -> CGPoint {
        PDFHighlightResolver.clampToLine(on: page, point: point)
    }

    func makeMultiPageSelection(
        from startPage: PDFPage, at startPoint: CGPoint,
        to endPage: PDFPage, at endPoint: CGPoint
    ) -> PDFSelection? {
        guard let document else { return nil }
        let startIndex = document.index(for: startPage)
        let endIndex = document.index(for: endPage)
        guard startIndex != NSNotFound, endIndex != NSNotFound else { return nil }

        return PDFHighlightResolver.selection(
            in: document,
            startPage: startIndex,
            startPoint: startPoint,
            endPage: endIndex,
            endPoint: endPoint
        )
    }

    func installHandleAnnotations(for lineRects: [HighlightRect], accent: NSColor = .systemYellow) {
        installHandleAnnotations(for: nil, lineRects: lineRects, accent: accent)
    }

    func installHandleAnnotations(for card: NoteCard?, lineRects: [HighlightRect], accent: NSColor = .systemYellow) {
        guard let document else { return }

        var targetRects = lineRects.filter {
            $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
        }
        if targetRects.isEmpty, let card {
            targetRects = PDFHighlightResolver.lineRects(for: card, in: document).filter {
                $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
            }
        }
        targetRects = PDFHighlightResolver.expandBlockRectsIfNeeded(targetRects, in: document)
        let sorted = PDFHighlightResolver.sortInReadingOrder(targetRects)
        guard let first = sorted.first, let last = sorted.last,
              let firstPage = document.page(at: first.page),
              let lastPage = document.page(at: last.page) else { return }

        addHandle(
            to: firstPage,
            at: endpoint(for: first, start: true),
            lineHeight: CGFloat(first.height),
            accent: accent,
            isStart: true
        )
        addHandle(
            to: lastPage,
            at: endpoint(for: last, start: false),
            lineHeight: CGFloat(last.height),
            accent: accent,
            isStart: false
        )
    }

    public static func handleDimensions(for lineHeight: CGFloat, scale: CGFloat = 1.0) -> (stemWidth: CGFloat, stemHeight: CGFloat, knobRadius: CGFloat, knobSize: CGFloat) {
        let ratio: CGFloat = 1.2
        let rawHeight = lineHeight > 0 ? min(lineHeight, 28.0) : 14.0
        let stemHeight = max(12.0, rawHeight * ratio)
        let stemWidth: CGFloat = 2.0
        let knobRadius: CGFloat = 3.2
        return (stemWidth, stemHeight, knobRadius, knobRadius)
    }

    private func addHandle(to page: PDFPage, at point: CGPoint, lineHeight: CGFloat, accent: NSColor, isStart: Bool, isPending: Bool = false) {
        let cursorColor = MarginNoteTheme.nsCursorColor
        let dims = Self.handleDimensions(for: lineHeight, scale: self.scaleFactor)
        let stemWidth = dims.stemWidth
        let stemHeight = dims.stemHeight
        let knobRadius = dims.knobRadius

        ensureSelectionCursorOverlay()
        selectionCursorOverlay?.setHandle(
            page: page,
            point: point,
            lineHeight: lineHeight,
            color: cursorColor,
            isStart: isStart
        )

        let pageBounds = page.bounds(for: .cropBox)
        let pad: CGFloat = 1.0

        // Stem & knob horizontal position: centerline clamped within cropBox
        let clampedX = max(pageBounds.minX + knobRadius + pad, min(point.x, pageBounds.maxX - knobRadius - pad))

        let handleBounds: CGRect
        if isStart {
            let clampedY = max(pageBounds.minY + stemHeight / 2 + pad, min(point.y, pageBounds.maxY - stemHeight / 2 - knobRadius - pad))
            handleBounds = CGRect(
                x: clampedX - knobRadius,
                y: clampedY - stemHeight / 2,
                width: knobRadius * 2,
                height: stemHeight + knobRadius
            )
        } else {
            let clampedY = max(pageBounds.minY + stemHeight / 2 + knobRadius + pad, min(point.y, pageBounds.maxY - stemHeight / 2 - pad))
            handleBounds = CGRect(
                x: clampedX - knobRadius,
                y: clampedY - stemHeight / 2 - knobRadius,
                width: knobRadius * 2,
                height: stemHeight + knobRadius
            )
        }

        let prefix = isPending ? (isStart ? "MarginGraph-pending-handle-start" : "MarginGraph-pending-handle-end")
                               : (isStart ? "MarginGraph-handle-start" : "MarginGraph-handle-end")

        for old in page.annotations where old.contents == prefix {
            page.removeAnnotation(old)
        }

        let handle = CursorHandleAnnotation(bounds: handleBounds, forType: .square, withProperties: nil)
        handle.isStart = isStart
        handle.stemWidth = stemWidth
        handle.stemHeight = stemHeight
        handle.knobRadius = knobRadius
        handle.fillColor = cursorColor
        handle.contents = prefix
        // Adding at the end of page.annotations guarantees it is drawn on top of all page text and highlights
        page.addAnnotation(handle)
    }

    public func bringHandlesToFront(on page: PDFPage) {
        let handles = page.annotations.filter {
            $0.contents?.hasPrefix("MarginGraph-handle") == true ||
            $0.contents?.hasPrefix("MarginGraph-pending-handle") == true
        }
        for handle in handles {
            page.removeAnnotation(handle)
            page.addAnnotation(handle)
        }
    }

    private func handleHitTest(
        point: CGPoint,
        handlePage: PDFPage,
        currentPage: PDFPage,
        handlePoint: CGPoint,
        lineHeight: CGFloat,
        isStart: Bool
    ) -> (isHit: Bool, distance: CGFloat) {
        guard handlePage === currentPage else { return (false, .infinity) }
        let dims = Self.handleDimensions(for: lineHeight, scale: self.scaleFactor)
        let stemHeight = dims.stemHeight
        let knobY = isStart
            ? (handlePoint.y + stemHeight / 2)
            : (handlePoint.y - stemHeight / 2)
        let knobCenter = CGPoint(x: handlePoint.x, y: knobY)

        let currentScale = max(0.5, self.scaleFactor > 0.05 ? self.scaleFactor : 1.0)
        let distToKnob = hypot(point.x - knobCenter.x, point.y - knobCenter.y) * currentScale
        let dx = abs(point.x - handlePoint.x) * currentScale
        let dy = max(0, abs(point.y - handlePoint.y) - stemHeight / 2) * currentScale
        let distToBar = hypot(dx, dy)

        let minDistance = min(distToKnob, distToBar)
        let isHit = (distToKnob <= 22.0) || (dx <= 16.0 && abs(point.y - handlePoint.y) * currentScale <= (stemHeight * currentScale / 2 + 14.0))
        return (isHit, minDistance)
    }

    private func beginHandleDragIfNeeded(page: PDFPage, point: CGPoint) -> Bool {
        if let pending = pendingSelection {
            let startHeight = CGFloat(pending.rects.first?.height ?? 16)
            let endHeight = CGFloat(pending.rects.last?.height ?? 16)

            let startTest = handleHitTest(
                point: point,
                handlePage: pending.startPage,
                currentPage: page,
                handlePoint: pending.startPoint,
                lineHeight: startHeight,
                isStart: true
            )
            let endTest = handleHitTest(
                point: point,
                handlePage: pending.endPage,
                currentPage: page,
                handlePoint: pending.endPoint,
                lineHeight: endHeight,
                isStart: false
            )

            if startTest.isHit || endTest.isHit {
                let pickStart = (startTest.isHit && endTest.isHit) ? (startTest.distance <= endTest.distance) : startTest.isHit
                let activePoint = pickStart ? pending.startPoint : pending.endPoint
                let grabOffset = CGPoint(x: point.x - activePoint.x, y: point.y - activePoint.y)
                handleDrag = HandleDrag(
                    cardID: nil,
                    segmentID: nil,
                    movingStart: pickStart,
                    startPage: pending.startPage,
                    startPoint: pending.startPoint,
                    endPage: pending.endPage,
                    endPoint: pending.endPoint,
                    grabOffset: grabOffset,
                    latestSelection: pending.selection
                )
                return true
            }
        }

        guard let selectedCardID,
              let card = cards.first(where: { $0.id == selectedCardID }),
              let document else { return false }
        if let bmd5 = card.bookMD5, !bmd5.isEmpty {
            let b1 = bmd5.lowercased()
            let b2 = bookMD5.lowercased()
            let matchesBook = b1 == b2 || b1.hasPrefix(b2) || b2.hasPrefix(b1)
            guard matchesBook else { return false }
        }
        let segment = card.effectiveSegments.first(where: { $0.id == selectedSegmentID }) ?? card.effectiveSegments.first
        let rawRects = (segment?.rects.isEmpty == false) ? segment!.rects : PDFHighlightResolver.lineRects(for: card, in: document)
        let expanded = PDFHighlightResolver.expandBlockRectsIfNeeded(rawRects.filter { $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0 }, in: document)
        let sortedRects = PDFHighlightResolver.sortInReadingOrder(expanded)
        guard let first = sortedRects.first, let last = sortedRects.last,
              let firstPage = document.page(at: first.page),
              let lastPage = document.page(at: last.page) else { return false }

        let startPoint = endpoint(for: first, start: true)
        let endPoint = endpoint(for: last, start: false)
        let startHeight = CGFloat(first.height)
        let endHeight = CGFloat(last.height)

        let startTest = handleHitTest(
            point: point,
            handlePage: firstPage,
            currentPage: page,
            handlePoint: startPoint,
            lineHeight: startHeight,
            isStart: true
        )
        let endTest = handleHitTest(
            point: point,
            handlePage: lastPage,
            currentPage: page,
            handlePoint: endPoint,
            lineHeight: endHeight,
            isStart: false
        )

        if startTest.isHit || endTest.isHit {
            let pickStart = (startTest.isHit && endTest.isHit) ? (startTest.distance <= endTest.distance) : startTest.isHit
            let activePoint = pickStart ? startPoint : endPoint
            let grabOffset = CGPoint(x: point.x - activePoint.x, y: point.y - activePoint.y)
            handleDrag = HandleDrag(
                cardID: card.id,
                segmentID: segment?.id,
                movingStart: pickStart,
                startPage: firstPage,
                startPoint: startPoint,
                endPage: lastPage,
                endPoint: endPoint,
                grabOffset: grabOffset,
                latestSelection: nil
            )
            return true
        }
        return false
    }

    private func cardHitSegment(on page: PDFPage, at point: CGPoint) -> (card: NoteCard, segment: ExcerptSegment)? {
        guard let document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        var matches: [(card: NoteCard, segment: ExcerptSegment)] = []
        for card in cards {
            if let bmd5 = card.bookMD5, !bmd5.isEmpty {
                let b1 = bmd5.lowercased()
                let b2 = bookMD5.lowercased()
                let matchesBook = b1 == b2 || b1.hasPrefix(b2) || b2.hasPrefix(b1)
                guard matchesBook else { continue }
            }
            for segment in card.effectiveSegments {
                let rects = (segment.rects.isEmpty == false) ? segment.rects : PDFHighlightResolver.lineRects(for: card, in: document)
                let hit = rects.contains { line in
                    guard line.page == pageIndex else { return false }
                    let rect = CGRect(x: line.x, y: line.y, width: line.width, height: line.height)
                        .insetBy(dx: -4, dy: -4)
                    return rect.contains(point)
                }
                if hit {
                    matches.append((card, segment))
                }
            }
        }
        guard !matches.isEmpty else { return nil }
        if let selectedCardID, let selectedSegmentID,
           let curIdx = matches.firstIndex(where: { $0.card.id == selectedCardID && $0.segment.id == selectedSegmentID }) {
            return matches[(curIdx + 1) % matches.count]
        }
        return matches.first
    }

    private func cardHit(on page: PDFPage, at point: CGPoint) -> NoteCard? {
        cardHitSegment(on: page, at: point)?.card
    }

    private func emphasisHit(in card: NoteCard, on page: PDFPage, at point: CGPoint) -> EmphasisHitInfo? {
        guard let document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        // 1. Direct hit check on stored card.emphasisRects
        if !card.emphasisRects.isEmpty {
            for rect in card.emphasisRects where rect.page == pageIndex {
                let rBox = CGRect(x: rect.x, y: rect.y - 4, width: rect.width, height: rect.height + 8).insetBy(dx: -4, dy: -3)
                if rBox.contains(point) {
                    let matchedPhrase = card.emphasisList.first(where: { phrase in
                        let pRects = PDFHighlightResolver.lineRects(forPhrase: phrase, in: card, in: document)
                        return pRects.contains(where: { $0.page == rect.page && abs($0.y - rect.y) < 2.0 && abs($0.x - rect.x) < 4.0 })
                    }) ?? card.emphasisList.first ?? ""
                    let phraseRects = card.emphasisRects.filter { e in
                        card.emphasisRects.count == 1 || abs(e.y - rect.y) < 60
                    }
                    return EmphasisHitInfo(cardID: card.id, text: matchedPhrase, rects: phraseRects.isEmpty ? [rect] : phraseRects, hitLine: rect)
                }
            }
        }

        // 2. Fallback resolution via lineRects(forPhrase:)
        for phrase in card.emphasisList where !phrase.isEmpty {
            let phraseRects = PDFHighlightResolver.lineRects(forPhrase: phrase, in: card, in: document)
            if let hitRect = phraseRects.first(where: { r in
                guard r.page == pageIndex else { return false }
                let rBox = CGRect(x: r.x, y: r.y - 4, width: r.width, height: r.height + 8).insetBy(dx: -4, dy: -2)
                return rBox.contains(point)
            }) {
                return EmphasisHitInfo(cardID: card.id, text: phrase, rects: phraseRects, hitLine: hitRect)
            }
        }
        return nil
    }

    private func renderLiveHighlight(
        _ selection: PDFSelection,
        cardID: UUID,
        startPoint: CGPoint,
        endPoint: CGPoint,
        startHeight: CGFloat,
        endHeight: CGFloat,
        startPage: PDFPage,
        endPage: PDFPage
    ) {
        clearLiveHighlight()
        clearHandles()
        guard let document else { return }
        let accent: NSColor
        if let card = cards.first(where: { $0.id == cardID }) {
            accent = NSColor(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
        } else {
            accent = .systemYellow
        }
        for line in PDFHighlightResolver.lineRects(from: selection, document: document) {
            guard let page = document.page(at: line.page) else { continue }
            let rect = CGRect(x: line.x, y: line.y, width: line.width, height: line.height)
            let annotation = PDFHighlightResolver.createHighlightAnnotation(
                bounds: rect,
                color: accent.withAlphaComponent(0.65),
                contents: "MarginGraph-drag-highlight"
            )
            page.addAnnotation(annotation)
        }
        addHandle(
            to: startPage,
            at: startPoint,
            lineHeight: startHeight,
            accent: accent,
            isStart: true
        )
        addHandle(
            to: endPage,
            at: endPoint,
            lineHeight: endHeight,
            accent: accent,
            isStart: false
        )
        setNeedsDisplay(bounds)
    }

    private func clearLiveHighlight() {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents == "MarginGraph-drag-highlight" {
                page.removeAnnotation(annotation)
            }
        }
    }

    func clearHandles() {
        selectionCursorOverlay?.clear()
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.contents?.hasPrefix("MarginGraph-handle") == true
                || annotation.contents?.hasPrefix("MarginGraph-pending-handle") == true {
                page.removeAnnotation(annotation)
            }
        }
    }

    private func endpoint(for rect: HighlightRect, start: Bool) -> CGPoint {
        let effectiveHeight = min(rect.height, 22.0)
        let y: CGFloat
        if rect.height > 24.0 {
            // For block/box rects that couldn't be broken into lines,
            // start is at the top of the box, end is at the bottom
            y = start ? CGFloat(rect.y + rect.height) - CGFloat(effectiveHeight / 2)
                      : CGFloat(rect.y) + CGFloat(effectiveHeight / 2)
        } else {
            y = CGFloat(rect.y + rect.height / 2)
        }
        return CGPoint(
            x: start ? CGFloat(rect.x) : CGFloat(rect.x + rect.width),
            y: y
        )
    }

    private func pageIndex(of page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private func installDragLayer() {
        wantsLayer = true
        let dragLayer = CAShapeLayer()
        dragLayer.fillColor = marqueeColor.withAlphaComponent(0.15).cgColor
        dragLayer.strokeColor = marqueeColor.cgColor
        dragLayer.lineWidth = 2
        layer?.addSublayer(dragLayer)
        self.dragLayer = dragLayer
    }

    private func cleanupDragLayer() {
        dragLayer?.removeFromSuperlayer()
        dragLayer = nil
    }
}
