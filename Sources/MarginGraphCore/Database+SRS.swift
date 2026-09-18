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
        let cards = try cardsForTopic(id: id)
        let reviews = Dictionary(
            uniqueKeysWithValues: try dueReviewItems(asOf: .distantFuture).map { ($0.cardId, $0) }
        )
        return cards.filter { card in
            guard let review = reviews[card.id] else { return true }
            return review.dueDate <= date
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
