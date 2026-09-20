import SwiftUI
import CoreGraphics

public struct MindMapCanvasView: View {
    public var cards: [NoteCard]
    public var links: [CardLink]
    public var selectedCardID: UUID?
    public var activeToolbarOwner: ToolbarOwner
    public var mediaStorage: MediaStorage?
    public var topics: [Topic]
    public var selectedTopic: Topic?
    public var onSelectTopic: ((Topic) -> Void)?
    public var onNewTopic: (() -> Void)?
    public var onSelect: (NoteCard?) -> Void
    public var onMove: (UUID, CGPoint) -> Void
    public var onReparent: (UUID, UUID?) -> Void
    public var onToggleFold: (UUID, Bool) -> Void
    public var onChangeColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onEditCard: ((NoteCard) -> Void)?
    public var onNewSibling: ((UUID) -> Void)?
    public var onNewChild: ((UUID) -> Void)?

    @State private var viewport = CanvasViewport()
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var dragLocations: [UUID: CGPoint] = [:]
    @State private var canvasMode: String = "Drag" // "Drag" or "Select"
    @State private var isDraggingVScroll = false
    @State private var vScrollStartPanY: CGFloat = 0
    @State private var isDraggingHScroll = false
    @State private var hScrollStartPanX: CGFloat = 0
    @State private var isHoveringScrollbars = false
    @State private var showMiniMap = true
    @State private var layoutResult: TreeLayoutResult

    public init(
        cards: [NoteCard],
        links: [CardLink] = [],
        selectedCardID: UUID? = nil,
        activeToolbarOwner: ToolbarOwner = .mindMap,
        mediaStorage: MediaStorage? = nil,
        topics: [Topic] = [],
        selectedTopic: Topic? = nil,
        onSelectTopic: ((Topic) -> Void)? = nil,
        onNewTopic: (() -> Void)? = nil,
        onSelect: @escaping (NoteCard?) -> Void,
        onMove: @escaping (UUID, CGPoint) -> Void,
        onReparent: @escaping (UUID, UUID?) -> Void,
        onToggleFold: @escaping (UUID, Bool) -> Void,
        onChangeColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onEditCard: ((NoteCard) -> Void)? = nil,
        onNewSibling: ((UUID) -> Void)? = nil,
        onNewChild: ((UUID) -> Void)? = nil
    ) {
        self.cards = cards
        self.links = links
        self.selectedCardID = selectedCardID
        self.activeToolbarOwner = activeToolbarOwner
        self.mediaStorage = mediaStorage
        self.topics = topics
        self.selectedTopic = selectedTopic
        self.onSelectTopic = onSelectTopic
        self.onNewTopic = onNewTopic
        self.onSelect = onSelect
        self.onMove = onMove
        self.onReparent = onReparent
        self.onToggleFold = onToggleFold
        self.onChangeColor = onChangeColor
        self.onDeleteCard = onDeleteCard
        self.onEditCard = onEditCard
        self.onNewSibling = onNewSibling
        self.onNewChild = onNewChild
        self._layoutResult = State(initialValue: TreeLayout.layout(cards: cards))
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = layoutResult
            let frames = displayFrames(layout: layout)
            let visibleCards = cards.filter { layout.visibleCardIDs.contains($0.id) }

            ZStack(alignment: .topLeading) {
                canvasBackgroundView

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

                // Note Cards with Viewport Culling
                cardsView(visibleCards: visibleCards, frames: frames, canvasSize: proxy.size)

                // Main MindMap Floating Header (MarginNote 3 signature)
                HStack {
                    Spacer()
                    mainMindMapHeader
                    Spacer()
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

                // Bottom-left Mode Toggles (MarginNote 3 signature Drag & Select stacked buttons)
                bottomLeftControls

                // MiniMapView at bottom-right (toggleable)
                if showMiniMap {
                    MiniMapView(
                        cards: visibleCards,
                        frames: frames,
                        viewport: $viewport,
                        canvasSize: proxy.size,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showMiniMap = false
                            }
                        }
                    )
                    .frame(width: 150, height: 100)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMiniMap = true
                        }
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color(white: 0.98).opacity(0.95))
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .overlay(
                                        Circle().stroke(Color.black.opacity(0.08), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show Overview Window")
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                // Draggable Vertical & Horizontal Scrollbars
                scrollBars(proxy: proxy, frames: frames)
            }
            .onChange(of: cards) { _, newCards in
                layoutResult = TreeLayout.layout(cards: newCards)
            }
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.delete) {
                if let id = selectedCardID {
                    onDeleteCard?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return) {
                if let id = selectedCardID {
                    onNewSibling?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                if let id = selectedCardID {
                    onNewChild?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.space) {
                if let id = selectedCardID, let card = cards.first(where: { $0.id == id }) {
                    onEditCard?(card)
                    return .handled
                }
                return .ignored
            }
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

    private var canvasBackgroundView: some View {
        MarginNoteTheme.canvasBackground
            .ignoresSafeArea()
            .background(
                ScrollWheelCatcherView(
                    onScroll: { dx, dy in
                        viewport.panOffset = CGPoint(
                            x: viewport.panOffset.x + dx,
                            y: viewport.panOffset.y + dy
                        )
                    },
                    onZoom: { factor, center in
                        viewport.zoom(by: factor, around: center)
                    }
                )
            )
            .onHover { hovering in
                isHoveringScrollbars = hovering
            }
    }

    @ViewBuilder
    private func cardsView(visibleCards: [NoteCard], frames: [UUID: CGRect], canvasSize: CGSize) -> some View {
        let visibleCanvasRect = CGRect(
            x: -viewport.panOffset.x / viewport.zoomScale,
            y: -viewport.panOffset.y / viewport.zoomScale,
            width: canvasSize.width / viewport.zoomScale,
            height: canvasSize.height / viewport.zoomScale
        ).insetBy(dx: -150, dy: -150)

        let culledCards = visibleCards.filter { card in
            if card.id == selectedCardID { return true }
            guard let frame = frames[card.id] else { return false }
            return frame.intersects(visibleCanvasRect)
        }

        ForEach(culledCards, id: \.id) { card in
            if let frame = frames[card.id] {
                let isCardSelected = selectedCardID == card.id
                let extraHeight: CGFloat = isCardSelected ? 28 : 0
                CardNodeView(
                    card: card,
                    isSelected: isCardSelected,
                    hasChildren: cards.contains(where: { $0.groupNoteId == card.id }),
                    mediaStorage: mediaStorage,
                    onSelect: {
                        print("[MindMap] CardNodeView onSelect: \(card.title)")
                        onSelect(card)
                    },
                    onToggleFold: { onToggleFold(card.id, !card.isFolded) },
                    onEdit: { onEditCard?(card) },
                    onComment: { onEditCard?(card) },
                    onLink: {},
                    onMerge: {},
                    onBranchStyle: {
                        onChangeColor?(card.id, (card.colorIndex + 1) % 6)
                    }
                )
                .frame(width: frame.width, height: frame.height + extraHeight)
                .scaleEffect(viewport.zoomScale)
                .frame(width: frame.width * viewport.zoomScale, height: (frame.height + extraHeight) * viewport.zoomScale)
                .contentShape(RoundedRectangle(cornerRadius: 7 * viewport.zoomScale))
                .gesture(nodeDrag(card: card, frame: frame, frames: frames))
                .position(
                    x: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY + extraHeight / 2)).x,
                    y: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY + extraHeight / 2)).y
                )
            }
        }
    }

    private var bottomLeftControls: some View {
        VStack(spacing: 8) {
            Button {
                canvasMode = "Drag"
            } label: {
                Text("Drag")
                    .font(.system(size: 11, weight: canvasMode == "Drag" ? .bold : .regular))
                    .foregroundStyle(canvasMode == "Drag" ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(white: 0.98).opacity(0.95))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .overlay(
                                Circle()
                                    .stroke(canvasMode == "Drag" ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.35) : Color.black.opacity(0.08), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .allowsHitTesting(true)
            .help("Pan / Drag Canvas")

            Button {
                canvasMode = "Select"
            } label: {
                Text("Select")
                    .font(.system(size: 11, weight: canvasMode == "Select" ? .bold : .regular))
                    .foregroundStyle(canvasMode == "Select" ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(white: 0.98).opacity(0.95))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .overlay(
                                Circle()
                                    .stroke(canvasMode == "Select" ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.35) : Color.black.opacity(0.08), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .allowsHitTesting(true)
            .help("Multi-Select Cards")
        }
        .padding(.leading, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private var mainMindMapHeader: some View {
        Menu {
            Button {
                if let selectedTopic {
                    onSelectTopic?(selectedTopic)
                }
            } label: {
                Label("Main MindMap", systemImage: "checkmark")
            }
            Divider()
            if let onNewTopic {
                Button("New MindMap Layer…") {
                    onNewTopic()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Main MindMap")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.98).opacity(0.92))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .allowsHitTesting(true)
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
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 3 {
                    let canvasDelta = CGPoint(
                        x: value.translation.width / viewport.zoomScale,
                        y: value.translation.height / viewport.zoomScale
                    )
                    dragLocations[card.id] = CGPoint(
                        x: frame.minX + canvasDelta.x,
                        y: frame.minY + canvasDelta.y
                    )
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                print("[MindMap] nodeDrag onEnded: card=\(card.title) distance=\(distance)")
                if distance <= 3 {
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
                    dragLocations[card.id] = nil
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

    @ViewBuilder
    private func scrollBars(proxy: GeometryProxy, frames: [UUID: CGRect]) -> some View {
        let allCardFrames = Array(frames.values)
        if !allCardFrames.isEmpty {
            let cardsBounds = allCardFrames.dropFirst().reduce(allCardFrames[0]) { $0.union($1) }.insetBy(dx: -120, dy: -120)
            let visibleOrigin = viewport.screenToCanvas(.zero)
            let visibleEnd = viewport.screenToCanvas(CGPoint(x: proxy.size.width, y: proxy.size.height))
            let visibleRect = CGRect(
                x: min(visibleOrigin.x, visibleEnd.x),
                y: min(visibleOrigin.y, visibleEnd.y),
                width: max(1, abs(visibleEnd.x - visibleOrigin.x)),
                height: max(1, abs(visibleEnd.y - visibleOrigin.y))
            )
            let domain = cardsBounds.union(visibleRect)

            // Vertical Scrollbar
            let trackHeight = max(50, proxy.size.height - 140)
            let visibleRatioY = min(1.0, max(0.08, visibleRect.height / max(1, domain.height)))
            let thumbHeight = max(24, trackHeight * visibleRatioY)
            let scrollableRangeY = max(1, domain.height - visibleRect.height)
            let currentProgressY = max(0.0, min(1.0, (visibleRect.minY - domain.minY) / scrollableRangeY))
            let thumbY = currentProgressY * (trackHeight - thumbHeight)

            let vScrollGesture = DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDraggingVScroll {
                        isDraggingVScroll = true
                        vScrollStartPanY = viewport.panOffset.y
                    }
                    let deltaFraction = value.translation.height / max(1, trackHeight - thumbHeight)
                    let deltaCanvasY = deltaFraction * scrollableRangeY
                    viewport.panOffset.y = vScrollStartPanY - deltaCanvasY * viewport.zoomScale
                }
                .onEnded { _ in
                    isDraggingVScroll = false
                }

            ZStack(alignment: .top) {
                // Track
                Capsule()
                    .fill(Color.black.opacity(isHoveringScrollbars || isDraggingVScroll ? 0.08 : 0.03))
                    .frame(width: 6, height: trackHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let targetProgress = max(0.0, min(1.0, (loc.y - thumbHeight / 2) / max(1, trackHeight - thumbHeight)))
                        let targetMinY = domain.minY + targetProgress * scrollableRangeY
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewport.panOffset.y = -targetMinY * viewport.zoomScale
                        }
                    }

                // Thumb
                Capsule()
                    .fill(Color.black.opacity(isDraggingVScroll ? 0.55 : (isHoveringScrollbars ? 0.38 : 0.22)))
                    .frame(width: 6, height: thumbHeight)
                    .offset(y: thumbY)
                    .highPriorityGesture(vScrollGesture)
            }
            .frame(width: 12, height: trackHeight)
            .position(x: proxy.size.width - 10, y: 16 + trackHeight / 2)

            // Horizontal Scrollbar
            let trackWidth = max(50, proxy.size.width - 250)
            let visibleRatioX = min(1.0, max(0.08, visibleRect.width / max(1, domain.width)))
            let thumbWidth = max(24, trackWidth * visibleRatioX)
            let scrollableRangeX = max(1, domain.width - visibleRect.width)
            let currentProgressX = max(0.0, min(1.0, (visibleRect.minX - domain.minX) / scrollableRangeX))
            let thumbX = currentProgressX * (trackWidth - thumbWidth)

            let hScrollGesture = DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDraggingHScroll {
                        isDraggingHScroll = true
                        hScrollStartPanX = viewport.panOffset.x
                    }
                    let deltaFraction = value.translation.width / max(1, trackWidth - thumbWidth)
                    let deltaCanvasX = deltaFraction * scrollableRangeX
                    viewport.panOffset.x = hScrollStartPanX - deltaCanvasX * viewport.zoomScale
                }
                .onEnded { _ in
                    isDraggingHScroll = false
                }

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.black.opacity(isHoveringScrollbars || isDraggingHScroll ? 0.08 : 0.03))
                    .frame(width: trackWidth, height: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let targetProgress = max(0.0, min(1.0, (loc.x - thumbWidth / 2) / max(1, trackWidth - thumbWidth)))
                        let targetMinX = domain.minX + targetProgress * scrollableRangeX
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewport.panOffset.x = -targetMinX * viewport.zoomScale
                        }
                    }

                // Thumb
                Capsule()
                    .fill(Color.black.opacity(isDraggingHScroll ? 0.55 : (isHoveringScrollbars ? 0.38 : 0.22)))
                    .frame(width: thumbWidth, height: 6)
                    .offset(x: thumbX)
                    .highPriorityGesture(hScrollGesture)
            }
            .frame(width: trackWidth, height: 12)
            .position(x: 84 + trackWidth / 2, y: proxy.size.height - 10)
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
    let cards: [NoteCard]
    let frames: [UUID: CGRect]
    @Binding var viewport: CanvasViewport
    let canvasSize: CGSize
    var onClose: (() -> Void)? = nil

    var body: some View {
        let allFrames = Array(frames.values)
        Canvas { context, size in
            guard let first = allFrames.first else { return }
            let bounds = allFrames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -40, dy: -40)
            let sx = size.width / max(1, bounds.width)
            let sy = size.height / max(1, bounds.height)
            let scale = min(sx, sy)

            let contentWidth = bounds.width * scale
            let contentHeight = bounds.height * scale
            let offsetX = (size.width - contentWidth) / 2.0
            let offsetY = (size.height - contentHeight) / 2.0

            let cardColorsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, NSColor(MarginNoteTheme.cardColors(for: $0.colorIndex).accent)) })

            for (cardID, frame) in frames {
                let rect = CGRect(
                    x: offsetX + (frame.minX - bounds.minX) * scale,
                    y: offsetY + (frame.minY - bounds.minY) * scale,
                    width: max(2, frame.width * scale),
                    height: max(2, frame.height * scale)
                )
                let accent = cardColorsByID[cardID].map { Color(nsColor: $0) } ?? Color(red: 0.65, green: 0.60, blue: 0.52)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(accent.opacity(0.8)))
            }

            let visibleOrigin = viewport.screenToCanvas(.zero)
            let visibleEnd = viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
            let visible = CGRect(
                x: offsetX + (visibleOrigin.x - bounds.minX) * scale,
                y: offsetY + (visibleOrigin.y - bounds.minY) * scale,
                width: (visibleEnd.x - visibleOrigin.x) * scale,
                height: (visibleEnd.y - visibleOrigin.y) * scale
            )
            context.fill(Path(visible), with: .color(Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12)))
            context.stroke(Path(visible), with: .color(Color(red: 0.15, green: 0.45, blue: 0.85)), lineWidth: 1.5)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.96).opacity(0.88))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.80, green: 0.76, blue: 0.70), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(white: 0.45))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Hide Overview Window")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard let first = allFrames.first else { return }
                    let bounds = allFrames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -40, dy: -40)
                    let sx = 150.0 / max(1, bounds.width)
                    let sy = 100.0 / max(1, bounds.height)
                    let scale = min(sx, sy)
                    guard scale > 0 else { return }

                    let contentWidth = bounds.width * scale
                    let contentHeight = bounds.height * scale
                    let offsetX = (150.0 - contentWidth) / 2.0
                    let offsetY = (100.0 - contentHeight) / 2.0

                    let canvasX = bounds.minX + (gesture.location.x - offsetX) / scale
                    let canvasY = bounds.minY + (gesture.location.y - offsetY) / scale
                    viewport.panOffset = CGPoint(
                        x: canvasSize.width / 2 - canvasX * viewport.zoomScale,
                        y: canvasSize.height / 2 - canvasY * viewport.zoomScale
                    )
                }
        )
    }
}

private struct ScrollWheelCatcherView: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat) -> Void
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    func makeNSView(context: Context) -> ScrollMonitorNSView {
        let view = ScrollMonitorNSView()
        view.onScroll = onScroll
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ScrollMonitorNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onZoom = onZoom
    }

    final class ScrollMonitorNSView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.focusRingType = .none
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.focusRingType = .none
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                if monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                        guard let self = self, let window = self.window, event.window == window else {
                            return event
                        }
                        let pointInView = self.convert(event.locationInWindow, from: nil)
                        if self.bounds.contains(pointInView) {
                            if event.modifierFlags.contains(.command) {
                                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                                if abs(dy) > 0.001 {
                                    let factor = 1.0 + dy * 0.008
                                    self.onZoom?(factor, pointInView)
                                    return nil
                                }
                            } else {
                                let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
                                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                                if abs(dx) > 0.001 || abs(dy) > 0.001 {
                                    self.onScroll?(dx, dy)
                                    return nil
                                }
                            }
                        }
                        return event
                    }
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}
