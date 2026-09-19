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
    public static func lineRects(for card: NoteCard, in document: PDFDocument) -> [HighlightRect] {
        let stored = card.highlightRects.filter {
            $0.page >= 0 && $0.page < document.pageCount && $0.width > 0 && $0.height > 0
        }
        if !stored.isEmpty { return stored }

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
                rects(from: selection, document: document)
            }
            if !resolved.isEmpty { return resolved }
        }

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
                    let resolved = rects(from: selection, document: document)
                    if !resolved.isEmpty { return resolved }
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

        return []
    }

    private static func rects(from selection: PDFSelection, document: PDFDocument) -> [HighlightRect] {
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
        return result
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

    public init(
        manager: PDFDocumentManager,
        displayMode: PDFReaderDisplayMode = .continuous,
        tool: PDFSelectionTool = .textSelection,
        highlightColor: NSColor = .systemYellow,
        cards: [NoteCard] = [],
        selectedCardID: UUID? = nil,
        jumpTarget: PDFJumpTarget? = nil,
        currentPageIndex: Binding<Int> = .constant(0),
        onExcerpt: ((PDFExcerpt) -> Void)? = nil
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
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
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
        view.autoScales = true
        configure(view)
        if context.coordinator.lastCardCount != cards.count ||
           context.coordinator.lastSelectedCardID != selectedCardID ||
           context.coordinator.lastDocument !== view.document {
            context.coordinator.lastCardCount = cards.count
            context.coordinator.lastSelectedCardID = selectedCardID
            context.coordinator.lastDocument = view.document
            applyCardHighlights(to: view)
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

    private func applyCardHighlights(to view: PDFView) {
        guard let document = view.document else { return }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.contents == "MarginGraph-card-highlight"
                || annotation.contents == "MarginGraph-active-highlight"
                || annotation.contents == "MarginGraph-jump" {
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
                annotation.color = accent.withAlphaComponent(0.40)
                annotation.contents = "MarginGraph-card-highlight"
                page.addAnnotation(annotation)
            }

            if isActive(card: card) {
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
            }
        }
        view.layoutDocumentView()
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
        var lastCardCount: Int = -1
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

    private var dragStart: (page: PDFPage, point: CGPoint)?
    private var dragLayer: CAShapeLayer?

    public override func mouseDown(with event: NSEvent) {
        guard selectionTool == .rectMarquee else {
            super.mouseDown(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }

        dragStart = (page, convert(viewPoint, to: page))
        installDragLayer()
    }

    public override func mouseDragged(with event: NSEvent) {
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
                let text = start.page.selection(for: bounds)?.string ?? ""
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
        excerptHandler?(factory(pageIndex, bounds, selection.string ?? ""))
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
