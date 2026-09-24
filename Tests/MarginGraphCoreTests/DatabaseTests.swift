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

    func testUndoRedoCardMutations() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "UndoTest")
        try db.insertTopic(topic)

        let initialCard = NoteCard(topicId: topic.id, title: "Initial Title", highlightText: "Initial Text", colorIndex: 0)
        try db.insertCard(initialCard)

        let undoManager = UndoManager()

        var editedCard = initialCard
        editedCard.title = "Edited Title"
        editedCard.colorIndex = 2

        final class UndoHelper: @unchecked Sendable {
            let db: Database
            let undoManager: UndoManager
            init(db: Database, undoManager: UndoManager) {
                self.db = db
                self.undoManager = undoManager
            }
            func applyUpdate(cardToRestore: NoteCard, opposite: NoteCard) {
                undoManager.registerUndo(withTarget: self) { helper in
                    helper.applyUpdate(cardToRestore: opposite, opposite: cardToRestore)
                }
                try! db.updateCard(cardToRestore)
            }
        }

        let helper = UndoHelper(db: db, undoManager: undoManager)
        helper.applyUpdate(cardToRestore: editedCard, opposite: initialCard)

        XCTAssertEqual(try db.getCard(id: initialCard.id)?.title, "Edited Title")
        XCTAssertEqual(try db.getCard(id: initialCard.id)?.colorIndex, 2)
        XCTAssertTrue(undoManager.canUndo)

        // Perform undo
        undoManager.undo()
        XCTAssertEqual(try db.getCard(id: initialCard.id)?.title, "Initial Title")
        XCTAssertEqual(try db.getCard(id: initialCard.id)?.colorIndex, 0)
        XCTAssertTrue(undoManager.canRedo)

        // Perform redo
        undoManager.redo()
        XCTAssertEqual(try db.getCard(id: initialCard.id)?.title, "Edited Title")
        XCTAssertEqual(try db.getCard(id: initialCard.id)?.colorIndex, 2)
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

    func testEmphasisListPersistence() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Emphasis Topic")
        try db.insertTopic(topic)

        var card = NoteCard(topicId: topic.id, title: "Card With Emphasis", highlightText: "This is some key highlighted text that matters")
        card.emphasisList = ["key highlighted text", "matters"]
        card.emphasisRects = [HighlightRect(page: 0, x: 10, y: 20, width: 80, height: 14)]
        try db.insertCard(card)

        let fetched = try db.getCard(id: card.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.emphasisList, ["key highlighted text", "matters"])
        XCTAssertEqual(fetched?.emphasisRects, [HighlightRect(page: 0, x: 10, y: 20, width: 80, height: 14)])

        card.emphasisList.append("This is some")
        card.emphasisRects.append(HighlightRect(page: 0, x: 100, y: 20, width: 40, height: 14))
        try db.updateCard(card)

        let updated = try db.getCard(id: card.id)
        XCTAssertEqual(updated?.emphasisList, ["key highlighted text", "matters", "This is some"])
        XCTAssertEqual(updated?.emphasisRects.count, 2)
    }

    func testPDFBookmarksDatabasePersistence() throws {
        let db = try Database(inMemory: true)
        let md5 = "fake_doc_md5_12345"

        let initial = try db.getBookmarks(for: md5)
        XCTAssertTrue(initial.isEmpty)

        try db.setBookmark(md5: md5, pageIndex: 3, isBookmarked: true)
        try db.setBookmark(md5: md5, pageIndex: 11, isBookmarked: true)

        let afterAdd = try db.getBookmarks(for: md5)
        XCTAssertEqual(afterAdd, [3, 11])

        try db.setBookmark(md5: md5, pageIndex: 3, isBookmarked: false)
        let afterRemove = try db.getBookmarks(for: md5)
        XCTAssertEqual(afterRemove, [11])
    }

    func testCardCountsByTopicAndDueCardCounts() throws {
        let db = try Database(inMemory: true)
        let topic1 = Topic(title: "Topic 1")
        let topic2 = Topic(title: "Topic 2")
        try db.insertTopic(topic1)
        try db.insertTopic(topic2)

        XCTAssertEqual(try db.totalCardCount(), 0)

        let card1 = NoteCard(topicId: topic1.id, title: "Card 1")
        let card2 = NoteCard(topicId: topic1.id, title: "Card 2")
        let card3 = NoteCard(topicId: topic2.id, title: "Card 3")
        try db.insertCard(card1)
        try db.insertCard(card2)
        try db.insertCard(card3)

        XCTAssertEqual(try db.totalCardCount(), 3)

        let counts = try db.cardCountsByTopic()
        XCTAssertEqual(counts[topic1.id], 2)
        XCTAssertEqual(counts[topic2.id], 1)

        let dueCounts = try db.dueCardCountsByTopic()
        XCTAssertEqual(dueCounts[topic1.id], 2)
        XCTAssertEqual(dueCounts[topic2.id], 1)

        // Set card1 to future due date
        let futureReview = ReviewItem(cardId: card1.id, dueDate: Date().addingTimeInterval(86400))
        try db.insertReviewItem(futureReview)

        let dueAfterReview = try db.dueCardCountsByTopic()
        XCTAssertEqual(dueAfterReview[topic1.id], 1)
        XCTAssertEqual(dueAfterReview[topic2.id], 1)
    }

    func testMultipleBookmarksListingAndDeletion() throws {
        let db = try Database(inMemory: true)
        let md5 = "test_doc_multiple_bookmarks"

        for page in [15, 2, 8, 20, 5] {
            try db.setBookmark(md5: md5, pageIndex: page, isBookmarked: true)
        }

        let bookmarks = try db.getBookmarks(for: md5)
        XCTAssertEqual(bookmarks.sorted(), [2, 5, 8, 15, 20])

        // Delete page 8
        try db.setBookmark(md5: md5, pageIndex: 8, isBookmarked: false)
        let afterDelete8 = try db.getBookmarks(for: md5)
        XCTAssertEqual(afterDelete8.sorted(), [2, 5, 15, 20])

        // Delete all remaining
        for p in afterDelete8 {
            try db.setBookmark(md5: md5, pageIndex: p, isBookmarked: false)
        }
        let afterDeleteAll = try db.getBookmarks(for: md5)
        XCTAssertTrue(afterDeleteAll.isEmpty)
    }

    func testDocumentCollisionAvoidanceAndStableUUID() throws {
        let db = try Database(inMemory: true)
        let legacySharedID = UUID()

        let doc1 = Document(id: legacySharedID, title: "Book One", filePath: "/tmp/book1.pdf", md5: "md5-one", totalPages: 100)
        try db.insertDocument(doc1)

        // Same ID, different MD5 should not overwrite doc1!
        let doc2 = Document(id: legacySharedID, title: "Book Two", filePath: "/tmp/book2.pdf", md5: "md5-two", totalPages: 200)
        try db.insertDocument(doc2)

        let all = try db.allDocuments()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.title == "Book One" && $0.md5 == "md5-one" })
        XCTAssertTrue(all.contains { $0.title == "Book Two" && $0.md5 == "md5-two" })

        // Repair document IDs
        try db.repairDocumentIDs()
        let repaired = try db.allDocuments()
        XCTAssertEqual(repaired.count, 2)
        for doc in repaired {
            XCTAssertEqual(doc.id, Document.stableUUID(doc.md5))
        }
    }

    func testDeleteDocument() throws {
        let db = try Database(inMemory: true)
        let doc = Document(title: "To Delete", filePath: "/tmp/del.pdf", md5: "md5-del", totalPages: 10)
        try db.insertDocument(doc)
        XCTAssertEqual(try db.allDocuments().count, 1)

        try db.deleteDocument(id: doc.id)
        XCTAssertEqual(try db.allDocuments().count, 0)

        try db.insertDocument(doc)
        XCTAssertEqual(try db.allDocuments().count, 1)
        try db.deleteDocument(md5: doc.md5)
        XCTAssertEqual(try db.allDocuments().count, 0)
    }

    func testSyncAvailableDocuments() throws {
        let db = try Database(inMemory: true)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_sync_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a dummy PDF file
        let pdfURL = tempDir.appendingPathComponent("TestDocument.pdf")
        let pdfData = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n3 0 obj<</Type/Page/MediaBox[0 0 100 100]/Parent 2 0 R>>endobj\nxref\n0 4\n0000000000 65535 f\n0000000009 00000 n\n0000000052 00000 n\n0000000101 00000 n\ntrailer<</Size 4/Root 1 0 R>>\nstartxref\n178\n%%EOF\n".data(using: .utf8)!
        try pdfData.write(to: pdfURL)

        let sidecarURL = tempDir.appendingPathComponent("TestDocument.pdf.md5")
        try "custom-sidecar-md5-12345".write(to: sidecarURL, atomically: true, encoding: .utf8)

        try db.syncAvailableDocuments(additionalSearchPaths: [tempDir])

        let docs = try db.allDocuments()
        XCTAssertTrue(docs.contains { $0.md5 == "custom-sidecar-md5-12345" && $0.title == "TestDocument" })
    }

    func testSyncRestoresAllDocumentsInLiveEnvironmentIfExists() throws {
        let liveDBPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MarginGraph/MarginGraph.sqlite").path
        guard FileManager.default.fileExists(atPath: liveDBPath) else { return }

        let db = try Database(path: liveDBPath)
        try db.syncAvailableDocuments()
        let docs = try db.allDocuments()
        print("Restored and synchronized live documents count: \(docs.count)")
        for doc in docs {
            print(" -> Doc: \(doc.title) (id: \(doc.id), md5: \(doc.md5))")
        }
        XCTAssertGreaterThanOrEqual(docs.count, 4)
        XCTAssertTrue(docs.contains { $0.title.contains("Save the Cat") || $0.filePath.contains("Save the Cat") })
        XCTAssertTrue(docs.contains { $0.title.contains("Screenplay") || $0.filePath.contains("Screenplay") })
        XCTAssertTrue(docs.contains { $0.title.contains("Adler") || $0.filePath.contains("Adler") })
        XCTAssertTrue(docs.contains { $0.title.contains("Ahrens") || $0.title.contains("Smart Notes") || $0.filePath.contains("Ahrens") })

        let topics = try db.allTopics()
        if let ahrensTopic = topics.first(where: { $0.title.contains("Ahrens") }) {
            let ahrensDocs = try db.documentsForTopic(id: ahrensTopic.id)
            XCTAssertFalse(ahrensDocs.isEmpty, "Ahrens topic must have attached document")
            XCTAssertTrue(FileManager.default.fileExists(atPath: ahrensDocs[0].filePath))
        }
        if let adlerTopic = topics.first(where: { $0.title.contains("Adler") }) {
            let adlerDocs = try db.documentsForTopic(id: adlerTopic.id)
            XCTAssertFalse(adlerDocs.isEmpty, "Adler topic must have attached document")
            XCTAssertTrue(FileManager.default.fileExists(atPath: adlerDocs[0].filePath))
        }
        if let saveTheCatTopic = topics.first(where: { $0.title.contains("Save the Cat") }) {
            let saveTheCatDocs = try db.documentsForTopic(id: saveTheCatTopic.id)
            XCTAssertFalse(saveTheCatDocs.isEmpty, "Save the Cat topic must have attached document")
            XCTAssertTrue(FileManager.default.fileExists(atPath: saveTheCatDocs[0].filePath))
        }
        if let screenplayTopic = topics.first(where: { $0.title.contains("Screenplay") }) {
            let screenplayDocs = try db.documentsForTopic(id: screenplayTopic.id)
            XCTAssertFalse(screenplayDocs.isEmpty, "Screenplay topic must have attached document")
            XCTAssertTrue(FileManager.default.fileExists(atPath: screenplayDocs[0].filePath))
        }
    }

    func testDocumentAndTopicPositionPersistence() throws {
        let db = try Database(inMemory: true)
        let docMD5 = "test_md5_persistence"
        let doc = Document(
            title: "Test Book",
            filePath: "/tmp/test_book.pdf",
            md5: docMD5,
            totalPages: 50,
            lastPageIndex: 7,
            lastPageOffsetY: 145.5,
            mindPanX: 80.0,
            mindPanY: -120.0,
            mindZoomScale: 1.5
        )
        try db.insertDocument(doc)

        let fetched = try db.getDocumentByMD5(md5: docMD5)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.lastPageIndex, 7)
        XCTAssertEqual(fetched?.lastPageOffsetY, 145.5)
        XCTAssertEqual(fetched?.mindPanX, 80.0)
        XCTAssertEqual(fetched?.mindPanY, -120.0)
        XCTAssertEqual(fetched?.mindZoomScale, 1.5)

        // Update PDF position
        try db.updateDocumentPosition(md5: docMD5, pageIndex: 12, pageOffsetY: 310.0)
        let updatedPDF = try db.getDocumentByMD5(md5: docMD5)
        XCTAssertEqual(updatedPDF?.lastPageIndex, 12)
        XCTAssertEqual(updatedPDF?.lastPageOffsetY, 310.0)

        // Update MindMap position
        try db.updateDocumentMindMapPosition(md5: docMD5, panX: 250.0, panY: -400.0, zoomScale: 0.8)
        let updatedMM = try db.getDocumentByMD5(md5: docMD5)
        XCTAssertEqual(updatedMM?.mindPanX, 250.0)
        XCTAssertEqual(updatedMM?.mindPanY, -400.0)
        XCTAssertEqual(updatedMM?.mindZoomScale, 0.8)

        // Test topic position persistence
        let topic = Topic(
            title: "Topic Persistence",
            bookMD5List: [docMD5],
            mindPanX: 50.0,
            mindPanY: 75.0,
            mindZoomScale: 1.1,
            lastDocumentMD5: docMD5
        )
        try db.insertTopic(topic)

        let fetchedTopic = try db.getTopic(id: topic.id)
        XCTAssertNotNil(fetchedTopic)
        XCTAssertEqual(fetchedTopic?.mindPanX, 50.0)
        XCTAssertEqual(fetchedTopic?.mindPanY, 75.0)
        XCTAssertEqual(fetchedTopic?.mindZoomScale, 1.1)
        XCTAssertEqual(fetchedTopic?.lastDocumentMD5, docMD5)

        // Update topic mindmap position and last document
        try db.updateTopicMindMapPosition(id: topic.id, panX: -100.0, panY: 200.0, zoomScale: 2.0)
        try db.updateTopicLastDocument(id: topic.id, md5: "other_doc_md5")

        let updatedTopic = try db.getTopic(id: topic.id)
        XCTAssertEqual(updatedTopic?.mindPanX, -100.0)
        XCTAssertEqual(updatedTopic?.mindPanY, 200.0)
        XCTAssertEqual(updatedTopic?.mindZoomScale, 2.0)
        XCTAssertEqual(updatedTopic?.lastDocumentMD5, "other_doc_md5")

        // Test preserving position when inserting an existing document with default values
        let incomingWithDefaults = Document(
            title: "Test Book Re-import",
            filePath: "/tmp/test_book.pdf",
            md5: docMD5,
            totalPages: 50
        )
        try db.insertDocument(incomingWithDefaults)
        let preserved = try db.getDocumentByMD5(md5: docMD5)
        XCTAssertEqual(preserved?.lastPageIndex, 12, "Re-inserting default doc should preserve existing lastPageIndex")
        XCTAssertEqual(preserved?.lastPageOffsetY, 310.0, "Re-inserting default doc should preserve existing lastPageOffsetY")
        XCTAssertEqual(preserved?.mindPanX, 250.0, "Re-inserting default doc should preserve existing mindPanX")
    }

    func testFTS5SearchAndTriggers() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "CS AI Topic")
        try db.insertTopic(topic)

        let card1 = NoteCard(
            topicId: topic.id,
            title: "Decision Trees",
            highlightText: "Decision trees choose the attribute that minimizes Shannon entropy.",
            notesText: "Chapter 3 Machine Learning review.",
            tags: ["ml", "cmu"]
        )
        let card2 = NoteCard(
            topicId: topic.id,
            title: "Convolutional Neural Networks",
            highlightText: "CNNs exploit spatial locality through shared weight convolution filters.",
            notesText: "Deep learning lecture 4.",
            tags: ["dl", "cv"]
        )
        try db.insertCard(card1)
        try db.insertCard(card2)

        // 1. Search for "entropy"
        let entropyMatches = try db.searchCards(query: "entropy")
        XCTAssertEqual(entropyMatches.count, 1)
        XCTAssertEqual(entropyMatches.first?.title, "Decision Trees")

        // 2. Search for "spatial"
        let spatialMatches = try db.searchCards(query: "spatial")
        XCTAssertEqual(spatialMatches.count, 1)
        XCTAssertEqual(spatialMatches.first?.title, "Convolutional Neural Networks")

        // 3. Search for prefix "convolut*"
        let prefixMatches = try db.searchCards(query: "convolut")
        XCTAssertEqual(prefixMatches.count, 1)
        XCTAssertEqual(prefixMatches.first?.title, "Convolutional Neural Networks")

        // 4. Update card and verify FTS trigger updates index
        var updated = card1
        updated.highlightText = "Information gain measures relative entropy reduction."
        try db.updateCard(updated)

        let infoGainMatches = try db.searchCards(query: "Information")
        XCTAssertEqual(infoGainMatches.count, 1)
        XCTAssertEqual(infoGainMatches.first?.id, card1.id)

        // 5. Delete card and verify removal from FTS index
        try db.deleteCard(id: card2.id)
        let deletedMatches = try db.searchCards(query: "spatial")
        XCTAssertEqual(deletedMatches.count, 0)
    }

    func testVideoNotesAndDocuments() throws {
        let db = try Database(inMemory: true)
        let videoDoc = Document(
            title: "Lecture 1: Intro to ML",
            filePath: "/Volumes/Media/lecture1.mp4",
            md5: "video_lecture_1_md5",
            totalPages: 4747,
            documentType: "video"
        )
        try db.insertDocument(videoDoc)

        let fetchedDoc = try db.getDocumentByMD5(md5: "video_lecture_1_md5")
        XCTAssertEqual(fetchedDoc?.documentType, "video")
        XCTAssertEqual(fetchedDoc?.totalPages, 4747)

        let topic = Topic(title: "ML Course", bookMD5List: ["video_lecture_1_md5"])
        try db.insertTopic(topic)

        let videoCard = NoteCard(
            topicId: topic.id,
            bookMD5: "video_lecture_1_md5",
            title: "Decision Trees Definition",
            highlightText: "Video segment explaining decision trees",
            mediaType: "video",
            videoStartTime: 781.5,
            videoEndTime: 841.8
        )
        try db.insertCard(videoCard)

        let fetchedCard = try db.getCard(id: videoCard.id)
        XCTAssertNotNil(fetchedCard)
        XCTAssertEqual(fetchedCard?.mediaType, "video")
        XCTAssertEqual(fetchedCard?.videoStartTime, 781.5)
        XCTAssertEqual(fetchedCard?.videoEndTime, 841.8)
    }

    func testMediaStorageHEICCompression() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try MediaStorage(directoryURL: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a test 400x300 image
        let width = 400
        let height = 300
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!

        let savedFilename = try storage.saveCGImage(img, format: "heic", quality: 0.82)
        XCTAssertTrue(savedFilename.hasSuffix(".heic"))

        // Test loading by filename and by raw hash
        let loadedData = storage.loadImage(hash: savedFilename)
        XCTAssertNotNil(loadedData)
        XCTAssertGreaterThan(loadedData?.count ?? 0, 100)

        let hashWithoutExt = String(savedFilename.dropLast(5))
        let loadedWithoutExt = storage.loadImage(hash: hashWithoutExt)
        XCTAssertNotNil(loadedWithoutExt)
        XCTAssertEqual(loadedData?.count, loadedWithoutExt?.count)
    }

    func testRenameDocumentAndRenameTopicAndCascadeDeleteTopic() throws {
        let db = try Database(inMemory: true)
        let doc = Document(title: "Old Doc Title", filePath: "/tmp/old.pdf", md5: "md5-rename-test", totalPages: 10)
        try db.insertDocument(doc)

        // Rename document
        try db.renameDocument(id: doc.id, newTitle: "New Doc Title")
        let renamedDoc = try db.getDocument(id: doc.id)
        XCTAssertEqual(renamedDoc?.title, "New Doc Title")

        // Topic creation & rename
        let topic = Topic(title: "Old Topic Title", bookMD5List: [doc.md5])
        try db.insertTopic(topic)
        try db.renameTopic(id: topic.id, newTitle: "New Topic Title")
        let renamedTopic = try db.getTopic(id: topic.id)
        XCTAssertEqual(renamedTopic?.title, "New Topic Title")

        // Add card, link, review item, deck card
        let card = NoteCard(topicId: topic.id, title: "Topic Card")
        try db.insertCard(card)
        let link = CardLink(topicId: topic.id, sourceCardId: card.id, targetCardId: card.id, label: nil, isBidirectional: false)
        try db.insertLink(link)
        let deck = try db.createDeck(title: "Test Deck")
        try db.addCardsToDeck(cardIds: [card.id], deckId: deck.id)

        // Delete topic
        try db.deleteTopic(id: topic.id)
        XCTAssertNil(try db.getTopic(id: topic.id))
        XCTAssertNil(try db.getCard(id: card.id))
        XCTAssertTrue(try db.linksForTopic(id: topic.id).isEmpty)
        XCTAssertTrue(try db.cardsForDeck(deckId: deck.id).isEmpty)
    }
}



