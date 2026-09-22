import Foundation
import SQLite3

public extension Database {
    func createDeck(id: UUID = UUID(), title: String) throws -> CardDeck {
        let deck = CardDeck(id: id, title: title)
        try withStatement("INSERT OR REPLACE INTO card_decks(id, title, created_at, updated_at) VALUES(?, ?, ?, ?)") { stmt in
            bind(deck.id.uuidString, to: 1, in: stmt)
            bind(deck.title, to: 2, in: stmt)
            bind(deck.createdAt.timeIntervalSince1970, to: 3, in: stmt)
            bind(deck.updatedAt.timeIntervalSince1970, to: 4, in: stmt)
            try requireDone(stmt)
        }
        return deck
    }

    func allDecks() throws -> [CardDeck] {
        try withStatement("SELECT id, title, created_at, updated_at FROM card_decks ORDER BY created_at DESC") { stmt in
            var results: [CardDeck] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = text(stmt, 0), let id = UUID(uuidString: idStr),
                   let title = text(stmt, 1) {
                    let createdAt = Date(timeIntervalSince1970: double(stmt, 2) ?? 0)
                    let updatedAt = Date(timeIntervalSince1970: double(stmt, 3) ?? 0)
                    results.append(CardDeck(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt))
                }
            }
            return results
        }
    }

    func getDeck(id: UUID) throws -> CardDeck? {
        try withStatement("SELECT id, title, created_at, updated_at FROM card_decks WHERE id = ?") { stmt in
            bind(id.uuidString, to: 1, in: stmt)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = text(stmt, 0), let id = UUID(uuidString: idStr),
                   let title = text(stmt, 1) {
                    let createdAt = Date(timeIntervalSince1970: double(stmt, 2) ?? 0)
                    let updatedAt = Date(timeIntervalSince1970: double(stmt, 3) ?? 0)
                    return CardDeck(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt)
                }
            }
            return nil
        }
    }

    func updateDeck(_ deck: CardDeck) throws {
        try withStatement("UPDATE card_decks SET title = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(deck.title, to: 1, in: stmt)
            bind(deck.updatedAt.timeIntervalSince1970, to: 2, in: stmt)
            bind(deck.id.uuidString, to: 3, in: stmt)
            try requireDone(stmt)
        }
    }

    func deleteDeck(id: UUID) throws {
        try withStatement("DELETE FROM card_decks WHERE id = ?") { stmt in
            bind(id.uuidString, to: 1, in: stmt)
            try requireDone(stmt)
        }
    }

    func addCardsToDeck(cardIds: [UUID], deckId: UUID) throws {
        let now = Date().timeIntervalSince1970
        for cardId in cardIds {
            try withStatement("INSERT OR IGNORE INTO deck_cards(deck_id, card_id, created_at) VALUES(?, ?, ?)") { stmt in
                bind(deckId.uuidString, to: 1, in: stmt)
                bind(cardId.uuidString, to: 2, in: stmt)
                bind(now, to: 3, in: stmt)
                try requireDone(stmt)
            }
            // Ensure card has a review item initialized for SRS review
            if try reviewItem(cardId: cardId) == nil {
                try insertReviewItem(ReviewItem(cardId: cardId, dueDate: Date()))
            }
        }
        // Update deck's updated_at timestamp
        try withStatement("UPDATE card_decks SET updated_at = ? WHERE id = ?") { stmt in
            bind(now, to: 1, in: stmt)
            bind(deckId.uuidString, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }

    func removeCardsFromDeck(cardIds: [UUID], deckId: UUID) throws {
        for cardId in cardIds {
            try withStatement("DELETE FROM deck_cards WHERE deck_id = ? AND card_id = ?") { stmt in
                bind(deckId.uuidString, to: 1, in: stmt)
                bind(cardId.uuidString, to: 2, in: stmt)
                try requireDone(stmt)
            }
        }
    }

    func cardsForDeck(deckId: UUID) throws -> [NoteCard] {
        let sql = """
        SELECT c.id, c.topic_id, c.book_md5, c.title, c.highlight_text, c.notes_text, c.group_note_id,
               c.mind_x, c.mind_y, c.mind_links, c.is_folded, c.start_page, c.end_page,
               c.start_x, c.start_y, c.end_x, c.end_y, c.color_index, c.tags, c.highlight_pic_hash,
               c.created_at, c.updated_at, c.highlight_rects, c.emphasis_list, c.emphasis_rects,
               c.excerpt_segments
        FROM cards c
        INNER JOIN deck_cards dc ON c.id = dc.card_id
        WHERE dc.deck_id = ?
        ORDER BY dc.created_at ASC
        """
        return try withStatement(sql) { stmt in
            bind(deckId.uuidString, to: 1, in: stmt)
            var results: [NoteCard] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let card = try decodeCard(stmt) {
                    results.append(card)
                }
            }
            return results
        }
    }

    func dueCardsForDeck(deckId: UUID, date: Date = Date()) throws -> [NoteCard] {
        let cards = try cardsForDeck(deckId: deckId)
        let reviews = Dictionary(
            uniqueKeysWithValues: try dueReviewItems(asOf: .distantFuture).map { ($0.cardId, $0) }
        )
        return cards.filter { card in
            guard let review = reviews[card.id] else { return true }
            return review.dueDate <= date
        }
    }

    func deckCardCounts() throws -> [UUID: Int] {
        try withStatement("SELECT deck_id, count(card_id) FROM deck_cards GROUP BY deck_id") { stmt in
            var counts: [UUID: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = text(stmt, 0), let id = UUID(uuidString: idStr) {
                    counts[id] = int(stmt, 1) ?? 0
                }
            }
            return counts
        }
    }

    func dueDeckCardCounts(date: Date = Date()) throws -> [UUID: Int] {
        let decks = try allDecks()
        var result: [UUID: Int] = [:]
        for deck in decks {
            let due = try dueCardsForDeck(deckId: deck.id, date: date)
            result[deck.id] = due.count
        }
        return result
    }

    func recordDeckReview(id: UUID, date: Date = Date()) throws {
        try withStatement("INSERT OR REPLACE INTO deck_reviews(deck_id, last_reviewed) VALUES(?, ?)") { stmt in
            bind(id.uuidString, to: 1, in: stmt)
            bind(date.timeIntervalSince1970, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }

    func allDeckReviews() throws -> [UUID: Date] {
        try withStatement("SELECT deck_id, last_reviewed FROM deck_reviews") { stmt in
            var result: [UUID: Date] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = text(stmt, 0), let id = UUID(uuidString: idStr) {
                    let time = double(stmt, 1) ?? 0
                    result[id] = Date(timeIntervalSince1970: time)
                }
            }
            return result
        }
    }
}
