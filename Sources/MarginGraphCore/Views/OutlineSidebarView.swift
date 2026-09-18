import SwiftUI
import AppKit

public struct OutlineSidebarView: View {
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var onSelect: (NoteCard) -> Void
    public var onToggleFold: (UUID, Bool) -> Void
    public var onIndent: (UUID, UUID) -> Void
    public var onOutdent: (UUID) -> Void
    public var onDelete: (UUID) -> Void
    public var onReorderBefore: (UUID, UUID?) -> Void

    @State private var query = ""
    @State private var colorFilter: Int?

    public init(
        cards: [NoteCard],
        selectedCardID: UUID?,
        onSelect: @escaping (NoteCard) -> Void,
        onToggleFold: @escaping (UUID, Bool) -> Void,
        onIndent: @escaping (UUID, UUID) -> Void,
        onOutdent: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onReorderBefore: @escaping (UUID, UUID?) -> Void
    ) {
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.onSelect = onSelect
        self.onToggleFold = onToggleFold
        self.onIndent = onIndent
        self.onOutdent = onOutdent
        self.onDelete = onDelete
        self.onReorderBefore = onReorderBefore
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search notes or #tag", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.85, green: 0.82, blue: 0.77), lineWidth: 0.8))

                Menu {
                    Button("All Colors") { colorFilter = nil }
                    ForEach(0..<6, id: \.self) { index in
                        Button("Color \(index)") { colorFilter = index }
                    }
                } label: {
                    Image(systemName: colorFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "paintpalette.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(10)
            .background(Color(white: 0.97))

            Divider()
                .background(MarginNoteTheme.separatorColor)

            // Rows List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(flattenedRows, id: \.card.id) { row in
                        OutlineRow(
                            card: row.card,
                            depth: row.depth,
                            hasChildren: cards.contains(where: { $0.groupNoteId == row.card.id }),
                            isSelected: selectedCardID == row.card.id,
                            onSelect: { onSelect(row.card) },
                            onToggleFold: { onToggleFold(row.card.id, !row.card.isFolded) }
                        )
                        .contextMenu {
                            if let previous = previousSibling(of: row.card) {
                                Button("Indent under Previous") {
                                    onIndent(row.card.id, previous.id)
                                }
                                .keyboardShortcut(.tab, modifiers: [])
                            }

                            if row.card.groupNoteId != nil {
                                Button("Outdent") {
                                    onOutdent(row.card.id)
                                }
                                .keyboardShortcut(.tab, modifiers: [.shift])
                            }

                            Divider()

                            Button("Move Before Previous") {
                                if let previous = previousSibling(of: row.card) {
                                    onReorderBefore(row.card.id, previous.id)
                                }
                            }

                            Button("Move to End") {
                                onReorderBefore(row.card.id, nil)
                            }

                            Button("Copy Deep Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.card.deepLinkURL.absoluteString, forType: .string)
                            }

                            Divider()

                            Button("Delete", role: .destructive) {
                                onDelete(row.card.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 220)
        .background(MarginNoteTheme.shelfBackground)
    }

    private var filteredCards: [NoteCard] {
        cards.filter { card in
            let colorMatches = colorFilter == nil || card.colorIndex == colorFilter
            guard colorMatches else { return false }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }

            if trimmed.hasPrefix("#") {
                let tag = String(trimmed.dropFirst()).lowercased()
                return card.tags.contains { $0.lowercased().contains(tag) }
            }

            let needle = trimmed.lowercased()
            return card.title.lowercased().contains(needle)
                || card.highlightText.lowercased().contains(needle)
                || card.notesText.lowercased().contains(needle)
                || card.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    private var flattenedRows: [OutlineRowModel] {
        let visibleIDs = Set(filteredCards.map(\.id))
        let grouped = Dictionary(grouping: cards, by: { $0.groupNoteId })
        var result: [OutlineRowModel] = []

        func append(_ card: NoteCard, depth: Int, ancestorMatched: Bool) {
            let directMatch = visibleIDs.contains(card.id)
            let descendants = descendantIDs(of: card.id, grouped: grouped)
            let subtreeMatches = !visibleIDs.isDisjoint(with: descendants)
            let unfiltered = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && colorFilter == nil
            let shouldShow = unfiltered || directMatch || subtreeMatches || ancestorMatched

            guard shouldShow else { return }
            result.append(OutlineRowModel(card: card, depth: depth))

            if !card.isFolded {
                for child in (grouped[card.id] ?? []).sorted(by: sortCards) {
                    append(child, depth: depth + 1, ancestorMatched: ancestorMatched || directMatch)
                }
            }
        }

        for root in (grouped[nil] ?? []).sorted(by: sortCards) {
            append(root, depth: 0, ancestorMatched: false)
        }

        return result
    }

    private func descendantIDs(
        of id: UUID,
        grouped: [UUID?: [NoteCard]]
    ) -> Set<UUID> {
        var result = Set<UUID>()
        var stack = grouped[id] ?? []

        while let card = stack.popLast() {
            if result.insert(card.id).inserted {
                stack.append(contentsOf: grouped[card.id] ?? [])
            }
        }

        return result
    }

    private func previousSibling(of card: NoteCard) -> NoteCard? {
        let siblings = cards
            .filter { $0.groupNoteId == card.groupNoteId }
            .sorted(by: sortCards)

        guard let index = siblings.firstIndex(where: { $0.id == card.id }),
              index > 0 else {
            return nil
        }

        return siblings[index - 1]
    }

    nonisolated private func sortCards(_ lhs: NoteCard, _ rhs: NoteCard) -> Bool {
        let ly = lhs.mindPos?.y ?? CGFloat(lhs.createdAt.timeIntervalSince1970)
        let ry = rhs.mindPos?.y ?? CGFloat(rhs.createdAt.timeIntervalSince1970)
        return ly < ry
    }
}

private struct OutlineRowModel {
    var card: NoteCard
    var depth: Int
}

private struct OutlineRow: View {
    var card: NoteCard
    var depth: Int
    var hasChildren: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onToggleFold: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(depth) * 14)

            if hasChildren {
                Button(action: onToggleFold) {
                    Image(systemName: card.isFolded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
            } else {
                Color.clear.frame(width: 16)
            }

            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? (card.highlightText.isEmpty ? "Note" : card.highlightText) : card.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !card.title.isEmpty && !card.highlightText.isEmpty {
                    Text(card.highlightText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color(red: 0.18, green: 0.65, blue: 0.65).opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var accentColor: Color {
        MarginNoteTheme.cardColors(for: card.colorIndex).accent
    }
}
