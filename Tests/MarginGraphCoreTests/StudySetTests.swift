import XCTest
import SwiftUI
import AppKit
@testable import MarginGraphCore

final class StudySetTests: XCTestCase {
    func testAttachDetachAndDocumentsForTopic() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Study Set")
        let first = Document(title: "One", filePath: "/tmp/one.pdf", md5: "md5-one", totalPages: 10)
        let second = Document(title: "Two", filePath: "/tmp/two.pdf", md5: "md5-two", totalPages: 20)

        try database.insertTopic(topic)
        try database.insertDocument(first)
        try database.insertDocument(second)

        try database.addDocument(to: topic.id, md5: first.md5)
        try database.addDocument(to: topic.id, md5: second.md5)
        try database.addDocument(to: topic.id, md5: first.md5)

        XCTAssertEqual(try database.getTopic(id: topic.id)?.bookMD5List, [first.md5, second.md5])
        XCTAssertEqual(try database.documentsForTopic(id: topic.id).map(\.md5), [first.md5, second.md5])

        try database.removeDocument(from: topic.id, md5: first.md5)

        XCTAssertEqual(try database.getTopic(id: topic.id)?.bookMD5List, [second.md5])
        XCTAssertEqual(try database.documentsForTopic(id: topic.id).map(\.md5), [second.md5])
    }

    func testDocumentRoutingUsesOwnCardsAndRespectsDetach() throws {
        let database = try Database(inMemory: true)
        let rock = Document(title: "Rock", filePath: "/tmp/rock.pdf", md5: "rock-hash", totalPages: 10)
        let ahrens = Topic(title: "Rock", bookMD5List: ["ahrens-hash", rock.md5])
        let own = Topic(title: "Rock", bookMD5List: [rock.md5])
        try database.insertDocument(rock)
        try database.insertTopic(ahrens)
        try database.insertTopic(own)
        for _ in 0..<10 {
            try database.insertCard(NoteCard(topicId: ahrens.id, bookMD5: "ahrens-hash", title: "Ahrens card"))
        }
        try database.insertCard(NoteCard(topicId: own.id, bookMD5: rock.md5, title: "Rock card"))
        XCTAssertEqual(try database.preferredTopic(for: rock, topics: [ahrens, own])?.id, own.id)

        // Even a stale in-memory topic or matching card/title must not undo removal.
        try database.removeDocument(from: own.id, md5: rock.md5)
        XCTAssertNil(try database.preferredTopic(for: rock, topics: [own]))
        XCTAssertTrue(try database.documentsForTopic(id: own.id).isEmpty)
        try database.addDocument(to: own.id, md5: rock.md5)
        XCTAssertEqual(try database.preferredTopic(for: rock, topics: [own])?.id, own.id)
        XCTAssertEqual(try database.documentsForTopic(id: own.id).map(\.id), [rock.id])
    }

    func testDetachRemovesPrefixAttachmentAndLastDocument() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Book", bookMD5List: ["abcdef"], lastDocumentMD5: "abcdef")
        try database.insertTopic(topic)
        try database.removeDocument(from: topic.id, md5: "abcdef123")
        let updated = try XCTUnwrap(database.getTopic(id: topic.id))
        XCTAssertTrue(updated.bookMD5List.isEmpty)
        XCTAssertNil(updated.lastDocumentMD5)
        XCTAssertFalse(Database.bookHashesMatch("", "abcdef"))
    }

    func testMarkdownExporterHierarchyAndContent() {
        let topic = Topic(title: "Physics")
        let relationID = UUID()
        let root = NoteCard(
            id: UUID(),
            topicId: topic.id,
            title: "Relativity",
            highlightText: "Space and time are linked.",
            notesText: "Root note",
            mindLinks: [relationID],
            tags: ["science"]
        )
        let child = NoteCard(
            id: UUID(),
            topicId: topic.id,
            title: "Time Dilation",
            highlightText: "Moving clocks run slow.",
            notesText: "Child note",
            groupNoteId: root.id,
            tags: ["einstein"]
        )

        let output = MarkdownExporter.export(topic: topic, cards: [child, root])

        XCTAssertTrue(output.contains("# Physics"))
        XCTAssertTrue(output.contains("## Relativity"))
        XCTAssertTrue(output.contains("- **Time Dilation**"))
        XCTAssertTrue(output.contains("> Space and time are linked."))
        XCTAssertTrue(output.contains("Root note"))
        XCTAssertTrue(output.contains("#science"))
        XCTAssertTrue(output.contains(relationID.uuidString))
    }

    func testOPMLExporterProducesNestedXML() {
        let topic = Topic(title: "Research & Notes")
        let root = NoteCard(
            id: UUID(),
            topicId: topic.id,
            title: "Root <Idea>",
            notesText: "Important & useful"
        )
        let child = NoteCard(
            id: UUID(),
            topicId: topic.id,
            title: "Child",
            highlightText: "Quoted text",
            groupNoteId: root.id
        )

        let output = OPMLExporter.export(topic: topic, cards: [child, root])

        XCTAssertTrue(output.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(output.contains("<opml version=\"2.0\">"))
        XCTAssertTrue(output.contains("<title>Research &amp; Notes</title>"))
        XCTAssertTrue(output.contains("<outline text=\"Root &lt;Idea&gt;\""))
        XCTAssertTrue(output.contains("_note=\"Important &amp; useful\""))
        XCTAssertTrue(output.contains("<outline text=\"Child\" _note=\"Quoted text\"/>"))
        XCTAssertTrue(output.contains("</outline>"))
        XCTAssertTrue(output.contains("</opml>"))
    }

    @MainActor
    func testStudyDocumentManagementSheetAndTabBarScaling() {
        let doc1 = Document(title: "Doc 1", filePath: "/tmp/1.pdf", md5: "md5-1", totalPages: 10)
        let doc2 = Document(title: "Doc 2", filePath: "/tmp/2.pdf", md5: "md5-2", totalPages: 20)
        let doc3 = Document(title: "Doc 3", filePath: "/tmp/3.pdf", md5: "md5-3", totalPages: 30)

        var addedDoc: Document?
        var imported = false
        var dismissed = false

        let sheet = StudyDocumentManagementSheet(
            documents: [doc1],
            allDocuments: [doc1, doc2, doc3],
            activeDocument: doc1,
            initialMode: .addExisting,
            onSwitchDocument: { _ in },
            onDetachDocument: { _ in },
            onAddExistingDocument: { doc in
                addedDoc = doc
            },
            onImportDocument: {
                imported = true
            },
            onDismiss: {
                dismissed = true
            }
        )

        let hosting = NSHostingView(rootView: sheet)
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hosting)

        sheet.onAddExistingDocument(doc2)
        XCTAssertEqual(addedDoc?.md5, doc2.md5)

        sheet.onImportDocument?()
        XCTAssertTrue(imported)

        sheet.onDismiss()
        XCTAssertTrue(dismissed)

        // Test Tab Bar with many documents (10 documents)
        var docs: [Document] = []
        for i in 1...10 {
            docs.append(Document(title: "Document Number \(i)", filePath: "/tmp/\(i).pdf", md5: "md5-\(i)", totalPages: i * 5))
        }

        var selected: Document?
        var addTriggered = false
        let tabBar = DocumentTabBarView(
            documents: docs,
            activeDocument: docs[4],
            onSelectDocument: { d in selected = d },
            onCloseDocument: { _ in },
            onAddDocument: { addTriggered = true },
            onManageDocuments: {}
        )

        let tabHosting = NSHostingView(rootView: tabBar)
        tabHosting.frame = NSRect(x: 0, y: 0, width: 600, height: 34)
        tabHosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(tabHosting)

        tabBar.onSelectDocument(docs[8])
        XCTAssertEqual(selected?.md5, docs[8].md5)

        tabBar.onAddDocument?()
        XCTAssertTrue(addTriggered)
    }
}
