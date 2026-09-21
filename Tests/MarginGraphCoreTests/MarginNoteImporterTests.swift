import XCTest
import SQLite3
@testable import MarginGraphCore

final class MarginNoteImporterTests: XCTestCase {
    func testImportsTopicsBooksCardsAndParentRelationship() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let topicID = UUID()
        let parentID = UUID()
        let childID = UUID()

        try exec(db, """
        CREATE TABLE ZTOPIC (Z_PK INTEGER, ZTOPICID TEXT, ZTITLE TEXT, ZBOOKMD5LIST TEXT);
        CREATE TABLE ZBOOK (Z_PK INTEGER, ZBOOKID TEXT, ZTITLE TEXT, ZFILEPATH TEXT, ZMD5 TEXT, ZTOTALPAGES INTEGER);
        CREATE TABLE ZBOOKNOTE (
            Z_PK INTEGER, ZNOTEID TEXT, ZTOPICID TEXT, ZBOOKMD5 TEXT, ZNOTETITLE TEXT,
            ZHIGHLIGHT_TEXT TEXT, ZNOTES_TEXT TEXT, ZGROUPNOTEID TEXT, ZMINDPOS TEXT, ZMINDLINKS TEXT,
            ZHIGHLIGHT_STYLE TEXT
        );
        INSERT INTO ZTOPIC VALUES(1, '\(topicID.uuidString)', 'Notebook', '["book-md5"]');
        INSERT INTO ZBOOK VALUES(1, '\(UUID().uuidString)', 'Book', '/tmp/book.pdf', 'book-md5', 99);
        INSERT INTO ZBOOKNOTE VALUES(
            1, '\(parentID.uuidString)', '\(topicID.uuidString)', 'book-md5',
            'Parent', 'quote', 'note', NULL, '{10,20}', '["\(childID.uuidString)"]', 'mbooks-annotationa'
        );
        INSERT INTO ZBOOKNOTE VALUES(
            2, '\(childID.uuidString)', '\(topicID.uuidString)', 'book-md5',
            'Child', '', '', '\(parentID.uuidString)', '{30,40}', '[]', 'mbooks-annotation1c'
        );
        """)

        let destination = try Database(inMemory: true)
        let result = try MarginNoteImporter(url: url).importInto(destination)

        XCTAssertEqual(result.topics.count, 1)
        XCTAssertEqual(result.documents.first?.totalPages, 99)
        XCTAssertEqual(result.cards.count, 2)

        let parent = try XCTUnwrap(result.cards.first(where: { $0.id == parentID }))
        let child = try XCTUnwrap(result.cards.first(where: { $0.id == childID }))

        XCTAssertEqual(parent.mindPos?.x, 10)
        XCTAssertEqual(parent.mindLinks, [childID])
        XCTAssertEqual(parent.colorIndex, 10)
        XCTAssertEqual(child.colorIndex, 12)
        XCTAssertEqual(child.groupNoteId, parentID)
        XCTAssertEqual(
            try destination.childCards(parentId: parentID, topicId: topicID).first?.id,
            childID
        )
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            XCTFail(message)
            throw NSError(
                domain: "SQLite",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func testLiveMarginNoteDatabaseImportIfExists() throws {
        let livePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Library/Application Support/QReader.MarginNoteMac/MarginNotes.sqlite")
        guard FileManager.default.fileExists(atPath: livePath.path) else {
            print("Live MarginNotes.sqlite not found, skipping live test.")
            return
        }
        let destination = try Database(inMemory: true)
        let result = try MarginNoteImporter(url: livePath).importInto(destination)
        print("Live import result: \(result.topics.count) topics, \(result.documents.count) books, \(result.cards.count) cards")
        XCTAssertGreaterThan(result.topics.count, 0)
        XCTAssertGreaterThan(result.cards.count, 0)
    }

    func testExampleMarginpkgImportIfExists() throws {
        let examplePath = "/Users/broliang/Downloads/Screenplay The Foundations of Screenwriting, revised & -- Field, Syd(2026-09-21-10-24-48).marginpkg"
        guard FileManager.default.fileExists(atPath: examplePath) else {
            print("Example marginpkg not found at \(examplePath), skipping.")
            return
        }

        let tempDocs = FileManager.default.temporaryDirectory.appendingPathComponent("test_docs_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDocs) }

        let importer = MarginNoteImporter(url: URL(fileURLWithPath: examplePath), documentsDestinationDirectory: tempDocs)
        let destination = try Database(inMemory: true)
        let result = try importer.importInto(destination)

        XCTAssertEqual(result.topics.count, 1)
        let topic = result.topics[0]
        XCTAssertEqual(topic.title, "Screenplay The Foundations of Screenwriting, revised & -- Field, Syd")
        XCTAssertEqual(result.documents.count, 1)
        let doc = result.documents[0]
        XCTAssertEqual(doc.totalPages, 340)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.filePath))
        XCTAssertEqual(result.cards.count, 293)
        let highlightedCards = result.cards.filter { !$0.highlightRects.isEmpty }
        XCTAssertGreaterThanOrEqual(highlightedCards.count, 290)

        // Verify stored in DB
        let dbCards = try destination.cardsForTopic(id: topic.id)
        XCTAssertEqual(dbCards.count, 293)
        let dbDoc = try destination.getDocumentByMD5(md5: doc.md5)
        XCTAssertNotNil(dbDoc)
    }

    func testConflictResolutionMergeReplaceAndCancel() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_conflict_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.marginnotes")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let incomingTopicID = UUID()
        let incomingCardID1 = UUID()
        let incomingCardID2 = UUID()

        try exec(db, """
        CREATE TABLE ZTOPIC (Z_PK INTEGER, ZTOPICID TEXT, ZTITLE TEXT, ZBOOKMD5LIST TEXT);
        CREATE TABLE ZBOOK (Z_PK INTEGER, ZBOOKID TEXT, ZTITLE TEXT, ZFILEPATH TEXT, ZMD5 TEXT, ZTOTALPAGES INTEGER);
        CREATE TABLE ZBOOKNOTE (
            Z_PK INTEGER, ZNOTEID TEXT, ZTOPICID TEXT, ZBOOKMD5 TEXT, ZNOTETITLE TEXT,
            ZHIGHLIGHT_TEXT TEXT, ZNOTES_TEXT TEXT, ZGROUPNOTEID TEXT, ZMINDPOS TEXT, ZMINDLINKS TEXT,
            ZHIGHLIGHT_STYLE TEXT
        );
        INSERT INTO ZTOPIC VALUES(1, '\(incomingTopicID.uuidString)', 'Shared Notebook', '["incoming-book-md5"]');
        INSERT INTO ZBOOK VALUES(1, '\(UUID().uuidString)', 'Book', '/tmp/book.pdf', 'incoming-book-md5', 50);
        INSERT INTO ZBOOKNOTE VALUES(1, '\(incomingCardID1.uuidString)', '\(incomingTopicID.uuidString)', 'incoming-book-md5', 'Inc1', 'q1', 'n1', NULL, '{1,1}', '[]', 'mbooks-annotation0');
        INSERT INTO ZBOOKNOTE VALUES(2, '\(incomingCardID2.uuidString)', '\(incomingTopicID.uuidString)', 'incoming-book-md5', 'Inc2', 'q2', 'n2', NULL, '{2,2}', '[]', 'mbooks-annotation0');
        """)

        // 1. Test Cancel
        let destination = try Database(inMemory: true)
        let existingTopic = Topic(title: "Shared Notebook", bookMD5List: ["existing-book-md5"])
        try destination.insertTopic(existingTopic)
        let existingCard = NoteCard(topicId: existingTopic.id, title: "Existing Card")
        try destination.insertCard(existingCard)

        var cancelPrompted = false
        let cancelResult = try MarginNoteImporter(url: dbURL, documentsDestinationDirectory: tempDir)
            .importInto(destination) { existing, imported in
                cancelPrompted = true
                XCTAssertEqual(existing.id, existingTopic.id)
                XCTAssertEqual(imported.title, "Shared Notebook")
                return .cancel
            }
        XCTAssertTrue(cancelPrompted)
        XCTAssertNil(cancelResult)
        // Verify DB untouched
        XCTAssertEqual(try destination.allTopics().count, 1)
        XCTAssertEqual(try destination.cardsForTopic(id: existingTopic.id).count, 1)

        // 2. Test Merge
        var mergePrompted = false
        let mergeResult = try MarginNoteImporter(url: dbURL, documentsDestinationDirectory: tempDir)
            .importInto(destination) { existing, imported in
                mergePrompted = true
                return .merge
            }
        XCTAssertTrue(mergePrompted)
        XCTAssertNotNil(mergeResult)
        // Topic preserved with same ID, both books present, 3 cards total (1 existing + 2 imported)
        let mergedTopic = try XCTUnwrap(destination.getTopic(id: existingTopic.id))
        XCTAssertTrue(mergedTopic.bookMD5List.contains("existing-book-md5"))
        XCTAssertTrue(mergedTopic.bookMD5List.contains("incoming-book-md5"))
        let mergedCards = try destination.cardsForTopic(id: existingTopic.id)
        XCTAssertEqual(mergedCards.count, 3)

        // 3. Test Replace
        var replacePrompted = false
        let replaceResult = try MarginNoteImporter(url: dbURL, documentsDestinationDirectory: tempDir)
            .importInto(destination) { existing, imported in
                replacePrompted = true
                return .replace
            }
        XCTAssertTrue(replacePrompted)
        XCTAssertNotNil(replaceResult)
        // Old topic deleted, replaced with incomingTopicID, exactly 2 incoming cards
        XCTAssertNil(try destination.getTopic(id: existingTopic.id))
        let replacedTopic = try XCTUnwrap(destination.getTopic(id: incomingTopicID))
        XCTAssertEqual(replacedTopic.title, "Shared Notebook")
        let replacedCards = try destination.cardsForTopic(id: incomingTopicID)
        XCTAssertEqual(replacedCards.count, 2)
    }

    func testLiveDatabaseTopicDocumentLinkage() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbFile = appSupport.appendingPathComponent("MarginGraph/MarginGraph.sqlite")
        guard FileManager.default.fileExists(atPath: dbFile.path) else { return }

        let start = Date()
        let db = try Database(url: dbFile)
        try db.syncAvailableDocuments()
        let elapsed = Date().timeIntervalSince(start)
        print("Live DB sync completed in \(elapsed)s")
        XCTAssertLessThan(elapsed, 1.0, "Live DB sync must take less than 1 second")

        let allDocs = try db.allDocuments()
        print("All documents count in live DB: \(allDocs.count)")
        for doc in allDocs {
            print("  - [\(doc.title)] path: \(doc.filePath)")
            XCTAssertFalse(doc.filePath.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: doc.filePath))
        }

        let topics = try db.allTopics()
        print("Total topics in live DB: \(topics.count)")

        // Check key study notebooks
        for key in ["Ahrens", "Adler", "Save the Cat", "Screenplay"] {
            if let topic = topics.first(where: { $0.title.localizedCaseInsensitiveContains(key) }) {
                let docs = try db.documentsForTopic(id: topic.id)
                print("Topic '\(topic.title)' matched \(docs.count) doc(s): \(docs.map(\.title))")
                XCTAssertFalse(docs.isEmpty, "Topic '\(topic.title)' should match a PDF document")
                if let matched = docs.first {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: matched.filePath))
                }
            }
        }
    }

    func testReplaceMarginpkgDeduplicatesDocumentsAndRetainsCards() throws {
        let examplePath = "/Users/broliang/Downloads/Screenplay The Foundations of Screenwriting, revised & -- Field, Syd(2026-09-21-10-24-48).marginpkg"
        guard FileManager.default.fileExists(atPath: examplePath) else { return }

        let tempDocs = FileManager.default.temporaryDirectory.appendingPathComponent("test_replace_dedup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDocs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDocs) }

        let database = try Database(inMemory: true)

        // 1. Simulate state before import: existing document with raw MD5 and dummy topic with 0 cards
        let rawMD5 = "bc3f0e792d203011ff788f93eb75a311"
        let pdfDest = tempDocs.appendingPathComponent("Screenplay The Foundations of Screenwriting, revised & -- Field, Syd.pdf")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", examplePath, tempDocs.path]
        try ditto.run()
        ditto.waitUntilExit()

        let initialDoc = Document(
            id: Document.stableUUID(rawMD5),
            title: "Screenplay: The Foundations of Screenwriting (2005)",
            filePath: pdfDest.path,
            md5: rawMD5,
            totalPages: 340
        )
        try database.insertDocument(initialDoc)

        let dummyTopic = Topic(title: "Screenplay: The Foundations of Screenwriting (2005)", bookMD5List: [rawMD5])
        try database.insertTopic(dummyTopic)

        XCTAssertEqual(try database.allDocuments().count, 1)
        XCTAssertEqual(try database.cardsForDocument(md5: rawMD5).count, 0)

        // 2. Import the .marginpkg with .replace resolution
        let importer = MarginNoteImporter(url: URL(fileURLWithPath: examplePath), documentsDestinationDirectory: tempDocs)
        let result = try importer.importInto(database) { existing, imported in
            return .replace
        }
        XCTAssertNotNil(result)

        try database.syncAvailableDocuments(additionalSearchPaths: [tempDocs])

        // 3. Verify: exactly 1 document for the physical PDF path
        let docs = try database.allDocuments().filter { $0.filePath == pdfDest.path }
        XCTAssertEqual(docs.count, 1, "There should only be one document for this physical PDF file!")
        let survivingDoc = try XCTUnwrap(docs.first)
        XCTAssertEqual(survivingDoc.md5, "2b548be0f506e48f4c6fa094a4f2e9acf685765d9632dba3910b312fc4568b83")

        // Cards for this document must be 293
        let docCards = try database.cardsForDocument(md5: survivingDoc.md5)
        XCTAssertEqual(docCards.count, 293)

        // The dummy topic with 0 cards was cleaned up
        let topics = try database.allTopics().filter { $0.title.contains("Screenplay") }
        XCTAssertEqual(topics.count, 1, "The 0-card dummy topic should have been cleaned up!")
        let survivingTopic = topics[0]
        let topicCards = try database.cardsForTopic(id: survivingTopic.id)
        XCTAssertEqual(topicCards.count, 293)

        // Documents for topic returns the surviving doc
        let topicDocs = try database.documentsForTopic(id: survivingTopic.id)
        XCTAssertEqual(topicDocs.map(\.id), [survivingDoc.id])
    }
}
