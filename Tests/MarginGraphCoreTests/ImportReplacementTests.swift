import XCTest
import PDFKit
@testable import MarginGraphCore

final class ImportReplacementTests: XCTestCase {
    func testBeforeCommitReadsMergedNotebookAndRollsBackOnFailure() throws {
        let db = try Database(inMemory: true)
        let existing = Topic(title: "Notebook")
        let original = NoteCard(topicId: existing.id, highlightText: "Existing")
        try db.insertTopic(existing)
        try db.insertCard(original)
        let incoming = Topic(title: existing.title)
        let added = NoteCard(topicId: incoming.id, highlightText: "Imported")

        XCTAssertThrowsError(try MarginNoteImporter.apply(
            .init(topics: [incoming], documents: [], cards: [added]), to: db, beforeCommit: { applied in
                XCTAssertEqual(applied.topics.map(\.id), [existing.id])
                XCTAssertEqual(Set(try db.cardsForTopic(id: existing.id).map(\.id)), [original.id, added.id])
                throw DatabaseError.encoding
            }
        ) { _, _ in .merge })
        XCTAssertEqual(try db.cardsForTopic(id: existing.id).map(\.id), [original.id])
    }

    func testImportLinksCardsToCanonicalDocumentWithoutLibraryRepair() throws {
        let db = try Database(inMemory: true)
        let existing = Document(title: "Book", filePath: "/tmp/previous.pdf", md5: "existing", totalPages: 10)
        let imported = Document(title: "Book", filePath: "/tmp/imported.pdf", md5: "imported", totalPages: 10)
        let unrelated = Topic(title: "Keep attachment", bookMD5List: ["offline-book"])
        let topic = Topic(title: "Imported Notebook", bookMD5List: [imported.md5])
        let card = NoteCard(topicId: topic.id, bookMD5: imported.md5, highlightText: "Package excerpt")
        try db.insertDocument(existing)
        try db.insertTopic(unrelated)

        let result = try XCTUnwrap(MarginNoteImporter.apply(
            .init(topics: [topic], documents: [imported], cards: [card]), to: db, conflictResolver: nil
        ))
        XCTAssertEqual(result.documents.map(\.md5), [existing.md5])
        XCTAssertEqual(result.topics.first?.bookMD5List, [existing.md5])
        XCTAssertEqual(try db.cardsForDocument(md5: existing.md5).map(\.id), [card.id])
        XCTAssertEqual(try db.getTopic(id: unrelated.id)?.bookMD5List, unrelated.bookMD5List)
    }

    func testFailedArchiveRetentionRollsBackReplacement() throws {
        let db = try Database(inMemory: true)
        let existing = Topic(title: "Notebook")
        try db.insertTopic(existing)
        let card = NoteCard(topicId: existing.id, highlightText: "Keep this excerpt")
        try db.insertCard(card)
        let storedCard = try XCTUnwrap(db.getCard(id: card.id))
        let incoming = Topic(title: existing.title)
        let missingArchive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).marginpkg")

        XCTAssertThrowsError(try MarginNoteImporter.apply(
            .init(topics: [incoming], documents: [], cards: []), to: db, retainingPackageAt: missingArchive
        ) { _, _ in .replace })
        XCTAssertEqual(try db.allTopics().map(\.id), [existing.id])
        XCTAssertEqual(try db.getCard(id: card.id), storedCard)
    }

    func testReplaceRetiresOldPDFDespiteSanitizedTitleAndKeepsSourceBytes() throws {
        let db = try Database(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.pdf")
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let bytes = data as Data; try bytes.write(to: oldURL)
        let old = Document(title: "Homo Deus: A Brief History of Tomorrow", filePath: oldURL.path, md5: "old", totalPages: 360)
        let topic = Topic(title: old.title, bookMD5List: [old.md5])
        try db.insertDocument(old); try db.insertTopic(topic)
        try db.insertCard(NoteCard(topicId: topic.id, bookMD5: old.md5, highlightText: "old notes", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let new = Document(title: "Homo Deus_ A Brief History of Tomorrow", filePath: root.appendingPathComponent("new.pdf").path, md5: "new", totalPages: 360)
        let incoming = Topic(title: topic.title, bookMD5List: [new.md5])
        let card = NoteCard(topicId: incoming.id, bookMD5: new.md5, highlightText: "replacement notes", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        let result = MarginNoteImportResult(topics: [incoming], documents: [new], cards: [card])
        _ = try MarginNoteImporter.apply(result, to: db) { _, _ in .replace }
        XCTAssertEqual(try db.allDocuments().map(\.md5), [new.md5])
        XCTAssertEqual(try db.cardsForDocument(md5: new.md5).map(\.id), [card.id])
        XCTAssertNil(try db.getTopic(id: topic.id))
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        // A later filesystem discovery cannot resurrect the retired entry.
        try db.syncAvailableDocuments(additionalSearchPaths: [root])
        XCTAssertEqual(try db.allDocuments().map(\.md5), [new.md5])
        // Explicitly importing the old source is still allowed.
        try db.insertDocument(old)
        XCTAssertNotNil(try db.getDocument(id: old.id))
    }

    func testReplaceKeepsSharedDocumentAndExactIncomingHashEvenWithIdenticalTitles() throws {
        let db = try Database(inMemory: true)
        let old = Document(title: "Book", filePath: "/tmp/old-book.pdf", md5: "old-book", totalPages: 10)
        let new = Document(title: "Book", filePath: "/tmp/new-book.pdf", md5: "new-book", totalPages: 10)
        let replaced = Topic(title: "Notebook", bookMD5List: [old.md5])
        let shared = Topic(title: "Keep this notebook", bookMD5List: [old.md5])
        try db.insertDocument(old); try db.insertTopic(replaced); try db.insertTopic(shared)
        let keptCard = NoteCard(topicId: shared.id, bookMD5: old.md5, highlightText: "Keep me", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try db.insertCard(keptCard)
        let incoming = Topic(title: replaced.title, bookMD5List: [new.md5])
        let newCard = NoteCard(topicId: incoming.id, bookMD5: new.md5, highlightText: "New revision", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        _ = try MarginNoteImporter.apply(.init(topics: [incoming], documents: [new], cards: [newCard]), to: db) { _, _ in .replace }
        try db.syncAvailableDocuments()
        XCTAssertEqual(Set(try db.allDocuments().map(\.md5)), [old.md5, new.md5])
        XCTAssertEqual(try db.getCard(id: keptCard.id), keptCard)
        XCTAssertEqual(try db.getCard(id: newCard.id), newCard)
    }

    func testLaterCancelAndFailedInsertLeaveEarlierReplacementUntouched() throws {
        let db = try Database(inMemory: true)
        let doc = Document(title: "Old", filePath: "/tmp/old.pdf", md5: "old", totalPages: 10)
        let first = Topic(title: "First", bookMD5List: [doc.md5]), second = Topic(title: "Second")
        try db.insertDocument(doc); try db.insertTopic(first); try db.insertTopic(second)
        let card = NoteCard(topicId: first.id, bookMD5: doc.md5, highlightText: "Preserve", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try db.insertCard(card)
        let incoming = Topic(title: first.title), later = Topic(title: second.title)
        let result = MarginNoteImportResult(topics: [incoming, later], documents: [], cards: [])
        XCTAssertNil(try MarginNoteImporter.apply(result, to: db) { existing, _ in existing.id == first.id ? .replace : .cancel })
        XCTAssertEqual(try db.getCard(id: card.id), card)
        XCTAssertNotNil(try db.getTopic(id: first.id))
        let invalid = NoteCard(topicId: UUID(), highlightText: "invalid owner", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertThrowsError(try MarginNoteImporter.apply(.init(topics: [incoming], documents: [], cards: [invalid]), to: db) { _, _ in .replace })
        XCTAssertEqual(try db.getCard(id: card.id), card)
        XCTAssertNotNil(try db.getDocument(id: doc.id))
    }
}
