import Foundation

enum MarginNoteHierarchy {
    /// Restore branches from MarginNote's ZMINDLINKS. Older imports also mirrored
    /// these IDs into unlabeled, one-way CardLinks. Both records identify an imported edge.
    static func restore(cards: inout [NoteCard], links: inout [CardLink]) {
        guard links.contains(where: { $0.label == nil && !$0.isBidirectional }) else { return }

        let indices = Dictionary(cards.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let anchors = MindMapLayers.anchors(in: cards)
        let anchorIDs = Set(anchors.map(\.id))
        let layerRoots = Set(anchors.flatMap(\.mindLinks))
        let sourceTargets = Dictionary(uniqueKeysWithValues: indices.compactMap { id, index in
            cards[index].mindLinks.isEmpty ? nil : (id, Set(cards[index].mindLinks))
        })
        let imported = links.filter { link in
            guard link.label == nil, !link.isBidirectional,
                  sourceTargets[link.sourceCardId]?.contains(link.targetCardId) == true,
                  let source = indices[link.sourceCardId], let target = indices[link.targetCardId] else { return false }
            return cards[source].topicId == link.topicId && cards[target].topicId == link.topicId
        }
        guard !imported.isEmpty else { return }

        var parents = Dictionary(uniqueKeysWithValues: indices.compactMap { id, index in
            cards[index].groupNoteId.map { (id, $0) }
        })
        var candidateSources: [UUID: Set<UUID>] = [:]
        var processedTargets: [UUID: Set<UUID>] = [:]
        for link in imported where !anchorIDs.contains(link.sourceCardId) {
            processedTargets[link.sourceCardId, default: []].insert(link.targetCardId)
            if link.sourceCardId != link.targetCardId, parents[link.targetCardId] == nil,
               !anchorIDs.contains(link.targetCardId), !layerRoots.contains(link.targetCardId) {
                candidateSources[link.targetCardId, default: []].insert(link.sourceCardId)
            }
        }

        let proposed = candidateSources.compactMapValues { $0.count == 1 ? $0.first : nil }
        let graph = parents.merging(proposed) { existing, _ in existing }
        let topics = indices.mapValues { cards[$0].topicId }
        var reachesRoot: [UUID: Bool] = [:]
        for (child, parent) in proposed {
            var path = Set<UUID>()
            var current: UUID? = child
            while let id = current, topics[id] == topics[child], reachesRoot[id] == nil, path.insert(id).inserted {
                current = graph[id]
            }
            let safe = current.map { topics[$0] == topics[child] && reachesRoot[$0] == true } ?? true
            for id in path { reachesRoot[id] = safe }
            if safe {
                parents[child] = parent
                if let index = indices[child] { cards[index].groupNoteId = parent }
            }
        }

        // Consume the legacy encoding even when a conflicting or cyclic edge must
        // stay a reference. Later edits should not reinterpret that reference as a parent.
        for (source, targets) in processedTargets {
            if let index = indices[source] { cards[index].mindLinks.removeAll { targets.contains($0) } }
        }
        let duplicates = Set(imported.filter {
            parents[$0.targetCardId] == $0.sourceCardId || anchorIDs.contains($0.sourceCardId)
        }.map(\.id))
        links.removeAll { duplicates.contains($0.id) }
    }
}
