import Foundation
import CoreGraphics

/// Built once at gesture start; pointer movement only performs rectangle lookups.
public struct MindMapDragTargets {
    public let excludedIDs: Set<UUID>
    private let candidates: [(UUID, CGRect)]

    public init(draggedID: UUID, cards: [NoteCard], frames: [UUID: CGRect], visible: Set<UUID>) {
        let children = Dictionary(grouping: cards, by: \.groupNoteId)
        var excluded: Set<UUID> = [draggedID]
        var queue = [draggedID]
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            for child in children[id] ?? [] where excluded.insert(child.id).inserted { queue.append(child.id) }
        }
        excludedIDs = excluded
        candidates = cards.reversed().compactMap { card in
            guard visible.contains(card.id), !excluded.contains(card.id), let frame = frames[card.id] else { return nil }
            return (card.id, frame)
        }
    }

    public func target(at point: CGPoint) -> UUID? {
        candidates.first { $0.1.contains(point) }?.0
    }
}
