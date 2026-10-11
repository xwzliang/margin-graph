import SwiftUI
import AppKit
import PDFKit

// Cache successes and failures, including when several notebooks share a book.
private final class NotebookCoverResult: @unchecked Sendable {
    let image: NSImage?
    init(image: NSImage?) { self.image = image }
}
// NSCache synchronizes its own lookups and insertions across queues.
private nonisolated(unsafe) let notebookCoverCache: NSCache<NSString, NotebookCoverResult> = {
    let cache = NSCache<NSString, NotebookCoverResult>()
    cache.countLimit = 256
    return cache
}()
private let notebookCoverQueue = DispatchQueue(label: "MarginGraph.NotebookCovers", qos: .utility)

public struct StudyNotebooksView: View {
    public var topics: [Topic]
    public var documents: [Document]
    public var cardCounts: [UUID: Int]
    public var onOpenTopic: (Topic) -> Void
    public var onCreateTopic: () -> Void
    public var onDeleteTopic: (Topic) -> Void
    public var onRenameTopic: ((Topic, String) -> Void)?
    @Binding public var isSearchPresented: Bool
    @Binding public var searchQuery: String

    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var filter: String = "All"
    @State private var topicToRename: Topic? = nil
    @State private var renameTopicTitle: String = ""
    @FocusState private var isSearchFieldFocused: Bool

    public init(
        topics: [Topic],
        documents: [Document] = [],
        cardCounts: [UUID: Int] = [:],
        isSearchPresented: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        onOpenTopic: @escaping (Topic) -> Void,
        onCreateTopic: @escaping () -> Void,
        onDeleteTopic: @escaping (Topic) -> Void,
        onRenameTopic: ((Topic, String) -> Void)? = nil
    ) {
        self.topics = topics
        self.documents = documents
        self.cardCounts = cardCounts
        self._isSearchPresented = isSearchPresented
        self._searchQuery = searchQuery
        self.onOpenTopic = onOpenTopic
        self.onCreateTopic = onCreateTopic
        self.onDeleteTopic = onDeleteTopic
        self.onRenameTopic = onRenameTopic
    }

    private var sortedTopics: [Topic] {
        var list = topics
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if sortMode == 0 {
            return list.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } else {
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    static func matchingDocument(for topic: Topic, documents: [Document]) -> Document? {
        // Rendering must not probe every candidate path on a network volume.
        // Missing/unavailable covers are handled by the background loader.
        documents.first { doc in
            guard !doc.filePath.isEmpty else { return false }
            let cleanTopicTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDocTitle = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let dFileName = URL(fileURLWithPath: doc.filePath).deletingPathExtension().lastPathComponent
            return topic.bookMD5List.contains { bmd5 in
                bmd5 == doc.md5 || bmd5.hasPrefix(doc.md5) || doc.md5.hasPrefix(bmd5)
            } || cleanDocTitle.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame
              || cleanTopicTitle.localizedCaseInsensitiveContains(cleanDocTitle)
              || cleanDocTitle.localizedCaseInsensitiveContains(cleanTopicTitle)
              || dFileName.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame
              || cleanTopicTitle.localizedCaseInsensitiveContains(dFileName)
              || dFileName.localizedCaseInsensitiveContains(cleanTopicTitle)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search notebooks…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchQuery = ""
                    isSearchPresented = false
                    isSearchFieldFocused = false
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: isSearchPresented) { presented in
            if presented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
            }
        }
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.15)) {
                searchQuery = ""
                isSearchPresented = false
                isSearchFieldFocused = false
            }
        }
    }

    private func renameTopicSheet(topic: Topic) -> some View {
        VStack(spacing: 18) {
            Text("Rename Notebook")
                .font(.headline)

            TextField("Notebook Title", text: $renameTopicTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    topicToRename = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    let trimmed = renameTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRenameTopic?(topic, trimmed)
                    }
                    topicToRename = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(renameTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 300)
        }
        .padding(24)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(spacing: 12) {
                Button(action: onCreateTopic) {
                    Text("New")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                Menu {
                    Button("All") { filter = "All" }
                } label: {
                    HStack(spacing: 4) {
                        Text(filter)
                            .font(.system(size: 13, weight: .regular))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button("Select") {
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                Image(systemName: "list.bullet")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if isSearchPresented {
                searchBar
            }

            // Subheader: Recent | Name
            Picker("", selection: $sortMode) {
                Text("Recent").tag(0)
                Text("Name").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .padding(.bottom, 18)

            Divider()
                .background(MarginNoteTheme.separatorColor)

            // Notebooks Grid
            ScrollView {
                if sortedTopics.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(searchQuery.isEmpty ? "No Study Notebooks" : "No Notebooks Found")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if searchQuery.isEmpty {
                            Button("New Notebook", action: onCreateTopic)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                        ForEach(sortedTopics, id: \.id) { topic in
                            NotebookCardView(
                                topic: topic,
                                document: Self.matchingDocument(for: topic, documents: documents),
                                cardCount: cardCounts[topic.id] ?? 0,
                                onOpen: { onOpenTopic(topic) },
                                onRename: {
                                    renameTopicTitle = topic.title
                                    topicToRename = topic
                                },
                                onDelete: { onDeleteTopic(topic) }
                            )
                            .contextMenu {
                                Button("Open Notebook") { onOpenTopic(topic) }
                                Divider()
                                Button("Rename…") {
                                    renameTopicTitle = topic.title
                                    topicToRename = topic
                                }
                                Divider()
                                Button("Delete", role: .destructive) { onDeleteTopic(topic) }
                            }
                        }
                    }
                    .padding(28)
                }
            }
        }
        .background(MarginNoteTheme.shelfBackground)
        .sheet(item: $topicToRename) { topic in
            renameTopicSheet(topic: topic)
        }
    }
}

public struct NotebookCardView: View {
    public var topic: Topic
    public var document: Document?
    public var cardCount: Int
    public var onOpen: () -> Void
    public var onRename: (() -> Void)?
    public var onDelete: (() -> Void)?

    @State private var isShowingActionCard: Bool = false
    @State private var loadedThumbnail: NSImage?
    @State private var thumbnailPath: String?

    public init(
        topic: Topic,
        document: Document? = nil,
        cardCount: Int,
        onOpen: @escaping () -> Void,
        onRename: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.topic = topic
        self.document = document
        self.cardCount = cardCount
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                // Notebook Preview Cover
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.92, green: 0.90, blue: 0.85))
                        .frame(height: 180)
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    // Mini preview representation of mindmap cards
                    VStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                miniCard(color: Color(red: 0.99, green: 0.97, blue: 0.85),
                                         stroke: Color(red: 0.90, green: 0.86, blue: 0.68),
                                         width: 95)
                                Spacer()
                            }
                            HStack {
                                Spacer()
                                miniCard(color: Color(red: 0.90, green: 0.94, blue: 0.99),
                                         stroke: Color(red: 0.76, green: 0.85, blue: 0.96),
                                         width: 85)
                            }
                            HStack {
                                miniCard(color: Color(red: 0.91, green: 0.97, blue: 0.90),
                                         stroke: Color(red: 0.78, green: 0.90, blue: 0.75),
                                         width: 90)
                                Spacer()
                            }
                        }
                        .padding(.top, 24)
                        .padding(.horizontal, 10)

                        Spacer()
                    }
                    .frame(height: 180)

                    // Top Left: Mini Document Cover Thumbnail (MarginNote 3 signature)
                    if let thumb = loadedThumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.9), lineWidth: 0.8)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                            .padding(6)
                    } else {
                        HStack(spacing: 0) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color(red: 0.85, green: 0.35, blue: 0.25), in: RoundedRectangle(cornerRadius: 2))
                        }
                        .padding(6)
                    }

                    // Top Right: Card Count Badge
                    if cardCount > 0 {
                        HStack {
                            Spacer()
                            Text("\(cardCount)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(MarginNoteTheme.badgeGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                                .padding(5)
                        }
                    }
                }

                // Title Below
                Text(topic.title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)

                // Cloud & More dots
                HStack {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                    Button {
                        isShowingActionCard.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .frame(width: 22, height: 16)
                            .background(isShowingActionCard ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingActionCard, arrowEdge: .trailing) {
                        NotebookActionCardView(
                            topic: topic,
                            onOpen: {
                                isShowingActionCard = false
                                onOpen()
                            },
                            onRename: {
                                isShowingActionCard = false
                                onRename?()
                            },
                            onDelete: {
                                isShowingActionCard = false
                                onDelete?()
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen()
            }
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbnailAsync() }
        .onChange(of: document?.filePath) { _, _ in loadThumbnailAsync() }
        .onDisappear { thumbnailPath = nil }
    }

    private func loadThumbnailAsync() {
        let path = document?.filePath ?? ""
        thumbnailPath = path
        loadedThumbnail = nil
        guard !path.isEmpty else { return }
        if let cached = notebookCoverCache.object(forKey: path as NSString) {
            loadedThumbnail = cached.image
            return
        }
        // Serialize PDF work so a large grid cannot flood the network share.
        notebookCoverQueue.async {
            let cached = notebookCoverCache.object(forKey: path as NSString)
            let result = cached ?? NotebookCoverResult(image: Self.loadMiniCoverThumbnail(path: path))
            notebookCoverCache.setObject(result, forKey: path as NSString)
            DispatchQueue.main.async {
                guard thumbnailPath == path else { return }
                loadedThumbnail = result.image
            }
        }
    }

    private func miniCard(color: Color, stroke: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.black.opacity(0.35))
                .frame(width: width * 0.55, height: 2.5)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.black.opacity(0.18))
                .frame(width: width * 0.75, height: 2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(width: width, height: 24, alignment: .leading)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(stroke, lineWidth: 0.8)
        )
    }

    private nonisolated static func loadMiniCoverThumbnail(path: String) -> NSImage? {
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let pdfDoc = PDFDocument(url: URL(fileURLWithPath: path)),
              let page = pdfDoc.page(at: 0) else {
            return nil
        }
        let thumbSize = NSSize(width: 44, height: 60)
        return page.thumbnail(of: thumbSize, for: .mediaBox)
    }
}

public struct NotebookActionCardView: View {
    public var topic: Topic
    public var onOpen: () -> Void
    public var onRename: () -> Void
    public var onDelete: () -> Void

    @State private var hoveredItem: String? = nil

    public init(
        topic: Topic,
        onOpen: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.topic = topic
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Open Notebook
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text("Open Notebook")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(hoveredItem == "open" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredItem = $0 ? "open" : nil }

            Divider()
                .padding(.vertical, 2)

            // Rename
            Button(action: onRename) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .frame(width: 16)
                    Text("Rename…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(hoveredItem == "rename" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredItem = $0 ? "rename" : nil }

            Divider()
                .padding(.vertical, 2)

            // Delete
            Button(role: .destructive, action: onDelete) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(width: 16)
                    Text("Delete")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(hoveredItem == "delete" ? Color.red.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredItem = $0 ? "delete" : nil }
        }
        .padding(6)
        .frame(width: 170)
    }
}
