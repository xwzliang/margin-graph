import SwiftUI
import AppKit
import PDFKit

public struct StudyNotebooksView: View {
    public var topics: [Topic]
    public var documents: [Document]
    public var cardCounts: [UUID: Int]
    public var onOpenTopic: (Topic) -> Void
    public var onCreateTopic: () -> Void
    public var onDeleteTopic: (Topic) -> Void

    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var filter: String = "All"

    public init(
        topics: [Topic],
        documents: [Document] = [],
        cardCounts: [UUID: Int] = [:],
        onOpenTopic: @escaping (Topic) -> Void,
        onCreateTopic: @escaping () -> Void,
        onDeleteTopic: @escaping (Topic) -> Void
    ) {
        self.topics = topics
        self.documents = documents
        self.cardCounts = cardCounts
        self.onOpenTopic = onOpenTopic
        self.onCreateTopic = onCreateTopic
        self.onDeleteTopic = onDeleteTopic
    }

    private var sortedTopics: [Topic] {
        if sortMode == 0 {
            return topics.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            return topics.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private func matchingDocument(for topic: Topic) -> Document? {
        documents.first { doc in
            topic.bookMD5List.contains { bmd5 in
                bmd5 == doc.md5 || bmd5.hasPrefix(doc.md5) || doc.md5.hasPrefix(bmd5)
            }
        }
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
                        Text("No Study Notebooks")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button("New Notebook", action: onCreateTopic)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                        ForEach(sortedTopics, id: \.id) { topic in
                            NotebookCardView(
                                topic: topic,
                                document: matchingDocument(for: topic),
                                cardCount: cardCounts[topic.id] ?? 0,
                                onOpen: { onOpenTopic(topic) }
                            )
                            .contextMenu {
                                Button("Open Notebook") { onOpenTopic(topic) }
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
    }
}

public struct NotebookCardView: View {
    public var topic: Topic
    public var document: Document?
    public var cardCount: Int
    public var onOpen: () -> Void

    public init(topic: Topic, document: Document? = nil, cardCount: Int, onOpen: @escaping () -> Void) {
        self.topic = topic
        self.document = document
        self.cardCount = cardCount
        self.onOpen = onOpen
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
                    if let doc = document, let thumb = loadMiniCoverThumbnail(path: doc.filePath) {
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
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func loadMiniCoverThumbnail(path: String) -> NSImage? {
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
