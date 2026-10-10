import Foundation
import CoreGraphics

public struct DocumentFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var parentId: UUID?
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), parentId: UUID? = nil, name: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Document: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var filePath: String
    public var md5: String
    public var totalPages: Int
    public var lastVisited: Date?
    public var lastPageIndex: Int
    public var lastPageOffsetY: Double
    public var mindPanX: Double?
    public var mindPanY: Double?
    public var mindZoomScale: Double?
    public var documentType: String
    public var folderId: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        filePath: String,
        md5: String,
        totalPages: Int,
        lastVisited: Date? = nil,
        lastPageIndex: Int = 0,
        lastPageOffsetY: Double = 0.0,
        mindPanX: Double? = nil,
        mindPanY: Double? = nil,
        mindZoomScale: Double? = nil,
        documentType: String = "pdf",
        folderId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.md5 = md5
        self.totalPages = totalPages
        self.lastVisited = lastVisited
        self.lastPageIndex = lastPageIndex
        self.lastPageOffsetY = lastPageOffsetY
        self.mindPanX = mindPanX
        self.mindPanY = mindPanY
        self.mindZoomScale = mindZoomScale
        self.documentType = documentType
        self.folderId = folderId
    }

    public static func stableUUID(_ raw: String) -> UUID {
        if let uuid = UUID(uuidString: raw) { return uuid }

        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for byte in raw.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte)) &* 0x100000001b3
        }

        var bytes = withUnsafeBytes(of: a.bigEndian, Array.init)
            + withUnsafeBytes(of: b.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct Topic: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var bookMD5List: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var mindPanX: Double?
    public var mindPanY: Double?
    public var mindZoomScale: Double?
    public var lastDocumentMD5: String?

    public init(
        id: UUID = UUID(),
        title: String,
        bookMD5List: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        mindPanX: Double? = nil,
        mindPanY: Double? = nil,
        mindZoomScale: Double? = nil,
        lastDocumentMD5: String? = nil
    ) {
        self.id = id
        self.title = title
        self.bookMD5List = bookMD5List
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mindPanX = mindPanX
        self.mindPanY = mindPanY
        self.mindZoomScale = mindZoomScale
        self.lastDocumentMD5 = lastDocumentMD5
    }
}

public struct CardDeck: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct HighlightRect: Codable, Hashable, Sendable {
    public var page: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ExcerptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var rects: [HighlightRect]

    public init(id: UUID = UUID(), text: String = "", rects: [HighlightRect] = []) {
        self.id = id
        self.text = text
        self.rects = rects
    }
}

public struct NoteCard: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var topicId: UUID
    public var bookMD5: String?
    public var title: String
    public var highlightText: String
    public var notesText: String
    public var groupNoteId: UUID?
    public var mindPos: CGPoint?
    public var mindLinks: [UUID]
    public var isFolded: Bool
    public var startPage: Int?
    public var endPage: Int?
    public var startPos: CGPoint?
    public var endPos: CGPoint?
    public var colorIndex: Int
    public var tags: [String]
    public var highlightPicHash: String?
    public var highlightRects: [HighlightRect]
    public var emphasisList: [String]
    public var emphasisRects: [HighlightRect]
    public var excerptSegments: [ExcerptSegment]
    public var mediaType: String
    public var videoStartTime: Double?
    public var videoEndTime: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        topicId: UUID,
        bookMD5: String? = nil,
        title: String = "",
        highlightText: String = "",
        notesText: String = "",
        groupNoteId: UUID? = nil,
        mindPos: CGPoint? = nil,
        mindLinks: [UUID] = [],
        isFolded: Bool = false,
        startPage: Int? = nil,
        endPage: Int? = nil,
        startPos: CGPoint? = nil,
        endPos: CGPoint? = nil,
        colorIndex: Int = 0,
        tags: [String] = [],
        highlightPicHash: String? = nil,
        highlightRects: [HighlightRect] = [],
        emphasisList: [String] = [],
        emphasisRects: [HighlightRect] = [],
        excerptSegments: [ExcerptSegment] = [],
        mediaType: String = "pdf",
        videoStartTime: Double? = nil,
        videoEndTime: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.topicId = topicId
        self.bookMD5 = bookMD5
        self.title = title
        self.highlightText = highlightText
        self.notesText = notesText
        self.groupNoteId = groupNoteId
        self.mindPos = mindPos
        self.mindLinks = mindLinks
        self.isFolded = isFolded
        self.startPage = startPage
        self.endPage = endPage
        self.startPos = startPos
        self.endPos = endPos
        self.colorIndex = colorIndex
        self.tags = tags
        self.highlightPicHash = highlightPicHash
        self.highlightRects = highlightRects
        self.emphasisList = emphasisList
        self.emphasisRects = emphasisRects
        self.excerptSegments = excerptSegments
        self.mediaType = mediaType
        self.videoStartTime = videoStartTime
        self.videoEndTime = videoEndTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var effectiveSegments: [ExcerptSegment] {
        if !excerptSegments.isEmpty {
            return excerptSegments
        }
        if !highlightRects.isEmpty || !highlightText.isEmpty {
            return [ExcerptSegment(id: id, text: highlightText, rects: highlightRects)]
        }
        return []
    }

    public static func allDescendants(of cardId: UUID, in cards: [NoteCard]) -> [NoteCard] {
        let childrenByParent = Dictionary(grouping: cards.filter { $0.groupNoteId != nil }, by: { $0.groupNoteId! })
        var result: [NoteCard] = []
        var queue: [UUID] = [cardId]
        var visited: Set<UUID> = [cardId]

        while !queue.isEmpty {
            let parentId = queue.removeFirst()
            guard let children = childrenByParent[parentId] else { continue }
            for child in children where !visited.contains(child.id) {
                visited.insert(child.id)
                result.append(child)
                queue.append(child.id)
            }
        }
        return result
    }

    public func allDescendants(in cards: [NoteCard]) -> [NoteCard] {
        NoteCard.allDescendants(of: id, in: cards)
    }

    /// For MarginNote libraries, backups (.marginbackupall), or exports (.marginpkg),
    /// MarginNote often creates a top-level synthetic "document note card" that is the father
    /// of all other remaining note cards in the notebook.
    /// This method identifies if a single top-level root card exists and is the ancestor of
    /// ALL other remaining note cards in the topic. If so, it ignores that root card and
    /// promotes its direct children to top-level root cards (groupNoteId = nil).
    public static func filterMarginNoteDocumentRootCard(from cards: [NoteCard]) -> [NoteCard] {
        guard cards.count > 1 else { return cards }

        var result = cards
        var removedAny = true

        while removedAny {
            removedAny = false
            let currentCards = result
            let candidates = currentCards.filter { card in
                card.groupNoteId == nil &&
                card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                card.notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                card.highlightRects.isEmpty &&
                card.startPage == nil &&
                card.highlightPicHash == nil
            }

            guard !candidates.isEmpty else { break }

            for rootCard in candidates {
                let otherCardsCount = currentCards.count - 1
                guard otherCardsCount > 0 else { continue }

                // Check groupNoteId tree hierarchy
                let descendants = allDescendants(of: rootCard.id, in: currentCards)
                let sameBookCards = (rootCard.bookMD5 != nil)
                    ? currentCards.filter { $0.bookMD5 == rootCard.bookMD5 && $0.id != rootCard.id }
                    : []

                let isGroupTreeRootOverall = descendants.count == otherCardsCount || (otherCardsCount >= 5 && Double(descendants.count) / Double(otherCardsCount) >= 0.8)
                let isGroupTreeRootPerBook = !sameBookCards.isEmpty && sameBookCards.count >= 3 &&
                    Double(descendants.filter { $0.bookMD5 == rootCard.bookMD5 }.count) / Double(sameBookCards.count) >= 0.8

                if isGroupTreeRootOverall || isGroupTreeRootPerBook {
                    let isTargetOfOther = currentCards.contains { $0.id != rootCard.id && ($0.mindLinks.contains(rootCard.id) || $0.groupNoteId == rootCard.id) }
                    // In group hierarchy, direct children have groupNoteId == rootCard.id, but no other card should treat it as child
                    let hasParent = currentCards.contains { $0.id != rootCard.id && $0.mindLinks.contains(rootCard.id) }
                    if !hasParent {
                        result = removeCardAndPromoteChildren(rootCard.id, from: currentCards)
                        removedAny = true
                        break
                    }
                }

                // Check mindLinks graph reachability
                let mindLinksMap = Dictionary(uniqueKeysWithValues: currentCards.map { ($0.id, $0.mindLinks) })
                var reachable = Set<UUID>()
                var queue: [UUID] = [rootCard.id]
                while !queue.isEmpty {
                    let curr = queue.removeFirst()
                    for target in mindLinksMap[curr] ?? [] where target != rootCard.id {
                        if reachable.insert(target).inserted {
                            queue.append(target)
                        }
                    }
                }

                let isMindLinksRootOverall = (reachable.count == otherCardsCount) || (otherCardsCount >= 5 && Double(reachable.count) / Double(otherCardsCount) >= 0.8)
                let reachableSameBook = sameBookCards.filter { reachable.contains($0.id) }
                let isMindLinksRootPerBook = !sameBookCards.isEmpty && sameBookCards.count >= 3 &&
                    (Double(reachableSameBook.count) / Double(sameBookCards.count) >= 0.8)

                if isMindLinksRootOverall || isMindLinksRootPerBook {
                    let isTargetOfOther = currentCards.contains { $0.id != rootCard.id && $0.mindLinks.contains(rootCard.id) }
                    if !isTargetOfOther {
                        result = removeCardAndPromoteChildren(rootCard.id, from: currentCards)
                        removedAny = true
                        break
                    }
                }
            }
        }

        return result
    }

    private static func removeCardAndPromoteChildren(_ rootCardID: UUID, from cards: [NoteCard]) -> [NoteCard] {
        cards.compactMap { card in
            if card.id == rootCardID {
                return nil
            }
            var updated = card
            if updated.groupNoteId == rootCardID {
                updated.groupNoteId = nil
            }
            if updated.mindLinks.contains(rootCardID) {
                updated.mindLinks.removeAll { $0 == rootCardID }
            }
            return updated
        }
    }
}

public struct CardLink: Codable, Hashable, Sendable {
    public var id: UUID
    public var topicId: UUID
    public var sourceCardId: UUID
    public var targetCardId: UUID
    public var label: String?
    public var isBidirectional: Bool

    public init(id: UUID = UUID(), topicId: UUID, sourceCardId: UUID, targetCardId: UUID, label: String? = nil, isBidirectional: Bool = false) {
        self.id = id
        self.topicId = topicId
        self.sourceCardId = sourceCardId
        self.targetCardId = targetCardId
        self.label = label
        self.isBidirectional = isBidirectional
    }
}

public struct ReviewItem: Codable, Hashable, Sendable {
    public var cardId: UUID
    public var easeFactor: Double
    public var intervalDays: Int
    public var repetitions: Int
    public var dueDate: Date
    public var lastReviewed: Date?

    public init(cardId: UUID, easeFactor: Double = 2.5, intervalDays: Int = 0, repetitions: Int = 0, dueDate: Date = Date(), lastReviewed: Date? = nil) {
        self.cardId = cardId
        self.easeFactor = easeFactor
        self.intervalDays = intervalDays
        self.repetitions = repetitions
        self.dueDate = dueDate
        self.lastReviewed = lastReviewed
    }
}

public enum ToolbarOwner: String, Codable, Hashable, Sendable {
    case none
    case mindMap
    case pdf
}
