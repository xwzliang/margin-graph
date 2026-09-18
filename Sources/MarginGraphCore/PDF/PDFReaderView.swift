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

public struct PDFReaderView: NSViewRepresentable {
    public var manager: PDFDocumentManager
    public var displayMode: PDFReaderDisplayMode
    public var tool: PDFSelectionTool
    public var highlightColor: NSColor
    public var cards: [NoteCard]
    public var jumpTarget: PDFJumpTarget?
    public var onExcerpt: ((PDFExcerpt) -> Void)?

    public init(
        manager: PDFDocumentManager,
        displayMode: PDFReaderDisplayMode = .continuous,
        tool: PDFSelectionTool = .textSelection,
        highlightColor: NSColor = .systemYellow,
        cards: [NoteCard] = [],
        jumpTarget: PDFJumpTarget? = nil,
        onExcerpt: ((PDFExcerpt) -> Void)? = nil
    ) {
        self.manager = manager
        self.displayMode = displayMode
        self.tool = tool
        self.highlightColor = highlightColor
        self.cards = cards
        self.jumpTarget = jumpTarget
        self.onExcerpt = onExcerpt
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        view.document = manager.document
        configure(view)
        return view
    }

    public func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== manager.document {
            view.document = manager.document
        }

        view.displayMode = displayMode == .continuous ? .singlePageContinuous : .singlePage
        view.autoScales = true
        configure(view)
        applyCardHighlights(to: view)

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
            where annotation.contents == "MarginGraph-card-highlight" || annotation.contents == "MarginGraph-jump" {
                page.removeAnnotation(annotation)
            }
        }

        for card in cards {
            guard card.bookMD5 == manager.md5,
                  let pageIndex = card.startPage,
                  let start = card.startPos,
                  let end = card.endPos,
                  let page = document.page(at: pageIndex) else { continue }

            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            guard rect.width > 0, rect.height > 0 else { continue }

            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.color = highlightColor.withAlphaComponent(0.35)
            annotation.contents = "MarginGraph-card-highlight"
            page.addAnnotation(annotation)
        }
    }

    private func jump(_ view: PDFView, to target: PDFJumpTarget) {
        guard let page = view.document?.page(at: target.pageIndex) else { return }
        let destination = PDFDestination(
            page: page,
            at: CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        )
        view.go(to: destination)

        let annotation = PDFAnnotation(bounds: target.bounds, forType: .square, withProperties: nil)
        annotation.color = highlightColor
        annotation.contents = "MarginGraph-jump"
        page.addAnnotation(annotation)
    }

    public final class Coordinator {
        var lastJump: PDFJumpTarget?
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
