import XCTest
@testable import MarginGraphCore

final class CardDeckTests: XCTestCase {
    func testDeckCreationAndQuery() throws {
        let database = try Database(inMemory: true)

        let deck = try database.createDeck(title: "Neuroscience Deck")
        XCTAssertEqual(deck.title, "Neuroscience Deck")

        let all = try database.allDecks()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, deck.id)

        let fetched = try database.getDeck(id: deck.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Neuroscience Deck")

        try database.deleteDeck(id: deck.id)
        XCTAssertTrue(try database.allDecks().isEmpty)
    }

    func testAddCardsToDeckAndSRSFlow() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Biology")
        try database.insertTopic(topic)

        let card1 = NoteCard(topicId: topic.id, title: "Neuron")
        let card2 = NoteCard(topicId: topic.id, title: "Synapse")
        try database.insertCard(card1)
        try database.insertCard(card2)

        let deck = try database.createDeck(title: "Chapter 1")
        try database.addCardsToDeck(cardIds: [card1.id, card2.id], deckId: deck.id)

        let deckCards = try database.cardsForDeck(deckId: deck.id)
        XCTAssertEqual(deckCards.count, 2)
        XCTAssertTrue(deckCards.contains(where: { $0.id == card1.id }))
        XCTAssertTrue(deckCards.contains(where: { $0.id == card2.id }))

        // Initial counts: both should be due
        let counts = try database.deckCardCounts()
        XCTAssertEqual(counts[deck.id], 2)

        let dueCards = try database.dueCardsForDeck(deckId: deck.id, date: Date())
        XCTAssertEqual(dueCards.count, 2)

        let dueCounts = try database.dueDeckCardCounts(date: Date())
        XCTAssertEqual(dueCounts[deck.id], 2)

        // Review card1 with Good (quality: 4)
        _ = try database.recordCardReview(id: card1.id, quality: 4)

        // Now only card2 should be due today
        let remainingDue = try database.dueCardsForDeck(deckId: deck.id, date: Date())
        XCTAssertEqual(remainingDue.count, 1)
        XCTAssertEqual(remainingDue.first?.id, card2.id)

        let updatedDueCounts = try database.dueDeckCardCounts(date: Date())
        XCTAssertEqual(updatedDueCounts[deck.id], 1)
    }

    func testRecursiveDescendants() {
        let topicID = UUID()
        let root = NoteCard(topicId: topicID, title: "Root")
        let child1 = NoteCard(topicId: topicID, title: "Child 1", groupNoteId: root.id)
        let child2 = NoteCard(topicId: topicID, title: "Child 2", groupNoteId: root.id)
        let grandChild = NoteCard(topicId: topicID, title: "Grandchild", groupNoteId: child1.id)
        let other = NoteCard(topicId: topicID, title: "Unrelated")

        let allCards = [root, child1, child2, grandChild, other]

        let rootDescendants = root.allDescendants(in: allCards)
        XCTAssertEqual(rootDescendants.count, 3)
        let descendantIDs = Set(rootDescendants.map(\.id))
        XCTAssertTrue(descendantIDs.contains(child1.id))
        XCTAssertTrue(descendantIDs.contains(child2.id))
        XCTAssertTrue(descendantIDs.contains(grandChild.id))
        XCTAssertFalse(descendantIDs.contains(other.id))

        let child1Descendants = child1.allDescendants(in: allCards)
        XCTAssertEqual(child1Descendants.count, 1)
        XCTAssertEqual(child1Descendants.first?.id, grandChild.id)

        let leafDescendants = grandChild.allDescendants(in: allCards)
        XCTAssertTrue(leafDescendants.isEmpty)
    }

    func testRemoveCardsFromDeck() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "History")
        try database.insertTopic(topic)

        let card = NoteCard(topicId: topic.id, title: "Rome")
        try database.insertCard(card)

        let deck = try database.createDeck(title: "Antiquity")
        try database.addCardsToDeck(cardIds: [card.id], deckId: deck.id)
        XCTAssertEqual(try database.cardsForDeck(deckId: deck.id).count, 1)

        try database.removeCardsFromDeck(cardIds: [card.id], deckId: deck.id)
        XCTAssertEqual(try database.cardsForDeck(deckId: deck.id).count, 0)
    }

    func testAddHierarchyToDeckAndSRSReview() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Computer Science")
        try database.insertTopic(topic)

        let parent = NoteCard(topicId: topic.id, title: "Data Structures")
        let child1 = NoteCard(topicId: topic.id, title: "Binary Trees", groupNoteId: parent.id)
        let child2 = NoteCard(topicId: topic.id, title: "Hash Tables", groupNoteId: parent.id)
        let grandchild = NoteCard(topicId: topic.id, title: "Red-Black Trees", groupNoteId: child1.id)
        try database.insertCard(parent)
        try database.insertCard(child1)
        try database.insertCard(child2)
        try database.insertCard(grandchild)

        let allCards = [parent, child1, child2, grandchild]

        // 1. Add this note only (1 card) to Deck A
        let deckA = try database.createDeck(title: "Only Parent")
        try database.addCardsToDeck(cardIds: [parent.id], deckId: deckA.id)
        XCTAssertEqual(try database.cardsForDeck(deckId: deckA.id).count, 1)

        // 2. Add this note and all its children (4 cards) to Deck B
        let deckB = try database.createDeck(title: "Full CS Tree")
        let treeCardIDs = [parent.id] + parent.allDescendants(in: allCards).map(\.id)
        XCTAssertEqual(treeCardIDs.count, 4)
        try database.addCardsToDeck(cardIds: treeCardIDs, deckId: deckB.id)

        let deckBCards = try database.cardsForDeck(deckId: deckB.id)
        XCTAssertEqual(deckBCards.count, 4)

        // All 4 cards should initially be due
        let dueInitial = try database.dueCardsForDeck(deckId: deckB.id, date: Date())
        XCTAssertEqual(dueInitial.count, 4)

        // Review the root card with Easy (quality: 5)
        _ = try database.recordCardReview(id: parent.id, quality: 5)

        // Root is no longer due today, remaining 3 cards are due
        let dueAfter1 = try database.dueCardsForDeck(deckId: deckB.id, date: Date())
        XCTAssertEqual(dueAfter1.count, 3)
        XCTAssertFalse(dueAfter1.contains(where: { $0.id == parent.id }))

        // Counts
        let counts = try database.deckCardCounts()
        XCTAssertEqual(counts[deckB.id], 4)
        let dueCounts = try database.dueDeckCardCounts(date: Date())
        XCTAssertEqual(dueCounts[deckB.id], 3)
    }

    func testReviewDeckItemEmptyFilteringAndTopicPromotion() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Biology")
        try database.insertTopic(topic)

        // Empty deck should have 0 count
        let emptyDeck = try database.createDeck(title: "Empty Review Deck")
        let counts1 = try database.deckCardCounts()
        XCTAssertEqual(counts1[emptyDeck.id] ?? 0, 0)

        // Add card
        let card = NoteCard(topicId: topic.id, title: "Mitochondria")
        try database.insertCard(card)
        try database.addCardsToDeck(cardIds: [card.id], deckId: emptyDeck.id)

        let counts2 = try database.deckCardCounts()
        XCTAssertEqual(counts2[emptyDeck.id], 1)

        // Verify topic deck promotion: creating deck with matching topic ID
        let topicDeck = try database.createDeck(id: topic.id, title: topic.title)
        XCTAssertEqual(topicDeck.id, topic.id)
        XCTAssertEqual(topicDeck.title, topic.title)
    }

    func testNewDeckCreationViaAddToDeckFlow() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "AI Notes")
        try database.insertTopic(topic)

        let card = NoteCard(topicId: topic.id, title: "Deep Learning")
        try database.insertCard(card)

        // Simulate user creating a new deck named "test"
        let newTitle = "test"
        let newDeck = try database.createDeck(title: newTitle)
        try database.addCardsToDeck(cardIds: [card.id], deckId: newDeck.id)

        let allDecks = try database.allDecks()
        XCTAssertTrue(allDecks.contains(where: { $0.title == "test" }))

        let deckCards = try database.cardsForDeck(deckId: newDeck.id)
        XCTAssertEqual(deckCards.count, 1)
        XCTAssertEqual(deckCards.first?.title, "Deep Learning")

        let counts = try database.deckCardCounts()
        XCTAssertEqual(counts[newDeck.id], 1)
    }
}
