import Foundation
import SQLite3

public extension SRSEngine {
    static func calculate(
        item: ReviewItem,
        quality: Int,
        at reviewDate: Date = Date(),
        calendar: Calendar = .current
    ) -> ReviewItem {
        review(item, grade: quality, at: reviewDate, calendar: calendar)
    }
}

public extension Database {
    private static let dueCardsInTopic = """
        FROM cards c WHERE c.topic_id = ?
        AND NOT EXISTS (
            SELECT 1 FROM review_items r WHERE r.card_id = c.id AND r.due_date > CAST(? AS REAL)
        )
        """

    func insertReviewItem(_ item: ReviewItem) throws {
        try upsertReviewItem(item)
    }

    func reviewItem(cardId: UUID) throws -> ReviewItem? {
        try dueReviewItems(asOf: .distantFuture).first { $0.cardId == cardId }
    }

    func dueCardsForTopic(id: UUID, date: Date = Date()) throws -> [NoteCard] {
        try cards(
            sql: "SELECT c.* \(Self.dueCardsInTopic) ORDER BY c.created_at",
            values: [id.uuidString, String(date.timeIntervalSince1970)]
        )
    }

    func dueCardIDsForTopic(id: UUID, date: Date = Date()) throws -> Set<UUID> {
        try withStatement("SELECT c.id \(Self.dueCardsInTopic)") { statement in
            bind(id.uuidString, to: 1, in: statement)
            bind(date.timeIntervalSince1970, to: 2, in: statement)
            var ids = Set<UUID>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = text(statement, 0).flatMap(UUID.init(uuidString:)) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    @discardableResult
    func recordCardReview(id: UUID, quality: Int) throws -> ReviewItem {
        guard try getCard(id: id) != nil else {
            throw DatabaseError.sqlite("Card not found: \(id.uuidString)")
        }
        let current = try reviewItem(cardId: id) ?? ReviewItem(cardId: id)
        let updated = SRSEngine.calculate(item: current, quality: quality)
        try insertReviewItem(updated)
        return updated
    }
}
