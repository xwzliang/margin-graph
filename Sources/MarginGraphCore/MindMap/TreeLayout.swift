import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#endif

public struct TreeLayoutConfiguration: Sendable {
    public var nodeSize: CGSize
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(
        nodeSize: CGSize = CGSize(width: 220, height: 120),
        horizontalSpacing: CGFloat = 80,
        verticalSpacing: CGFloat = 36
    ) {
        self.nodeSize = nodeSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }
}

public struct TreeLayoutResult {
    public var frames: [UUID: CGRect]
    public var visibleCardIDs: Set<UUID>

    public init(frames: [UUID: CGRect], visibleCardIDs: Set<UUID>) {
        self.frames = frames
        self.visibleCardIDs = visibleCardIDs
    }

    public func connectorPath(parentID: UUID, childID: UUID) -> CGPath? {
        guard let parent = frames[parentID], let child = frames[childID] else { return nil }
        return TreeLayout.connectorPath(from: parent, to: child)
    }

    public func relationPath(sourceID: UUID, targetID: UUID) -> CGPath? {
        guard let source = frames[sourceID], let target = frames[targetID] else { return nil }
        return TreeLayout.connectorPath(from: source, to: target)
    }
}

public enum TreeLayout {
#if canImport(AppKit)
    public static func measureTextHeight(
        text: String,
        font: NSFont,
        width: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let para = NSMutableParagraphStyle()
        if lineSpacing > 0 {
            para.lineSpacing = lineSpacing
        }
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: para
            ]
        )
        let rect = attr.boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
#endif

    private static func fallbackMeasureTextHeight(
        text: String,
        width: CGFloat,
        fontPointSize: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let charsPerLine = max(10, Int(width / (fontPointSize * 0.6)))
        let lines = text.components(separatedBy: "\n")
        var totalLines = 0
        for line in lines {
            if line.isEmpty {
                totalLines += 1
            } else {
                totalLines += max(1, (line.count + charsPerLine - 1) / charsPerLine)
            }
        }
        let lineHeight = fontPointSize * 1.25 + lineSpacing
        return ceil(CGFloat(totalLines) * lineHeight)
    }

    public static func estimatedCardHeight(for card: NoteCard, width: CGFloat = 220) -> CGFloat {
        let cardWidth = max(100, width)
        let isVideo = card.mediaType == "video" || card.videoStartTime != nil
        let hasExcerpt = !card.highlightText.isEmpty
        let hasNotes = !card.notesText.isEmpty
        let hasImage = card.highlightPicHash != nil
        let hasTags = !card.tags.isEmpty

        // 1. Header calculation
        let headerHeight: CGFloat
        if !card.title.isEmpty {
            let availableTitleWidth = max(40, cardWidth - 28.0)
            #if canImport(AppKit)
            let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let titleTextH = measureTextHeight(text: card.title, font: titleFont, width: availableTitleWidth)
            #else
            let titleTextH = fallbackMeasureTextHeight(text: card.title, width: availableTitleWidth, fontPointSize: 13, lineSpacing: 0)
            #endif
            headerHeight = titleTextH + 16.0
        } else if !hasExcerpt && !hasNotes {
            headerHeight = 30.0
        } else {
            // Minimal header with chevron only
            headerHeight = 20.0
        }

        // 2. Body calculation
        var bodyContentHeight: CGFloat = 0
        var bodyItemsCount = 0
        let availableTextWidth = max(40, cardWidth - 18.0)

        if isVideo {
            bodyContentHeight += 20.0
            bodyItemsCount += 1
        }

        if hasExcerpt {
            #if canImport(AppKit)
            let excerptFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            let excerptTextH = measureTextHeight(text: card.highlightText, font: excerptFont, width: availableTextWidth, lineSpacing: 2)
            #else
            let excerptTextH = fallbackMeasureTextHeight(text: card.highlightText, width: availableTextWidth, fontPointSize: 11.5, lineSpacing: 2)
            #endif
            bodyContentHeight += excerptTextH
            bodyItemsCount += 1
        }

        if hasNotes {
            #if canImport(AppKit)
            let notesFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
            let notesTextH = measureTextHeight(text: card.notesText, font: notesFont, width: availableTextWidth, lineSpacing: 2)
            #else
            let notesTextH = fallbackMeasureTextHeight(text: card.notesText, width: availableTextWidth, fontPointSize: 11.5, lineSpacing: 2)
            #endif
            bodyContentHeight += notesTextH
            bodyItemsCount += 1
        }

        if hasImage {
            bodyContentHeight += 82.0
            bodyItemsCount += 1
        }

        if hasTags {
            bodyContentHeight += 20.0
            bodyItemsCount += 1
        }

        if bodyItemsCount > 1 {
            bodyContentHeight += CGFloat(bodyItemsCount - 1) * 6.0
        }

        let bodyHeight: CGFloat = bodyItemsCount > 0 ? (bodyContentHeight + 16.0) : 0
        let total = headerHeight + bodyHeight
        if !card.title.isEmpty || hasExcerpt || hasNotes || hasImage || hasTags || isVideo {
            return max(70.0, total)
        } else {
            return max(56.0, total)
        }
    }

    public static func layout(
        cards: [NoteCard],
        configuration: TreeLayoutConfiguration = TreeLayoutConfiguration()
    ) -> TreeLayoutResult {
        let cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let children = Dictionary(grouping: cards, by: { $0.groupNoteId })
        let roots = (children[nil] ?? []).sorted(by: cardOrder)

        var frames: [UUID: CGRect] = [:]
        var visible = Set<UUID>()
        var nextY: CGFloat = 40
        let totalCards = max(1, cards.count)
        let maxColumnHeight: CGFloat = max(1400.0, 270.0 * sqrt(CGFloat(totalCards)))

        var currentColumnMaxX: CGFloat = 40.0

        @discardableResult
        func place(_ card: NoteCard, depth: Int, baseX: CGFloat) -> CGRect {
            let cardChildren = (children[card.id] ?? []).sorted(by: cardOrder)
            let x = baseX + CGFloat(depth) * (configuration.nodeSize.width + configuration.horizontalSpacing)
            let cardHeight = estimatedCardHeight(for: card, width: configuration.nodeSize.width)
            let currentSize = CGSize(width: configuration.nodeSize.width, height: cardHeight)

            if card.isFolded || cardChildren.isEmpty {
                let frame = CGRect(origin: CGPoint(x: x, y: nextY), size: currentSize)
                frames[card.id] = frame
                visible.insert(card.id)
                currentColumnMaxX = max(currentColumnMaxX, frame.maxX)
                nextY += cardHeight + configuration.verticalSpacing
                return frame
            }

            let subtreeStartY = nextY
            var childFrames: [CGRect] = []
            for child in cardChildren where cardByID[child.id] != nil {
                childFrames.append(place(child, depth: depth + 1, baseX: baseX))
            }

            let childCenterY: CGFloat
            if let first = childFrames.first, let last = childFrames.last {
                childCenterY = (first.midY + last.midY) / 2
            } else {
                childCenterY = subtreeStartY + cardHeight / 2
            }

            let originY = max(subtreeStartY, childCenterY - cardHeight / 2)
            let frame = CGRect(origin: CGPoint(x: x, y: originY), size: currentSize)
            frames[card.id] = frame
            visible.insert(card.id)
            currentColumnMaxX = max(currentColumnMaxX, frame.maxX)
            nextY = max(nextY, originY + cardHeight + configuration.verticalSpacing)
            return frame
        }

        func estimatedSubtreeHeight(_ card: NoteCard) -> CGFloat {
            let cardHeight = estimatedCardHeight(for: card, width: configuration.nodeSize.width)
            let cardChildren = (children[card.id] ?? []).sorted(by: cardOrder)
            if card.isFolded || cardChildren.isEmpty {
                return cardHeight
            }
            var childrenHeight: CGFloat = 0
            for child in cardChildren where cardByID[child.id] != nil {
                childrenHeight += estimatedSubtreeHeight(child) + configuration.verticalSpacing
            }
            return max(cardHeight, childrenHeight)
        }

        // Partition roots into Column Containers
        var columnContainers: [[NoteCard]] = []

        // If roots have explicit columns (clustered by valid canvas X):
        let rootsWithExplicitX = roots.filter { ($0.mindPos?.x ?? 0) > 20 && ($0.mindPos?.x ?? 0) < 10000 }
        if !rootsWithExplicitX.isEmpty {
            var clusters: [(baseX: CGFloat, roots: [NoteCard])] = []
            for root in rootsWithExplicitX.sorted(by: { ($0.mindPos?.x ?? 0) < ($1.mindPos?.x ?? 0) }) {
                let x = root.mindPos!.x
                if let idx = clusters.firstIndex(where: { abs($0.baseX - x) < 140 }) {
                    clusters[idx].roots.append(root)
                    clusters[idx].baseX = min(clusters[idx].baseX, x)
                } else {
                    clusters.append((baseX: x, roots: [root]))
                }
            }
            clusters.sort(by: { $0.baseX < $1.baseX })
            columnContainers = clusters.map(\.roots)
        }

        // Unpositioned roots (or when no explicit columns exist):
        let unpositionedRoots = roots.filter { ($0.mindPos?.x ?? 0) <= 20 || ($0.mindPos?.x ?? 0) >= 10000 }
        if !unpositionedRoots.isEmpty {
            var currentColumn: [NoteCard] = []
            var currentHeight: CGFloat = 0
            for root in unpositionedRoots {
                let h = estimatedSubtreeHeight(root) + configuration.verticalSpacing
                if currentHeight + h > maxColumnHeight && !currentColumn.isEmpty {
                    columnContainers.append(currentColumn)
                    currentColumn = [root]
                    currentHeight = h
                } else {
                    currentColumn.append(root)
                    currentHeight += h
                }
            }
            if !currentColumn.isEmpty {
                columnContainers.append(currentColumn)
            }
        }

        // Lay out each column container sequentially from left to right
        var columnStartX: CGFloat = 40.0
        for column in columnContainers {
            let sortedColumn = column.sorted(by: cardOrder)
            let explicitX = sortedColumn.compactMap(\.mindPos?.x).filter { $0 > 20 && $0 < 10000 }.min()
            let baseX = max(columnStartX, explicitX ?? columnStartX)

            let explicitFirstY = sortedColumn.first.flatMap { card -> CGFloat? in
                guard let y = card.mindPos?.y, (card.mindPos?.x ?? 0) > 20, y > 20, y < 5000 else { return nil }
                return y
            }
            nextY = explicitFirstY ?? 40.0

            currentColumnMaxX = baseX + configuration.nodeSize.width
            for root in sortedColumn {
                if let savedY = root.mindPos?.y, (root.mindPos?.x ?? 0) > 20, savedY > nextY && savedY < 5000 {
                    nextY = savedY
                }
                _ = place(root, depth: 0, baseX: baseX)
            }

            // Next column starts after the rightmost edge of this column and its branches
            columnStartX = currentColumnMaxX + configuration.horizontalSpacing
        }

        return TreeLayoutResult(frames: frames, visibleCardIDs: visible)
    }

    public static func connectorPath(from parent: CGRect, to child: CGRect) -> CGPath {
        let start = CGPoint(x: parent.maxX, y: parent.midY)
        let end = CGPoint(x: child.minX, y: child.midY)
        let dx = max(30, (end.x - start.x) * 0.5)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + dx, y: start.y),
            control2: CGPoint(x: end.x - dx, y: end.y)
        )
        return path
    }

    public static func arrowHead(for path: CGPath, at targetFrame: CGRect, size: CGFloat = 9) -> CGPath {
        let tip = CGPoint(x: targetFrame.minX, y: targetFrame.midY)
        let arrow = CGMutablePath()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - size, y: tip.y - size * 0.55))
        arrow.addLine(to: CGPoint(x: tip.x - size, y: tip.y + size * 0.55))
        arrow.closeSubpath()
        return arrow
    }

    public static func cardOrder(_ lhs: NoteCard, _ rhs: NoteCard) -> Bool {
        if let ly = lhs.mindPos?.y, let ry = rhs.mindPos?.y, ly != ry {
            return ly < ry
        }
        if lhs.startPage != rhs.startPage {
            return (lhs.startPage ?? 0) < (rhs.startPage ?? 0)
        }
        if lhs.mindPos?.y != rhs.mindPos?.y {
            return (lhs.mindPos?.y ?? .greatestFiniteMagnitude) < (rhs.mindPos?.y ?? .greatestFiniteMagnitude)
        }
        return lhs.createdAt < rhs.createdAt
    }

    public static func snapToGrid(_ point: CGPoint, gridSize: CGFloat = 20.0) -> CGPoint {
        let snappedX = (point.x / gridSize).rounded() * gridSize
        let snappedY = (point.y / gridSize).rounded() * gridSize
        return CGPoint(x: snappedX, y: snappedY)
    }
}

public struct CanvasViewport: Equatable, Sendable {
    public var panOffset: CGPoint
    public var zoomScale: CGFloat {
        didSet { zoomScale = min(3.0, max(0.1, zoomScale)) }
    }
    public var viewportSize: CGSize

    public init(
        panOffset: CGPoint = CGPoint(x: 40, y: 40),
        zoomScale: CGFloat = 1,
        viewportSize: CGSize = CGSize(width: 1000, height: 700)
    ) {
        self.panOffset = panOffset
        self.zoomScale = min(3.0, max(0.1, zoomScale))
        self.viewportSize = viewportSize
    }

    public func screenToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - panOffset.x) / zoomScale,
            y: (point.y - panOffset.y) / zoomScale
        )
    }

    public func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * zoomScale + panOffset.x,
            y: point.y * zoomScale + panOffset.y
        )
    }

    public mutating func zoomToFit(nodes: [CGRect], padding: CGFloat = 48) {
        guard let first = nodes.first else {
            zoomScale = 1
            panOffset = CGPoint(x: 40, y: 40)
            return
        }
        let bounds = nodes.dropFirst().reduce(first) { $0.union($1) }
        let availableWidth = max(1, viewportSize.width - padding * 2)
        let availableHeight = max(1, viewportSize.height - padding * 2)
        let scaleX = availableWidth / max(1, bounds.width)
        let scaleY = availableHeight / max(1, bounds.height)
        let naturalScale = min(scaleX, scaleY)
        if nodes.count > 15 {
            zoomScale = min(1.0, max(0.85, naturalScale))
            panOffset = CGPoint(x: padding, y: padding + 20)
        } else {
            zoomScale = min(1.5, max(0.6, naturalScale))
            panOffset = CGPoint(
                x: viewportSize.width / 2 - bounds.midX * zoomScale,
                y: viewportSize.height / 2 - bounds.midY * zoomScale
            )
        }
    }

    public mutating func center(on frame: CGRect) {
        panOffset = CGPoint(
            x: viewportSize.width / 2 - frame.midX * zoomScale,
            y: viewportSize.height / 2 - frame.midY * zoomScale
        )
    }

    public mutating func zoom(by factor: CGFloat, around screenCenter: CGPoint) {
        let oldScale = zoomScale
        let targetScale = min(3.0, max(0.1, oldScale * factor))
        guard oldScale != targetScale else { return }
        let canvasPoint = screenToCanvas(screenCenter)
        zoomScale = targetScale
        panOffset = CGPoint(
            x: screenCenter.x - canvasPoint.x * targetScale,
            y: screenCenter.y - canvasPoint.y * targetScale
        )
    }

    public mutating func zoomIn(factor: CGFloat = 1.15) {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        zoom(by: factor, around: center)
    }

    public mutating func zoomOut(factor: CGFloat = 1.15) {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        zoom(by: 1.0 / factor, around: center)
    }

    public mutating func resetZoom() {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let canvasPoint = screenToCanvas(center)
        zoomScale = 1.0
        panOffset = CGPoint(
            x: center.x - canvasPoint.x,
            y: center.y - canvasPoint.y
        )
    }
}
