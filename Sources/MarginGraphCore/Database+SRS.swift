import Foundation

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
    func insertReviewItem(_ item: ReviewItem) throws {
        try upsertReviewItem(item)
    }

    func reviewItem(cardId: UUID) throws -> ReviewItem? {
        try dueReviewItems(asOf: .distantFuture).first { $0.cardId == cardId }
    }

    func dueCardsForTopic(id: UUID, date: Date = Date()) throws -> [NoteCard] {
        try cards(
            sql: """
            SELECT c.* FROM cards c WHERE topic_id = ?
            AND NOT EXISTS (
                SELECT 1 FROM review_items r WHERE r.card_id = c.id AND r.due_date > CAST(? AS REAL)
            ) ORDER BY c.created_at
            """,
            values: [id.uuidString, String(date.timeIntervalSince1970)]
        )
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
