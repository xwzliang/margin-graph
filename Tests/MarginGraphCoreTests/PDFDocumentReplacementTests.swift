import PDFKit
import XCTest
@testable import MarginGraphCore

@MainActor
final class PDFDocumentReplacementTests: XCTestCase {
    func testReplacementAndRestoreUpdateOutlineAndKeepDocumentAndStudyState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Library")
        let original = library.appendingPathComponent("Book.pdf")
        let source = directory.appendingPathComponent("Revised.pdf")
        try makePDF(at: original, outline: "Old chapter")
        try makePDF(at: source, outline: "New chapter")
        let oldBytes = try Data(contentsOf: original)
        let revisedBytes = try Data(contentsOf: source)
        let sourceSidecar = source.appendingPathExtension("md5")
        try "incoming-hash".write(to: sourceSidecar, atomically: true, encoding: .utf8)

        let database = try Database(inMemory: true)
        let folder = DocumentFolder(name: "Reading")
        try database.insertFolder(folder)
        let hash = "stable-book-hash"
        let document = Document(id: Document.stableUUID(hash), title: "My book", filePath: original.path,
                                md5: hash, totalPages: 1, lastVisited: Date(timeIntervalSince1970: 10),
                                lastPageIndex: 1, lastPageOffsetY: 42, mindPanX: 12, mindPanY: 14,
                                mindZoomScale: 1.5, folderId: folder.id)
        try database.insertDocument(document)
        let topic = Topic(title: "Notebook", bookMD5List: [hash], lastDocumentMD5: hash)
        try database.insertTopic(topic)
        let first = NoteCard(topicId: topic.id, bookMD5: hash, title: "Excerpt", highlightText: "Kept",
                             startPage: 1, highlightRects: [HighlightRect(page: 1, x: 20, y: 40, width: 100, height: 12)])
        let second = NoteCard(topicId: topic.id, bookMD5: hash, title: "Follow-up", groupNoteId: first.id)
        try database.insertCard(first)
        try database.insertCard(second)
        let link = CardLink(topicId: topic.id, sourceCardId: first.id, targetCardId: second.id)
        try database.insertLink(link)
        try database.setBookmark(md5: hash, pageIndex: 1, isBookmarked: true)
        let savedCards = try database.cardsForTopic(id: topic.id)
        let savedTopic = try database.getTopic(id: topic.id)

        let result = try PDFDocumentReplacement.replace(document, with: source, in: database, managedDirectory: library)
        XCTAssertEqual(result.manager.outline.first?.title, "New chapter")
        XCTAssertEqual(result.manager.outline.first?.pageIndex, 1)
        XCTAssertEqual(result.manager.md5, hash)
        XCTAssertEqual(try Data(contentsOf: result.manager.url), revisedBytes)
        XCTAssertEqual(try Data(contentsOf: source), revisedBytes)
        XCTAssertEqual(try String(contentsOf: sourceSidecar, encoding: .utf8), "incoming-hash")
        XCTAssertEqual(try Data(contentsOf: original), oldBytes)

        var expected = document
        expected.filePath = result.manager.url.path
        expected.totalPages = 2
        XCTAssertNotEqual(expected.filePath, source.path)
        XCTAssertEqual(result.document, expected)
        try database.syncAvailableDocuments(libraryRoot: library)
        XCTAssertEqual(try database.allDocuments(), [expected])
        XCTAssertEqual(try database.cardsForTopic(id: topic.id), savedCards)
        XCTAssertEqual(try database.getTopic(id: topic.id), savedTopic)
        XCTAssertEqual(try database.linksForTopic(id: topic.id), [link])
        XCTAssertEqual(try database.getBookmarks(for: hash), [1])

        let laterNote = NoteCard(topicId: topic.id, bookMD5: hash, title: "Added after replacement")
        try database.insertCard(laterNote)
        let cardsBeforeRestore = try database.cardsForTopic(id: topic.id)
        let laterSource = directory.appendingPathComponent("Second revision.pdf")
        try makePDF(at: laterSource, outline: "Another outline")
        let later = try PDFDocumentReplacement.replace(result.document, with: laterSource, in: database, managedDirectory: library)

        let firstPrevious = try XCTUnwrap(PDFDocumentReplacement.previousURL(for: later.document, in: database))
        XCTAssertEqual(firstPrevious, result.manager.url)
        let firstRestore = try PDFDocumentReplacement.restore(later.document, to: firstPrevious, in: database)
        XCTAssertEqual(firstRestore.document, expected)
        XCTAssertEqual(firstRestore.manager.outline.first?.title, "New chapter")
        XCTAssertNil(try PDFDocumentReplacement.previousURL(for: later.document, in: database))

        let nextPrevious = try XCTUnwrap(PDFDocumentReplacement.previousURL(for: firstRestore.document, in: database))
        XCTAssertEqual(nextPrevious.path, original.path)
        let secondRestore = try PDFDocumentReplacement.restore(firstRestore.document, to: nextPrevious, in: database)
        expected.filePath = original.path
        XCTAssertEqual(secondRestore.document, expected)
        XCTAssertEqual(secondRestore.manager.outline.first?.title, "Old chapter")
        XCTAssertNil(try PDFDocumentReplacement.previousURL(for: secondRestore.document, in: database))
        try database.syncAvailableDocuments(additionalSearchPaths: [library])
        XCTAssertEqual(try database.allDocuments().map(\.filePath), [original.path])
        XCTAssertEqual(try database.cardsForTopic(id: topic.id), cardsBeforeRestore)
        XCTAssertEqual(try database.getTopic(id: topic.id), savedTopic)
        XCTAssertEqual(try database.linksForTopic(id: topic.id), [link])
        XCTAssertEqual(try database.getBookmarks(for: hash), [1])
        XCTAssertEqual(try Data(contentsOf: result.manager.url), revisedBytes)
    }

    func testLegacyReplacementCanBeRestoredAfterMissingPDFIsRecovered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Book.pdf")
        let revised = directory.appendingPathComponent(PDFDocumentReplacement.directoryName)
            .appendingPathComponent("Revision/Book.pdf")
        try makePDF(at: revised, outline: "New chapter")

        let database = try Database(inMemory: true)
        let document = Document(title: "Book", filePath: revised.path, md5: "book", totalPages: 2)
        try database.insertDocument(document)
        try database.recordRetiredDocumentPath(original.path, md5: document.md5)
        try database.createPDFReplacementHistory()

        let previous = try XCTUnwrap(PDFDocumentReplacement.previousURL(for: document, in: database))
        XCTAssertEqual(previous.path, original.path)
        XCTAssertThrowsError(try PDFDocumentReplacement.restore(document, to: previous, in: database))
        XCTAssertEqual(try database.getDocument(id: document.id), document)
        XCTAssertEqual(try PDFDocumentReplacement.previousURL(for: document, in: database), previous)

        try makePDF(at: original, outline: "Old chapter")
        let restored = try PDFDocumentReplacement.restore(document, to: previous, in: database)
        XCTAssertEqual(restored.manager.outline.first?.title, "Old chapter")
        XCTAssertEqual(restored.document.filePath, original.path)
        XCTAssertNil(try PDFDocumentReplacement.previousURL(for: restored.document, in: database))
    }

    func testLegacyHistoryRequiresAnUnambiguousManagedReplacement() throws {
        let database = try Database(inMemory: true)
        let ordinary = Document(title: "Ordinary", filePath: "/original.pdf", md5: "ordinary", totalPages: 1)
        let revised = Document(title: "Revised", filePath: "/\(PDFDocumentReplacement.directoryName)/Revision/book.pdf",
                               md5: "revised", totalPages: 1)
        try database.insertDocument(ordinary)
        try database.insertDocument(revised)
        try database.recordRetiredDocumentPath("/unrelated.pdf", md5: ordinary.md5)
        try database.recordRetiredDocumentPath("/one.pdf", md5: revised.md5)
        try database.recordRetiredDocumentPath("/two.pdf", md5: revised.md5)
        try database.createPDFReplacementHistory()
        XCTAssertNil(try PDFDocumentReplacement.previousURL(for: ordinary, in: database))
        XCTAssertNil(try PDFDocumentReplacement.previousURL(for: revised, in: database))
    }

    func testFailedReplacementLeavesTheCurrentPDFAndCleansUpTheCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Book.pdf")
        let source = directory.appendingPathComponent("Revised.pdf")
        let managed = directory.appendingPathComponent("Managed")
        try makePDF(at: original, outline: "Old chapter")
        let database = try Database(inMemory: true)
        let document = Document(title: "Book", filePath: original.path, md5: "book", totalPages: 2)
        try database.insertDocument(document)

        try makePDF(at: source, outline: "Wrong count", pageCount: 1)
        XCTAssertThrowsError(try PDFDocumentReplacement.replace(document, with: source, in: database, managedDirectory: managed))
        try makePDF(at: source, outline: "Wrong layout", pageWidth: 400)
        XCTAssertThrowsError(try PDFDocumentReplacement.replace(document, with: source, in: database, managedDirectory: managed))

        // Force a write failure after the previous path was recorded as retired.
        try makePDF(at: source, outline: "New chapter")
        try database.execute("""
            CREATE TRIGGER reject_pdf_update BEFORE UPDATE OF file_path ON documents
            BEGIN SELECT RAISE(ABORT, 'test failure'); END;
            """)
        XCTAssertThrowsError(try PDFDocumentReplacement.replace(document, with: source, in: database, managedDirectory: managed))
        XCTAssertEqual(try database.getDocument(id: document.id), document)
        XCTAssertEqual(try database.getDocumentByPath(filePath: original.path), document)
        let replacements = managed.appendingPathComponent(PDFDocumentReplacement.directoryName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacements.path), [])
    }

    private func makePDF(at url: URL, outline title: String, pageCount: Int = 2, pageWidth: CGFloat = 300) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 20, y: 40, width: 100, height: 12))
            context.endPDFPage()
        }
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: url))
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = title
        chapter.destination = PDFDestination(page: try XCTUnwrap(document.page(at: pageCount - 1)), at: .zero)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        XCTAssertTrue(document.write(to: url))
    }
}
