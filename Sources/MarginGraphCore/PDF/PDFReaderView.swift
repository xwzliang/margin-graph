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
    public var onExcerpt: ((PDFExcerpt) -> Void)?
    public var onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)?
    public var onEditCard: ((UUID) -> Void)?
    public var onChangeCardColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onSelectCard: ((UUID?) -> Void)?
    public var onUpdateCardHighlight: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)?
    public var onAsTitle: ((UUID, String) -> Void)?
    public var onAddToComments: ((UUID, String) -> Void)?
    public var onMerge: ((UUID, String, [HighlightRect]) -> Void)?
    public var onEmphasize: ((UUID, String) -> Void)?

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
        onExcerpt: ((PDFExcerpt) -> Void)? = nil,
        onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)? = nil,
        onEditCard: ((UUID) -> Void)? = nil,
        onChangeCardColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onSelectCard: ((UUID?) -> Void)? = nil,
        onUpdateCardHighlight: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)? = nil,
        onAsTitle: ((UUID, String) -> Void)? = nil,
        onAddToComments: ((UUID, String) -> Void)? = nil,
        onMerge: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onEmphasize: ((UUID, String) -> Void)? = nil
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
        self.onExcerpt = onExcerpt
        self.onCreateCardWithColor = onCreateCardWithColor
        self.onEditCard = onEditCard
        self.onChangeCardColor = onChangeCardColor
        self.onDeleteCard = onDeleteCard
        self.onSelectCard = onSelectCard
        self.onUpdateCardHighlight = onUpdateCardHighlight
        self.onAsTitle = onAsTitle
        self.onAddToComments = onAddToComments
        self.onMerge = onMerge
        self.onEmphasize = onEmphasize
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 0.5, left: 0, bottom: 0.5, right: 0)
        view.backgroundColor = NSColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1.0)
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
        view.pageBreakMargins = NSEdgeInsets(top: 0.5, left: 0, bottom: 0.5, right: 0)
        view.backgroundColor = NSColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1.0)
        view.autoScales = true
        configure(view)
        let cardsChanged = context.coordinator.lastCards != cards ||
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
        view.selectCardHandler = onSelectCard
        view.updateCardHighlightHandler = onUpdateCardHighlight
        view.asTitleHandler = onAsTitle
        view.addToCommentsHandler = onAddToComments
        view.mergeHandler = onMerge
        view.emphasizeHandler = onEmphasize
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
            for phrase in card.emphasisList {
                let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let selections = document.findString(clean, withOptions: [.caseInsensitive])
                for sel in selections {
                    guard let selPage = sel.pages.first else { continue }
                    let pageIdx = document.index(for: selPage)
                    guard lineRects.contains(where: { $0.page == pageIdx }) else { continue }
                    for line in PDFHighlightResolver.lineRects(from: sel, document: document) {
                        guard let page = document.page(at: line.page) else { continue }
                        let lineBounds = CGRect(x: line.x, y: line.y - 2.0, width: line.width, height: 4.0)
                        let annot = PDFAnnotation(bounds: lineBounds, forType: .line, withProperties: nil)
                        annot.startPoint = CGPoint(x: line.x, y: line.y + 0.5)
                        annot.endPoint = CGPoint(x: line.x + line.width, y: line.y + 0.5)
                        let border = PDFBorder()
                        border.lineWidth = 2.5
                        border.style = .dashed
                        border.dashPattern = [2, 2]
                        annot.border = border
                        annot.color = MarginNoteTheme.nsCursorColor
                        annot.contents = "MarginGraph-card-emphasis"
                        page.addAnnotation(annot)
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
                || annotation.contents == "MarginGraph-handle-start"
                || annotation.contents == "MarginGraph-handle-end"
                || annotation.contents == "MarginGraph-handle-knob-start"
                || annotation.contents == "MarginGraph-handle-knob-end"
                || annotation.contents == "MarginGraph-drag-highlight"
                || annotation.contents == "MarginGraph-target-bracket"
                || annotation.contents == "MarginGraph-jump" {
                page.removeAnnotation(annotation)
            }
        }

        if let selected = cards.first(where: { isActive(card: $0) }) {
            let lineRects = PDFHighlightResolver.lineRects(for: selected, in: document)
            let accent = NSColor(MarginNoteTheme.cardColors(for: selected.colorIndex).accent)
            view.installHandleAnnotations(for: selected, lineRects: lineRects, accent: accent)
            if activeToolbarOwner == .pdf {
                view.updateToolbarPosition()
            } else {
                view.hideToolbar()
            }
        } else if view.hasPendingSelection {
            view.updateToolbarPosition()
        } else {
            view.hideToolbar()
        }
        view.setNeedsDisplay(view.bounds)
    }

    private func isActive(card: NoteCard) -> Bool {
        guard let selectedCardID else { return false }
        return card.id == selectedCardID
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
        var lastToolbarOwner: ToolbarOwner = .none
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
    var bookMD5: String = ""
    var excerptHandler: ((PDFExcerpt) -> Void)?
    var excerptFactory: ((Int, CGRect, String) -> PDFExcerpt)?
    var createCardWithColorHandler: ((PDFExcerpt, Int) -> Void)?
    var editCardHandler: ((UUID) -> Void)?
    var changeCardColorHandler: ((UUID, Int) -> Void)?
    var deleteCardHandler: ((UUID) -> Void)?
    var cards: [NoteCard] = []
    var selectedCardID: UUID?
    var activeToolbarOwner: ToolbarOwner = .none
    var selectCardHandler: ((UUID?) -> Void)?
    var updateCardHighlightHandler: ((UUID, String, [HighlightRect], CGPoint, CGPoint) -> Void)?
    var asTitleHandler: ((UUID, String) -> Void)?
    var addToCommentsHandler: ((UUID, String) -> Void)?
    var mergeHandler: ((UUID, String, [HighlightRect]) -> Void)?
    var emphasizeHandler: ((UUID, String) -> Void)?
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
    private var toolbarHostingView: NSHostingView<AnyView>?
    private var scrollObserver: NSObjectProtocol?

    private struct HandleDrag {
        var cardID: UUID? // nil for pendingSelection
        var movingStart: Bool
        var startPage: PDFPage
        var startPoint: CGPoint
        var endPage: PDFPage
        var endPoint: CGPoint
        var latestSelection: PDFSelection?
    }
    private var handleDrag: HandleDrag?

    private var pdfScrollView: NSScrollView? {
        subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupScrollObserver()
        } else {
            removeScrollObserver()
            hideToolbar()
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
                self?.updateToolbarPosition()
            }
        }
    }

    private func removeScrollObserver() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
    }

    public override func layout() {
        super.layout()
        updateToolbarPosition()
    }

    func updateToolbarPosition() {
        if let pending = pendingSelection {
            let knobView = convert(pending.endPoint, from: pending.endPage)
            if bounds.contains(knobView) {
                let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                showToolbar(
                    mode: .create,
                    knobViewPoint: knobView,
                    hasTargetCard: targetCardID != nil,
                    isWithinTargetHighlight: isWithin
                )
            } else {
                hideToolbar()
            }
        } else if activeToolbarOwner == .pdf,
                  let cardID = selectedCardID,
                  let card = cards.first(where: { $0.id == cardID }),
                  let doc = document {
            let rects = PDFHighlightResolver.lineRects(for: card, in: doc)
            if let last = rects.last, let lastPage = doc.page(at: last.page) {
                let endPt = endpoint(for: last, start: false)
                let knobView = convert(endPt, from: lastPage)
                if bounds.contains(knobView) {
                    showToolbar(mode: .edit(colorIndex: card.colorIndex), knobViewPoint: knobView)
                } else {
                    hideToolbar()
                }
            } else {
                hideToolbar()
            }
        } else {
            hideToolbar()
        }
    }

    private func showToolbar(
        mode: PDFPopoverMode,
        knobViewPoint: CGPoint,
        hasTargetCard: Bool = false,
        isWithinTargetHighlight: Bool = false
    ) {
        let toolbarWidth: CGFloat
        if mode == .create {
            if hasTargetCard {
                toolbarWidth = isWithinTargetHighlight ? 585.0 : 520.0
            } else {
                toolbarWidth = 310.0
            }
        } else {
            toolbarWidth = 420.0
        }
        let toolbarHeight: CGFloat = 46.0

        var x = knobViewPoint.x - toolbarWidth / 2.0
        x = max(12, min(x, bounds.width - toolbarWidth - 12))

        let arrowOffset = max(14, min(knobViewPoint.x - x - 7, toolbarWidth - 28))

        let fitsBelow = knobViewPoint.y - toolbarHeight - 6 >= 10
        let isArrowFlipped = !fitsBelow
        let y: CGFloat = fitsBelow ? (knobViewPoint.y - toolbarHeight - 6) : (knobViewPoint.y + 16)

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
            hasTargetCard: hasTargetCard,
            isWithinTargetHighlight: isWithinTargetHighlight
        )

        let frame = CGRect(x: x, y: y, width: toolbarWidth, height: toolbarHeight)
        Swift.print("[Toolbar] showToolbar mode=\(mode) knobView=\(knobViewPoint) frame=\(frame) bounds=\(bounds)")
        if let existing = toolbarHostingView {
            existing.rootView = AnyView(toolbarView)
            existing.frame = frame
            existing.isHidden = false
            addSubview(existing, positioned: .above, relativeTo: nil)
        } else {
            let hosting = NSHostingView(rootView: AnyView(toolbarView))
            hosting.frame = frame
            addSubview(hosting, positioned: .above, relativeTo: nil)
            toolbarHostingView = hosting
        }
    }

    func hideToolbar() {
        toolbarHostingView?.isHidden = true
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
        guard let targetID = targetCardID, let pending = pendingSelection else { return }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let targetID = targetCardID, let pending = pendingSelection else { return }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let targetID = targetCardID, let pending = pendingSelection else { return }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        mergeHandler?(targetID, text, pending.rects)
        clearPendingSelection()
        clearBrackets()
        hideToolbar()
        targetCardID = nil
    }

    private func handleToolbarEmphasize() {
        guard let targetID = targetCardID, let pending = pendingSelection else { return }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        emphasizeHandler?(targetID, text)
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

    private func handleToolbarEdit() {
        if let cardID = selectedCardID {
            editCardHandler?(cardID)
        }
    }

    private func handleToolbarDelete() {
        if let cardID = selectedCardID {
            let toDelete = cardID
            selectedCardID = nil
            clearHandles()
            clearBrackets()
            hideToolbar()
            deleteCardHandler?(toDelete)
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
        let knobView = convert(canonicalEnd, from: page)

        let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
        showToolbar(
            mode: .create,
            knobViewPoint: knobView,
            hasTargetCard: targetCardID != nil,
            isWithinTargetHighlight: isWithin
        )

        handleDrag = HandleDrag(
            cardID: nil,
            movingStart: false,
            startPage: page,
            startPoint: canonicalStart,
            endPage: page,
            endPoint: canonicalEnd,
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
                super.mouseDown(with: event)
                return
            }
        }

        guard let page = page(for: viewPoint, nearest: true) else {
            holdTracker?.timer?.invalidate()
            holdTracker = nil
            clearPendingSelection()
            clearBrackets()
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
            holdTracker?.timer?.invalidate()
            holdTracker = nil
            return
        }

        // Double-click shortcut: immediately select word and show creation toolbar
        if event.clickCount >= 2, selectionTool == .textSelection {
            holdTracker?.timer?.invalidate()
            holdTracker = nil
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
                    let knobView = convert(canonicalEnd, from: page)
                    let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                    showToolbar(
                        mode: .create,
                        knobViewPoint: knobView,
                        hasTargetCard: targetCardID != nil,
                        isWithinTargetHighlight: isWithin
                    )
                    return
                }
            }
        }

        if selectionTool == .textSelection {
            let hitCard = cardHit(on: page, at: pagePoint)
            let initialTargetID = selectedCardID ?? hitCard?.id

            if let card = hitCard {
                clearPendingSelection()
                clearBrackets()
                targetCardID = nil
                selectedCardID = card.id
                activeToolbarOwner = .pdf
                selectCardHandler?(card.id)
                if let document {
                    let rects = PDFHighlightResolver.lineRects(for: card, in: document)
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
                cardHitID: hitCard?.id,
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
                if let cardID = handleDrag.cardID {
                    renderLiveHighlight(selection, cardID: cardID)
                    let knobView = convert(handleDrag.endPoint, from: handleDrag.endPage)
                    showToolbar(mode: .edit(colorIndex: cards.first(where: { $0.id == cardID })?.colorIndex ?? 0), knobViewPoint: knobView)
                } else {
                    // Pending selection drag
                    if let doc = document {
                        let rects = PDFHighlightResolver.lineRects(from: selection, document: doc)
                        let text = PDFHighlightResolver.normalizeExcerptParagraphs(selection)
                        let pending = PendingSelection(
                            selection: selection,
                            text: text,
                            rects: rects,
                            startPage: handleDrag.startPage,
                            startPoint: handleDrag.startPoint,
                            endPage: handleDrag.endPage,
                            endPoint: handleDrag.endPoint
                        )
                        renderPendingHighlight(pending)
                        let knobView = convert(handleDrag.endPoint, from: handleDrag.endPage)
                        let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                        showToolbar(
                            mode: .create,
                            knobViewPoint: knobView,
                            hasTargetCard: targetCardID != nil,
                            isWithinTargetHighlight: isWithin
                        )
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
            let currentPoint = convert(currentView, to: currentPage)
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
                    normalizedText,
                    rects,
                    canonicalStart,
                    canonicalEnd
                )
                let knobView = convert(canonicalEnd, from: endPage)
                showToolbar(mode: .edit(colorIndex: cards.first(where: { $0.id == cardID })?.colorIndex ?? 0), knobViewPoint: knobView)
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
                let knobView = convert(canonicalEnd, from: endPage)
                let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
                showToolbar(
                    mode: .create,
                    knobViewPoint: knobView,
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

        if let tracker, !tracker.didTrigger {
            // Quick click without hold!
            if tracker.cardHitID == nil {
                clearPendingSelection()
                clearBrackets()
                targetCardID = nil
                selectedCardID = nil
                activeToolbarOwner = .none
                selectCardHandler?(nil)
                clearHandles()
                hideToolbar()
            }
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
        let knobView = convert(endPoint, from: lastPage)
        let isWithin = checkIfPendingWithinTarget(pending, targetCardID: targetCardID)
        showToolbar(
            mode: .create,
            knobViewPoint: knobView,
            hasTargetCard: targetCardID != nil,
            isWithinTargetHighlight: isWithin
        )
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            return super.menu(for: event)
        }
        let pagePoint = convert(viewPoint, to: page)

        if let card = cardHit(on: page, at: pagePoint) ?? (selectedCardID.flatMap { id in cards.first(where: { $0.id == id }) }) {
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

    @objc private func deleteNoteAction(_ sender: NSMenuItem) {
        guard let card = sender.representedObject as? NoteCard else { return }
        deleteCardHandler?(card.id)
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

    private func addHandle(to page: PDFPage, at point: CGPoint, lineHeight: CGFloat, accent: NSColor, isStart: Bool, isPending: Bool = false) {
        let cursorColor = MarginNoteTheme.nsCursorColor
        let height = max(22, lineHeight + 14)
        let barBounds = CGRect(x: point.x - 1.0, y: point.y - height / 2, width: 2.0, height: height)
        let bar = PDFAnnotation(bounds: barBounds, forType: .square, withProperties: nil)
        bar.color = cursorColor
        bar.interiorColor = cursorColor
        let border = PDFBorder()
        border.lineWidth = 1.0
        border.style = .solid
        bar.border = border
        bar.contents = isPending ? (isStart ? "MarginGraph-pending-handle-start" : "MarginGraph-pending-handle-end")
                                 : (isStart ? "MarginGraph-handle-start" : "MarginGraph-handle-end")
        page.addAnnotation(bar)

        let knobSize: CGFloat = 11.0
        let knobY = isStart ? (point.y + height / 2 + 1) : (point.y - height / 2 - 1)
        let knobBounds = CGRect(x: point.x - knobSize / 2, y: knobY - knobSize / 2, width: knobSize, height: knobSize)
        let knob = PDFAnnotation(bounds: knobBounds, forType: .circle, withProperties: nil)
        knob.color = cursorColor
        knob.interiorColor = cursorColor
        let knobBorder = PDFBorder()
        knobBorder.lineWidth = 1.0
        knobBorder.style = .solid
        knob.border = knobBorder
        knob.contents = isPending ? (isStart ? "MarginGraph-pending-handle-knob-start" : "MarginGraph-pending-handle-knob-end")
                                  : (isStart ? "MarginGraph-handle-knob-start" : "MarginGraph-handle-knob-end")
        page.addAnnotation(knob)
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
        let stemHeight = max(22, lineHeight + 14)
        let knobY = isStart ? (handlePoint.y + stemHeight / 2 + 1) : (handlePoint.y - stemHeight / 2 - 1)
        let knobCenter = CGPoint(x: handlePoint.x, y: knobY)

        let distToKnob = hypot(point.x - knobCenter.x, point.y - knobCenter.y)
        let dx = abs(point.x - handlePoint.x)
        let dy = max(0, abs(point.y - handlePoint.y) - stemHeight / 2)
        let distToBar = hypot(dx, dy)

        let minDistance = min(distToKnob, distToBar)
        let isHit = (distToKnob <= 18.0) || (dx <= 14.0 && abs(point.y - handlePoint.y) <= (stemHeight / 2 + 10.0))
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

            if startTest.isHit && endTest.isHit {
                let pickStart = startTest.distance <= endTest.distance
                handleDrag = HandleDrag(
                    cardID: nil,
                    movingStart: pickStart,
                    startPage: pending.startPage,
                    startPoint: pending.startPoint,
                    endPage: pending.endPage,
                    endPoint: pending.endPoint,
                    latestSelection: pending.selection
                )
                return true
            } else if startTest.isHit {
                handleDrag = HandleDrag(
                    cardID: nil,
                    movingStart: true,
                    startPage: pending.startPage,
                    startPoint: pending.startPoint,
                    endPage: pending.endPage,
                    endPoint: pending.endPoint,
                    latestSelection: pending.selection
                )
                return true
            } else if endTest.isHit {
                handleDrag = HandleDrag(
                    cardID: nil,
                    movingStart: false,
                    startPage: pending.startPage,
                    startPoint: pending.startPoint,
                    endPage: pending.endPage,
                    endPoint: pending.endPoint,
                    latestSelection: pending.selection
                )
                return true
            }
        }

        guard let selectedCardID,
              let card = cards.first(where: { $0.id == selectedCardID }),
              let document else { return false }
        let rects = PDFHighlightResolver.lineRects(for: card, in: document)
        guard let first = rects.first, let last = rects.last,
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

        if startTest.isHit && endTest.isHit {
            let pickStart = startTest.distance <= endTest.distance
            handleDrag = HandleDrag(
                cardID: card.id,
                movingStart: pickStart,
                startPage: firstPage,
                startPoint: startPoint,
                endPage: lastPage,
                endPoint: endPoint,
                latestSelection: nil
            )
            return true
        } else if startTest.isHit {
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
        } else if endTest.isHit {
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
            let annotation = PDFHighlightResolver.createHighlightAnnotation(
                bounds: rect,
                color: accent.withAlphaComponent(0.65),
                contents: "MarginGraph-drag-highlight"
            )
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

    func clearHandles() {
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
