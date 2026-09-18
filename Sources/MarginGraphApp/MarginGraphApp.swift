import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarginGraphCore

@MainActor
final class AppModel: ObservableObject {
    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    @Published var activeDocument: Document?
    @Published var manager: PDFDocumentManager?
    @Published var cards: [NoteCard] = []
    @Published var jumpTarget: PDFJumpTarget?

    let database: Database
    let mediaStorage: MediaStorage

    init() {
        database = try! Database()
        mediaStorage = try! MediaStorage()
        reloadLibrary()
    }

    func reloadLibrary() {
        topics = (try? database.allTopics()) ?? []
        documents = (try? database.allDocuments()) ?? []
    }

    func openPDFPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPDF(url: url)
    }

    func open(document: Document) {
        openPDF(url: URL(fileURLWithPath: document.filePath))
    }

    func openPDF(url: URL) {
        guard let manager = try? PDFDocumentManager(url: url) else { return }
        let document = Document(
            title: manager.title,
            filePath: url.path,
            md5: manager.md5,
            totalPages: manager.pageCount,
            lastVisited: Date()
        )
        try? database.insertDocument(document)
        activeDocument = document
        self.manager = manager
        reloadCards()
        reloadLibrary()
    }

    func createExcerpt(_ excerpt: PDFExcerpt) {
        let topic = ensureTopic()
        let coordinator = ExcerptCoordinator(database: database, mediaStorage: mediaStorage)
        _ = try? coordinator.createCard(from: excerpt, topicId: topic.id)
        reloadCards()
    }

    func select(card: NoteCard) {
        guard let page = card.startPage,
              let start = card.startPos,
              let end = card.endPos else { return }
        let bounds = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        jumpTarget = PDFJumpTarget(pageIndex: page, bounds: bounds)
    }

    private func ensureTopic() -> Topic {
        if let topic = topics.first { return topic }
        let topic = Topic(title: "Inbox")
        try? database.insertTopic(topic)
        reloadLibrary()
        return topic
    }

    private func reloadCards() {
        guard let md5 = manager?.md5 else {
            cards = []
            return
        }
        cards = (try? database.cardsForDocument(md5: md5)) ?? []
    }
}

struct ReaderWorkspace: View {
    @ObservedObject var model: AppModel
    @State private var tool: PDFSelectionTool = .textSelection
    @State private var displayMode: PDFReaderDisplayMode = .continuous
    @State private var highlightColor: Color = .yellow

    var body: some View {
        Group {
            if let manager = model.manager {
                HSplitView {
                    PDFReaderView(
                        manager: manager,
                        displayMode: displayMode,
                        tool: tool,
                        highlightColor: NSColor(highlightColor),
                        cards: model.cards,
                        jumpTarget: model.jumpTarget,
                        onExcerpt: { excerpt in
                            model.createExcerpt(excerpt)
                        }
                    )
                    .frame(minWidth: 560)

                    List(model.cards, id: \.id) { card in
                        Button {
                            model.select(card: card)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(card.title.isEmpty ? "Excerpt" : card.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                if !card.highlightText.isEmpty {
                                    Text(card.highlightText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                if let page = card.startPage {
                                    Text("Page \(page + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Picker("Tool", selection: $tool) {
                            Text("Text Select").tag(PDFSelectionTool.textSelection)
                            Text("Rect Marquee").tag(PDFSelectionTool.rectMarquee)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        Picker("Display", selection: $displayMode) {
                            Text("Continuous").tag(PDFReaderDisplayMode.continuous)
                            Text("Single Page").tag(PDFReaderDisplayMode.singlePage)
                        }
                        .frame(width: 140)

                        ColorPicker("Highlight", selection: $highlightColor)
                            .labelsHidden()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Open a PDF to start reading",
                    systemImage: "doc.richtext",
                    description: Text("Use Open PDF in the sidebar.")
                )
            }
        }
    }
}

@main
struct MarginGraphApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                List {
                    Button {
                        model.openPDFPicker()
                    } label: {
                        Label("Open PDF…", systemImage: "folder")
                    }

                    Section("Notebooks") {
                        ForEach(model.topics, id: \.id) { topic in
                            Label(topic.title, systemImage: "square.grid.2x2")
                        }
                    }

                    Section("Documents") {
                        ForEach(model.documents, id: \.id) { document in
                            Button {
                                model.open(document: document)
                            } label: {
                                Label(document.title, systemImage: "doc")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationTitle("MarginGraph")
            } detail: {
                ReaderWorkspace(model: model)
            }
        }
    }
}
