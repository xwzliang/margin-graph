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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
