import Foundation

/// MarginNote represents child maps as empty map-anchor notes with outgoing roots.
public enum MindMapLayers {
    public static func anchors(in cards: [NoteCard]) -> [NoteCard] {
        cards.filter { $0.title.hasPrefix("Child Map ") && $0.highlightText.isEmpty && $0.highlightPicHash == nil && !$0.mindLinks.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func members(of anchor: NoteCard, cards: [NoteCard]) -> Set<UUID> {
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let anchors = Set(Self.anchors(in: cards).map(\.id))
        var found = Set<UUID>()
        var pending = anchor.mindLinks
        while let id = pending.popLast() {
            guard !anchors.contains(id), found.insert(id).inserted, let card = byID[id] else { continue }
            pending.append(contentsOf: card.mindLinks)
            pending.append(contentsOf: cards.filter { $0.groupNoteId == id }.map(\.id))
        }
        return found
    }

    public static func layer(for cardID: UUID, cards: [NoteCard]) -> UUID? {
        anchors(in: cards).first { members(of: $0, cards: cards).contains(cardID) }?.id
    }

    public static func cards(in layer: UUID?, all cards: [NoteCard]) -> [NoteCard] {
        let anchors = Self.anchors(in: cards)
        if let layer, let anchor = anchors.first(where: { $0.id == layer }) {
            let members = Self.members(of: anchor, cards: cards)
            let selected = cards.filter { members.contains($0.id) }
            // MarginNote's ordered mind links encode the child-map tree. Preserve
            // existing explicit parents; assign each remaining node once to avoid cycles.
            var parents: [UUID: UUID] = [:]
            var visited = Set(anchor.mindLinks)
            var queue = anchor.mindLinks
            let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            var cursor = 0
            while cursor < queue.count {
                let id = queue[cursor]; cursor += 1
                guard let card = byID[id] else { continue }
                for child in card.mindLinks where members.contains(child) && visited.insert(child).inserted {
                    parents[child] = id
                    queue.append(child)
                }
            }
            return selected.map { card in
                var projected = card
                if projected.groupNoteId == nil { projected.groupNoteId = parents[card.id] }
                return projected
            }
        }
        let childMembers = anchors.reduce(into: Set<UUID>()) { $0.formUnion(Self.members(of: $1, cards: cards)) }
        return cards.filter { !childMembers.contains($0.id) }
    }
}
