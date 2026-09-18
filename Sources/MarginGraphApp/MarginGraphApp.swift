import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarginGraphCore

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case document = "Document"
    case mindMap = "MindMap"
    case split = "2-View"
    case triple = "3-View"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    @Published var activeDocument: Document?
    @Published var manager: PDFDocumentManager?
    @Published var documentCards: [NoteCard] = []
    @Published var mindMapCards: [NoteCard] = []
    @Published var links: [CardLink] = []
    @Published var selectedCardID: UUID?
    @Published var jumpTarget: PDFJumpTarget?

    let database: Database
    let mediaStorage: MediaStorage

    init() {
        database = try! Database()
        mediaStorage = try! MediaStorage()
        reloadLibrary()
        reloadMindMap()
    }

    func reloadLibrary() {
        topics = (try? database.allTopics()) ?? []
        documents = (try? database.allDocuments()) ?? []
    }

    func reloadMindMap() {
        guard let topic = topics.first else {
            mindMapCards = []
            links = []
            return
        }
        mindMapCards = (try? database.cardsForTopic(id: topic.id)) ?? []
        links = (try? database.linksForTopic(id: topic.id)) ?? []
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
        reloadDocumentCards()
        reloadLibrary()
    }

    func createExcerpt(_ excerpt: PDFExcerpt) {
        let topic = ensureTopic()
        let coordinator = ExcerptCoordinator(database: database, mediaStorage: mediaStorage)
        guard let card = try? coordinator.createCard(from: excerpt, topicId: topic.id) else { return }
        selectedCardID = card.id
        reloadDocumentCards()
        reloadMindMap()
    }

    func select(card: NoteCard) {
        selectedCardID = card.id
        guard let page = card.startPage,
              let start = card.startPos,
              let end = card.endPos else { return }
        jumpTarget = PDFJumpTarget(
            pageIndex: page,
            bounds: CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        )
    }

    func deselect() {
        selectedCardID = nil
    }

    func move(cardID: UUID, to position: CGPoint) {
        try? database.moveCard(id: cardID, to: position)
        reloadMindMap()
    }

    func reparent(cardID: UUID, to parentID: UUID?) {
        try? database.reparentCard(id: cardID, to: parentID)
        reloadMindMap()
    }

    func toggleFold(cardID: UUID, folded: Bool) {
        try? database.setCardFolded(id: cardID, folded: folded)
        reloadMindMap()
    }

    func indent(cardID: UUID, under siblingID: UUID) {
        try? database.indentCard(id: cardID, under: siblingID)
        reloadMindMap()
    }

    func outdent(cardID: UUID) {
        try? database.outdentCard(id: cardID)
        reloadMindMap()
    }

    func delete(cardID: UUID) {
        try? database.deleteCard(id: cardID)
        if selectedCardID == cardID { selectedCardID = nil }
        reloadDocumentCards()
        reloadMindMap()
    }

    func reorder(cardID: UUID, before siblingID: UUID?) {
        try? database.reorderCard(id: cardID, before: siblingID)
        reloadMindMap()
    }

    private func ensureTopic() -> Topic {
        if let topic = topics.first { return topic }
        let topic = Topic(title: "Inbox")
        try? database.insertTopic(topic)
        reloadLibrary()
        reloadMindMap()
        return topic
    }

    private func reloadDocumentCards() {
        guard let md5 = manager?.md5 else {
            documentCards = []
            return
        }
        documentCards = (try? database.cardsForDocument(md5: md5)) ?? []
    }
}

struct DocumentPane: View {
    @ObservedObject var model: AppModel
    @State private var tool: PDFSelectionTool = .textSelection
    @State private var displayMode: PDFReaderDisplayMode = .continuous
    @State private var highlightColor: Color = .yellow

    var body: some View {
        Group {
            if let manager = model.manager {
                PDFReaderView(
                    manager: manager,
                    displayMode: displayMode,
                    tool: tool,
                    highlightColor: NSColor(highlightColor),
                    cards: model.documentCards,
                    jumpTarget: model.jumpTarget,
                    onExcerpt: model.createExcerpt
                )
                .toolbar {
                    ToolbarItemGroup {
                        Picker("Tool", selection: $tool) {
                            Text("Text").tag(PDFSelectionTool.textSelection)
                            Text("Marquee").tag(PDFSelectionTool.rectMarquee)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)

                        ColorPicker("Highlight", selection: $highlightColor)
                            .labelsHidden()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Open a PDF to start reading",
                    systemImage: "doc.richtext",
                    description: Text("Use Open PDF in the library sidebar.")
                )
            }
        }
    }
}

struct MindMapPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MindMapCanvasView(
            cards: model.mindMapCards,
            links: model.links,
            selectedCardID: model.selectedCardID,
            mediaStorage: model.mediaStorage,
            onSelect: { card in
                if let card { model.select(card: card) } else { model.deselect() }
            },
            onMove: model.move,
            onReparent: model.reparent,
            onToggleFold: model.toggleFold
        )
    }
}

struct OutlinePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        OutlineSidebarView(
            cards: model.mindMapCards,
            selectedCardID: model.selectedCardID,
            onSelect: model.select,
            onToggleFold: model.toggleFold,
            onIndent: model.indent,
            onOutdent: model.outdent,
            onDelete: model.delete,
            onReorderBefore: model.reorder
        )
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var mode: WorkspaceMode = .split

    var body: some View {
        Group {
            switch mode {
            case .document:
                DocumentPane(model: model)
            case .mindMap:
                MindMapPane(model: model)
            case .split:
                HSplitView {
                    DocumentPane(model: model)
                        .frame(minWidth: 420)
                    MindMapPane(model: model)
                        .frame(minWidth: 380)
                }
            case .triple:
                HSplitView {
                    OutlinePane(model: model)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    DocumentPane(model: model)
                        .frame(minWidth: 400)
                    MindMapPane(model: model)
                        .frame(minWidth: 360)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
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
                WorkspaceView(model: model)
            }
        }
    }
}
