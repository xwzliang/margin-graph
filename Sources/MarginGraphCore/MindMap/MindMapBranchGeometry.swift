import Foundation
import CoreGraphics

/// Resting branch paths are independent of viewport motion. Only incident paths
/// need rebuilding while a card is moving.
public struct MindMapBranchGeometry {
    public let sourceID: UUID
    public let targetID: UUID?
    public let colorIndex: Int
    public let path: CGPath

    public func intersects(_ viewport: CGRect) -> Bool {
        // Expand zero-height horizontal stems and allow for the stroke.
        path.boundingBoxOfPath.insetBy(dx: -4, dy: -4).intersects(viewport)
    }

    public func moving(frames: [UUID: CGRect]) -> MindMapBranchGeometry {
        guard let source = frames[sourceID] else { return self }
        let updated: CGPath
        if let targetID, let target = frames[targetID] {
            updated = TreeLayout.connectorPath(from: source, to: target)
        } else {
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: source.maxX, y: source.midY))
            stem.addLine(to: CGPoint(x: source.maxX + 14, y: source.midY))
            updated = stem
        }
        return Self(sourceID: sourceID, targetID: targetID, colorIndex: colorIndex, path: updated)
    }

    public static func build(cards: [NoteCard], frames: [UUID: CGRect], visible: Set<UUID>) -> [Self] {
        let index = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let parents = Set(cards.compactMap(\.groupNoteId))
        return cards.filter { visible.contains($0.id) }.flatMap { card -> [Self] in
            var result: [Self] = []
            if let parentID = card.groupNoteId, visible.contains(parentID),
               let parent = frames[parentID], let child = frames[card.id] {
                result.append(Self(sourceID: parentID, targetID: card.id,
                                   colorIndex: index[parentID]?.colorIndex ?? 0,
                                   path: TreeLayout.connectorPath(from: parent, to: child)))
            }
            if card.isFolded, parents.contains(card.id), let frame = frames[card.id] {
                let stem = CGMutablePath()
                stem.move(to: CGPoint(x: frame.maxX, y: frame.midY))
                stem.addLine(to: CGPoint(x: frame.maxX + 14, y: frame.midY))
                result.append(Self(sourceID: card.id, targetID: nil, colorIndex: card.colorIndex, path: stem))
            }
            return result
        }
    }
}
