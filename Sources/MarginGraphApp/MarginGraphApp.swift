import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarginGraphCore

enum WorkspaceViewMode: String, CaseIterable, Identifiable {
    case readerOnly = "Reader"
    case splitView = "2-View"
    case threeView = "3-View"
    case mindMapOnly = "MindMap"

    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    @Published var selectedTopicID: UUID?
    @Published var studyDocuments: [Document] = []
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
        if selectedTopicID == nil {
            selectedTopicID = topics.first?.id
        }
        reloadStudySet()
    }

    var selectedTopic: Topic? {
        topics.first(where: { $0.id == selectedTopicID })
    }

    func reloadLibrary() {
        topics = (try? database.allTopics()) ?? []
        documents = (try? database.allDocuments()) ?? []
        if selectedTopicID == nil || !topics.contains(where: { $0.id == selectedTopicID }) {
            selectedTopicID = topics.first?.id
        }
    }

    func selectTopic(_ topic: Topic) {
        selectedTopicID = topic.id
        selectedCardID = nil
        jumpTarget = nil
        reloadStudySet()
    }

    func reloadStudySet() {
        guard let topicID = selectedTopicID else {
            studyDocuments = []
            mindMapCards = []
            links = []
            return
        }
        studyDocuments = (try? database.documentsForTopic(id: topicID)) ?? []
        mindMapCards = (try? database.cardsForTopic(id: topicID)) ?? []
        links = (try? database.linksForTopic(id: topicID)) ?? []

        if let activeDocument, studyDocuments.contains(where: { $0.md5 == activeDocument.md5 }) {
            reloadDocumentCards()
        } else if let first = studyDocuments.first {
            switchToDocument(first)
        } else {
            activeDocument = nil
            manager = nil
            documentCards = []
        }
    }

    func openPDFPicker(attachToTopic: Bool = true) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPDF(url: url, attachToTopic: attachToTopic)
    }

    func openPDF(url: URL, attachToTopic: Bool = true) {
        guard let manager = try? PDFDocumentManager(url: url) else { return }
        let existing = try? database.getDocumentByMD5(md5: manager.md5)
        let document = existing ?? Document(
            title: manager.title,
            filePath: url.path,
            md5: manager.md5,
            totalPages: manager.pageCount,
            lastVisited: Date()
        )
        try? database.insertDocument(document)

        if attachToTopic, let topicID = selectedTopicID {
            try? database.addDocument(to: topicID, md5: document.md5)
        }

        reloadLibrary()
        reloadStudySet()
        switchToDocument(document)
    }

    func switchToDocument(_ document: Document) {
        guard let loaded = try? PDFDocumentManager(url: URL(fileURLWithPath: document.filePath)) else { return }
        activeDocument = document
        manager = loaded
        reloadDocumentCards()
    }

    func attachExistingDocument(_ document: Document) {
        guard let topicID = selectedTopicID else { return }
        try? database.addDocument(to: topicID, md5: document.md5)
        reloadLibrary()
        reloadStudySet()
        switchToDocument(document)
    }

    func detachDocument(_ document: Document) {
        guard let topicID = selectedTopicID else { return }
        try? database.removeDocument(from: topicID, md5: document.md5)
        reloadLibrary()
        reloadStudySet()
    }

    func createExcerpt(_ excerpt: PDFExcerpt) {
        let topic = ensureTopic()
        let coordinator = ExcerptCoordinator(database: database, mediaStorage: mediaStorage)
        guard let card = try? coordinator.createCard(from: excerpt, topicId: topic.id) else { return }
        selectedCardID = card.id
        reloadStudySet()
        navigateToCard(card)
    }

    func select(card: NoteCard) {
        selectedCardID = card.id
        navigateToCard(card)
    }

    func navigateToCard(_ card: NoteCard) {
        if let md5 = card.bookMD5,
           let document = studyDocuments.first(where: { $0.md5 == md5 }),
           activeDocument?.md5 != md5 {
            switchToDocument(document)
        }

        guard let page = card.startPage else { return }
        let bounds: CGRect
        if let start = card.startPos, let end = card.endPos {
            bounds = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        } else {
            bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        jumpTarget = PDFJumpTarget(pageIndex: page, bounds: bounds)
    }

    func deselect() {
        selectedCardID = nil
    }

    func move(cardID: UUID, to position: CGPoint) {
        try? database.moveCard(id: cardID, to: position)
        reloadStudySet()
    }

    func reparent(cardID: UUID, to parentID: UUID?) {
        try? database.reparentCard(id: cardID, to: parentID)
        reloadStudySet()
    }

    func toggleFold(cardID: UUID, folded: Bool) {
        try? database.setCardFolded(id: cardID, folded: folded)
        reloadStudySet()
    }

    func indent(cardID: UUID, under siblingID: UUID) {
        try? database.indentCard(id: cardID, under: siblingID)
        reloadStudySet()
    }

    func outdent(cardID: UUID) {
        try? database.outdentCard(id: cardID)
        reloadStudySet()
    }

    func delete(cardID: UUID) {
        try? database.deleteCard(id: cardID)
        if selectedCardID == cardID { selectedCardID = nil }
        reloadStudySet()
    }

    func reorder(cardID: UUID, before siblingID: UUID?) {
        try? database.reorderCard(id: cardID, before: siblingID)
        reloadStudySet()
    }

    func importMarginNote() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["sqlite"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        var sourceURL: URL?
        if panel.runModal() == .OK, let selected = panel.url {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
            sourceURL = isDirectory.boolValue
                ? selected.appendingPathComponent("MarginNotes.sqlite")
                : selected
        } else {
            let standard = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QReader.MarginStudyMac/MarginNotes.sqlite")
            if FileManager.default.fileExists(atPath: standard.path) {
                sourceURL = standard
            }
        }

        guard let sourceURL,
              let result = try? MarginNoteImporter(url: sourceURL).importInto(database) else { return }

        reloadLibrary()
        if let first = result.topics.first {
            selectedTopicID = first.id
        }
        reloadStudySet()
    }

    func exportMarkdown() {
        guard let topic = selectedTopic else { return }
        saveExport(
            content: MarkdownExporter.export(topic: topic, cards: mindMapCards),
            suggestedName: "\(safeFilename(topic.title)).md",
            type: UTType(filenameExtension: "md") ?? .plainText
        )
    }

    func exportOPML() {
        guard let topic = selectedTopic else { return }
        saveExport(
            content: OPMLExporter.export(topic: topic, cards: mindMapCards),
            suggestedName: "\(safeFilename(topic.title)).opml",
            type: UTType(filenameExtension: "opml") ?? .xml
        )
    }

    private func saveExport(content: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }

    private func ensureTopic() -> Topic {
        if let topic = selectedTopic { return topic }
        let topic = Topic(title: "Inbox")
        try? database.insertTopic(topic)
        reloadLibrary()
        selectedTopicID = topic.id
        reloadStudySet()
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

struct DocumentTabsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.studyDocuments, id: \.id) { document in
                        Button {
                            model.switchToDocument(document)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc")
                                Text(document.title).lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                model.activeDocument?.md5 == document.md5
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Detach from Study Set") {
                                model.detachDocument(document)
                            }
                        }
                    }
                }
            }

            Menu {
                if !model.documents.isEmpty {
                    Section("Existing Documents") {
                        ForEach(model.documents, id: \.id) { document in
                            Button(document.title) {
                                model.attachExistingDocument(document)
                            }
                        }
                    }
                }
                Button("Open New PDF…") {
                    model.openPDFPicker(attachToTopic: true)
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .help("Attach Document…")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct DocumentPane: View {
    @ObservedObject var model: AppModel
    @State private var tool: PDFSelectionTool = .textSelection
    @State private var displayMode: PDFReaderDisplayMode = .continuous
    @State private var highlightColor: Color = .yellow

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabsView(model: model)
            Divider()

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
                } else {
                    ContentUnavailableView(
                        "Attach or open a PDF",
                        systemImage: "doc.richtext",
                        description: Text("Use the + button in the document tab bar.")
                    )
                }
            }
        }
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
    @State private var mode: WorkspaceViewMode = .splitView

    var body: some View {
        Group {
            switch mode {
            case .readerOnly:
                DocumentPane(model: model)
            case .mindMapOnly:
                MindMapPane(model: model)
            case .splitView:
                HSplitView {
                    DocumentPane(model: model)
                        .frame(minWidth: 420)
                    MindMapPane(model: model)
                        .frame(minWidth: 380)
                }
            case .threeView:
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
                    ForEach(WorkspaceViewMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            ToolbarItemGroup {
                Menu("Import / Export") {
                    Button("Import MarginNote 3…") { model.importMarginNote() }
                    Divider()
                    Button("Export to Markdown…") { model.exportMarkdown() }
                    Button("Export to OPML…") { model.exportOPML() }
                }

                Button("Reader") { mode = .readerOnly }
                    .keyboardShortcut("1", modifiers: [.command])
                    .hidden()
                Button("Split") { mode = .splitView }
                    .keyboardShortcut("2", modifiers: [.command])
                    .hidden()
                Button("3-View") { mode = .threeView }
                    .keyboardShortcut("3", modifiers: [.command])
                    .hidden()
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
                List(selection: $model.selectedTopicID) {
                    Section("Study Sets") {
                        ForEach(model.topics, id: \.id) { topic in
                            Button {
                                model.selectTopic(topic)
                            } label: {
                                Label(topic.title, systemImage: "square.grid.2x2")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section("Library") {
                        ForEach(model.documents, id: \.id) { document in
                            Button {
                                model.open(document: document, attachToTopic: false)
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

private extension AppModel {
    func open(document: Document, attachToTopic: Bool) {
        if attachToTopic, let topicID = selectedTopicID {
            try? database.addDocument(to: topicID, md5: document.md5)
            reloadStudySet()
        }
        switchToDocument(document)
    }
}
