import XCTest
import CoreGraphics
@testable import MarginGraphCore

final class DatabaseTests: XCTestCase {
    func testCRUDHierarchyAndLinks() throws {
        let db = try Database(inMemory: true)
        let document = Document(title: "Book", filePath: "/tmp/book.pdf", md5: "abc", totalPages: 12)
        try db.insertDocument(document)
        XCTAssertEqual(try db.getDocument(id: document.id)?.md5, "abc")
        XCTAssertEqual(try db.getDocumentByMD5(md5: "abc")?.title, "Book")
        XCTAssertEqual(try db.allDocuments().count, 1)

        let topic = Topic(title: "Study", bookMD5List: ["abc"])
        try db.insertTopic(topic)
        XCTAssertEqual(try db.getTopic(id: topic.id)?.title, "Study")

        let parent = NoteCard(topicId: topic.id, title: "Parent", mindPos: CGPoint(x: 10, y: 20))
        try db.insertCard(parent)
        var child = NoteCard(topicId: topic.id, title: "Child", groupNoteId: parent.id)
        try db.insertCard(child)

        child.mindPos = CGPoint(x: 42, y: 84)
        try db.updateCard(child)
        XCTAssertEqual(try db.getCard(id: child.id)?.mindPos?.x, 42)
        XCTAssertEqual(try db.childCards(parentId: parent.id, topicId: topic.id).map(\.id), [child.id])
        XCTAssertEqual(try db.childCards(parentId: nil, topicId: topic.id).map(\.id), [parent.id])

        let link = CardLink(
            topicId: topic.id,
            sourceCardId: parent.id,
            targetCardId: child.id,
            label: "supports",
            isBidirectional: true
        )
        try db.insertLink(link)
        XCTAssertEqual(try db.linksForTopic(id: topic.id), [link])
        try db.deleteLink(id: link.id)
        XCTAssertTrue(try db.linksForTopic(id: topic.id).isEmpty)

        try db.deleteCard(id: child.id)
        XCTAssertNil(try db.getCard(id: child.id))

        var updatedTopic = topic
        updatedTopic.title = "Updated"
        try db.updateTopic(updatedTopic)
        XCTAssertEqual(try db.getTopic(id: topic.id)?.title, "Updated")
        try db.deleteTopic(id: topic.id)
        XCTAssertNil(try db.getTopic(id: topic.id))
    }

    func testMultilineTitleAndHighlightRectsPersistExactly() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Persistence")
        try db.insertTopic(topic)

        let title = "First line\nSecond line\nThird line"
        let rects = [
            HighlightRect(page: 2, x: 10, y: 20, width: 100, height: 14),
            HighlightRect(page: 2, x: 10, y: 38, width: 80, height: 14)
        ]
        let card = NoteCard(
            topicId: topic.id,
            title: title,
            highlightText: "Selected text",
            startPage: 2,
            highlightRects: rects
        )
        try db.insertCard(card)

        let fetched = try XCTUnwrap(db.getCard(id: card.id))
        XCTAssertEqual(fetched.title, title)
        XCTAssertEqual(fetched.highlightRects, rects)

        var updated = fetched
        updated.title = "Leading\n\nBlank line preserved\nTrailing"
        try db.updateCard(updated)
        XCTAssertEqual(try db.getCard(id: card.id)?.title, updated.title)
    }

    func testDueReviewItems() throws {
        let db = try Database(inMemory: true)
        let due = ReviewItem(cardId: UUID(), dueDate: Date(timeIntervalSince1970: 100))
        let future = ReviewItem(cardId: UUID(), dueDate: Date(timeIntervalSince1970: 300))
        try db.upsertReviewItem(due)
        try db.upsertReviewItem(future)
        XCTAssertEqual(
            try db.dueReviewItems(asOf: Date(timeIntervalSince1970: 200)).map(\.cardId),
            [due.cardId]
        )
    }
}
