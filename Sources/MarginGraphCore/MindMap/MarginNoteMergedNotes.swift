import Foundation

enum MarginNoteMergedNotes {
    // Earlier imports kept both rows, but discarded ZNOTES. Require the
    // original group ID and the complete mirrored excerpt to recover a fragment.
    static func legacyGroups(in cards: [NoteCard]) -> [UUID: [UUID]] {
        let fragments = cards.filter { card in
            card.groupNoteId != nil && card.title.isEmpty && card.notesText.isEmpty
                && card.mindPos == nil && card.mindLinks.isEmpty && !card.highlightRects.isEmpty
                && !card.excerptSegments.contains { $0.id != card.id }
        }
        guard !fragments.isEmpty else { return [:] }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [UUID: [UUID]] = [:]
        for fragment in fragments {
            guard let ownerID = fragment.groupNoteId, let owner = byID[ownerID] else { continue }
            let excerpt = normalized(fragment.highlightText)
            let notes = normalized(owner.notesText)
            guard !excerpt.isEmpty, (" " + notes + " ").contains(" " + excerpt + " ") else { continue }
            groups[ownerID, default: []].append(fragment.id)
        }
        return groups.mapValues { fragments in
            fragments.sorted { first, second in
                guard let lhs = byID[first], let rhs = byID[second] else { return first.uuidString < second.uuidString }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return first.uuidString < second.uuidString
            }
        }
    }

    /// Moves selection segments into the visible note and returns old-ID aliases.
    static func combine(cards: inout [NoteCard], links: inout [CardLink],
                        groups: [UUID: [UUID]]) -> [UUID: UUID] {
        guard !groups.isEmpty else { return [:] }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var owners: [UUID: UUID] = [:]
        for (id, fragments) in groups {
            guard let owner = byID[id] else { continue }
            for fragmentID in fragments {
                guard let fragment = byID[fragmentID], fragment.id != id,
                      fragment.groupNoteId == id, fragment.topicId == owner.topicId,
                      let book = fragment.bookMD5, let ownerBook = owner.bookMD5,
                      Database.bookHashesMatch(book, ownerBook), fragment.mediaType == owner.mediaType,
                      fragment.highlightPicHash == nil || owner.highlightPicHash == fragment.highlightPicHash,
                      fragment.videoStartTime == nil || (fragment.videoStartTime == owner.videoStartTime
                        && fragment.videoEndTime == owner.videoEndTime) else { continue }
                owners[fragmentID] = id
            }
        }

        // Flatten nested groups. Leave a malformed cycle intact.
        let directOwners = owners
        for fragment in directOwners.keys {
            var root = fragment
            var visited = Set<UUID>()
            while let owner = directOwners[root], visited.insert(root).inserted { root = owner }
            owners[fragment] = directOwners[root] == nil ? root : nil
        }
        guard !owners.isEmpty else { return [:] }

        let fragmentsByOwner = Dictionary(grouping: cards.filter { owners[$0.id] != nil },
                                          by: { owners[$0.id]! })
        // The native LinkNote list orders direct selections. Keep the input order
        // for any nested fragments.
        var combined: [NoteCard] = []
        for var card in cards where owners[card.id] == nil {
            if let fragments = fragmentsByOwner[card.id] {
                let ordered = (groups[card.id] ?? []).compactMap { owners[$0] == card.id ? byID[$0] : nil }
                var included = Set<UUID>()
                for fragment in ordered + fragments where included.insert(fragment.id).inserted {
                    append(fragment, to: &card)
                }
            }
            if let parent = card.groupNoteId, let owner = owners[parent] {
                card.groupNoteId = owner == card.id ? nil : owner
            }
            var seen = Set<UUID>()
            card.mindLinks = card.mindLinks.map { owners[$0] ?? $0 }
                .filter { $0 != card.id && seen.insert($0).inserted }
            combined.append(card)
        }
        cards = combined
        links = links.compactMap { original in
            var link = original
            link.sourceCardId = owners[link.sourceCardId] ?? link.sourceCardId
            link.targetCardId = owners[link.targetCardId] ?? link.targetCardId
            return link.sourceCardId == link.targetCardId && link != original ? nil : link
        }
        return owners
    }

    private static func append(_ fragment: NoteCard, to owner: inout NoteCard) {
        let segments = owner.effectiveSegments + fragment.effectiveSegments
        var seen = Set<UUID>()
        owner.excerptSegments = segments.filter { seen.insert($0.id).inserted }
        owner.highlightRects = orderedUnion(owner.highlightRects, fragment.highlightRects)
        owner.emphasisRects = orderedUnion(owner.emphasisRects, fragment.emphasisRects)
        owner.emphasisList = orderedUnion(owner.emphasisList, fragment.emphasisList)
        owner.tags = orderedUnion(owner.tags, fragment.tags)
        owner.mindLinks = orderedUnion(owner.mindLinks, fragment.mindLinks)
        owner.startPage = owner.startPage ?? fragment.startPage
        owner.startPos = owner.startPos ?? fragment.startPos
        if let page = fragment.endPage ?? fragment.startPage, owner.endPage.map({ $0 < page }) ?? true {
            owner.endPage = page
            owner.endPos = fragment.endPos
        }
        for text in [fragment.title, fragment.highlightText, fragment.notesText] {
            let excerpt = normalized(text)
            let body = normalized(owner.title + "\n" + owner.highlightText + "\n" + owner.notesText)
            if !excerpt.isEmpty && !(" " + body + " ").contains(" " + excerpt + " ") {
                owner.notesText += (owner.notesText.isEmpty ? "" : "\n\n") + text
            }
        }
    }

    private static func orderedUnion<T: Hashable>(_ first: [T], _ second: [T]) -> [T] {
        var seen = Set(first)
        return first + second.filter { seen.insert($0).inserted }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
