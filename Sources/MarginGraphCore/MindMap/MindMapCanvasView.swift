import SwiftUI
import CoreGraphics

public struct MindMapCanvasView: View {
    public var cards: [NoteCard]
    public var links: [CardLink]
    public var selectedCardID: UUID?
    public var mediaStorage: MediaStorage?
    public var onSelect: (NoteCard?) -> Void
    public var onMove: (UUID, CGPoint) -> Void
    public var onReparent: (UUID, UUID?) -> Void
    public var onToggleFold: (UUID, Bool) -> Void

    @State private var viewport = CanvasViewport()
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var dragLocations: [UUID: CGPoint] = [:]

    public init(
        cards: [NoteCard],
        links: [CardLink] = [],
        selectedCardID: UUID? = nil,
        mediaStorage: MediaStorage? = nil,
        onSelect: @escaping (NoteCard?) -> Void,
        onMove: @escaping (UUID, CGPoint) -> Void,
        onReparent: @escaping (UUID, UUID?) -> Void,
        onToggleFold: @escaping (UUID, Bool) -> Void
    ) {
        self.cards = cards
        self.links = links
        self.selectedCardID = selectedCardID
        self.mediaStorage = mediaStorage
        self.onSelect = onSelect
        self.onMove = onMove
        self.onReparent = onReparent
        self.onToggleFold = onToggleFold
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = TreeLayout.layout(cards: cards)
            let frames = displayFrames(layout: layout)
            let visibleCards = cards.filter { layout.visibleCardIDs.contains($0.id) }

            ZStack(alignment: .topLeading) {
                grid
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(nil) }

                Canvas { context, _ in
                    drawConnectors(context: &context, frames: frames, visible: layout.visibleCardIDs)
                }

                ForEach(visibleCards, id: \.id) { card in
                    if let frame = frames[card.id] {
                        CardNodeView(
                            card: card,
                            isSelected: selectedCardID == card.id,
                            hasChildren: cards.contains(where: { $0.groupNoteId == card.id }),
                            mediaStorage: mediaStorage,
                            onSelect: { onSelect(card) },
                            onToggleFold: { onToggleFold(card.id, !card.isFolded) }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(
                            x: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY)).x,
                            y: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY)).y
                        )
                        .scaleEffect(viewport.zoomScale)
                        .gesture(nodeDrag(card: card, frame: frame, frames: frames))
                    }
                }

                MiniMapView(
                    frames: Array(frames.values),
                    viewport: viewport,
                    canvasSize: proxy.size
                )
                .frame(width: 150, height: 100)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .clipped()
            .onAppear {
                viewport.viewportSize = proxy.size
                if viewport.panOffset == .zero {
                    viewport.zoomToFit(nodes: Array(frames.values))
                }
            }
            .onChange(of: proxy.size) { _, size in
                viewport.viewportSize = size
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if panStart == nil { panStart = viewport.panOffset }
                        let start = panStart ?? .zero
                        viewport.panOffset = CGPoint(
                            x: start.x + value.translation.width,
                            y: start.y + value.translation.height
                        )
                    }
                    .onEnded { _ in panStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if zoomStart == nil { zoomStart = viewport.zoomScale }
                        let oldScale = viewport.zoomScale
                        viewport.zoomScale = (zoomStart ?? oldScale) * value.magnification
                        let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        let canvasCenter = CGPoint(
                            x: (center.x - viewport.panOffset.x) / oldScale,
                            y: (center.y - viewport.panOffset.y) / oldScale
                        )
                        viewport.panOffset = CGPoint(
                            x: center.x - canvasCenter.x * viewport.zoomScale,
                            y: center.y - canvasCenter.y * viewport.zoomScale
                        )
                    }
                    .onEnded { _ in zoomStart = nil }
            )
        }
    }

    private var grid: some View {
        Canvas { context, size in
            let spacing = max(12, 36 * viewport.zoomScale)
            var path = Path()
            var x = viewport.panOffset.x.truncatingRemainder(dividingBy: spacing)
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = viewport.panOffset.y.truncatingRemainder(dividingBy: spacing)
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.secondary.opacity(0.09)), lineWidth: 1)
        }
    }

    private func displayFrames(layout: TreeLayoutResult) -> [UUID: CGRect] {
        var result = layout.frames
        for card in cards where layout.visibleCardIDs.contains(card.id) {
            if let drag = dragLocations[card.id] ?? card.mindPos,
               let automatic = result[card.id] {
                result[card.id] = CGRect(origin: drag, size: automatic.size)
            }
        }
        return result
    }

    private func nodeDrag(card: NoteCard, frame: CGRect, frames: [UUID: CGRect]) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let canvasDelta = CGPoint(
                    x: value.translation.width / viewport.zoomScale,
                    y: value.translation.height / viewport.zoomScale
                )
                dragLocations[card.id] = CGPoint(
                    x: frame.minX + canvasDelta.x,
                    y: frame.minY + canvasDelta.y
                )
            }
            .onEnded { value in
                let screenPoint = value.location
                let canvasPoint = viewport.screenToCanvas(screenPoint)
                let target = frames.first {
                    $0.key != card.id && $0.value.insetBy(dx: -16, dy: -16).contains(canvasPoint)
                }?.key
                if let target {
                    onReparent(card.id, target)
                    dragLocations[card.id] = nil
                } else if let position = dragLocations[card.id] {
                    onMove(card.id, position)
                }
            }
    }

    private func drawConnectors(
        context: inout GraphicsContext,
        frames: [UUID: CGRect],
        visible: Set<UUID>
    ) {
        for card in cards where visible.contains(card.id) {
            if let parentID = card.groupNoteId,
               visible.contains(parentID),
               let parent = frames[parentID],
               let child = frames[card.id] {
                var path = Path()
                path.addPath(Path(TreeLayout.connectorPath(from: parent, to: child)))
                context.stroke(
                    transformed(path),
                    with: .color(.secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }

        for link in links where visible.contains(link.sourceCardId) && visible.contains(link.targetCardId) {
            guard let source = frames[link.sourceCardId], let target = frames[link.targetCardId] else { continue }
            var relation = Path()
            relation.addPath(Path(TreeLayout.connectorPath(from: source, to: target)))
            context.stroke(
                transformed(relation),
                with: .color(.accentColor.opacity(0.7)),
                style: StrokeStyle(lineWidth: 2, dash: [7, 4])
            )

            var arrow = Path()
            arrow.addPath(Path(TreeLayout.arrowHead(for: TreeLayout.connectorPath(from: source, to: target), at: target)))
            context.fill(transformed(arrow), with: .color(.accentColor.opacity(0.75)))
        }
    }

    private func transformed(_ path: Path) -> Path {
        path.applying(CGAffineTransform(
            a: viewport.zoomScale,
            b: 0,
            c: 0,
            d: viewport.zoomScale,
            tx: viewport.panOffset.x,
            ty: viewport.panOffset.y
        ))
    }
}

private struct MiniMapView: View {
    let frames: [CGRect]
    let viewport: CanvasViewport
    let canvasSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let first = frames.first else { return }
            let bounds = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -40, dy: -40)
            let sx = size.width / max(1, bounds.width)
            let sy = size.height / max(1, bounds.height)
            let scale = min(sx, sy)

            for frame in frames {
                let rect = CGRect(
                    x: (frame.minX - bounds.minX) * scale,
                    y: (frame.minY - bounds.minY) * scale,
                    width: max(2, frame.width * scale),
                    height: max(2, frame.height * scale)
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.secondary.opacity(0.45)))
            }

            let visibleOrigin = viewport.screenToCanvas(.zero)
            let visibleEnd = viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
            let visible = CGRect(
                x: (visibleOrigin.x - bounds.minX) * scale,
                y: (visibleOrigin.y - bounds.minY) * scale,
                width: (visibleEnd.x - visibleOrigin.x) * scale,
                height: (visibleEnd.y - visibleOrigin.y) * scale
            )
            context.stroke(Path(visible), with: .color(.accentColor), lineWidth: 2)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
    }
}
