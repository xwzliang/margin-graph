import Foundation
import CoreGraphics

public struct Document: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var filePath: String
    public var md5: String
    public var totalPages: Int
    public var lastVisited: Date?

    public init(id: UUID = UUID(), title: String, filePath: String, md5: String, totalPages: Int, lastVisited: Date? = nil) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.md5 = md5
        self.totalPages = totalPages
        self.lastVisited = lastVisited
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

    public init(id: UUID = UUID(), title: String, bookMD5List: [String] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.bookMD5List = bookMD5List
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
