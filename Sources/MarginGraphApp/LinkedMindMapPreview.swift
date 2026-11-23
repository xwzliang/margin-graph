import SwiftUI
import MarginGraphCore

/// An independent canvas: browsing a reference must not move the underlying workspace.
struct LinkedMindMapPreview: View {
    @ObservedObject var model: AppModel
    @State private var cards: [NoteCard] = []
    @State private var links: [CardLink] = []
    @State private var topic: Topic?
    @State private var selectedID: UUID?
    @State private var centerID: UUID?
    @State private var editingID: UUID?
    @State private var canvasIdentity = UUID()
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    let destination: NoteCard

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic?.title ?? "Linked MindMap").font(.headline)
                    Text("Browse linked notes").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Main MindMap") {
                    let id = selectedID ?? destination.id
                    dismiss()
                    model.linkedMindMapCard = nil
                    model.handleDeepLink(DeepLinkHandler.url(forCard: id))
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            HStack {
                TextField("Find a note", text: $query)
                Button("Find") {
                    if let match = cards.first(where: { !$0.title.isEmpty && $0.title.localizedCaseInsensitiveContains(query) }) {
                        selectedID = match.id
                        centerID = match.id
                    }
                }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Center Linked Note") {
                    load(card: destination)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            MindMapCanvasView(
                cards: cards, links: links, selectedCardID: selectedID,
                cardIDToCenter: $centerID, editingCardTitleID: $editingID,
                initialZoomScale: 0.85, mediaStorage: model.mediaStorage,
                topics: model.topics, selectedTopic: topic,
                onSelectTopic: { load(topic: $0) },
                onSelect: { selectedID = $0?.id },
                onMove: { _, _ in }, onReparent: { _, _ in },
                onToggleFold: { id, folded in
                    if let index = cards.firstIndex(where: { $0.id == id }) { cards[index].isFolded = folded }
                },
                onOpenNoteLink: { url in
                    guard case .openCard(let id) = DeepLinkHandler.parse(url),
                          let card = try? model.database.getCard(id: id) else { return }
                    load(card: card)
                }
            ).id(canvasIdentity)
        }
        .frame(width: 900, height: 620)
        .onAppear { load(card: destination) }
    }

    private func load(topic: Topic) {
        self.topic = topic
        loadGraph(topicID: topic.id)
        selectedID = nil
        centerID = nil
    }

    private func loadGraph(topicID: UUID) {
        let graph = try? model.database.notebookGraph(id: topicID)
        cards = NoteCard.filterMarginNoteDocumentRootCard(from: graph?.cards ?? [])
        links = graph?.links ?? []
        canvasIdentity = UUID()
    }

    private func load(card: NoteCard) {
        if let owner = model.topics.first(where: { $0.id == card.topicId }) {
            load(topic: owner)
        } else {
            loadGraph(topicID: card.topicId)
        }
        // Expand the destination's ancestors in the preview only.
        var ancestor = cards.first(where: { $0.id == card.id })?.groupNoteId
        var visited = Set<UUID>()
        while let id = ancestor, visited.insert(id).inserted,
              let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].isFolded = false
            ancestor = cards[index].groupNoteId
        }
        selectedID = card.id
        centerID = card.id
    }
}
