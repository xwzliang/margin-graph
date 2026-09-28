import XCTest
import PDFKit
@testable import MarginGraphCore

final class EPUBConverterTests: XCTestCase {

    func testEPUBConverterFindsPythonOrCalibre() {
        let python = EPUBConverter.findExecutable(named: "python3")
        let calibre = EPUBConverter.findExecutable(named: "ebook-convert")
        XCTAssertTrue(python != nil || calibre != nil, "At least one conversion executable (python3 or ebook-convert) should be available")
    }

    func testEPUBConversionAndPDFDocumentManagerIntegration() throws {
        let sampleEPUBPath = "/Users/broliang/Documents/book/HowtoWriteShortStoriesAndUseThemtoFurtherYour--JamesScottBell--2016--CompendiumPress--955df5aa080edfb8429de639bf271b11--Anna_sArchive.epub"
        guard FileManager.default.fileExists(atPath: sampleEPUBPath) else {
            print("Skipping testEPUBConversionAndPDFDocumentManagerIntegration: sample epub not found")
            return
        }

        let epubURL = URL(fileURLWithPath: sampleEPUBPath)
        let result = try EPUBConverter.ensureConvertedPDF(for: epubURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.pdfURL.path))
        XCTAssertGreaterThan(result.pageCount, 50)
        XCTAssertFalse(result.title.isEmpty)
        XCTAssertFalse(result.md5.isEmpty)

        // Verify PDFDocumentManager opens the epub URL transparently
        let manager = try PDFDocumentManager(url: epubURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertFalse(manager.title.isEmpty)
        XCTAssertGreaterThan(manager.outline.count, 0, "Table of contents should be preserved")

        // Subsequent call uses cache instantly
        let cachedResult = try EPUBConverter.ensureConvertedPDF(for: epubURL)
        XCTAssertEqual(cachedResult.pdfURL.path, result.pdfURL.path)
        XCTAssertEqual(cachedResult.pageCount, result.pageCount)
    }

    func testEPUBDocumentCreationAndDatabaseStorage() throws {
        let db = try Database(inMemory: true)
        let sampleEPUBPath = "/Users/broliang/Documents/book/HowtoWriteShortStoriesAndUseThemtoFurtherYour--JamesScottBell--2016--CompendiumPress--955df5aa080edfb8429de639bf271b11--Anna_sArchive.epub"
        guard FileManager.default.fileExists(atPath: sampleEPUBPath) else {
            return
        }

        let epubURL = URL(fileURLWithPath: sampleEPUBPath)
        let result = try EPUBConverter.ensureConvertedPDF(for: epubURL)
        let manager = try PDFDocumentManager(url: epubURL)

        let doc = Document(
            id: Document.stableUUID(result.md5),
            title: manager.title,
            filePath: result.pdfURL.path,
            md5: result.md5,
            totalPages: manager.pageCount,
            lastVisited: Date(),
            documentType: "epub"
        )
        try db.insertDocument(doc)

        let fetched = try db.getDocumentByMD5(md5: result.md5)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.documentType, "epub")
        XCTAssertEqual(fetched?.totalPages, manager.pageCount)

        // Test attaching to a study topic
        let topic = Topic(id: UUID(), title: "Fiction Writing Study")
        try db.insertTopic(topic)
        try db.addDocument(to: topic.id, md5: result.md5)

        let topicDocs = try db.documentsForTopic(id: topic.id)
        XCTAssertEqual(topicDocs.count, 1)
        XCTAssertEqual(topicDocs.first?.documentType, "epub")

        // Test creating note card excerpt on the EPUB
        let card = NoteCard(
            id: UUID(),
            topicId: topic.id,
            bookMD5: result.md5,
            title: "Crucial Excerpt",
            highlightText: "Story structure quote",
            colorIndex: 0,
            highlightRects: [HighlightRect(page: 1, x: 50, y: 400, width: 200, height: 14)]
        )
        try db.insertCard(card)

        let cardsForDoc = try db.cardsForDocument(md5: result.md5)
        XCTAssertEqual(cardsForDoc.count, 1)
        XCTAssertEqual(cardsForDoc.first?.title, "Crucial Excerpt")
    }

    func testNativeWebKitEPUBConversionStandalone() throws {
        let sampleEPUBPath = "/Users/broliang/Documents/book/HowtoWriteShortStoriesAndUseThemtoFurtherYour--JamesScottBell--2016--CompendiumPress--955df5aa080edfb8429de639bf271b11--Anna_sArchive.epub"
        guard FileManager.default.fileExists(atPath: sampleEPUBPath) else {
            return
        }

        let epubURL = URL(fileURLWithPath: sampleEPUBPath)
        let targetPDF = FileManager.default.temporaryDirectory.appendingPathComponent("test_native_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: targetPDF) }

        try EPUBConverter.convertWithNativeWebKit(epubURL: epubURL, targetPDF: targetPDF)

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPDF.path))
        let doc = PDFDocument(url: targetPDF)
        XCTAssertNotNil(doc)
        XCTAssertGreaterThan(doc?.pageCount ?? 0, 10, "Native WebKit conversion should render all chapters")

        // Verify outline/TOC was generated
        XCTAssertNotNil(doc?.outlineRoot)
        XCTAssertGreaterThan(doc?.outlineRoot?.numberOfChildren ?? 0, 5, "Native WebKit conversion should build Table of Contents")

        // Verify selectable text exists on chapters
        let pageText = doc?.page(at: 4)?.string ?? ""
        XCTAssertTrue(pageText.contains("SHORT STORY") || pageText.contains("Seinfeld"), "Vector text must be selectable and intact")
    }

    func testExtractEPUBCoverImage() throws {
        let sampleEPUBPath = "/Volumes/omv/backups/marginnote/MarginNoteBackup(2026-09-21-12-33-07).marginbackupall/Cade Metz - Genius Makers_ The Mavericks Who Brought AI to Google, Facebook, and the World-Dutton (2021).epub"
        guard FileManager.default.fileExists(atPath: sampleEPUBPath) else { return }

        let epubURL = URL(fileURLWithPath: sampleEPUBPath)
        let cover = MediaDocumentHelper.extractEPUBCoverImage(url: epubURL)
        XCTAssertNotNil(cover, "Genius Makers EPUB should extract cover image")
        if let cover {
            XCTAssertGreaterThan(cover.size.width, 300)
            XCTAssertGreaterThan(cover.size.height, 400)
        }
    }
}
