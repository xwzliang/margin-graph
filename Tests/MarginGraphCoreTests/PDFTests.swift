import XCTest
import CoreGraphics
import CoreText
import PDFKit
import SwiftUI
@testable import MarginGraphCore

@MainActor
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

    @MainActor
    func testInteractivePDFViewHighlightDragUpdate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-drag-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeSyntheticPDF(at: url)
        let manager = try PDFDocumentManager(url: url)
        let doc = manager.document
        guard let page = doc.page(at: 0) else {
            XCTFail("Missing page 0")
            return
        }

        let cardID = UUID()
        let initialRects = [
            HighlightRect(page: 0, x: 60, y: 95, width: 200, height: 25)
        ]
        let card = NoteCard(
            id: cardID,
            topicId: UUID(),
            title: "Original Title",
            highlightText: "MarginGraph synthetic PDF",
            startPage: 0,
            highlightRects: initialRects
        )

        let view = InteractivePDFView()
        view.document = doc
        view.cards = [card]
        view.selectedCardID = cardID

        var updatedCardID: UUID?
        var updatedText: String?
        var updatedRects: [HighlightRect] = []
        view.updateCardHighlightHandler = { id, segId, text, newRects, startPt, endPt in
            updatedCardID = id
            updatedText = text
            updatedRects = newRects
        }

        // Test resolving lineRects from selection
        if let sel = page.selection(for: CGRect(x: 60, y: 95, width: 120, height: 25)) {
            let extracted = PDFHighlightResolver.lineRects(from: sel, document: doc)
            XCTAssertFalse(extracted.isEmpty)
            XCTAssertEqual(extracted.first?.page, 0)
            view.updateCardHighlightHandler?(cardID, nil, sel.string ?? "", extracted, .zero, .zero)
            XCTAssertEqual(updatedCardID, cardID)
            XCTAssertFalse(updatedRects.isEmpty)
            XCTAssertNotNil(updatedText)
        }
    }

    func testExcerptSegmentDatabaseRoundTrip() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Segment Test")
        try db.insertTopic(topic)

        let seg1 = ExcerptSegment(id: UUID(), text: "First segment text", rects: [HighlightRect(page: 0, x: 10, y: 20, width: 100, height: 15)])
        let seg2 = ExcerptSegment(id: UUID(), text: "Second segment text", rects: [HighlightRect(page: 0, x: 10, y: 40, width: 120, height: 15)])

        let card = NoteCard(
            topicId: topic.id,
            highlightText: "First segment text\n\nSecond segment text",
            highlightRects: seg1.rects + seg2.rects,
            emphasisList: ["First segment"],
            excerptSegments: [seg1, seg2]
        )
        try db.insertCard(card)

        let loaded = try XCTUnwrap(db.getCard(id: card.id))
        XCTAssertEqual(loaded.excerptSegments.count, 2)
        XCTAssertEqual(loaded.excerptSegments[0].text, "First segment text")
        XCTAssertEqual(loaded.excerptSegments[1].text, "Second segment text")
        XCTAssertEqual(loaded.effectiveSegments.count, 2)
        XCTAssertEqual(loaded.emphasisList, ["First segment"])

        // Test fallback when excerptSegments is empty
        var legacyCard = card
        legacyCard.id = UUID()
        legacyCard.excerptSegments = []
        try db.insertCard(legacyCard)

        let loadedLegacy = try XCTUnwrap(db.getCard(id: legacyCard.id))
        XCTAssertEqual(loadedLegacy.excerptSegments.count, 0)
        XCTAssertEqual(loadedLegacy.effectiveSegments.count, 1)
        XCTAssertEqual(loadedLegacy.effectiveSegments[0].text, legacyCard.highlightText)
    }

    func testDottedLineAnnotationRendering() {
        let annot = DottedLineAnnotation(
            bounds: CGRect(x: 10, y: 20, width: 100, height: 10),
            forType: .square,
            withProperties: nil
        )
        annot.lineStartPoint = CGPoint(x: 10, y: 25)
        annot.lineEndPoint = CGPoint(x: 110, y: 25)
        annot.strokeLineWidth = 2.5
        annot.dashPattern = [2.5, 3.5]

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create graphics context")
            return
        }

        annot.draw(with: .cropBox, in: context)
    }

    func testMultiPageSelectionAcrossPages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-multipage-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeMultiPageSyntheticPDF(at: url)
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load multi-page PDF")
            return
        }
        XCTAssertEqual(doc.pageCount, 2)
        guard let page0 = doc.page(at: 0), let page1 = doc.page(at: 1) else {
            XCTFail("Missing pages")
            return
        }

        let view = InteractivePDFView()
        view.document = doc

        let selection = view.makeMultiPageSelection(
            from: page0, at: CGPoint(x: 60, y: 120),
            to: page1, at: CGPoint(x: 400, y: 700)
        )
        XCTAssertNotNil(selection)
        let rects = PDFHighlightResolver.lineRects(from: try XCTUnwrap(selection), document: doc)
        XCTAssertFalse(rects.isEmpty)

        let pagesInRects = Set(rects.map { $0.page })
        XCTAssertTrue(pagesInRects.contains(0))
        XCTAssertTrue(pagesInRects.contains(1))
    }

    func testMarginNoteColorPaletteAndCursorColor() {
        XCTAssertGreaterThanOrEqual(MarginNoteTheme.cardPastels.count, 6)
        XCTAssertEqual(MarginNoteTheme.cursorBlueHex, "#1265dd")
        XCTAssertEqual(MarginNoteTheme.nsCursorColor, NSColor(srgbRed: 18/255.0, green: 101/255.0, blue: 221/255.0, alpha: 1.0))
    }

    func testNormalizeExcerptParagraphs() {
        let input = """
        Even the best scientists and thinkers
        are not free from it. What sets them
        apart is the mere fact that they are
        aware of the problem and do
        something about it.

        The classic role model would be
        Charles Darwin. He forced himself
        to write down dis-
        confirming facts.
        """
        let normalized = PDFHighlightResolver.normalizeExcerptParagraphs(input)
        let paragraphs = normalized.components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0], "Even the best scientists and thinkers are not free from it. What sets them apart is the mere fact that they are aware of the problem and do something about it.")
        XCTAssertEqual(paragraphs[1], "The classic role model would be Charles Darwin. He forced himself to write down disconfirming facts.")
    }

    func testNormalizeExcerptPreservesEmptyLinesBetweenParagraphs() {
        let input = "Paragraph one with several words here.\n\nParagraph two starting after an empty line."
        let normalized = PDFHighlightResolver.normalizeExcerptParagraphs(input)
        XCTAssertTrue(normalized.contains("\n\n"))
        let parts = normalized.components(separatedBy: "\n\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "Paragraph one with several words here.")
        XCTAssertEqual(parts[1], "Paragraph two starting after an empty line.")
    }

    func testPhysicalLinesBuildSingleParagraphWithQuotesAndDehyphenation() {
        let page = PDFPage()
        // Line 1: starts with indent
        let line1 = PDFHighlightResolver.PhysicalLine(
            text: "There is another reason that note-",
            bounds: CGRect(x: 86.25, y: 430, width: 453, height: 14),
            page: page
        )
        // Line 2: de-hyphenates "notetaking." and has quotes within line
        let line2 = PDFHighlightResolver.PhysicalLine(
            text: "taking. “Some people are just like that,” “writing has to be difficult,” “the",
            bounds: CGRect(x: 72.0, y: 412, width: 468, height: 14),
            page: page
        )
        // Line 3: continues sentence and finishes
        let line3 = PDFHighlightResolver.PhysicalLine(
            text: "struggle is part of the deal” are just a few mantras that keep many from inquiring.",
            bounds: CGRect(x: 72.0, y: 394, width: 350, height: 14),
            page: page
        )

        let result = PDFHighlightResolver.buildParagraphs(from: [line1, line2, line3], fallbackRaw: "")
        let paras = result.components(separatedBy: "\n\n")
        XCTAssertEqual(paras.count, 1)
        XCTAssertTrue(paras[0].contains("notetaking. “Some people are just like that,” “writing has to be difficult,” “the struggle"))
    }

    func testPhysicalLinesDetectsRealParagraphBreak() {
        let page = PDFPage()
        // Paragraph 1, line 1
        let p1_1 = PDFHighlightResolver.PhysicalLine(
            text: "This is the first line of the first paragraph.",
            bounds: CGRect(x: 86.25, y: 500, width: 450, height: 14),
            page: page
        )
        // Paragraph 1, line 2 (ends short with period)
        let p1_2 = PDFHighlightResolver.PhysicalLine(
            text: "This ends short.",
            bounds: CGRect(x: 72.0, y: 482, width: 120, height: 14),
            page: page
        )
        // Paragraph 2, line 1 (starts with indent at 86.25)
        let p2_1 = PDFHighlightResolver.PhysicalLine(
            text: "This is the second paragraph starting with indent.",
            bounds: CGRect(x: 86.25, y: 464, width: 450, height: 14),
            page: page
        )

        let result = PDFHighlightResolver.buildParagraphs(from: [p1_1, p1_2, p2_1], fallbackRaw: "")
        let paras = result.components(separatedBy: "\n\n")
        XCTAssertEqual(paras.count, 2)
        XCTAssertEqual(paras[0], "This is the first line of the first paragraph. This ends short.")
        XCTAssertEqual(paras[1], "This is the second paragraph starting with indent.")
    }

    func testHighlightRectDeduplication() {
        let rects = [
            HighlightRect(page: 1, x: 50, y: 100, width: 200, height: 16),
            HighlightRect(page: 1, x: 50, y: 100, width: 200, height: 16), // exact duplicate
            HighlightRect(page: 1, x: 51, y: 100.5, width: 199, height: 16), // near duplicate
            HighlightRect(page: 1, x: 50, y: 120, width: 200, height: 16) // distinct line
        ]
        let deduplicated = PDFHighlightResolver.deduplicate(rects)
        XCTAssertEqual(deduplicated.count, 2)
    }

    func testExcerptCoordinatorDefaultsToEmptyTitleAndSpecifiedColor() throws {
        let database = try Database(inMemory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraphMediaTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try MediaStorage(directoryURL: root)
        let topic = Topic(title: "Test Topic")
        try database.insertTopic(topic)

        let excerpt = PDFExcerpt(
            bookMD5: "md5test",
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 30),
            text: "Important excerpt text"
        )
        let coordinator = ExcerptCoordinator(database: database, mediaStorage: media)
        let card = try coordinator.createCard(from: excerpt, topicId: topic.id, colorIndex: 2)

        XCTAssertEqual(card.title, "", "New card title must default to empty string")
        XCTAssertEqual(card.highlightText, "Important excerpt text")
        XCTAssertEqual(card.colorIndex, 2)
    }

    func testMarginNoteBlueColorIsBfdbfe() {
        let colors = MarginNoteTheme.cardColors(for: 2)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        NSColor(colors.accent).usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(round(red * 255), 191)
        XCTAssertEqual(round(green * 255), 219)
        XCTAssertEqual(round(blue * 255), 254)
    }

    func testCreateHighlightAnnotationPreservesBoundsWithoutDisplacement() {
        let bounds = CGRect(x: 72.0, y: 702.5, width: 467.5, height: 14.0)
        let annotation = PDFHighlightResolver.createHighlightAnnotation(
            bounds: bounds,
            color: .yellow,
            contents: "MarginGraph-card-highlight"
        )
        XCTAssertEqual(annotation.bounds, bounds)
        XCTAssertEqual(annotation.contents, "MarginGraph-card-highlight")
        // Default quadrilateralPoints generated by PDFKit must be local to bounds (origin 0,0)
        if let quadPoints = annotation.quadrilateralPoints, !quadPoints.isEmpty {
            let p1 = quadPoints[0].pointValue
            XCTAssertEqual(p1.x, 0.0, accuracy: 0.1)
            XCTAssertEqual(p1.y, bounds.height, accuracy: 0.1)
        }
    }

    private func makeMultiPageSyntheticPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary

        context.beginPDFPage(nil)
        let attr1 = CFAttributedStringCreate(nil, "Page One line of synthetic text here" as CFString, attributes)!
        let line1 = CTLineCreateWithAttributedString(attr1)
        context.textPosition = CGPoint(x: 60, y: 120)
        CTLineDraw(line1, context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        let attr2 = CFAttributedStringCreate(nil, "Page Two continuation of text here" as CFString, attributes)!
        let line2 = CTLineCreateWithAttributedString(attr2)
        context.textPosition = CGPoint(x: 60, y: 700)
        CTLineDraw(line2, context)
        context.endPDFPage()

        context.closePDF()
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

    func testTargetCardPendingSelectionContainment() {
        let card = NoteCard(
            topicId: UUID(),
            title: "Test Card",
            highlightText: "This is a key excerpt from the document.",
            highlightRects: [
                HighlightRect(page: 0, x: 50, y: 100, width: 300, height: 16)
            ]
        )
        let view = InteractivePDFView()
        view.cards = [card]

        let pendingWithin = InteractivePDFView.PendingSelection(
            selection: PDFSelection(),
            text: "key excerpt",
            rects: [HighlightRect(page: 0, x: 80, y: 100, width: 60, height: 16)],
            startPage: PDFPage(),
            startPoint: CGPoint(x: 80, y: 108),
            endPage: PDFPage(),
            endPoint: CGPoint(x: 140, y: 108)
        )
        XCTAssertTrue(view.checkIfPendingWithinTarget(pendingWithin, targetCardID: card.id))

        let pendingOutside = InteractivePDFView.PendingSelection(
            selection: PDFSelection(),
            text: "completely different text elsewhere",
            rects: [HighlightRect(page: 0, x: 80, y: 300, width: 120, height: 16)],
            startPage: PDFPage(),
            startPoint: CGPoint(x: 80, y: 308),
            endPage: PDFPage(),
            endPoint: CGPoint(x: 200, y: 308)
        )
        XCTAssertFalse(view.checkIfPendingWithinTarget(pendingOutside, targetCardID: card.id))
    }
}
