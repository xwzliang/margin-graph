import Foundation
import CoreGraphics

public struct TreeLayoutConfiguration: Sendable {
    public var nodeSize: CGSize
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(
        nodeSize: CGSize = CGSize(width: 240, height: 120),
        horizontalSpacing: CGFloat = 80,
        verticalSpacing: CGFloat = 28
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
    public static func layout(
        cards: [NoteCard],
        configuration: TreeLayoutConfiguration = TreeLayoutConfiguration()
    ) -> TreeLayoutResult {
        let cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let children = Dictionary(grouping: cards, by: { $0.groupNoteId })
        let roots = (children[nil] ?? []).sorted(by: cardOrder)

        var frames: [UUID: CGRect] = [:]
        var visible = Set<UUID>()
        var columnStartX: CGFloat = 40
        var nextY: CGFloat = 40
        let maxColumnHeight: CGFloat = 720

        @discardableResult
        func place(_ card: NoteCard, depth: Int, baseX: CGFloat) -> CGRect {
            let cardChildren = (children[card.id] ?? []).sorted(by: cardOrder)
            let x = baseX + CGFloat(depth) * (configuration.nodeSize.width + configuration.horizontalSpacing)

            if card.isFolded || cardChildren.isEmpty {
                let frame = CGRect(origin: CGPoint(x: x, y: nextY), size: configuration.nodeSize)
                frames[card.id] = frame
                visible.insert(card.id)
                nextY += configuration.nodeSize.height + configuration.verticalSpacing
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
                childCenterY = subtreeStartY + configuration.nodeSize.height / 2
            }

            let originY = max(subtreeStartY, childCenterY - configuration.nodeSize.height / 2)
            let frame = CGRect(origin: CGPoint(x: x, y: originY), size: configuration.nodeSize)
            frames[card.id] = frame
            visible.insert(card.id)
            return frame
        }

        for root in roots {
            if nextY >= maxColumnHeight {
                columnStartX += configuration.nodeSize.width + configuration.horizontalSpacing
                nextY = 40
            }
            _ = place(root, depth: 0, baseX: columnStartX)
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

    private static func cardOrder(_ lhs: NoteCard, _ rhs: NoteCard) -> Bool {
        if lhs.startPage != rhs.startPage {
            return (lhs.startPage ?? 0) < (rhs.startPage ?? 0)
        }
        if lhs.mindPos?.y != rhs.mindPos?.y {
            return (lhs.mindPos?.y ?? .greatestFiniteMagnitude) < (rhs.mindPos?.y ?? .greatestFiniteMagnitude)
        }
        return lhs.createdAt < rhs.createdAt
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
}
