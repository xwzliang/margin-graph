import SwiftUI
import AppKit
import PDFKit

public enum MarginNotePDFTool: String, CaseIterable, Identifiable {
    case hand = "Hand"
    case text = "Text"
    case marquee = "Marquee"
    case lasso = "Lasso"
    case crop = "Crop"
    case pen = "Pen"
    case highlighter = "Highlighter"
    case eraser = "Eraser"
    case textbox = "TextBox"
    case list = "List"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .hand: return "hand.draw"
        case .text: return "character.cursor.ibeam"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "point.topleft.down.to.point.bottomright.curvepath"
        case .crop: return "bolt.fill"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .textbox: return "t.square"
        case .list: return "list.bullet.rectangle"
        }
    }

    public var tooltipTitle: String {
        switch self {
        case .hand: return "Hand / Drag"
        case .text: return "Text Excerpt"
        case .marquee: return "Rect Excerpt"
        case .lasso: return "Lasso Excerpt"
        case .crop: return "Crop Excerpt"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .textbox: return "Text Box"
        case .list: return "Select Area"
        }
    }
}

private struct PDFToolbarButtonFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

public struct MarginNotePDFContainerView: View {
    public var manager: PDFDocumentManager
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var activeToolbarOwner: ToolbarOwner
    public var jumpTarget: PDFJumpTarget?
    public var studyDocuments: [Document]
    public var activeDocument: Document?
    public var showsDocumentTabBar: Bool
    public var onSwitchDocument: ((Document) -> Void)?
    public var onManageDocuments: (() -> Void)?
    public var onExcerpt: (PDFExcerpt) -> Void
    public var onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)?
    public var onEditCard: ((UUID) -> Void)?
    public var onChangeCardColor: ((UUID, Int) -> Void)?
    public var onDeleteCard: ((UUID) -> Void)?
    public var onDeleteSegment: ((UUID, UUID) -> Void)?
    public var onSelectCard: ((UUID?) -> Void)?
    public var onUpdateCardHighlight: ((UUID, UUID?, String, [HighlightRect], CGPoint, CGPoint) -> Void)?
    public var onAsTitle: ((UUID, String) -> Void)?
    public var onAddToComments: ((UUID, String) -> Void)?
    public var onMerge: ((UUID, String, [HighlightRect]) -> Void)?
    public var onEmphasize: ((UUID, String, [HighlightRect]) -> Void)?
    public var onDeleteEmphasis: ((UUID, String, [HighlightRect]) -> Void)?
    public var bookmarks: Set<Int>
    public var onToggleBookmark: ((Int, Bool) -> Void)?
    public var initialPageIndex: Int
    public var initialPageOffsetY: CGFloat
    public var onPageChanged: ((Int) -> Void)?
    public var onPositionChanged: ((Int, CGFloat) -> Void)?

    @State private var activeTool: MarginNotePDFTool = .hand
    @State private var highlightColor: Color = .yellow
    @State private var currentPageIndex: Int = 0
    @State private var totalPageCount: Int = 1
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var currentMatchIndex: Int = 0
    @State private var totalMatches: Int = 0
    @State private var bookmarkedPages: Set<Int> = []
    @State private var showBookmarksPopover: Bool = false
    @State private var showTableOfContentsPopover: Bool = false
    @State private var tocButtonFrame: CGRect? = nil
    @State private var bookmarksButtonFrame: CGRect? = nil
    @State private var displayMode: PDFReaderDisplayMode = .continuous
    @State private var pageHistory: [Int] = []
    @State private var historyIndex: Int = 0
    @State private var internalJumpTarget: PDFJumpTarget? = nil
    @State private var showPageBanner: Bool = false
    @State private var hideBannerTask: Task<Void, Never>? = nil
    @State private var showGoToPageDialog: Bool = false
    @State private var goToPageText: String = ""

    public init(
        manager: PDFDocumentManager,
        cards: [NoteCard],
        selectedCardID: UUID? = nil,
        activeToolbarOwner: ToolbarOwner = .none,
        jumpTarget: PDFJumpTarget? = nil,
        studyDocuments: [Document] = [],
        activeDocument: Document? = nil,
        showsDocumentTabBar: Bool = false,
        bookmarks: Set<Int> = [],
        initialPageIndex: Int = 0,
        initialPageOffsetY: CGFloat = 0,
        onPageChanged: ((Int) -> Void)? = nil,
        onPositionChanged: ((Int, CGFloat) -> Void)? = nil,
        onSwitchDocument: ((Document) -> Void)? = nil,
        onManageDocuments: (() -> Void)? = nil,
        onToggleBookmark: ((Int, Bool) -> Void)? = nil,
        onExcerpt: @escaping (PDFExcerpt) -> Void,
        onCreateCardWithColor: ((PDFExcerpt, Int) -> Void)? = nil,
        onEditCard: ((UUID) -> Void)? = nil,
        onChangeCardColor: ((UUID, Int) -> Void)? = nil,
        onDeleteCard: ((UUID) -> Void)? = nil,
        onDeleteSegment: ((UUID, UUID) -> Void)? = nil,
        onSelectCard: ((UUID?) -> Void)? = nil,
        onUpdateCardHighlight: ((UUID, UUID?, String, [HighlightRect], CGPoint, CGPoint) -> Void)? = nil,
        onAsTitle: ((UUID, String) -> Void)? = nil,
        onAddToComments: ((UUID, String) -> Void)? = nil,
        onMerge: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onEmphasize: ((UUID, String, [HighlightRect]) -> Void)? = nil,
        onDeleteEmphasis: ((UUID, String, [HighlightRect]) -> Void)? = nil
    ) {
        self.manager = manager
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.activeToolbarOwner = activeToolbarOwner
        self.jumpTarget = jumpTarget
        self.studyDocuments = studyDocuments
        self.activeDocument = activeDocument
        self.showsDocumentTabBar = showsDocumentTabBar
        self.bookmarks = bookmarks
        self.initialPageIndex = initialPageIndex
        self.initialPageOffsetY = initialPageOffsetY
        self.onPageChanged = onPageChanged
        self.onPositionChanged = onPositionChanged
        self.onSwitchDocument = onSwitchDocument
        self.onManageDocuments = onManageDocuments
        self.onToggleBookmark = onToggleBookmark
        self.onExcerpt = onExcerpt
        self.onCreateCardWithColor = onCreateCardWithColor
        self.onEditCard = onEditCard
        self.onChangeCardColor = onChangeCardColor
        self.onDeleteCard = onDeleteCard
        self.onDeleteSegment = onDeleteSegment
        self.onSelectCard = onSelectCard
        self.onUpdateCardHighlight = onUpdateCardHighlight
        self.onAsTitle = onAsTitle
        self.onAddToComments = onAddToComments
        self.onMerge = onMerge
        self.onEmphasize = onEmphasize
        self.onDeleteEmphasis = onDeleteEmphasis
        self.initialPageIndex = initialPageIndex
        self.onPageChanged = onPageChanged
        self._currentPageIndex = State(initialValue: initialPageIndex)
        self._bookmarkedPages = State(initialValue: bookmarks)
    }

    public var body: some View {
        GeometryReader { containerGeometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // Row 1: PDF Annotation Toolbar (MarginNote 3 standard)
                    HStack(spacing: 12) {
                // Main Tools Group
                HStack(spacing: 6) {
                    toolButton(.hand)
                    toolButton(.text)
                    toolButton(.marquee)
                    toolButton(.lasso)
                    toolButton(.crop)
                }

                Divider()
                    .frame(height: 16)

                // Pens & Drawing Tools
                HStack(spacing: 6) {
                    toolButton(.pen)
                    toolButton(.highlighter)
                    toolButton(.eraser)
                    toolButton(.textbox)
                    toolButton(.list)
                }

                Spacer()

                // Right Utility Icons
                HStack(spacing: 10) {
                    // Search button
                    Button {
                        isSearching.toggle()
                        if isSearching {
                            NSApp.activate(ignoringOtherApps: true)
                        } else {
                            searchQuery = ""
                            totalMatches = 0
                            currentMatchIndex = 0
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: isSearching ? .bold : .regular))
                            .foregroundStyle(isSearching ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSearching ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12) : Color.clear)
                            )
                            .enlargedHitTarget(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Search")

                    // Table of Contents button
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showTableOfContentsPopover.toggle()
                            if showTableOfContentsPopover {
                                showBookmarksPopover = false
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 13, weight: showTableOfContentsPopover ? .semibold : .regular))
                            .foregroundStyle(showTableOfContentsPopover ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(showTableOfContentsPopover ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12) : Color.clear)
                            )
                            .enlargedHitTarget(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Table of Contents")
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: PDFToolbarButtonFrameKey.self,
                                value: ["toc": geo.frame(in: .named("PDFContainerSpace"))]
                            )
                        }
                    )

                    // Bookmarks: Direct toggle + Dropdown for listing and deleting
                    HStack(spacing: 2) {
                        Button {
                            let isBookmarked = bookmarkedPages.contains(currentPageIndex)
                            let newBookmarked = !isBookmarked
                            if newBookmarked {
                                bookmarkedPages.insert(currentPageIndex)
                            } else {
                                bookmarkedPages.remove(currentPageIndex)
                            }
                            onToggleBookmark?(currentPageIndex, newBookmarked)
                        } label: {
                            Image(systemName: bookmarkedPages.contains(currentPageIndex) ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 13))
                                .foregroundStyle(bookmarkedPages.contains(currentPageIndex) ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                                .frame(width: 20, height: 24)
                                .enlargedHitTarget(width: 26, height: 28)
                        }
                        .buttonStyle(.plain)
                        .marginNoteTooltip(bookmarkedPages.contains(currentPageIndex) ? "Remove Bookmark" : "Bookmark")

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showBookmarksPopover.toggle()
                                if showBookmarksPopover {
                                    showTableOfContentsPopover = false
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color(white: 0.45))
                                .frame(width: 12, height: 24)
                                .enlargedHitTarget(width: 18, height: 28)
                        }
                        .buttonStyle(.plain)
                        .marginNoteTooltip("Bookmarks List")
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: PDFToolbarButtonFrameKey.self,
                                    value: ["bookmarks": geo.frame(in: .named("PDFContainerSpace"))]
                                )
                            }
                        )
                    }

                    // More options menu
                    Menu {
                        Button(displayMode == .continuous ? "✓ Continuous Scroll" : "Continuous Scroll") {
                            displayMode = .continuous
                        }
                        Button(displayMode == .singlePage ? "✓ Single Page" : "Single Page") {
                            displayMode = .singlePage
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(white: 0.35))
                            .frame(width: 26, height: 26)
                            .enlargedHitTarget(width: 32, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 32, height: 28)
                    .marginNoteTooltip("Document Options")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: MarginNoteTheme.topToolbarHeight)
            .background(MarginNoteTheme.headerBarBackground)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(MarginNoteTheme.separatorColor),
                alignment: .bottom
            )
            .tooltipContainer()
            .zIndex(100)

            // Search Bar Overlay (when search is active)
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    FocusableSearchField(
                        text: $searchQuery,
                        placeholder: "Search in document…",
                        onSubmit: {
                            if totalMatches > 0 {
                                currentMatchIndex = (currentMatchIndex + 1) % totalMatches
                            }
                        },
                        onCancel: {
                            searchQuery = ""
                            isSearching = false
                            totalMatches = 0
                            currentMatchIndex = 0
                        }
                    )
                    .frame(height: 20)

                    if totalMatches > 0 {
                        Text("\(currentMatchIndex + 1) of \(totalMatches)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Button {
                            if currentMatchIndex > 0 {
                                currentMatchIndex -= 1
                            } else {
                                currentMatchIndex = totalMatches - 1
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(white: 0.3))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if currentMatchIndex < totalMatches - 1 {
                                currentMatchIndex += 1
                            } else {
                                currentMatchIndex = 0
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(white: 0.3))
                        }
                        .buttonStyle(.plain)
                    } else if !searchQuery.isEmpty {
                        Text("No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        searchQuery = ""
                        isSearching = false
                        totalMatches = 0
                        currentMatchIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(white: 0.93))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(Color(white: 0.85)),
                    alignment: .bottom
                )
            }

            // Row 2: Document Tab Bar (MarginNote 3 signature)
            if showsDocumentTabBar && (activeDocument != nil || !studyDocuments.isEmpty) {
                HStack(spacing: 8) {
                    if let firstPage = manager.document.page(at: 0) {
                        let thumb = firstPage.thumbnail(of: CGSize(width: 14, height: 18), for: .cropBox)
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    } else {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.25))
                    }

                    Menu {
                        ForEach(studyDocuments, id: \.id) { doc in
                            Button(doc.title) {
                                onSwitchDocument?(doc)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(activeDocument?.title ?? "Document")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Color(white: 0.15))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(Color(white: 0.4))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)

                    Spacer()

                    Button {
                        onManageDocuments?()
                    } label: {
                        Text("Manage")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color(white: 0.95))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(Color(white: 0.88)),
                    alignment: .bottom
                )
            }

            // PDF Reader Canvas
            ZStack(alignment: .bottom) {
                let selectionTool: PDFSelectionTool = (activeTool == .marquee) ? .rectMarquee : .textSelection
                PDFReaderView(
                    manager: manager,
                    displayMode: displayMode,
                    tool: selectionTool,
                    highlightColor: NSColor(highlightColor),
                    cards: cards,
                    selectedCardID: selectedCardID,
                    activeToolbarOwner: activeToolbarOwner,
                    jumpTarget: jumpTarget ?? internalJumpTarget,
                    currentPageIndex: $currentPageIndex,
                    initialPageOffsetY: initialPageOffsetY,
                    searchQuery: searchQuery,
                    searchMatchIndex: currentMatchIndex,
                    onSearchResultCount: { count in
                        totalMatches = count
                    },
                    onPositionChanged: { page, offset in
                        onPageChanged?(page)
                        onPositionChanged?(page, offset)
                    },
                    onExcerpt: onExcerpt,
                    onCreateCardWithColor: onCreateCardWithColor,
                    onEditCard: onEditCard,
                    onChangeCardColor: onChangeCardColor,
                    onDeleteCard: onDeleteCard,
                    onDeleteSegment: onDeleteSegment,
                    onSelectCard: onSelectCard,
                    onUpdateCardHighlight: onUpdateCardHighlight,
                    onAsTitle: onAsTitle,
                    onAddToComments: onAddToComments,
                    onMerge: onMerge,
                    onEmphasize: onEmphasize,
                    onDeleteEmphasis: onDeleteEmphasis,
                    onScroll: {
                        triggerPageBanner()
                    }
                )
                .background(Color(white: 0.94))

                // Floating < > Navigation Pill (MarginNote 3 signature)
                if pageHistory.count > 1 {
                    HStack(spacing: 0) {
                        Button {
                            if historyIndex > 0 {
                                historyIndex -= 1
                                let page = pageHistory[historyIndex]
                                navigateToHistoryPage(page)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(historyIndex > 0 ? Color(white: 0.3) : Color(white: 0.65))
                                .frame(width: 16, height: 26)
                                .enlargedHitTarget(width: 22, height: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(historyIndex <= 0)

                        Divider()
                            .frame(height: 14)

                        Button {
                            if historyIndex < pageHistory.count - 1 {
                                historyIndex += 1
                                let page = pageHistory[historyIndex]
                                navigateToHistoryPage(page)
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(historyIndex < pageHistory.count - 1 ? Color(white: 0.3) : Color(white: 0.65))
                                .frame(width: 16, height: 26)
                                .enlargedHitTarget(width: 22, height: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(historyIndex >= pageHistory.count - 1)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.98))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 1.5)
                            .overlay(Capsule().stroke(Color(white: 0.85), lineWidth: 0.75))
                    )
                    .padding(.leading, 14)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                // Temporary Page Number Banner on Scroll (MarginNote 3 style)
                if showPageBanner {
                    let totalCount = max(manager.pageCount, totalPageCount)
                    Button {
                        goToPageText = "\(currentPageIndex + 1)"
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showGoToPageDialog = true
                        }
                    } label: {
                        Text("\(currentPageIndex + 1) / \(totalCount)")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .fill(Color(red: 0.77, green: 0.77, blue: 0.77).opacity(0.95))
                                    .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Click or ⌘G to Jump to Page")
                    .padding(.bottom, 24)
                    .transition(.opacity)
                }
                }
            }
            .frame(width: containerGeometry.size.width, height: containerGeometry.size.height)

                // In-Window Popovers (strictly contained within window boundaries)
                if showTableOfContentsPopover {
                    InWindowPopoverContainer(
                        anchorFrame: tocButtonFrame ?? CGRect(x: containerGeometry.size.width - 100, y: 7, width: 24, height: 24),
                        containerWidth: containerGeometry.size.width,
                        popoverWidth: 320,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showTableOfContentsPopover = false
                            }
                        }
                    ) {
                        TableOfContentsPopoverView(
                            items: manager.outline,
                            currentPageIndex: currentPageIndex,
                            cards: cards,
                            totalPageCount: max(manager.pageCount, totalPageCount),
                            onJumpToPage: { page in
                                navigateToHistoryPage(page)
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showTableOfContentsPopover = false
                                }
                            }
                        )
                    }
                    .transition(.opacity)
                    .zIndex(200)
                }

                if showBookmarksPopover {
                    InWindowPopoverContainer(
                        anchorFrame: bookmarksButtonFrame ?? CGRect(x: containerGeometry.size.width - 60, y: 7, width: 24, height: 24),
                        containerWidth: containerGeometry.size.width,
                        popoverWidth: 280,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showBookmarksPopover = false
                            }
                        }
                    ) {
                        BookmarksPopoverView(
                            bookmarkedPages: $bookmarkedPages,
                            currentPageIndex: currentPageIndex,
                            manager: manager,
                            onJumpToPage: { page in
                                navigateToHistoryPage(page)
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showBookmarksPopover = false
                                }
                            },
                            onToggleBookmark: { page, isBookmarked in
                                onToggleBookmark?(page, isBookmarked)
                            },
                            onDeleteBookmark: { page in
                                onToggleBookmark?(page, false)
                            }
                        )
                    }
                    .transition(.opacity)
                    .zIndex(200)
                }

                if showGoToPageDialog {
                    let totalCount = max(manager.pageCount, totalPageCount)
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showGoToPageDialog = false
                            }
                        }

                    HStack(spacing: 8) {
                        Text("Go to Page:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary)

                        FocusableSearchField(
                            text: $goToPageText,
                            placeholder: "1 - \(totalCount)",
                            onSubmit: {
                                if let page = Int(goToPageText.trimmingCharacters(in: .whitespacesAndNewlines)),
                                   page >= 1, page <= totalCount {
                                    navigateToHistoryPage(page - 1)
                                    triggerPageBanner()
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        showGoToPageDialog = false
                                    }
                                }
                            },
                            onCancel: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showGoToPageDialog = false
                                }
                            }
                        )
                        .frame(width: 65, height: 22)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.82), lineWidth: 0.75))

                        Text("/ \(totalCount)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.secondary)

                        Button("Go") {
                            if let page = Int(goToPageText.trimmingCharacters(in: .whitespacesAndNewlines)),
                               page >= 1, page <= totalCount {
                                navigateToHistoryPage(page - 1)
                                triggerPageBanner()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showGoToPageDialog = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showGoToPageDialog = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.98))
                            .shadow(color: Color.black.opacity(0.20), radius: 8, y: 3)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12), lineWidth: 0.8))
                    )
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(300)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .coordinateSpace(name: "PDFContainerSpace")
            .onKeyPress { press in
                if press.modifiers.contains(.command) && (press.characters == "g" || press.characters == "G") {
                    goToPageText = "\(currentPageIndex + 1)"
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showGoToPageDialog = true
                    }
                    return .handled
                }
                return .ignored
            }
            .onPreferenceChange(PDFToolbarButtonFrameKey.self) { frames in
                if let f = frames["toc"] {
                    tocButtonFrame = f
                }
                if let f = frames["bookmarks"] {
                    bookmarksButtonFrame = f
                }
            }
        }
        .onAppear {
            totalPageCount = manager.pageCount
            bookmarkedPages = bookmarks
        }
        .onChange(of: bookmarks) { _, newBookmarks in
            bookmarkedPages = newBookmarks
        }
        .onChange(of: currentPageIndex) { _, newPage in
            onPageChanged?(newPage)
        }
        .onChange(of: jumpTarget) { _, target in
            if let target {
                internalJumpTarget = nil
                let page = target.pageIndex
                if pageHistory.isEmpty || (historyIndex < pageHistory.count && pageHistory[historyIndex] != page) {
                    if historyIndex < pageHistory.count - 1 {
                        pageHistory.removeSubrange((historyIndex + 1)...)
                    }
                    pageHistory.append(page)
                    historyIndex = pageHistory.count - 1
                }
                currentPageIndex = page
            }
        }
        .onDisappear {
            hideBannerTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .marginGraphGoToPage)) { _ in
            goToPageText = "\(currentPageIndex + 1)"
            withAnimation(.easeInOut(duration: 0.15)) {
                showGoToPageDialog = true
            }
        }
    }

    private func triggerPageBanner() {
        withAnimation(.easeIn(duration: 0.15)) {
            showPageBanner = true
        }
        hideBannerTask?.cancel()
        hideBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.3)) {
                    showPageBanner = false
                }
            }
        }
    }

    private func navigateToHistoryPage(_ page: Int) {
        currentPageIndex = page
        internalJumpTarget = PDFJumpTarget(pageIndex: page, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func toolButton(_ tool: MarginNotePDFTool) -> some View {
        let isSelected = activeTool == tool
        return Button {
            activeTool = tool
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: tool.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                    .frame(width: 26, height: 26)

                if tool == .highlighter {
                    Circle()
                        .fill(highlightColor)
                        .frame(width: 4, height: 4)
                        .offset(y: -2.5)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.15) : Color.clear)
            )
            .enlargedHitTarget(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .marginNoteTooltip(tool.tooltipTitle)
    }
}

public struct BookmarksPopoverView: View {
    @Binding public var bookmarkedPages: Set<Int>
    public var currentPageIndex: Int
    public var manager: PDFDocumentManager
    public var onJumpToPage: (Int) -> Void
    public var onToggleBookmark: (Int, Bool) -> Void
    public var onDeleteBookmark: (Int) -> Void

    @State private var hoveredPage: Int? = nil

    public init(
        bookmarkedPages: Binding<Set<Int>>,
        currentPageIndex: Int,
        manager: PDFDocumentManager,
        onJumpToPage: @escaping (Int) -> Void,
        onToggleBookmark: @escaping (Int, Bool) -> Void,
        onDeleteBookmark: @escaping (Int) -> Void
    ) {
        self._bookmarkedPages = bookmarkedPages
        self.currentPageIndex = currentPageIndex
        self.manager = manager
        self.onJumpToPage = onJumpToPage
        self.onToggleBookmark = onToggleBookmark
        self.onDeleteBookmark = onDeleteBookmark
    }

    private func pageSnippet(for page: Int) -> String? {
        guard let pdfPage = manager.document.page(at: page),
              let text = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first {
            return first.count > 45 ? String(first.prefix(42)) + "..." : first
        }
        return nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Bookmarks (\(bookmarkedPages.count))", systemImage: "bookmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Spacer()

                let isCurrentBookmarked = bookmarkedPages.contains(currentPageIndex)
                Button {
                    let willBookmark = !isCurrentBookmarked
                    if willBookmark {
                        bookmarkedPages.insert(currentPageIndex)
                    } else {
                        bookmarkedPages.remove(currentPageIndex)
                    }
                    onToggleBookmark(currentPageIndex, willBookmark)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCurrentBookmarked ? "bookmark.slash" : "bookmark.fill")
                            .font(.system(size: 10))
                        Text(isCurrentBookmarked ? "Unbookmark" : "Bookmark")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isCurrentBookmarked
                            ? Color.red.opacity(0.12)
                            : Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .foregroundStyle(
                        isCurrentBookmarked
                            ? Color.red
                            : Color(red: 0.15, green: 0.45, blue: 0.85)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCurrentBookmarked ? "Remove bookmark for Page \(currentPageIndex + 1)" : "Bookmark Page \(currentPageIndex + 1)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Bookmark items
            if bookmarkedPages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Text("No Bookmarks in this document")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(bookmarkedPages.sorted()), id: \.self) { page in
                            let isCurrent = page == currentPageIndex
                            HStack(spacing: 8) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("Page \(page + 1)")
                                            .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                                            .foregroundStyle(isCurrent ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.primary)
                                        if isCurrent {
                                            Text("(current)")
                                                .font(.system(size: 9))
                                                .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                                        }
                                    }

                                    if let snippet = pageSnippet(for: page) {
                                        Text(snippet)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Button {
                                    bookmarkedPages.remove(page)
                                    onDeleteBookmark(page)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(hoveredPage == page ? Color.red : Color.secondary.opacity(0.6))
                                        .frame(width: 22, height: 22)
                                        .background(hoveredPage == page ? Color.red.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Delete Bookmark")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isCurrent ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.08) : (hoveredPage == page ? Color.black.opacity(0.04) : Color.clear))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onJumpToPage(page)
                            }
                            .onHover { isHovered in
                                if isHovered { hoveredPage = page }
                                else if hoveredPage == page { hoveredPage = nil }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 220)

                if bookmarkedPages.count > 1 {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Delete All Bookmarks") {
                            let toDelete = bookmarkedPages
                            bookmarkedPages.removeAll()
                            for page in toDelete {
                                onDeleteBookmark(page)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

