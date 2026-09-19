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
    public var pageIndex: Int
    public var bounds: CGRect

    public init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.bounds = bounds
    }
}

public enum PDFHighlightResolver {
    public static func deduplicate(_ rects: [HighlightRect]) -> [HighlightRect] {
        var seen = Set<String>()
        var result: [HighlightRect] = []
        for r in rects {
            let key = "\(r.page)_\(Int((r.y / 2).rounded()))_\(Int((r.x / 4).rounded()))_\(Int((r.width / 4).rounded()))"
            if seen.insert(key).inserted {
                result.append(r)
            }
        }
        return result
    }

    public static func normalizeExcerptParagraphs(_ rawText: String) -> String {
        let lines = rawText.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var currentParagraph: [String] = []

        func flush() {
            if !currentParagraph.isEmpty {
                paragraphs.append(currentParagraph.joined(separator: " "))
                currentParagraph.removeAll()
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }

            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
            let isNumbered = line.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) != nil

            if isBullet || isNumbered {
                flush()
                currentParagraph.append(line)
            } else if let last = currentParagraph.last, last.hasSuffix("-") {
                currentParagraph[currentParagraph.count - 1] = String(last.dropLast()) + line
            } else {
                currentParagraph.append(line)
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    public static func lineRects(for card: NoteCard, in document: PDFDocument) -> [HighlightRect] {
        let stored = card.highlightRects.filter {
            $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
        }
        if !stored.isEmpty { return deduplicate(stored) }

        if let pageIndex = card.startPage,
           pageIndex >= 0,
           pageIndex < document.pageCount,
           let page = document.page(at: pageIndex),
           let start = card.startPos,
           let end = card.endPos {
            let bounds = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if bounds.width > 0, bounds.height > 0 {
                if let selection = page.selection(for: bounds) {
                    let resolved = lineRects(from: selection, document: document)
                    if !resolved.isEmpty { return deduplicate(resolved) }
                }
                return [HighlightRect(
                    page: pageIndex,
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height
                )]
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
            if !resolved.isEmpty { return deduplicate(resolved) }
        }

        return []
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
}

public struct PDFReaderView: NSViewRepresentable {
    public var manager: PDFDocumentManager
    public var displayMode: PDFReaderDisplayMode
    public var tool: PDFSelectionTool
    public var highlightColor: NSColor
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var jumpTarget: PDFJumpTarget?
    @Binding public var currentPageIndex: Int
    public var onExcerpt: ((PDFExcerpt) -> Void)?
    public var onSelectCard: ((UUID) -> Void)?
    public var onUpdateCardHighlight: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)?

    public init(
        manager: PDFDocumentManager,
        displayMode: PDFReaderDisplayMode = .continuous,
        tool: PDFSelectionTool = .textSelection,
        highlightColor: NSColor = .systemYellow,
        cards: [NoteCard] = [],
        selectedCardID: UUID? = nil,
        jumpTarget: PDFJumpTarget? = nil,
        currentPageIndex: Binding<Int> = .constant(0),
        onExcerpt: ((PDFExcerpt) -> Void)? = nil,
        onSelectCard: ((UUID) -> Void)? = nil,
        onUpdateCardHighlight: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)? = nil
    ) {
        self.manager = manager
        self.displayMode = displayMode
        self.tool = tool
        self.highlightColor = highlightColor
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.jumpTarget = jumpTarget
        self._currentPageIndex = currentPageIndex
        self.onExcerpt = onExcerpt
        self.onSelectCard = onSelectCard
        self.onUpdateCardHighlight = onUpdateCardHighlight
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.document = manager.document
        configure(view)
        context.coordinator.setupObserver(for: view)
        return view
    }

    public func updateNSView(_ view: InteractivePDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== manager.document {
            view.document = manager.document
            context.coordinator.setupObserver(for: view)
        }

        view.displayMode = displayMode == .continuous ? .singlePageContinuous : .singlePage
        view.pageBreakMargins = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.autoScales = true
        configure(view)
        let cardsChanged = context.coordinator.lastCards != cards ||
                           context.coordinator.lastDocument !== view.document
        let selectionChanged = context.coordinator.lastSelectedCardID != selectedCardID

        if cardsChanged {
            context.coordinator.lastCards = cards
            context.coordinator.lastDocument = view.document
            context.coordinator.lastSelectedCardID = selectedCardID
            applyBaseHighlights(to: view)
            applyActiveSelection(to: view)
        } else if selectionChanged {
            context.coordinator.lastSelectedCardID = selectedCardID
            applyActiveSelection(to: view)
        }

        if context.coordinator.lastPageIndex != currentPageIndex {
            context.coordinator.lastPageIndex = currentPageIndex
            if let page = view.document?.page(at: currentPageIndex) {
                view.go(to: page)
            }
        }

        if context.coordinator.lastJump != jumpTarget, let jumpTarget {
            context.coordinator.lastJump = jumpTarget
            jump(view, to: jumpTarget)
        }
    }

    private func configure(_ view: InteractivePDFView) {
        view.selectionTool = tool
        view.marqueeColor = highlightColor
        view.excerptHandler = { excerpt in
            onExcerpt?(excerpt)
        }
        view.cards = cards
        view.selectedCardID = selectedCardID
        view.selectCardHandler = onSelectCard
        view.updateCardHighlightHandler = onUpdateCardHighlight
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
            for annotation in page.annotations where annotation.contents == "MarginGraph-card-highlight" {
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
                let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                annotation.color = accent.withAlphaComponent(0.65)
                annotation.contents = "MarginGraph-card-highlight"
                page.addAnnotation(annotation)
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
                || annotation.contents == "MarginGraph-handle-start"
                || annotation.contents == "MarginGraph-handle-end"
                || annotation.contents == "MarginGraph-handle-knob-start"
                || annotation.contents == "MarginGraph-handle-knob-end"
                || annotation.contents == "MarginGraph-drag-highlight"
                || annotation.contents == "MarginGraph-jump" {
                page.removeAnnotation(annotation)
            }
        }

        if let selected = cards.first(where: { isActive(card: $0) }) {
            let lineRects = PDFHighlightResolver.lineRects(for: selected, in: document)
            let accent = NSColor(MarginNoteTheme.cardColors(for: selected.colorIndex).accent)
            let cardPageRects: [Int: [CGRect]] = Dictionary(grouping: lineRects, by: \.page)
                .mapValues { $0.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } }
            for (pageIdx, rects) in cardPageRects {
                guard let page = document.page(at: pageIdx), let first = rects.first else { continue }
                let union = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -3, dy: -3)
                let active = PDFAnnotation(bounds: union, forType: .square, withProperties: nil)
                active.color = accent.withAlphaComponent(0.95)
                let border = PDFBorder()
                border.lineWidth = 2.0
                border.style = .solid
                active.border = border
                active.contents = "MarginGraph-active-highlight"
                page.addAnnotation(active)
            }
            view.installHandleAnnotations(for: selected, lineRects: lineRects, accent: accent)
        }
        view.setNeedsDisplay(view.bounds)
    }

    private func isActive(card: NoteCard) -> Bool {
        if let selectedCardID {
            return card.id == selectedCardID
        }
        guard let jumpTarget, card.startPage == jumpTarget.pageIndex else { return false }
        guard let start = card.startPos, let end = card.endPos else {
            return !card.highlightText.isEmpty
        }
        let cardBounds = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return cardBounds.intersects(jumpTarget.bounds) || jumpTarget.bounds.width <= 2
    }

    private func jump(_ view: PDFView, to target: PDFJumpTarget) {
        guard let page = view.document?.page(at: target.pageIndex) else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let destinationPoint: CGPoint
        if target.bounds.width > 2 && target.bounds.height > 2 {
            destinationPoint = CGPoint(x: max(0, target.bounds.minX - 30), y: min(pageBounds.maxY, target.bounds.maxY + 80))
        } else {
            destinationPoint = CGPoint(x: pageBounds.midX, y: pageBounds.maxY - 100)
        }
        let destination = PDFDestination(page: page, at: destinationPoint)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            view.go(to: destination)
        }
    }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: PDFReaderView
        var lastJump: PDFJumpTarget?
        var lastPageIndex: Int = 0
        var lastCards: [NoteCard] = []
        var lastSelectedCardID: UUID?
        weak var lastDocument: PDFDocument?
        var observer: NSObjectProtocol?

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
                    if idx != NSNotFound && self.parent.currentPageIndex != idx {
                        self.lastPageIndex = idx
                        self.parent.currentPageIndex = idx
                    }
                }
            }
        }
    }

    public static func dismantleNSView(_ nsView: InteractivePDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }
    }
}

public final class InteractivePDFView: PDFView {
    var selectionTool: PDFSelectionTool = .textSelection
    var marqueeColor: NSColor = .systemYellow
    var excerptHandler: ((PDFExcerpt) -> Void)?
    var excerptFactory: ((Int, CGRect, String) -> PDFExcerpt)?
    var cards: [NoteCard] = []
    var selectedCardID: UUID?
    var selectCardHandler: ((UUID) -> Void)?
    var updateCardHighlightHandler: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)?

    private var dragStart: (page: PDFPage, point: CGPoint)?
    private var dragLayer: CAShapeLayer?

    private struct HandleDrag {
        var cardID: UUID
        var movingStart: Bool
        var startPage: PDFPage
        var startPoint: CGPoint
        var endPage: PDFPage
        var endPoint: CGPoint
        var latestSelection: PDFSelection?
    }
    private var handleDrag: HandleDrag?

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        Swift.print("[InteractivePDFView] mouseDown viewPoint=\(viewPoint) pagePoint=\(pagePoint)")

        if selectionTool == .textSelection,
           beginHandleDragIfNeeded(page: page, point: pagePoint) {
            Swift.print("[InteractivePDFView] Began handle drag at \(pagePoint)")
            return
        }

        if selectionTool == .textSelection,
           let card = cardHit(on: page, at: pagePoint) {
            Swift.print("[InteractivePDFView] Hit card: \(card.id) - \(card.title)")
            selectedCardID = card.id
            selectCardHandler?(card.id)
            return
        }

        guard selectionTool == .rectMarquee else {
            super.mouseDown(with: event)
            return
        }

        dragStart = (page, pagePoint)
        installDragLayer()
    }

    public override func mouseDragged(with event: NSEvent) {
        if var handleDrag {
            let currentView = convert(event.locationInWindow, from: nil)
            guard let currentPage = page(for: currentView, nearest: true) else { return }
            let currentPoint = convert(currentView, to: currentPage)
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
            ) {
                handleDrag.latestSelection = selection
                renderLiveHighlight(selection, cardID: handleDrag.cardID)
            }
            self.handleDrag = handleDrag
            Swift.print("[InteractivePDFView] handleDrag mouseDragged movingStart=\(handleDrag.movingStart) curPt=\(currentPoint) selChars=\(handleDrag.latestSelection?.string?.count ?? 0)")
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
        if let handleDrag {
            defer {
                clearLiveHighlight()
                self.handleDrag = nil
            }
            let currentView = convert(event.locationInWindow, from: nil)
            guard let currentPage = page(for: currentView, nearest: true) else { return }
            let currentPoint = convert(currentView, to: currentPage)
            let startPage = handleDrag.movingStart ? currentPage : handleDrag.startPage
            let startPoint = handleDrag.movingStart ? currentPoint : handleDrag.startPoint
            let endPage = handleDrag.movingStart ? handleDrag.endPage : currentPage
            let endPoint = handleDrag.movingStart ? handleDrag.endPoint : currentPoint
            Swift.print("[InteractivePDFView] handleDrag mouseUp start=\(startPoint) end=\(endPoint)")
            guard let document,
                  let selection = makeMultiPageSelection(from: startPage, at: startPoint, to: endPage, at: endPoint) ?? handleDrag.latestSelection
            else {
                Swift.print("[InteractivePDFView] handleDrag mouseUp failed to get selection")
                return
            }
            let rects = PDFHighlightResolver.lineRects(from: selection, document: document)
            guard !rects.isEmpty else {
                Swift.print("[InteractivePDFView] handleDrag mouseUp rects was empty")
                return
            }

            let canonicalStart = endpoint(for: rects.first!, start: true)
            let canonicalEnd = endpoint(for: rects.last!, start: false)
            let rawString = selection.string ?? ""
            let normalizedText = PDFHighlightResolver.normalizeExcerptParagraphs(rawString)
            Swift.print("[InteractivePDFView] handleDrag calling handler cardID=\(handleDrag.cardID) textLength=\(normalizedText.count) rects=\(rects.count)")
            updateCardHighlightHandler?(
                handleDrag.cardID,
                normalizedText,
                rects,
                canonicalStart,
                canonicalEnd
            )
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

        super.mouseUp(with: event)

        guard selectionTool == .textSelection,
              let selection = currentSelection,
              let page = selection.pages.first,
              let document,
              let pageIndex = pageIndex(of: page, in: document),
              let factory = excerptFactory else { return }

        let bounds = selection.bounds(for: page)
        guard !bounds.isEmpty else { return }
        let text = PDFHighlightResolver.normalizeExcerptParagraphs(selection.string ?? "")
        excerptHandler?(factory(pageIndex, bounds, text))
    }

    static func clampToLine(on page: PDFPage, point: CGPoint) -> CGPoint {
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

    func makeMultiPageSelection(
        from startPage: PDFPage, at startPoint: CGPoint,
        to endPage: PDFPage, at endPoint: CGPoint
    ) -> PDFSelection? {
        guard let document else { return nil }
        let startIndex = document.index(for: startPage)
        let endIndex = document.index(for: endPage)
        guard startIndex != NSNotFound, endIndex != NSNotFound else { return nil }

        if startIndex == endIndex {
            let p = startPage
            let clampedStart = Self.clampToLine(on: p, point: startPoint)
            let clampedEnd = Self.clampToLine(on: p, point: endPoint)

            let isForward: Bool
            if abs(clampedStart.y - clampedEnd.y) > 6 {
                isForward = clampedStart.y > clampedEnd.y
            } else {
                isForward = clampedStart.x <= clampedEnd.x
            }

            let pA = isForward ? clampedStart : clampedEnd
            let pB = isForward ? clampedEnd : clampedStart
            return p.selection(from: pA, to: pB)
        }

        let forward = startIndex < endIndex
        let pStart = forward ? startPage : endPage
        let ptStartRaw = forward ? startPoint : endPoint
        let pEnd = forward ? endPage : startPage
        let ptEndRaw = forward ? endPoint : startPoint
        let idxStart = forward ? startIndex : endIndex
        let idxEnd = forward ? endIndex : startIndex

        let clampedStart = Self.clampToLine(on: pStart, point: ptStartRaw)
        let clampedEnd = Self.clampToLine(on: pEnd, point: ptEndRaw)

        var endOfFirstPage = CGPoint(x: pStart.bounds(for: .cropBox).maxX - 5, y: pStart.bounds(for: .cropBox).minY + 5)
        if let fullFirst = pStart.selection(for: pStart.bounds(for: .cropBox)),
           let lastLine = fullFirst.selectionsByLine().last {
            let lb = lastLine.bounds(for: pStart)
            endOfFirstPage = CGPoint(x: lb.maxX - 2, y: lb.midY)
        }

        var combined: PDFSelection?
        if let selFirst = pStart.selection(from: clampedStart, to: endOfFirstPage) {
            combined = (selFirst.copy() as? PDFSelection)
        }

        if idxEnd > idxStart + 1 {
            for midIdx in (idxStart + 1)..<idxEnd {
                guard let midPage = document.page(at: midIdx) else { continue }
                if let fullSel = midPage.selection(for: midPage.bounds(for: .cropBox)) {
                    if let c = combined {
                        c.add(fullSel)
                    } else {
                        combined = (fullSel.copy() as? PDFSelection)
                    }
                }
            }
        }

        var startOfLastPage = CGPoint(x: pEnd.bounds(for: .cropBox).minX + 5, y: pEnd.bounds(for: .cropBox).maxY - 5)
        if let fullLast = pEnd.selection(for: pEnd.bounds(for: .cropBox)),
           let firstLine = fullLast.selectionsByLine().first {
            let fb = firstLine.bounds(for: pEnd)
            startOfLastPage = CGPoint(x: fb.minX + 2, y: fb.midY)
        }

        if let selLast = pEnd.selection(from: startOfLastPage, to: clampedEnd) {
            if let c = combined {
                c.add(selLast)
            } else {
                combined = (selLast.copy() as? PDFSelection)
            }
        }

        return combined
    }

    func installHandleAnnotations(for card: NoteCard, lineRects: [HighlightRect], accent: NSColor = .systemYellow) {
        guard let document, let first = lineRects.first, let last = lineRects.last,
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

    private func addHandle(to page: PDFPage, at point: CGPoint, lineHeight: CGFloat, accent: NSColor, isStart: Bool) {
        let cursorColor = MarginNoteTheme.nsCursorColor
        let height = max(16, lineHeight + 8)
        let barBounds = CGRect(x: point.x - 1.5, y: point.y - height / 2, width: 3, height: height)
        let bar = PDFAnnotation(bounds: barBounds, forType: .square, withProperties: nil)
        bar.color = .clear
        bar.interiorColor = cursorColor.withAlphaComponent(0.95)
        let border = PDFBorder()
        border.lineWidth = 0
        bar.border = border
        bar.contents = isStart ? "MarginGraph-handle-start" : "MarginGraph-handle-end"
        page.addAnnotation(bar)

        let knobSize: CGFloat = 8
        let knobY = isStart ? (point.y + height / 2) : (point.y - height / 2)
        let knobBounds = CGRect(x: point.x - knobSize / 2, y: knobY - knobSize / 2, width: knobSize, height: knobSize)
        let knob = PDFAnnotation(bounds: knobBounds, forType: .circle, withProperties: nil)
        knob.color = cursorColor
        knob.interiorColor = cursorColor
        knob.contents = isStart ? "MarginGraph-handle-knob-start" : "MarginGraph-handle-knob-end"
        page.addAnnotation(knob)
    }

    private func beginHandleDragIfNeeded(page: PDFPage, point: CGPoint) -> Bool {
        guard let selectedCardID,
              let card = cards.first(where: { $0.id == selectedCardID }),
              let document else { return false }
        let rects = PDFHighlightResolver.lineRects(for: card, in: document)
        guard let first = rects.first, let last = rects.last,
              let firstPage = document.page(at: first.page),
              let lastPage = document.page(at: last.page) else { return false }

        let startPoint = endpoint(for: first, start: true)
        let endPoint = endpoint(for: last, start: false)
        let startHeight = max(16, CGFloat(first.height) + 8)
        let endHeight = max(16, CGFloat(last.height) + 8)

        let isNearStart = (firstPage === page) && abs(point.x - startPoint.x) <= 26 && abs(point.y - startPoint.y) <= (startHeight / 2 + 16)
        let isNearEnd = (lastPage === page) && abs(point.x - endPoint.x) <= 26 && abs(point.y - endPoint.y) <= (endHeight / 2 + 16)

        if isNearStart {
            handleDrag = HandleDrag(
                cardID: card.id,
                movingStart: true,
                startPage: firstPage,
                startPoint: startPoint,
                endPage: lastPage,
                endPoint: endPoint,
                latestSelection: nil
            )
            return true
        }
        if isNearEnd {
            handleDrag = HandleDrag(
                cardID: card.id,
                movingStart: false,
                startPage: firstPage,
                startPoint: startPoint,
                endPage: lastPage,
                endPoint: endPoint,
                latestSelection: nil
            )
            return true
        }
        return false
    }

    private func cardHit(on page: PDFPage, at point: CGPoint) -> NoteCard? {
        guard let document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        let matching = cards.filter { card in
            PDFHighlightResolver.lineRects(for: card, in: document).contains { line in
                guard line.page == pageIndex else { return false }
                let rect = CGRect(x: line.x, y: line.y, width: line.width, height: line.height)
                    .insetBy(dx: -4, dy: -4)
                return rect.contains(point)
            }
        }
        guard !matching.isEmpty else { return nil }
        if let selectedCardID, let curIdx = matching.firstIndex(where: { $0.id == selectedCardID }) {
            return matching[(curIdx + 1) % matching.count]
        }
        return matching.first
    }

    private func renderLiveHighlight(_ selection: PDFSelection, cardID: UUID) {
        clearLiveHighlight()
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
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = accent.withAlphaComponent(0.65)
            annotation.contents = "MarginGraph-drag-highlight"
            page.addAnnotation(annotation)
        }
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

    private func endpoint(for rect: HighlightRect, start: Bool) -> CGPoint {
        CGPoint(
            x: start ? rect.x : rect.x + rect.width,
            y: rect.y + rect.height / 2
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
