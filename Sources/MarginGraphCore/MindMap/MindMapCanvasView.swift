import SwiftUI
import CoreGraphics

public enum MindMapSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case title = "Title"
    case content = "Content"

    public var id: String { rawValue }
}

public enum MindMapSearchMatcher {
    public static func matches(card: NoteCard, query: String, scope: MindMapSearchScope = .all) -> Bool {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return true }

        let inTitle = card.title.localizedCaseInsensitiveContains(clean)
            || (card.title.isEmpty && card.highlightText.localizedCaseInsensitiveContains(clean))

        let inNotes = card.notesText.localizedCaseInsensitiveContains(clean)
        let inHighlight = card.highlightText.localizedCaseInsensitiveContains(clean)
        let inSegments = card.excerptSegments.contains { $0.text.localizedCaseInsensitiveContains(clean) }
        let inTags = card.tags.contains { $0.localizedCaseInsensitiveContains(clean) }
        let inContent = inNotes || inHighlight || inSegments || inTags

        switch scope {
        case .all:
            return inTitle || inContent
        case .title:
            return inTitle
        case .content:
            return inContent
        }
    }
}

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
    public var onMoveBatch: (([(id: UUID, position: CGPoint)]) -> Void)?
    public var onReparent: (UUID, UUID?) -> Void
    public var onToggleFold: (UUID, Bool) -> Void
    public var onChangeColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onEditCard: ((NoteCard) -> Void)?
    public var onNewSibling: ((UUID) -> Void)?
    public var onNewChild: ((UUID) -> Void)?
    public var onNewNote: ((CGPoint) -> Void)?
    public var onUpdateTitle: ((UUID, String) -> Void)?
    public var onAddToDeck: ((NoteCard) -> Void)?
    public var initialPanOffset: CGPoint?
    public var initialZoomScale: CGFloat?
    public var onViewportChanged: ((CGPoint, CGFloat) -> Void)?
    @Binding public var editingCardTitleID: UUID?
    public var searchQuery: String
    public var searchScope: MindMapSearchScope
    public var currentSearchMatchID: UUID?
    public var isSearchActive: Bool

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
    @State private var draggingCardID: UUID? = nil
    @State private var hoverTargetCardID: UUID? = nil
    @State private var layoutResult: TreeLayoutResult
    @State private var hasInitialFitted = false
    @State private var lastHoverLocation: CGPoint? = nil
    @State private var viewportDebounceWorkItem: DispatchWorkItem? = nil
    @Binding public var cardIDToCenter: UUID?

    public init(
        cards: [NoteCard],
        links: [CardLink] = [],
        selectedCardID: UUID? = nil,
        cardIDToCenter: Binding<UUID?> = .constant(nil),
        editingCardTitleID: Binding<UUID?> = .constant(nil),
        initialPanOffset: CGPoint? = nil,
        initialZoomScale: CGFloat? = nil,
        onViewportChanged: ((CGPoint, CGFloat) -> Void)? = nil,
        activeToolbarOwner: ToolbarOwner = .none,
        mediaStorage: MediaStorage? = nil,
        topics: [Topic] = [],
        selectedTopic: Topic? = nil,
        onSelectTopic: ((Topic) -> Void)? = nil,
        onNewTopic: (() -> Void)? = nil,
        onSelect: @escaping (NoteCard?) -> Void,
        onMove: @escaping (UUID, CGPoint) -> Void,
        onMoveBatch: (([(id: UUID, position: CGPoint)]) -> Void)? = nil,
        onReparent: @escaping (UUID, UUID?) -> Void,
        onToggleFold: @escaping (UUID, Bool) -> Void,
        onChangeColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onEditCard: ((NoteCard) -> Void)? = nil,
        onNewSibling: ((UUID) -> Void)? = nil,
        onNewChild: ((UUID) -> Void)? = nil,
        onNewNote: ((CGPoint) -> Void)? = nil,
        onUpdateTitle: ((UUID, String) -> Void)? = nil,
        onAddToDeck: ((NoteCard) -> Void)? = nil,
        searchQuery: String = "",
        searchScope: MindMapSearchScope = .all,
        currentSearchMatchID: UUID? = nil,
        isSearchActive: Bool = false
    ) {
        self.cards = cards
        self.links = links
        self.selectedCardID = selectedCardID
        self._cardIDToCenter = cardIDToCenter
        self._editingCardTitleID = editingCardTitleID
        self.initialPanOffset = initialPanOffset
        self.initialZoomScale = initialZoomScale
        self.onViewportChanged = onViewportChanged
        self.activeToolbarOwner = activeToolbarOwner
        self.mediaStorage = mediaStorage
        self.topics = topics
        self.selectedTopic = selectedTopic
        self.onSelectTopic = onSelectTopic
        self.onNewTopic = onNewTopic
        self.onSelect = onSelect
        self.onMove = onMove
        self.onMoveBatch = onMoveBatch
        self.onReparent = onReparent
        self.onToggleFold = onToggleFold
        self.onChangeColor = onChangeColor
        self.onDeleteCard = onDeleteCard
        self.onEditCard = onEditCard
        self.onNewSibling = onNewSibling
        self.onNewChild = onNewChild
        self.onNewNote = onNewNote
        self.onUpdateTitle = onUpdateTitle
        self.onAddToDeck = onAddToDeck
        self.searchQuery = searchQuery
        self.searchScope = searchScope
        self.currentSearchMatchID = currentSearchMatchID
        self.isSearchActive = isSearchActive
        self._layoutResult = State(initialValue: TreeLayout.layout(cards: cards))
    }

    public static func matchesSearch(card: NoteCard, query: String, scope: MindMapSearchScope = .all) -> Bool {
        MindMapSearchMatcher.matches(card: card, query: query, scope: scope)
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = layoutResult
            let frames = displayFrames(layout: layout)
            let visibleCards = cards.filter { layout.visibleCardIDs.contains($0.id) }

            canvasZStack(proxy: proxy, layout: layout, frames: frames, visibleCards: visibleCards)
                .coordinateSpace(name: "MindMapCanvas")
                .onChange(of: cards) { _, newCards in
                    let oldFrames = layoutResult.frames
                    layoutResult = TreeLayout.layout(cards: newCards)
                    if viewport.viewportSize.width < 50 && proxy.size.width > 50 {
                        viewport.viewportSize = proxy.size
                    }
                    if let selectedID = cardIDToCenter ?? selectedCardID, let frame = layoutResult.frames[selectedID] {
                        let oldOrigin = oldFrames[selectedID]?.origin
                        let didMove = oldOrigin != nil && (abs(oldOrigin!.x - frame.origin.x) > 1.0 || abs(oldOrigin!.y - frame.origin.y) > 1.0)
                        if didMove || cardIDToCenter == selectedID {
                            cardIDToCenter = nil
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewport.center(on: frame)
                            }
                        } else {
                            let screenOrigin = viewport.canvasToScreen(CGPoint(x: frame.minX, y: frame.minY))
                            let screenRect = CGRect(origin: screenOrigin, size: CGSize(width: frame.width * viewport.zoomScale, height: frame.height * viewport.zoomScale))
                            let viewRect = CGRect(origin: .zero, size: viewport.viewportSize)
                            if viewport.viewportSize.width > 50, !viewRect.insetBy(dx: 40, dy: 40).contains(screenRect) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    viewport.center(on: frame)
                                }
                            }
                        }
                    }
                }
                .clipped()
                .focusable()
                .focusEffectDisabled()
                .modifier(MindMapKeyboardHandler(
                    selectedCardID: selectedCardID,
                    isEditingTitle: editingCardTitleID != nil,
                    cards: cards,
                    frames: frames,
                    visibleCardIDs: layout.visibleCardIDs,
                    visibleCards: visibleCards,
                    onDeleteCard: onDeleteCard,
                    onNewSibling: onNewSibling,
                    onNewChild: onNewChild,
                    onEditCard: onEditCard,
                    onSelect: onSelect,
                    viewport: $viewport
                ))
                .onAppear {
                    if proxy.size.width > 20 && proxy.size.height > 20 {
                        viewport.viewportSize = proxy.size
                    }
                    if let targetID = cardIDToCenter, let frame = frames[targetID] {
                        viewport.center(on: frame)
                        hasInitialFitted = true
                        cardIDToCenter = nil
                    } else if let savedPan = initialPanOffset, let savedZoom = initialZoomScale {
                        viewport.panOffset = savedPan
                        viewport.zoomScale = savedZoom
                        hasInitialFitted = true
                    } else if let targetID = selectedCardID, let frame = frames[targetID] {
                        viewport.center(on: frame)
                        hasInitialFitted = true
                    } else if !hasInitialFitted && !cards.isEmpty {
                        viewport.zoomToFit(nodes: Array(frames.values))
                        hasInitialFitted = true
                    }
                }
                .onChange(of: proxy.size) { _, size in
                    guard size.width > 20 && size.height > 20 else { return }
                    viewport.viewportSize = size
                    if let targetID = cardIDToCenter, let frame = frames[targetID] {
                        viewport.center(on: frame)
                        cardIDToCenter = nil
                    }
                }
                .onChange(of: cardIDToCenter) { _, newID in
                    guard let newID else { return }
                    if let frame = frames[newID] {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewport.center(on: frame)
                        }
                        cardIDToCenter = nil
                    }
                }
                .onChange(of: selectedTopic?.id) { _, _ in
                    if let targetID = cardIDToCenter, let frame = frames[targetID] {
                        viewport.center(on: frame)
                        hasInitialFitted = true
                        cardIDToCenter = nil
                    } else if let savedPan = initialPanOffset, let savedZoom = initialZoomScale {
                        viewport.panOffset = savedPan
                        viewport.zoomScale = savedZoom
                        hasInitialFitted = true
                    } else {
                        hasInitialFitted = false
                        if !cards.isEmpty {
                            viewport.zoomToFit(nodes: Array(frames.values))
                            hasInitialFitted = true
                        }
                    }
                }
                .onChange(of: initialPanOffset) { _, newPan in
                    if let newPan, let newZoom = initialZoomScale {
                        viewport.panOffset = newPan
                        viewport.zoomScale = newZoom
                        hasInitialFitted = true
                    }
                }
                .onChange(of: viewport.panOffset) { _, newPan in
                    if hasInitialFitted {
                        scheduleViewportChange(pan: newPan, zoom: viewport.zoomScale)
                    }
                }
                .onChange(of: viewport.zoomScale) { _, newZoom in
                    if hasInitialFitted {
                        scheduleViewportChange(pan: viewport.panOffset, zoom: newZoom)
                    }
                }
                .onDisappear {
                    viewportDebounceWorkItem?.perform()
                    viewportDebounceWorkItem = nil
                }
                .onChange(of: selectedCardID) { _, newID in
                    if let newID, let frame = frames[newID] {
                        let screenOrigin = viewport.canvasToScreen(CGPoint(x: frame.minX, y: frame.minY))
                        let screenRect = CGRect(origin: screenOrigin, size: CGSize(width: frame.width * viewport.zoomScale, height: frame.height * viewport.zoomScale))
                        let viewRect = CGRect(origin: .zero, size: viewport.viewportSize)
                        if viewport.viewportSize.width > 50, !viewRect.insetBy(dx: 40, dy: 40).contains(screenRect) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewport.center(on: frame)
                            }
                        }
                    }
                }
                .simultaneousGesture(magnifyGesture(proxy: proxy))
                .onReceive(NotificationCenter.default.publisher(for: .marginGraphZoomIn)) { _ in
                    withAnimation(.easeOut(duration: 0.10)) {
                        viewport.zoomIn(factor: 1.20)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .marginGraphZoomOut)) { _ in
                    withAnimation(.easeOut(duration: 0.10)) {
                        viewport.zoomOut(factor: 1.20)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .marginGraphZoomReset)) { _ in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewport.resetZoom()
                    }
                }
        }
    }

    private func scheduleViewportChange(pan: CGPoint, zoom: CGFloat) {
        viewportDebounceWorkItem?.cancel()
        let item = DispatchWorkItem {
            onViewportChanged?(pan, zoom)
        }
        viewportDebounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
    }

    private func magnifyGesture(proxy: GeometryProxy) -> some Gesture {
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
    }

    @ViewBuilder
    private func canvasZStack(
        proxy: GeometryProxy,
        layout: TreeLayoutResult,
        frames: [UUID: CGRect],
        visibleCards: [NoteCard]
    ) -> some View {
        ZStack(alignment: .topLeading) {
            canvasBackgroundView

            // Subtle grid with pan and deselect
            grid
                .contentShape(Rectangle())
                .gesture(panGesture, including: editingCardTitleID == nil ? .all : .none)
                .gesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .named("MindMapCanvas"))
                        .onEnded { event in
                            let canvasPoint = viewport.screenToCanvas(event.location)
                            onNewNote?(canvasPoint)
                        }
                        .exclusively(before:
                            SpatialTapGesture(count: 1, coordinateSpace: .named("MindMapCanvas"))
                                .onEnded { _ in
                                    onSelect(nil)
                                    editingCardTitleID = nil
                                }
                        )
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        lastHoverLocation = loc
                    case .ended:
                        break
                    }
                }
                .contextMenu {
                    Button {
                        let loc = lastHoverLocation ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        let canvasPoint = viewport.screenToCanvas(loc)
                        onNewNote?(canvasPoint)
                    } label: {
                        Label("New Note", systemImage: "plus.rectangle")
                    }
                }

            // Tree connectors and links
            Canvas { context, _ in
                drawConnectors(context: &context, frames: frames, visible: layout.visibleCardIDs)
            }
            .allowsHitTesting(false)

            // Note Cards with Viewport Culling
            cardsView(visibleCards: visibleCards, frames: frames, staticFrames: layout.frames, canvasSize: proxy.size)

            // Dedicated MindMap Card Floating Toolbar
            if activeToolbarOwner == .mindMap,
               draggingCardID == nil,
               let selectedID = selectedCardID,
               let card = cards.first(where: { $0.id == selectedID }),
               let cardFrame = frames[card.id] {
                let toolbarWidth: CGFloat = 410
                let toolbarHeight: CGFloat = 34
                let screenMinX = cardFrame.minX * viewport.zoomScale + viewport.panOffset.x
                let screenMinY = cardFrame.minY * viewport.zoomScale + viewport.panOffset.y
                let screenW = cardFrame.width * viewport.zoomScale
                let screenH = (cardFrame.height + 28) * viewport.zoomScale
                let idealX = screenMinX + (screenW - toolbarWidth) / 2
                let clampedX = max(12, min(idealX, proxy.size.width - toolbarWidth - 12))
                let idealY = (screenMinY - toolbarHeight - 8 >= 48)
                    ? (screenMinY - toolbarHeight - 8)
                    : (screenMinY + screenH + 8)
                let clampedY = max(48, min(idealY, proxy.size.height - toolbarHeight - 12))

                mindMapCardToolbar(card: card)
                    .frame(width: toolbarWidth, height: toolbarHeight)
                    .offset(x: clampedX, y: clampedY)
                    .zIndex(180)
            }

            // Main MindMap Floating Header (MarginNote 3 signature)
            HStack {
                Spacer()
                mainMindMapHeader
                Spacer()
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .zIndex(150)

            // Bottom-left Mode Toggles (MarginNote 3 signature Drag & Select stacked buttons)
            bottomLeftControls
                .zIndex(150)

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
                .zIndex(150)
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
                .zIndex(150)
            }

            // Draggable Vertical & Horizontal Scrollbars
            scrollBars(proxy: proxy, frames: frames)
                .zIndex(160)
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
    private func cardsView(visibleCards: [NoteCard], frames: [UUID: CGRect], staticFrames: [UUID: CGRect], canvasSize: CGSize) -> some View {
        let visibleCanvasRect = CGRect(
            x: -viewport.panOffset.x / viewport.zoomScale,
            y: -viewport.panOffset.y / viewport.zoomScale,
            width: canvasSize.width / viewport.zoomScale,
            height: canvasSize.height / viewport.zoomScale
        ).insetBy(dx: -150, dy: -150)

        let culledCards = visibleCards.filter { card in
            if card.id == selectedCardID || card.id == draggingCardID || card.id == hoverTargetCardID || card.id == editingCardTitleID { return true }
            guard let frame = frames[card.id] else { return false }
            return frame.intersects(visibleCanvasRect)
        }

        let isSearching = isSearchActive && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        ForEach(culledCards, id: \.id) { card in
            if let frame = frames[card.id] {
                let isCardSelected = selectedCardID == card.id
                let isTargeted = hoverTargetCardID == card.id
                let isBeingDragged = draggingCardID == card.id
                let extraHeight: CGFloat = isCardSelected ? 28 : 0
                let isMatch = isSearching ? MindMapSearchMatcher.matches(card: card, query: searchQuery, scope: searchScope) : true
                let isCurrentMatch = isSearching && (currentSearchMatchID == card.id)
                CardNodeView(
                    card: card,
                    isSelected: isCardSelected,
                    hasChildren: cards.contains(where: { $0.groupNoteId == card.id }),
                    mediaStorage: mediaStorage,
                    isEditingTitle: editingCardTitleID == card.id,
                    onSelect: {
                        print("[MindMap] CardNodeView onSelect: \(card.title)")
                        if editingCardTitleID != card.id {
                            editingCardTitleID = nil
                        }
                        onSelect(card)
                    },
                    onToggleFold: { onToggleFold(card.id, !card.isFolded) },
                    onEdit: { onEditCard?(card) },
                    onStartEditTitle: {
                        editingCardTitleID = card.id
                        if selectedCardID != card.id {
                            onSelect(card)
                        }
                    },
                    onCommitTitle: { newTitle in
                        onUpdateTitle?(card.id, newTitle)
                        editingCardTitleID = nil
                    },
                    onComment: { onEditCard?(card) },
                    onLink: {},
                    onMerge: {},
                    onBranchStyle: {
                        onChangeColor?(card.id, (card.colorIndex + 1) % 6)
                    },
                    onChangeColor: { newColor in
                        onChangeColor?(card.id, newColor)
                    },
                    onDelete: {
                        onDeleteCard?(card.id)
                    },
                    onNewSibling: onNewSibling != nil ? { onNewSibling?(card.id) } : nil,
                    onNewChild: onNewChild != nil ? { onNewChild?(card.id) } : nil,
                    onAddToDeck: { onAddToDeck?(card) }
                )
                .frame(width: frame.width, height: frame.height + extraHeight)
                .overlay {
                    if isCurrentMatch {
                        // Striking gold/amber selection ring for the active search match
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 0.95, green: 0.55, blue: 0.10), lineWidth: 3.5)
                            .shadow(color: Color.orange.opacity(0.6), radius: 5)
                    } else if isSearching && isMatch {
                        // Blue highlight ring for all matching cards
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 0.15, green: 0.50, blue: 0.95), lineWidth: 2.2)
                    } else if isTargeted {
                        // Bright blue selection border on target card (MarginNote 3 style)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 0.05, green: 0.35, blue: 1.0), lineWidth: 3.2)
                    }
                }
                .opacity(isBeingDragged ? 0.78 : (isSearching ? (isMatch ? 1.0 : 0.28) : 1.0))
                .shadow(color: isBeingDragged ? Color.black.opacity(0.25) : Color.clear, radius: 10, y: 5)
                .scaleEffect(viewport.zoomScale)
                .frame(width: frame.width * viewport.zoomScale, height: (frame.height + extraHeight) * viewport.zoomScale)
                .zIndex(isBeingDragged || editingCardTitleID == card.id ? 100 : (isCurrentMatch ? 90 : (isCardSelected ? 60 : (isTargeted ? 50 : 1))))
                .contentShape(RoundedRectangle(cornerRadius: 7 * viewport.zoomScale))
                .gesture(
                    nodeDrag(card: card, initialFrame: staticFrames[card.id] ?? frame, staticFrames: staticFrames),
                    including: editingCardTitleID == nil ? .all : .none
                )
                .contextMenu {
                    cardContextMenu(for: card)
                }
                .position(
                    x: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY + extraHeight / 2)).x,
                    y: viewport.canvasToScreen(CGPoint(x: frame.midX, y: frame.midY + extraHeight / 2)).y
                )
            }
        }

        // MarginNote 3 Branch Fold/Unfold circular toggle buttons
        ForEach(culledCards, id: \.id) { card in
            if let frame = frames[card.id] {
                let hasChildren = cards.contains(where: { $0.groupNoteId == card.id })
                if hasChildren {
                    branchFoldButton(card: card, frame: frame)
                }
            }
        }

        // Red "Become child" floating banner (MarginNote 3 signature)
        if let targetID = hoverTargetCardID,
           let targetFrame = frames[targetID] {
            let targetCenter = viewport.canvasToScreen(CGPoint(x: targetFrame.midX, y: targetFrame.midY))
            Text("Become child")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color(red: 0.95, green: 0.20, blue: 0.20))
                        .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)
                )
                .scaleEffect(viewport.zoomScale)
                .frame(width: 140, height: 32)
                .offset(x: targetCenter.x - 70, y: targetCenter.y - 16)
                .zIndex(200)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func branchFoldButton(card: NoteCard, frame: CGRect) -> some View {
        let accentColor = MarginNoteTheme.cardColors(for: card.colorIndex).accent
        let isFolded = card.isFolded
        let buttonDiameter: CGFloat = max(13.0, 15.0 * viewport.zoomScale)
        let hitSize: CGFloat = max(26.0, buttonDiameter + 10.0)
        let screenCenter = viewport.canvasToScreen(CGPoint(x: frame.maxX + 14, y: frame.midY))

        Button {
            onToggleFold(card.id, !isFolded)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: buttonDiameter, height: buttonDiameter)
                Circle()
                    .stroke(accentColor, lineWidth: max(1.2, 1.5 * viewport.zoomScale))
                    .frame(width: buttonDiameter, height: buttonDiameter)

                // Minus "-" horizontal line
                Rectangle()
                    .fill(accentColor)
                    .frame(width: max(5.0, 7.0 * viewport.zoomScale), height: max(1.2, 1.5 * viewport.zoomScale))

                // Plus "+" vertical line if folded
                if isFolded {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: max(1.2, 1.5 * viewport.zoomScale), height: max(5.0, 7.0 * viewport.zoomScale))
                }
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitSize, height: hitSize)
        .offset(x: screenCenter.x - hitSize / 2, y: screenCenter.y - hitSize / 2)
        .zIndex(130)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .marginNoteTooltip(isFolded ? "Expand Branch" : "Collapse Branch")
    }

    @ViewBuilder
    private func cardContextMenu(for card: NoteCard) -> some View {
        Button("Edit Title") {
            editingCardTitleID = card.id
            onSelect(card)
        }
        Button("Edit Details…") {
            onEditCard?(card)
        }
        Button("Add to Review Deck…") {
            onAddToDeck?(card)
        }
        Divider()
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.title, forType: .string)
        }
        Button("Copy Note Content") {
            NSPasteboard.general.clearContents()
            let content = !card.highlightText.isEmpty ? card.highlightText : (!card.notesText.isEmpty ? card.notesText : card.title)
            NSPasteboard.general.setString(content, forType: .string)
        }
        Divider()
        Button("Copy Deep Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.deepLinkURL.absoluteString, forType: .string)
        }
        Divider()
        Menu("Card Color") {
            let colorNames = ["Yellow", "Green", "Blue", "Red", "Purple", "Orange"]
            ForEach(0..<6, id: \.self) { idx in
                Button {
                    onChangeColor?(card.id, idx)
                } label: {
                    let isCurrent = card.colorIndex == idx
                    Text(isCurrent ? "✓ \(colorNames[idx])" : colorNames[idx])
                }
            }
        }
        Divider()
        Button(role: .destructive) {
            onDeleteCard?(card.id)
        } label: {
            Label("Delete Note", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func toolbarSiblingButton(cardID: UUID) -> some View {
        Button {
            onNewSibling?(cardID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Sibling")
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .enlargedHitTarget(width: 68, height: 28)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .marginNoteTooltip("Add Sibling Note (Return)")
    }

    @ViewBuilder
    private func toolbarChildButton(cardID: UUID) -> some View {
        Button {
            onNewChild?(cardID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Child")
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .enlargedHitTarget(width: 58, height: 28)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .marginNoteTooltip("Add Child Note (Tab)")
    }

    @ViewBuilder
    private func toolbarColorPalette(card: NoteCard) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { idx in
                let isSelectedColor = (card.colorIndex == idx)
                let colors = MarginNoteTheme.cardColors(for: idx)
                Button {
                    onChangeColor?(card.id, idx)
                } label: {
                    Circle()
                        .fill(colors.accent)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: isSelectedColor ? 2.2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .enlargedHitTarget(width: 20, height: 28)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .marginNoteTooltip("Change Color")
            }
        }
    }

    @ViewBuilder
    private func toolbarActionButtons(card: NoteCard) -> some View {
        HStack(spacing: 4) {
            Button {
                onEditCard?(card)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .enlargedHitTarget(width: 26, height: 28)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .marginNoteTooltip("Edit Note")

            Button {
                onAddToDeck?(card)
            } label: {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .enlargedHitTarget(width: 26, height: 28)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .marginNoteTooltip("Add to Review Deck")

            Button {
                onDeleteCard?(card.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 0.95, green: 0.40, blue: 0.40))
            }
            .buttonStyle(.plain)
            .enlargedHitTarget(width: 26, height: 28)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .marginNoteTooltip("Delete Note (Delete)")
        }
    }

    @ViewBuilder
    private func mindMapCardToolbar(card: NoteCard) -> some View {
        HStack(spacing: 6) {
            toolbarSiblingButton(cardID: card.id)
            toolbarChildButton(cardID: card.id)

            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.25))
                .padding(.horizontal, 2)

            toolbarColorPalette(card: card)

            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.25))
                .padding(.horizontal, 2)

            toolbarActionButtons(card: card)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(white: 0.17).opacity(0.96))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            if hovering {
                NSCursor.arrow.set()
            }
        }
    }

    private var bottomLeftControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Mode buttons (Drag / Select)
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
                .marginNoteTooltip("Pan / Drag Canvas")

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
                .marginNoteTooltip("Multi-Select Cards")
            }

            // Zoom controls pill
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.10)) {
                        viewport.zoomOut(factor: 1.20)
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MindMapPillButtonStyle())
                .marginNoteTooltip("Zoom Out (⌘-)")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewport.resetZoom()
                    }
                } label: {
                    Text("\(Int(viewport.zoomScale * 100))%")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color(white: 0.30))
                        .frame(width: 36, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MindMapPillButtonStyle())
                .marginNoteTooltip("Reset Zoom (100%)")

                Button {
                    withAnimation(.easeOut(duration: 0.10)) {
                        viewport.zoomIn(factor: 1.20)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MindMapPillButtonStyle())
                .marginNoteTooltip("Zoom In (⌘+)")

                Divider()
                    .frame(height: 12)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewport.zoomToFit(nodes: Array(layoutResult.frames.values))
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MindMapPillButtonStyle())
                .marginNoteTooltip("Zoom to Fit (⌘0)")
            }
            .background(
                Capsule()
                    .fill(Color(white: 0.98).opacity(0.95))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
            )
        }
        .padding(.leading, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
                    .fill(Color(white: 0.99))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
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

    private func nodeDrag(card: NoteCard, initialFrame: CGRect, staticFrames: [UUID: CGRect]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("MindMapCanvas"))
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance >= 4 {
                    draggingCardID = card.id
                    let canvasDelta = CGPoint(
                        x: value.translation.width / viewport.zoomScale,
                        y: value.translation.height / viewport.zoomScale
                    )
                    let currentOrigin = CGPoint(
                        x: initialFrame.minX + canvasDelta.x,
                        y: initialFrame.minY + canvasDelta.y
                    )
                    dragLocations[card.id] = currentOrigin

                    let mouseCanvasPoint = viewport.screenToCanvas(value.location)
                    hoverTargetCardID = findMouseOverlapTarget(draggedID: card.id, mousePoint: mouseCanvasPoint, frames: staticFrames)
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 4 {
                    draggingCardID = nil
                    hoverTargetCardID = nil
                    return
                }

                let finalOrigin = dragLocations[card.id] ?? initialFrame.origin
                let mouseCanvasPoint = viewport.screenToCanvas(value.location)
                let overlapTarget = findMouseOverlapTarget(draggedID: card.id, mousePoint: mouseCanvasPoint, frames: staticFrames)

                if let overlapTarget {
                    // 1. Mouse overlaps another card's area: Become child of target card
                    cardIDToCenter = card.id
                    onReparent(card.id, overlapTarget)
                    onToggleFold(overlapTarget, false)
                    onSelect(card)
                    if let targetFrame = staticFrames[overlapTarget] {
                        let approxFrame = CGRect(x: targetFrame.maxX + 40, y: targetFrame.minY, width: initialFrame.width, height: initialFrame.height)
                        withAnimation(.easeInOut(duration: 0.25)) { viewport.center(on: approxFrame) }
                    }
                } else {
                    // 2. Mouse does NOT overlap other cards: Drop into Column Container Grid
                    let rootCards = cards.filter { $0.groupNoteId == nil }
                    let childrenByParent = Dictionary(grouping: cards.filter { $0.groupNoteId != nil }, by: { $0.groupNoteId! })
                    func subtreeMaxX(_ rootID: UUID, initialMax: CGFloat) -> CGFloat {
                        var maxVal = initialMax
                        var q = [rootID]
                        var visited: Set<UUID> = [rootID]
                        while !q.isEmpty {
                            let p = q.removeFirst()
                            if let kids = childrenByParent[p] {
                                for k in kids where !visited.contains(k.id) {
                                    visited.insert(k.id)
                                    if let kf = staticFrames[k.id] {
                                        maxVal = max(maxVal, kf.maxX)
                                    }
                                    q.append(k.id)
                                }
                            }
                        }
                        return maxVal
                    }

                    var colMap: [(baseX: CGFloat, maxX: CGFloat, cards: [NoteCard])] = []

                    for r in rootCards.sorted(by: { (staticFrames[$0.id]?.minX ?? 0) < (staticFrames[$1.id]?.minX ?? 0) }) {
                        guard let f = staticFrames[r.id] else { continue }
                        let branchMaxX = subtreeMaxX(r.id, initialMax: f.maxX)
                        if let idx = colMap.firstIndex(where: { abs($0.baseX - f.minX) < 140 }) {
                            colMap[idx].cards.append(r)
                            colMap[idx].baseX = min(colMap[idx].baseX, f.minX)
                            colMap[idx].maxX = max(colMap[idx].maxX, branchMaxX)
                        } else {
                            colMap.append((baseX: f.minX, maxX: branchMaxX, cards: [r]))
                        }
                    }
                    colMap.sort(by: { $0.baseX < $1.baseX })

                    let dropCenterX = finalOrigin.x + initialFrame.width / 2.0
                    let dropCenterY = finalOrigin.y + initialFrame.height / 2.0

                    let targetColIdx: Int
                    let targetBaseX: CGFloat

                    if colMap.isEmpty {
                        targetColIdx = 0
                        targetBaseX = 40.0
                    } else if let last = colMap.last, dropCenterX > last.maxX + 40 {
                        // Dragged beyond rightmost column: Create new column!
                        targetColIdx = colMap.count
                        targetBaseX = last.maxX + 80.0
                    } else {
                        var bestIdx = 0
                        var minDiff = CGFloat.greatestFiniteMagnitude
                        for (i, col) in colMap.enumerated() {
                            let colCenterX = col.baseX + initialFrame.width / 2.0
                            let diff = abs(dropCenterX - colCenterX)
                            if diff < minDiff {
                                minDiff = diff
                                bestIdx = i
                            }
                        }
                        targetColIdx = bestIdx
                        targetBaseX = colMap[bestIdx].baseX
                    }

                    // Build ordered list of cards in target column
                    var targetColumnCards: [NoteCard] = []
                    if targetColIdx < colMap.count {
                        targetColumnCards = colMap[targetColIdx].cards.filter { $0.id != card.id }
                        targetColumnCards.sort(by: { (staticFrames[$0.id]?.minY ?? 0) < (staticFrames[$1.id]?.minY ?? 0) })
                    }

                    // Find insertion index in target column
                    var insertIdx = targetColumnCards.count
                    for (i, c) in targetColumnCards.enumerated() {
                        if let f = staticFrames[c.id], dropCenterY < f.midY {
                            insertIdx = i
                            break
                        }
                    }

                    targetColumnCards.insert(card, at: insertIdx)

                    var batchUpdates: [(id: UUID, position: CGPoint)] = []
                    var curY: CGFloat = 40.0
                    for c in targetColumnCards {
                        let cardH = TreeLayout.estimatedCardHeight(for: c, width: 220)
                        batchUpdates.append((id: c.id, position: CGPoint(x: targetBaseX, y: curY)))
                        curY += cardH + 56.0
                    }

                    // If card was moved from another column, re-pack that source column as well
                    if let srcColIdx = colMap.firstIndex(where: { $0.cards.contains(where: { $0.id == card.id }) }),
                       srcColIdx != targetColIdx {
                        let srcBaseX = colMap[srcColIdx].baseX
                        let remainingSrcCards = colMap[srcColIdx].cards.filter { $0.id != card.id }
                            .sorted(by: { (staticFrames[$0.id]?.minY ?? 0) < (staticFrames[$1.id]?.minY ?? 0) })
                        var srcY: CGFloat = 40.0
                        for sc in remainingSrcCards {
                            let scH = TreeLayout.estimatedCardHeight(for: sc, width: 220)
                            batchUpdates.append((id: sc.id, position: CGPoint(x: srcBaseX, y: srcY)))
                            srcY += scH + 56.0
                        }
                    }

                    // If it was a child card, detach it to root
                    if card.groupNoteId != nil {
                        onReparent(card.id, nil)
                    }

                    let targetSlotY = batchUpdates.first(where: { $0.id == card.id })?.position.y ?? curY
                    let cardH = TreeLayout.estimatedCardHeight(for: card, width: 220)
                    let predictedFrame = CGRect(x: targetBaseX, y: targetSlotY, width: 220, height: cardH)

                    cardIDToCenter = card.id
                    if let onMoveBatch, !batchUpdates.isEmpty {
                        onMoveBatch(batchUpdates)
                    } else {
                        onMove(card.id, CGPoint(x: targetBaseX, y: targetSlotY))
                    }
                    onSelect(card)

                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewport.center(on: predictedFrame)
                    }
                }

                dragLocations[card.id] = nil
                draggingCardID = nil
                hoverTargetCardID = nil
            }
    }

    private func findMouseOverlapTarget(draggedID: UUID, mousePoint: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        var descendants = Set<UUID>()
        var queue = [draggedID]
        while !queue.isEmpty {
            let curr = queue.removeFirst()
            for c in cards where c.groupNoteId == curr {
                if descendants.insert(c.id).inserted {
                    queue.append(c.id)
                }
            }
        }

        for other in cards.reversed() where other.id != draggedID && !descendants.contains(other.id) {
            guard layoutResult.visibleCardIDs.contains(other.id),
                  let otherFrame = frames[other.id] else { continue }
            if otherFrame.contains(mousePoint) {
                return other.id
            }
        }
        return nil
    }

    private func drawConnectors(
        context: inout GraphicsContext,
        frames: [UUID: CGRect],
        visible: Set<UUID>
    ) {
        let isSearching = isSearchActive && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        for card in cards where visible.contains(card.id) {
            if let parentID = card.groupNoteId,
               visible.contains(parentID),
               let parent = frames[parentID],
               let child = frames[card.id] {
                var path = Path()
                path.addPath(Path(TreeLayout.connectorPath(from: parent, to: child)))
                let parentCard = cards.first(where: { $0.id == parentID })
                let baseColor = parentCard.map { MarginNoteTheme.cardColors(for: $0.colorIndex).accent } ?? Color(red: 0.70, green: 0.66, blue: 0.58)
                let strokeColor: Color
                if isSearching {
                    let parentMatch = parentCard.map { MindMapSearchMatcher.matches(card: $0, query: searchQuery, scope: searchScope) } ?? false
                    let childMatch = MindMapSearchMatcher.matches(card: card, query: searchQuery, scope: searchScope)
                    strokeColor = (parentMatch || childMatch) ? baseColor : baseColor.opacity(0.18)
                } else {
                    strokeColor = baseColor
                }
                context.stroke(
                    transformed(path),
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
            }
        }

        // Draw short horizontal stem for collapsed cards with children
        for card in cards where visible.contains(card.id) && card.isFolded {
            let hasChildren = cards.contains(where: { $0.groupNoteId == card.id })
            if hasChildren, let parent = frames[card.id] {
                var stem = Path()
                stem.move(to: CGPoint(x: parent.maxX, y: parent.midY))
                stem.addLine(to: CGPoint(x: parent.maxX + 14, y: parent.midY))
                let strokeColor = MarginNoteTheme.cardColors(for: card.colorIndex).accent
                context.stroke(
                    transformed(stem),
                    with: .color(strokeColor),
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

    public enum ArrowDirection: Sendable {
        case up, down, left, right
    }

    nonisolated public static func nextCardID(
        from currentID: UUID,
        direction: ArrowDirection,
        cards: [NoteCard],
        frames: [UUID: CGRect],
        visibleCardIDs: Set<UUID>
    ) -> UUID? {
        guard let currentFrame = frames[currentID],
              let currentCard = cards.first(where: { $0.id == currentID }) else {
            return nil
        }

        let visibleCards = cards.filter { visibleCardIDs.contains($0.id) && frames[$0.id] != nil }

        switch direction {
        case .right:
            let children = visibleCards
                .filter { $0.groupNoteId == currentID }
                .sorted { (frames[$0.id]?.minY ?? 0) < (frames[$1.id]?.minY ?? 0) }
            if let firstChild = children.first {
                return firstChild.id
            }
            let rightCandidates = visibleCards.filter {
                guard let f = frames[$0.id], $0.id != currentID else { return false }
                return f.midX > currentFrame.midX + 20
            }
            return rightCandidates.min(by: { a, b in
                let fa = frames[a.id]!
                let fb = frames[b.id]!
                let distA = (fa.midX - currentFrame.midX) + abs(fa.midY - currentFrame.midY) * 2.0
                let distB = (fb.midX - currentFrame.midX) + abs(fb.midY - currentFrame.midY) * 2.0
                return distA < distB
            })?.id

        case .left:
            if let parentID = currentCard.groupNoteId, visibleCardIDs.contains(parentID) {
                return parentID
            }
            let leftCandidates = visibleCards.filter {
                guard let f = frames[$0.id], $0.id != currentID else { return false }
                return f.midX < currentFrame.midX - 20
            }
            return leftCandidates.min(by: { a, b in
                let fa = frames[a.id]!
                let fb = frames[b.id]!
                let distA = (currentFrame.midX - fa.midX) + abs(fa.midY - currentFrame.midY) * 2.0
                let distB = (currentFrame.midX - fb.midX) + abs(fb.midY - currentFrame.midY) * 2.0
                return distA < distB
            })?.id

        case .down:
            let siblings = visibleCards
                .filter { $0.groupNoteId == currentCard.groupNoteId }
                .sorted { (frames[$0.id]?.midY ?? 0) < (frames[$1.id]?.midY ?? 0) }
            if let idx = siblings.firstIndex(where: { $0.id == currentID }), idx + 1 < siblings.count {
                return siblings[idx + 1].id
            }
            let belowCandidates = visibleCards.filter {
                guard let f = frames[$0.id], $0.id != currentID else { return false }
                return f.midY > currentFrame.midY + 5
            }
            return belowCandidates.min(by: { a, b in
                let fa = frames[a.id]!
                let fb = frames[b.id]!
                let distA = abs(fa.midX - currentFrame.midX) * 1.5 + (fa.midY - currentFrame.midY)
                let distB = abs(fb.midX - currentFrame.midX) * 1.5 + (fb.midY - currentFrame.midY)
                return distA < distB
            })?.id

        case .up:
            let siblings = visibleCards
                .filter { $0.groupNoteId == currentCard.groupNoteId }
                .sorted { (frames[$0.id]?.midY ?? 0) < (frames[$1.id]?.midY ?? 0) }
            if let idx = siblings.firstIndex(where: { $0.id == currentID }), idx > 0 {
                return siblings[idx - 1].id
            }
            let aboveCandidates = visibleCards.filter {
                guard let f = frames[$0.id], $0.id != currentID else { return false }
                return f.midY < currentFrame.midY - 5
            }
            return aboveCandidates.min(by: { a, b in
                let fa = frames[a.id]!
                let fb = frames[b.id]!
                let distA = abs(fa.midX - currentFrame.midX) * 1.5 + (currentFrame.midY - fa.midY)
                let distB = abs(fb.midX - currentFrame.midX) * 1.5 + (currentFrame.midY - fb.midY)
                return distA < distB
            })?.id
        }
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

private struct MindMapKeyboardHandler: ViewModifier {
    let selectedCardID: UUID?
    let isEditingTitle: Bool
    let cards: [NoteCard]
    let frames: [UUID: CGRect]
    let visibleCardIDs: Set<UUID>
    let visibleCards: [NoteCard]
    let onDeleteCard: ((UUID) -> Void)?
    let onNewSibling: ((UUID) -> Void)?
    let onNewChild: ((UUID) -> Void)?
    let onEditCard: ((NoteCard) -> Void)?
    let onSelect: (NoteCard?) -> Void
    @Binding var viewport: CanvasViewport

    func body(content: Content) -> some View {
        content
            .onKeyPress(.delete) {
                guard !isEditingTitle else { return .ignored }
                if let id = selectedCardID {
                    onDeleteCard?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return) {
                guard !isEditingTitle else { return .ignored }
                if let id = selectedCardID {
                    onNewSibling?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.tab) {
                guard !isEditingTitle else { return .ignored }
                if let id = selectedCardID {
                    onNewChild?(id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.space) {
                guard !isEditingTitle else { return .ignored }
                if let id = selectedCardID, let card = cards.first(where: { $0.id == id }) {
                    onEditCard?(card)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.rightArrow) {
                guard !isEditingTitle else { return .ignored }
                if let curID = selectedCardID {
                    if let targetID = MindMapCanvasView.nextCardID(from: curID, direction: .right, cards: cards, frames: frames, visibleCardIDs: visibleCardIDs),
                       let targetCard = cards.first(where: { $0.id == targetID }) {
                        onSelect(targetCard)
                        return .handled
                    }
                } else if let first = visibleCards.first {
                    onSelect(first)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.leftArrow) {
                guard !isEditingTitle else { return .ignored }
                if let curID = selectedCardID {
                    if let targetID = MindMapCanvasView.nextCardID(from: curID, direction: .left, cards: cards, frames: frames, visibleCardIDs: visibleCardIDs),
                       let targetCard = cards.first(where: { $0.id == targetID }) {
                        onSelect(targetCard)
                        return .handled
                    }
                } else if let first = visibleCards.first {
                    onSelect(first)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                guard !isEditingTitle else { return .ignored }
                if let curID = selectedCardID {
                    if let targetID = MindMapCanvasView.nextCardID(from: curID, direction: .down, cards: cards, frames: frames, visibleCardIDs: visibleCardIDs),
                       let targetCard = cards.first(where: { $0.id == targetID }) {
                        onSelect(targetCard)
                        return .handled
                    }
                } else if let first = visibleCards.first {
                    onSelect(first)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                guard !isEditingTitle else { return .ignored }
                if let curID = selectedCardID {
                    if let targetID = MindMapCanvasView.nextCardID(from: curID, direction: .up, cards: cards, frames: frames, visibleCardIDs: visibleCardIDs),
                       let targetCard = cards.first(where: { $0.id == targetID }) {
                        onSelect(targetCard)
                        return .handled
                    }
                } else if let first = visibleCards.first {
                    onSelect(first)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress { press in
                if press.modifiers.contains(.command) {
                    if press.characters == "+" || press.characters == "=" {
                        withAnimation(.easeOut(duration: 0.10)) { viewport.zoomIn(factor: 1.20) }
                        return .handled
                    } else if press.characters == "-" {
                        withAnimation(.easeOut(duration: 0.10)) { viewport.zoomOut(factor: 1.20) }
                        return .handled
                    } else if press.characters == "0" {
                        withAnimation(.easeInOut(duration: 0.15)) { viewport.zoomToFit(nodes: Array(frames.values)) }
                        return .handled
                    }
                }
                return .ignored
            }
    }
}

private struct MindMapPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.black.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
    }
}
