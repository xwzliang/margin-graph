import XCTest
@testable import MarginGraphCore

final class FlashcardReviewTests: XCTestCase {
    func testClozeParserMasksAndRevealsSupportedForms() {
        let text = "Alpha {{c1::beta}} gamma {{delta}} and [epsilon]."
        XCTAssertEqual(
            ClozeParser.masked(text),
            "Alpha [...] gamma [...] and [...]."
        )
        XCTAssertEqual(
            ClozeParser.revealed(text),
            "Alpha beta gamma delta and epsilon."
        )
    }

    func testDueCardsAndReviewStateTransitions() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Review")
        try database.insertTopic(topic)

        let first = NoteCard(topicId: topic.id, title: "One")
        let second = NoteCard(topicId: topic.id, title: "Two")
        try database.insertCard(first)
        try database.insertCard(second)

        XCTAssertEqual(Set(try database.dueCardsForTopic(id: topic.id).map(\.id)), Set([first.id, second.id]))

        let reviewed = try database.recordCardReview(id: first.id, quality: 4)
        XCTAssertEqual(reviewed.cardId, first.id)
        XCTAssertEqual(reviewed.repetitions, 1)
        XCTAssertEqual(reviewed.intervalDays, 1)
        XCTAssertNotNil(reviewed.lastReviewed)

        let immediateDue = try database.dueCardsForTopic(id: topic.id, date: Date())
        XCTAssertFalse(immediateDue.contains(where: { $0.id == first.id }))
        XCTAssertTrue(immediateDue.contains(where: { $0.id == second.id }))

        let failed = try database.recordCardReview(id: first.id, quality: 1)
        XCTAssertEqual(failed.repetitions, 0)
        XCTAssertGreaterThanOrEqual(failed.easeFactor, 1.3)
    }

    func testDeepLinkRoundTrip() {
        let topicID = UUID()
        let card = NoteCard(topicId: topicID, title: "Linked")

        XCTAssertEqual(
            DeepLinkHandler.parse(card.deepLinkURL),
            .openCard(cardId: card.id)
        )

        let topicURL = DeepLinkHandler.url(forTopic: topicID)
        XCTAssertEqual(
            DeepLinkHandler.parse(topicURL),
            .openTopic(topicId: topicID)
        )

        XCTAssertNil(DeepLinkHandler.parse(URL(string: "https://example.com/note/\(card.id)")!))
    }

    func testAnkiExporterTSV() {
        let topic = Topic(title: "Deck")
        let card = NoteCard(
            topicId: topic.id,
            bookMD5: "book-md5",
            title: "Card",
            highlightText: "The {{c1::answer}} is hidden.",
            notesText: "Extra notes",
            startPage: 4,
            tags: ["tag1", "tag2"]
        )

        let output = AnkiExporter.export(topic: topic, cards: [card])
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(String(lines[0]), "Front\tBack\tTags\tSourceBook\tPage")
        XCTAssertTrue(String(lines[1]).contains("The [...] is hidden."))
        XCTAssertTrue(String(lines[1]).contains("The answer is hidden.<br><br>Extra notes"))
        XCTAssertTrue(String(lines[1]).contains("tag1 tag2"))
        XCTAssertTrue(String(lines[1]).contains("book-md5"))
        XCTAssertTrue(String(lines[1]).hasSuffix("\t5"))
    }
}
