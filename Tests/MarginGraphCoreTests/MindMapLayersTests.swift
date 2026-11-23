import XCTest
@testable import MarginGraphCore

final class MindMapLayersTests: XCTestCase {
    func testLegacyMergedExcerptRepairKeepsDecksReviewAndReferences() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Imported")
        try db.insertTopic(topic)
        let first = HighlightRect(page: 1, x: 1, y: 1, width: 20, height: 10)
        let second = HighlightRect(page: 3, x: 1, y: 1, width: 20, height: 10)
        let owner = NoteCard(topicId: topic.id, bookMD5: "book", title: "Owner", highlightText: "First",
                             notesText: "Second", startPage: 1, endPage: 1, highlightRects: [first])
        let fragment = NoteCard(topicId: topic.id, bookMD5: "book", highlightText: "Second",
                                groupNoteId: owner.id, startPage: 3, endPage: 3, highlightRects: [second])
        let branch = NoteCard(topicId: topic.id, bookMD5: "book", title: "Branch", groupNoteId: fragment.id)
        for card in [owner, fragment, branch] { try db.insertCard(card) }
        let firstDeck = try db.createDeck(title: "First")
        let secondDeck = try db.createDeck(title: "Second")
        try db.addCardsToDeck(cardIds: [owner.id], deckId: firstDeck.id)
        try db.addCardsToDeck(cardIds: [fragment.id], deckId: secondDeck.id)
        try db.upsertReviewItem(ReviewItem(cardId: fragment.id, repetitions: 3))
        try db.insertLink(CardLink(topicId: topic.id, sourceCardId: branch.id, targetCardId: fragment.id, label: "Reference"))

        let graph = try db.notebookGraph(id: topic.id)
        XCTAssertEqual(Set(graph.cards.map(\.id)), [owner.id, branch.id])
        XCTAssertEqual(graph.cards.first { $0.id == branch.id }?.groupNoteId, owner.id)
        XCTAssertEqual(graph.links.first?.targetCardId, owner.id)
        XCTAssertEqual(try db.cardForNoteLink(id: fragment.id)?.excerptSegments.map(\.id), [owner.id, fragment.id])
        XCTAssertEqual(try db.deckCardCounts(), [firstDeck.id: 1, secondDeck.id: 1])
        XCTAssertEqual(try db.dueReviewItems(asOf: .distantFuture).map(\.cardId), [owner.id])
        XCTAssertEqual(try db.notebookGraph(id: topic.id).cards, graph.cards)
    }

    func testLegacyBranchesRepairOnNotebookOpenAndCanBeReparented() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Imported")
        try db.insertTopic(topic)
        let child = NoteCard(topicId: topic.id, title: "Child")
        let parent = NoteCard(topicId: topic.id, title: "Parent", mindLinks: [child.id], isFolded: true)
        let reference = CardLink(topicId: topic.id, sourceCardId: child.id, targetCardId: parent.id)
        try db.insertCard(parent)
        try db.insertCard(child)
        try db.insertLink(CardLink(topicId: topic.id, sourceCardId: parent.id, targetCardId: child.id))
        try db.insertLink(reference)

        let graph = try db.notebookGraph(id: topic.id)
        XCTAssertEqual(try db.getCard(id: child.id)?.groupNoteId, parent.id)
        XCTAssertEqual(graph.links, [reference])
        XCTAssertEqual(TreeLayout.layout(cards: graph.cards).visibleCardIDs, [parent.id])

        try db.reparentCard(id: child.id, to: nil)
        let reloaded = try db.notebookGraph(id: topic.id)
        XCTAssertEqual(reloaded.links, [reference])
        XCTAssertEqual(TreeLayout.layout(cards: reloaded.cards).visibleCardIDs, [parent.id, child.id])
    }

    func testHierarchyKeepsConflictingCyclicAndOrphanedEdgesAsReferences() {
        let topic = UUID()
        var a = NoteCard(topicId: topic, title: "A")
        var b = NoteCard(topicId: topic, title: "B", mindLinks: [a.id])
        let c = NoteCard(topicId: topic, title: "C")
        let root = NoteCard(topicId: topic, title: "Root")
        let orphan = NoteCard(topicId: topic, title: "Orphan", groupNoteId: UUID(), mindLinks: [root.id])
        a.mindLinks = [b.id, c.id]
        b.mindLinks.append(c.id)
        var cards = [a, b, c, root, orphan]
        var links = cards.flatMap { card in
            card.mindLinks.map { CardLink(topicId: topic, sourceCardId: card.id, targetCardId: $0) }
        }
        let references = links

        MarginNoteHierarchy.restore(cards: &cards, links: &links)

        XCTAssertEqual(cards.map(\.groupNoteId), [nil, nil, nil, nil, orphan.groupNoteId])
        XCTAssertTrue(cards.allSatisfy { $0.mindLinks.isEmpty })
        XCTAssertEqual(links, references)
    }

    func testChildMapOwnershipHierarchyAndCycleSafety() {
        let brainID = UUID(), cortexID = UUID(), detailID = UUID()
        let anchor = NoteCard(topicId: UUID(), title: "Child Map 0", mindLinks: [brainID])
        let brain = NoteCard(id: brainID, topicId: anchor.topicId, title: "Your Brain", mindLinks: [cortexID])
        let cortex = NoteCard(id: cortexID, topicId: anchor.topicId, title: "Prefrontal Cortex", mindLinks: [detailID])
        let detail = NoteCard(id: detailID, topicId: anchor.topicId, title: "Space", mindLinks: [brainID])
        let main = NoteCard(topicId: anchor.topicId, title: "Main note")
        let cards = [anchor, brain, cortex, detail, main]
        XCTAssertEqual(MindMapLayers.layer(for: cortexID, cards: cards), anchor.id)
        let child = MindMapLayers.cards(in: anchor.id, all: cards)
        XCTAssertEqual(Set(child.map(\.id)), [brainID, cortexID, detailID])
        XCTAssertNil(child.first { $0.id == brainID }?.groupNoteId)
        XCTAssertEqual(child.first { $0.id == cortexID }?.groupNoteId, brainID)
        XCTAssertEqual(child.first { $0.id == detailID }?.groupNoteId, cortexID)
        XCTAssertEqual(Set(MindMapLayers.cards(in: nil, all: cards).map(\.id)), [anchor.id, main.id])
        XCTAssertEqual(TreeLayout.layout(cards: child).visibleCardIDs.count, 3)
    }
}
