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
        guard ProcessInfo.processInfo.environment["ENABLE_LIVE_MN_TESTS"] == "1" else {
            print("Live MarginNotes.sqlite test skipped in automated runs (set ENABLE_LIVE_MN_TESTS=1).")
            return
        }
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

    func testImportVideoNotesAndHighlightPicAndLinksAndSRS() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mn_v2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        try exec(db, """
        CREATE TABLE ZTOPIC (Z_PK INTEGER, ZTOPICID TEXT, ZTITLE TEXT, ZBOOKMD5LIST TEXT);
        CREATE TABLE ZBOOK (Z_PK INTEGER, ZBOOKID TEXT, ZTITLE TEXT, ZFILEPATH TEXT, ZMD5 TEXT, ZTOTALPAGES INTEGER);
        CREATE TABLE ZBOOKNOTE (
            Z_PK INTEGER, ZNOTEID TEXT, ZTOPICID TEXT, ZBOOKMD5 TEXT, ZNOTETITLE TEXT,
            ZHIGHLIGHT_TEXT TEXT, ZNOTES_TEXT TEXT, ZGROUPNOTEID TEXT, ZMINDPOS TEXT, ZMINDLINKS TEXT,
            ZHIGHLIGHT_STYLE TEXT, ZSTARTPOS TEXT, ZENDPOS TEXT, ZHIGHLIGHT_PIC BLOB
        );
        CREATE TABLE ZMEDIA (Z_PK INTEGER, ZMD5 TEXT, ZDATA BLOB);
        CREATE TABLE ZACTIVITY (Z_PK INTEGER, ZACTION TEXT, ZNOTEID TEXT, ZINFO TEXT, ZTIME REAL);
        """)

        let topicID = UUID()
        let videoCardID = UUID()
        let picCardID = UUID()
        let videoMD5 = "video-lecture-md5"
        let mediaCropMD5 = "media-crop-md5"

        // Create dummy video file
        let videoFilePath = tempDir.appendingPathComponent("lecture1.mp4").path
        FileManager.default.createFile(atPath: videoFilePath, contents: Data([0x00, 0x00, 0x00, 0x18]), attributes: nil)

        // Generate a 32x32 red PNG image for ZMEDIA
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let cgImage = ctx.makeImage()!
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let pngData = rep.representation(using: .png, properties: [:])!

        // Insert ZMEDIA row
        var mediaStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ZMEDIA (Z_PK, ZMD5, ZDATA) VALUES (1, ?, ?)", -1, &mediaStmt, nil), SQLITE_OK)
        sqlite3_bind_text(mediaStmt, 1, mediaCropMD5, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = pngData.withUnsafeBytes { raw in
            sqlite3_bind_blob(mediaStmt, 2, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(mediaStmt), SQLITE_DONE)
        sqlite3_finalize(mediaStmt)

        // Generate ZHIGHLIGHT_PIC binary plist with selLst
        let selLst: [[String: Any]] = [
            ["pageNo": 1, "rect": "{{10, 20}, {100, 30}}"],
            ["pageNo": 2, "rect": "{{50, 60}, {200, 40}}"]
        ]
        let picDict: [String: Any] = [
            "paint": mediaCropMD5,
            "selLst": selLst
        ]
        let picPlistData = try PropertyListSerialization.data(fromPropertyList: picDict, format: .binary, options: 0)

        // Insert ZTOPIC
        try exec(db, "INSERT INTO ZTOPIC VALUES(1, '\(topicID.uuidString)', 'ML Course Notebook', '[\"\(videoMD5)\"]');")

        // Insert ZBOOK (video document)
        try exec(db, "INSERT INTO ZBOOK VALUES(1, '\(UUID().uuidString)', 'Lecture 1', '\(videoFilePath)', '\(videoMD5)', 0);")

        // Insert Card 1 (Video Note linking to Card 2)
        try exec(db, """
        INSERT INTO ZBOOKNOTE VALUES(
            1, '\(videoCardID.uuidString)', '\(topicID.uuidString)', '\(videoMD5)',
            'Decision Trees Intro', '', 'Key conceptual definition', NULL, '{100, 200}', '["\(picCardID.uuidString)"]',
            'mbooks-annotation0', 'MN3VIDEO|4747.46|0.1646599238', 'MN3VIDEO|4747.46|0.1772821037', NULL
        );
        """)

        // Insert Card 2 (Image excerpt with ZHIGHLIGHT_PIC)
        var card2Stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, """
        INSERT INTO ZBOOKNOTE (Z_PK, ZNOTEID, ZTOPICID, ZBOOKMD5, ZNOTETITLE, ZHIGHLIGHT_TEXT, ZNOTES_TEXT, ZGROUPNOTEID, ZMINDPOS, ZMINDLINKS, ZHIGHLIGHT_STYLE, ZSTARTPOS, ZENDPOS, ZHIGHLIGHT_PIC)
        VALUES (2, ?, ?, ?, 'Algorithm Diagram', '', '', NULL, '{300, 400}', '[]', 'mbooks-annotation1', NULL, NULL, ?)
        """, -1, &card2Stmt, nil), SQLITE_OK)
        sqlite3_bind_text(card2Stmt, 1, picCardID.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(card2Stmt, 2, topicID.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(card2Stmt, 3, videoMD5, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = picPlistData.withUnsafeBytes { raw in
            sqlite3_bind_blob(card2Stmt, 4, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(card2Stmt), SQLITE_DONE)
        sqlite3_finalize(card2Stmt)

        // Insert ZACTIVITY row (Spaced Repetition review item)
        try exec(db, """
        INSERT INTO ZACTIVITY VALUES(1, 'SpacedRepetition', '\(videoCardID.uuidString)', '{"ivl": 6, "factor": 2.6, "reps": 2}', 1700000000.0);
        """)

        let mediaStorage = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))
        let destination = try Database(inMemory: true)
        let importer = MarginNoteImporter(url: dbURL, mediaStorage: mediaStorage)
        let result = try importer.importInto(destination)

        // Verify document
        XCTAssertEqual(result.documents.count, 1)
        let doc = result.documents[0]
        XCTAssertEqual(doc.documentType, "video")
        XCTAssertEqual(doc.md5, videoMD5)

        // Verify cards
        XCTAssertEqual(result.cards.count, 2)
        let videoCard: NoteCard = try XCTUnwrap(result.cards.first(where: { $0.id == videoCardID }))
        XCTAssertEqual(videoCard.mediaType, "video")
        let startTime: Double = try XCTUnwrap(videoCard.videoStartTime)
        let endTime: Double = try XCTUnwrap(videoCard.videoEndTime)
        XCTAssertEqual(startTime, 4747.46 * 0.1646599238, accuracy: 0.01)
        XCTAssertEqual(endTime, 4747.46 * 0.1772821037, accuracy: 0.01)

        let picCard: NoteCard = try XCTUnwrap(result.cards.first(where: { $0.id == picCardID }))
        XCTAssertNotNil(picCard.highlightPicHash)
        // Verify crop was re-encoded and saved to mediaStorage
        if let hash = picCard.highlightPicHash {
            let loadedImage = mediaStorage.loadImage(hash: hash)
            XCTAssertNotNil(loadedImage, "Re-encoded HEIC crop should be loadable from mediaStorage")
        }
        // Verify selLst multi-segment rects were extracted
        XCTAssertEqual(picCard.highlightRects.count, 2)
        XCTAssertEqual(picCard.highlightRects[0].page, 0)
        XCTAssertEqual(picCard.highlightRects[0].x, 10)
        XCTAssertEqual(picCard.highlightRects[0].y, 20)
        XCTAssertEqual(picCard.highlightRects[1].page, 1)

        // Verify card-to-card graph links imported
        let links = try destination.linksForTopic(id: topicID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].sourceCardId, videoCardID)
        XCTAssertEqual(links[0].targetCardId, picCardID)

        // Verify Spaced Repetition (SRS) review items imported
        let dueItems = try destination.dueReviewItems(asOf: Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(dueItems.count, 1)
        XCTAssertEqual(dueItems[0].cardId, videoCardID)
        XCTAssertEqual(dueItems[0].intervalDays, 6)
        XCTAssertEqual(dueItems[0].easeFactor, 2.6, accuracy: 0.001)
        XCTAssertEqual(dueItems[0].repetitions, 2)
    }

    func testReadFolderWithoutCopyingDocumentsOrMedia() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_backup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let subDir = tempDir.appendingPathComponent("Subfolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let mediaDir = tempDir.appendingPathComponent("MarginNotes.sqlite.files")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let doc1URL = tempDir.appendingPathComponent("RootBook.pdf")
        try Data("dummy pdf 1".utf8).write(to: doc1URL)

        let doc2URL = subDir.appendingPathComponent("SubBook.pdf")
        try Data("dummy pdf 2".utf8).write(to: doc2URL)

        let sampleMediaData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let mediaFile = mediaDir.appendingPathComponent("mediahash123")
        try sampleMediaData.write(to: mediaFile)

        let dbURL = tempDir.appendingPathComponent("MarginNotes.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let topicID = UUID()
        let cardID = UUID()

        try exec(db, """
        CREATE TABLE ZTOPIC (Z_PK INTEGER, ZTOPICID TEXT, ZTITLE TEXT, ZBOOKMD5LIST TEXT);
        CREATE TABLE ZBOOK (Z_PK INTEGER, ZBOOKID TEXT, ZTITLE TEXT, ZFILE TEXT, ZPATH TEXT, ZMD5 TEXT, ZTOTALPAGES INTEGER);
        CREATE TABLE ZBOOKNOTE (
            Z_PK INTEGER, ZNOTEID TEXT, ZTOPICID TEXT, ZBOOKMD5 TEXT, ZNOTETITLE TEXT,
            ZHIGHLIGHT_TEXT TEXT, ZNOTES_TEXT TEXT, ZGROUPNOTEID TEXT, ZMINDPOS TEXT, ZMINDLINKS TEXT,
            ZHIGHLIGHT_STYLE TEXT, ZHIGHLIGHT_PIC TEXT
        );
        INSERT INTO ZTOPIC VALUES(1, '\(topicID.uuidString)', 'Backup Notebook', '["md5-1", "md5-2"]');
        INSERT INTO ZBOOK VALUES(1, '1', 'Root Book', 'RootBook.pdf', '', 'md5-1', 10);
        INSERT INTO ZBOOK VALUES(2, '2', 'Sub Book', 'SubBook.pdf', 'Subfolder', 'md5-2', 20);
        INSERT INTO ZBOOKNOTE VALUES(
            1, '\(cardID.uuidString)', '\(topicID.uuidString)', 'md5-1',
            'Card Title', 'quote', 'note', NULL, '{0,0}', '[]', 'style', 'paint:mediahash123'
        );
        """)

        let mediaStorage = try MediaStorage(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("test_ms_\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: mediaStorage.directoryURL) }
        mediaStorage.fallbackDirectories = [mediaDir]

        // Pass the folder URL directly, with copyDocuments: false and copyMedia: false
        let importer = MarginNoteImporter(
            url: tempDir,
            mediaStorage: mediaStorage,
            copyDocuments: false,
            copyMedia: false
        )
        let destination = try Database(inMemory: true)
        let result = try importer.importInto(destination)

        XCTAssertEqual(result.topics.count, 1)
        XCTAssertEqual(result.documents.count, 2)

        let rootDoc = try XCTUnwrap(result.documents.first(where: { $0.md5 == "md5-1" }))
        XCTAssertEqual(rootDoc.filePath, doc1URL.path)
        XCTAssertEqual(rootDoc.title, "Root Book")

        let subDoc = try XCTUnwrap(result.documents.first(where: { $0.md5 == "md5-2" }))
        XCTAssertEqual(subDoc.filePath, doc2URL.path)
        XCTAssertEqual(subDoc.title, "Sub Book")

        XCTAssertEqual(result.cards.count, 1)
        let card = result.cards[0]
        XCTAssertEqual(card.highlightPicHash, "mediahash123")

        // Verify mediaStorage can read the image directly from fallbackDirectories without copying!
        let loaded = mediaStorage.loadImage(hash: "mediahash123")
        XCTAssertEqual(loaded, sampleMediaData)
    }

    func testLiveBackupAllImportInPlace() throws {
        let backupURL = URL(fileURLWithPath: "/Volumes/omv/backups/marginnote/MarginNoteBackup(2026-09-21-12-33-07).marginbackupall")
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            print("Omv backup not mounted, skipping testLiveBackupAllImportInPlace")
            return
        }

        let tempLocalMediaDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_local_media_\(UUID().uuidString)")
        let mediaStorage = try MediaStorage(directoryURL: tempLocalMediaDir)
        defer { try? FileManager.default.removeItem(at: tempLocalMediaDir) }

        let mediaFilesDir = backupURL.appendingPathComponent("MarginNotes.sqlite.files")
        if FileManager.default.fileExists(atPath: mediaFilesDir.path) {
            mediaStorage.fallbackDirectories = [mediaFilesDir]
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let extDir = appSupport.appendingPathComponent("MarginGraph/ExternalDatabases", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let cacheDbURL = extDir.appendingPathComponent("MarginNoteBackup_2026_09_21_12_33_07_marginbackupall.sqlite")

        let destination: Database
        let startTime = CFAbsoluteTimeGetCurrent()

        if !FileManager.default.fileExists(atPath: cacheDbURL.path) {
            destination = try Database(url: cacheDbURL)
            let importer = MarginNoteImporter(
                url: backupURL,
                mediaStorage: mediaStorage,
                copyDocuments: false,
                copyMedia: false
            )
            let result = try importer.importInto(destination)
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("Imported live backupall to cache in \(duration)s: \(result.topics.count) topics, \(result.documents.count) docs, \(result.cards.count) cards")
            XCTAssertEqual(result.documents.count, 363)
            XCTAssertGreaterThan(result.topics.count, 400)
            XCTAssertGreaterThan(result.cards.count, 15000)
        } else {
            destination = try Database(url: cacheDbURL)
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("Loaded cached external DB in \(duration)s")
        }

        let allDocs = try destination.allDocuments()
        XCTAssertEqual(allDocs.count, 363)

        // Verify zero files copied to temp local media storage
        let localMediaFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempLocalMediaDir.path)) ?? []
        XCTAssertEqual(localMediaFiles.count, 0, "No media should be copied locally when copyMedia is false")

        // Verify every single document exists in place
        for doc in allDocs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: doc.filePath), "Document missing at \(doc.filePath)")
        }
    }
}
