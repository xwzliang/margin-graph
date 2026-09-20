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
}

public struct MarginNotePDFContainerView: View {
    public var manager: PDFDocumentManager
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var activeToolbarOwner: ToolbarOwner
    public var jumpTarget: PDFJumpTarget?
    public var studyDocuments: [Document]
    public var activeDocument: Document?
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

    @State private var activeTool: MarginNotePDFTool = .hand
    @State private var highlightColor: Color = .yellow
    @State private var currentPageIndex: Int = 0
    @State private var totalPageCount: Int = 1
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var currentMatchIndex: Int = 0
    @State private var totalMatches: Int = 0
    @State private var bookmarkedPages: Set<Int> = []
    @State private var displayMode: PDFReaderDisplayMode = .continuous
    @State private var pageHistory: [Int] = []
    @State private var historyIndex: Int = 0
    @State private var internalJumpTarget: PDFJumpTarget? = nil

    public init(
        manager: PDFDocumentManager,
        cards: [NoteCard],
        selectedCardID: UUID? = nil,
        activeToolbarOwner: ToolbarOwner = .none,
        jumpTarget: PDFJumpTarget? = nil,
        studyDocuments: [Document] = [],
        activeDocument: Document? = nil,
        bookmarks: Set<Int> = [],
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
        self.bookmarks = bookmarks
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
        self._bookmarkedPages = State(initialValue: bookmarks)
    }

    public var body: some View {
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
                        if !isSearching {
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
                    }
                    .buttonStyle(.plain)
                    .help("Search in Document")

                    // Bookmarks ribbon menu
                    Menu {
                        Button(bookmarkedPages.contains(currentPageIndex) ? "Remove Bookmark (Page \(currentPageIndex + 1))" : "Bookmark Page \(currentPageIndex + 1)") {
                            let willBookmark = !bookmarkedPages.contains(currentPageIndex)
                            if willBookmark {
                                bookmarkedPages.insert(currentPageIndex)
                            } else {
                                bookmarkedPages.remove(currentPageIndex)
                            }
                            onToggleBookmark?(currentPageIndex, willBookmark)
                        }
                        if !bookmarkedPages.isEmpty {
                            Divider()
                            ForEach(Array(bookmarkedPages.sorted()), id: \.self) { page in
                                Button("Page \(page + 1)") {
                                    currentPageIndex = page
                                }
                            }
                        }
                    } label: {
                        Image(systemName: bookmarkedPages.contains(currentPageIndex) ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13))
                            .foregroundStyle(bookmarkedPages.contains(currentPageIndex) ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(white: 0.35))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Bookmarks")

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
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Document Options")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(MarginNoteTheme.headerBarBackground)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(MarginNoteTheme.separatorColor),
                alignment: .bottom
            )

            // Search Bar Overlay (when search is active)
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Search in document…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            if totalMatches > 0 {
                                currentMatchIndex = (currentMatchIndex + 1) % totalMatches
                            }
                        }

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
            if activeDocument != nil || !studyDocuments.isEmpty {
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
                    jumpTarget: internalJumpTarget ?? jumpTarget,
                    currentPageIndex: $currentPageIndex,
                    searchQuery: searchQuery,
                    searchMatchIndex: currentMatchIndex,
                    onSearchResultCount: { count in
                        totalMatches = count
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
                    onDeleteEmphasis: onDeleteEmphasis
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
            }
        }
        .onAppear {
            totalPageCount = manager.pageCount
            bookmarkedPages = bookmarks
        }
        .onChange(of: bookmarks) { _, newBookmarks in
            bookmarkedPages = newBookmarks
        }
        .onChange(of: jumpTarget) { _, target in
            if let target {
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
        }
        .buttonStyle(.plain)
    }
}
