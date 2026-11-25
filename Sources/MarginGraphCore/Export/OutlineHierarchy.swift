import Foundation

enum OutlineHierarchy {
    static func group(_ cards: [NoteCard]) -> [UUID?: [NoteCard]] {
        var ids = Set<UUID>()
        let ordered = cards.filter { ids.insert($0.id).inserted }.sorted(by: cardOrder)
        var parents: [UUID: UUID] = [:]
        for card in ordered {
            if let parent = card.groupNoteId, ids.contains(parent) {
                parents[card.id] = parent
            }
        }

        // A parent chain can end at a root or enter a cycle. Break one edge
        // inside each cycle so attached branches retain their real parent.
        var resolved = Set<UUID>()
        for card in ordered where !resolved.contains(card.id) {
            var path: [UUID] = []
            var positions: [UUID: Int] = [:]
            var next: UUID? = card.id
            while let id = next, !resolved.contains(id) {
                if let start = positions[id] {
                    let root = path[start...].min { $0.uuidString < $1.uuidString }!
                    parents.removeValue(forKey: root)
                    break
                }
                positions[id] = path.count
                path.append(id)
                next = parents[id]
            }
            resolved.formUnion(path)
        }
        return Dictionary(grouping: ordered, by: { parents[$0.id] })
    }

    nonisolated private static func cardOrder(_ lhs: NoteCard, _ rhs: NoteCard) -> Bool {
        let ly = lhs.mindPos?.y ?? CGFloat(lhs.createdAt.timeIntervalSince1970)
        let ry = rhs.mindPos?.y ?? CGFloat(rhs.createdAt.timeIntervalSince1970)
        return ly == ry ? lhs.createdAt < rhs.createdAt : ly < ry
    }
}
