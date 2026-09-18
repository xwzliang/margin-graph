import XCTest
import CoreGraphics
import CoreText
@testable import MarginGraphCore

final class PDFTests: XCTestCase {
    func testPDFLoadingTextHashAndCrop() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeSyntheticPDF(at: url)
        let manager = try PDFDocumentManager(url: url)

        XCTAssertEqual(manager.pageCount, 1)
        XCTAssertEqual(manager.md5.count, 32)
        XCTAssertTrue(manager.text(onPage: 0).contains("MarginGraph"))
        XCTAssertNotNil(manager.thumbnail(pageIndex: 0))

        let cropBounds = CGRect(x: 40, y: 40, width: 260, height: 120)
        let png = try XCTUnwrap(manager.crop(pageIndex: 0, bounds: cropBounds))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testMediaStorageAndExcerptCoordinatorRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraphMedia-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let media = try MediaStorage(directoryURL: root)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        let hash = try media.saveImage(imageData, format: "png")

        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(media.loadImage(hash: hash), imageData)
        XCTAssertEqual(media.imageURL(hash: hash).lastPathComponent, hash)

        let database = try Database(inMemory: true)
        let topic = Topic(title: "PDF Study")
        try database.insertTopic(topic)

        let excerpt = PDFExcerpt(
            bookMD5: "deadbeef",
            pageIndex: 2,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 40),
            text: "Synthetic excerpt",
            croppedImageData: imageData
        )

        let card = try ExcerptCoordinator(database: database, mediaStorage: media)
            .createCard(from: excerpt, topicId: topic.id)

        XCTAssertEqual(card.bookMD5, "deadbeef")
        XCTAssertEqual(card.startPage, 2)
        XCTAssertEqual(card.startPos, CGPoint(x: 10, y: 20))
        XCTAssertEqual(card.endPos, CGPoint(x: 110, y: 60))
        XCTAssertNotNil(card.highlightPicHash)
        let fetched = try XCTUnwrap(database.getCard(id: card.id))
        XCTAssertEqual(fetched.id, card.id)
        XCTAssertEqual(fetched.highlightText, card.highlightText)
        XCTAssertEqual(fetched.bookMD5, card.bookMD5)
        XCTAssertEqual(try database.cardsForDocument(md5: "deadbeef").map(\.id), [card.id])
    }

    func testHighlightResolverUsesStoredRectsAndPDFTextLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-highlight-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeSyntheticPDF(at: url)
        let manager = try PDFDocumentManager(url: url)
        let topicID = UUID()

        let stored = [
            HighlightRect(page: 0, x: 60, y: 90, width: 100, height: 20),
            HighlightRect(page: 0, x: 60, y: 65, width: 120, height: 20)
        ]
        let importedCard = NoteCard(
            topicId: topicID,
            highlightText: "MarginGraph synthetic PDF",
            startPage: 0,
            highlightRects: stored
        )
        XCTAssertEqual(PDFHighlightResolver.lineRects(for: importedCard, in: manager.document), stored)

        let textCard = NoteCard(
            topicId: topicID,
            highlightText: "MarginGraph synthetic PDF",
            startPage: 0
        )
        let resolved = PDFHighlightResolver.lineRects(for: textCard, in: manager.document)
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(resolved.allSatisfy { $0.page == 0 && $0.width > 0 && $0.height > 0 })
    }

    private func makeSyntheticPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 260, height: 120))
        context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 40, y: 40, width: 260, height: 120))

        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(
            nil,
            "MarginGraph synthetic PDF" as CFString,
            attributes
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 60, y: 100)
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        CTLineDraw(line, context)

        context.endPDFPage()
        context.closePDF()
    }
}
