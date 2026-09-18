import Foundation
import CoreGraphics

public extension Database {
    func reparentCard(id: UUID, to parentID: UUID?) throws {
        guard var card = try getCard(id: id) else { return }
        if let parentID {
            guard parentID != id,
                  let parent = try getCard(id: parentID),
                  parent.topicId == card.topicId else { return }
            var cursor: UUID? = parent.groupNoteId
            while let current = cursor {
                if current == id { return }
                cursor = try getCard(id: current)?.groupNoteId
            }
        }
        card.groupNoteId = parentID
        card.updatedAt = Date()
        try updateCard(card)
    }

    func setCardFolded(id: UUID, folded: Bool) throws {
        guard var card = try getCard(id: id) else { return }
        card.isFolded = folded
        card.updatedAt = Date()
        try updateCard(card)
    }

    func moveCard(id: UUID, to position: CGPoint) throws {
        guard var card = try getCard(id: id) else { return }
        card.mindPos = position
        card.updatedAt = Date()
        try updateCard(card)
    }

    func indentCard(id: UUID, under siblingID: UUID) throws {
        try reparentCard(id: id, to: siblingID)
    }

    func outdentCard(id: UUID) throws {
        guard let card = try getCard(id: id),
              let parentID = card.groupNoteId,
              let parent = try getCard(id: parentID) else { return }
        try reparentCard(id: id, to: parent.groupNoteId)
    }

    func reorderCard(id: UUID, before siblingID: UUID?) throws {
        guard var card = try getCard(id: id) else { return }
        let siblings = try childCards(parentId: card.groupNoteId, topicId: card.topicId)
            .filter { $0.id != id }
        let targetY: CGFloat
        if let siblingID,
           let index = siblings.firstIndex(where: { $0.id == siblingID }) {
            let previousY = index > 0 ? siblings[index - 1].mindPos?.y : nil
            let nextY = siblings[index].mindPos?.y
            switch (previousY, nextY) {
            case let (a?, b?): targetY = (a + b) / 2
            case let (nil, b?): targetY = b - 100
            default: targetY = card.mindPos?.y ?? 0
            }
        } else {
            targetY = (siblings.last?.mindPos?.y ?? 0) + 100
        }
        card.mindPos = CGPoint(x: card.mindPos?.x ?? 0, y: targetY)
        card.updatedAt = Date()
        try updateCard(card)
    }
}
