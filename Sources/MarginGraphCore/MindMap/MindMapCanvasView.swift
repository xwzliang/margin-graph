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
    public var onChangeColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onEditCard: ((NoteCard) -> Void)?

    @State private var viewport = CanvasViewport()
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var dragLocations: [UUID: CGPoint] = [:]
    @State private var canvasMode: String = "Drag" // "Drag" or "Select"

    public init(
        cards: [NoteCard],
        links: [CardLink] = [],
        selectedCardID: UUID? = nil,
        mediaStorage: MediaStorage? = nil,
        onSelect: @escaping (NoteCard?) -> Void,
        onMove: @escaping (UUID, CGPoint) -> Void,
        onReparent: @escaping (UUID, UUID?) -> Void,
        onToggleFold: @escaping (UUID, Bool) -> Void,
        onChangeColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onEditCard: ((NoteCard) -> Void)? = nil
    ) {
        self.cards = cards
        self.links = links
        self.selectedCardID = selectedCardID
        self.mediaStorage = mediaStorage
        self.onSelect = onSelect
        self.onMove = onMove
        self.onReparent = onReparent
        self.onToggleFold = onToggleFold
        self.onChangeColor = onChangeColor
        self.onDeleteCard = onDeleteCard
        self.onEditCard = onEditCard
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = TreeLayout.layout(cards: cards)
            let frames = displayFrames(layout: layout)
            let visibleCards = cards.filter { layout.visibleCardIDs.contains($0.id) }

            ZStack(alignment: .topLeading) {
                // Warm parchment background
                MarginNoteTheme.canvasBackground
                    .ignoresSafeArea()

                // Subtle grid with pan and deselect
                grid
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture {
                        onSelect(nil)
                    }

                // Tree connectors and links
                Canvas { context, _ in
                    drawConnectors(context: &context, frames: frames, visible: layout.visibleCardIDs)
                }
                .allowsHitTesting(false)

                // Main MindMap Title Header
                mainMindMapHeader(frames: frames)

                // Note Cards
                ForEach(visibleCards, id: \.id) { card in
                    if let frame = frames[card.id] {
                        CardNodeView(
                            card: card,
                            isSelected: selectedCardID == card.id,
                            hasChildren: cards.contains(where: { $0.groupNoteId == card.id }),
                            mediaStorage: mediaStorage,
                            onSelect: {
                                print("[MindMap] CardNodeView onSelect: \(card.title)")
                                onSelect(card)
                            },
                            onToggleFold: { onToggleFold(card.id, !card.isFolded) },
                            onEdit: { onEditCard?(card) }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(viewport.zoomScale)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                        .highPriorityGesture(nodeDrag(card: card, frame: frame, frames: frames))
                        .position(
                            x: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY)).x,
                            y: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY)).y
                        )
                    }
                }

                // Floating Card Inspector Toolbar
                if let selectedID = selectedCardID,
                   let selectedCard = cards.first(where: { $0.id == selectedID }),
                   let frame = frames[selectedID] {
                    let cardPos = viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.minY))
                    CardInspectorToolbar(
                        card: selectedCard,
                        onEdit: {
                            onEditCard?(selectedCard)
                        },
                        onChangeColor: { newColor in
                            onChangeColor?(selectedID, newColor)
                        },
                        onDelete: {
                            onDeleteCard?(selectedID)
                        },
                        onLink: {},
                        onFocus: {}
                    )
                    .position(x: cardPos.x, y: max(30, cardPos.y - 30 * viewport.zoomScale))
                }

                // Bottom-left "Drag" / "Select" Mode Control Pill (MarginNote 3 signature)
                VStack(spacing: 0) {
                    Button {
                        canvasMode = "Drag"
                    } label: {
                        Text("Drag")
                            .font(.system(size: 11, weight: canvasMode == "Drag" ? .semibold : .regular))
                            .foregroundStyle(canvasMode == "Drag" ? .primary : .secondary)
                            .frame(width: 52, height: 32)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(width: 40)

                    Button {
                        canvasMode = "Select"
                    } label: {
                        Text("Select")
                            .font(.system(size: 11, weight: canvasMode == "Select" ? .semibold : .regular))
                            .foregroundStyle(canvasMode == "Select" ? .primary : .secondary)
                            .frame(width: 52, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(white: 0.98).opacity(0.85))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                )
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                // MiniMapView at bottom-right
                MiniMapView(
                    frames: Array(frames.values),
                    viewport: viewport,
                    canvasSize: proxy.size
                )
                .frame(width: 140, height: 90)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .clipped()
            .onAppear {
                viewport.viewportSize = proxy.size
                viewport.zoomToFit(nodes: Array(frames.values))
            }
            .onChange(of: proxy.size) { _, size in
                viewport.viewportSize = size
            }
            .onChange(of: selectedCardID) { _, newID in
                if let newID, let frame = frames[newID] {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewport.center(on: frame)
                    }
                }
            }
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

    @ViewBuilder
    private func mainMindMapHeader(frames: [UUID: CGRect]) -> some View {
        if let first = frames.values.min(by: { $0.minY < $1.minY }) {
            let screenPoint = viewport.canvasToScreen(CGPoint(x: first.minX + 30, y: first.minY - 24))
            HStack(spacing: 4) {
                Text("Main MindMap")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.35))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(white: 0.45))
            }
            .position(screenPoint)
        }
    }

    private var grid: some View {
        Canvas { context, size in
            let spacing = max(16, 40 * viewport.zoomScale)
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
            context.stroke(path, with: .color(Color(red: 0.88, green: 0.85, blue: 0.78).opacity(0.4)), lineWidth: 0.75)
        }
    }

    private var panGesture: some Gesture {
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
    }

    private func displayFrames(layout: TreeLayoutResult) -> [UUID: CGRect] {
        var result = layout.frames
        for card in cards where layout.visibleCardIDs.contains(card.id) {
            if let drag = dragLocations[card.id],
               let automatic = result[card.id] {
                result[card.id] = CGRect(origin: drag, size: automatic.size)
            }
        }
        return result
    }

    private func nodeDrag(card: NoteCard, frame: CGRect, frames: [UUID: CGRect]) -> some Gesture {
        DragGesture(minimumDistance: 4)
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
                let distance = hypot(value.translation.width, value.translation.height)
                print("[MindMap] nodeDrag onEnded: card=\(card.title) distance=\(distance)")
                if distance < 4 {
                    print("[MindMap] nodeDrag calling onSelect(\(card.title))")
                    onSelect(card)
                    return
                }
                let dropPoint = dragLocations[card.id] ?? frame.origin
                let target = frames.first {
                    $0.key != card.id && $0.value.insetBy(dx: -16, dy: -16).contains(dropPoint)
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
                    with: .color(Color(red: 0.70, green: 0.66, blue: 0.58)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
            }
        }

        for link in links where visible.contains(link.sourceCardId) && visible.contains(link.targetCardId) {
            guard let source = frames[link.sourceCardId], let target = frames[link.targetCardId] else { continue }
            var relation = Path()
            relation.addPath(Path(TreeLayout.connectorPath(from: source, to: target)))
            context.stroke(
                transformed(relation),
                with: .color(Color(red: 0.25, green: 0.55, blue: 0.85).opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.8, dash: [6, 3])
            )

            var arrow = Path()
            arrow.addPath(Path(TreeLayout.arrowHead(for: TreeLayout.connectorPath(from: source, to: target), at: target)))
            context.fill(transformed(arrow), with: .color(Color(red: 0.25, green: 0.55, blue: 0.85).opacity(0.85)))
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
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Color(red: 0.65, green: 0.60, blue: 0.52).opacity(0.6)))
            }

            let visibleOrigin = viewport.screenToCanvas(.zero)
            let visibleEnd = viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
            let visible = CGRect(
                x: (visibleOrigin.x - bounds.minX) * scale,
                y: (visibleOrigin.y - bounds.minY) * scale,
                width: (visibleEnd.x - visibleOrigin.x) * scale,
                height: (visibleEnd.y - visibleOrigin.y) * scale
            )
            context.stroke(Path(visible), with: .color(Color(red: 0.20, green: 0.50, blue: 0.85)), lineWidth: 1.5)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.96).opacity(0.85))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.80, green: 0.76, blue: 0.70), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}
