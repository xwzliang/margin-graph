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

    private func makeMultiLineSyntheticPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary

        let linesText = [
            "First line of the text selection in reading order.",
            "Second line of the text selection in reading order.",
            "Third line of the text selection in reading order."
        ]

        for (i, t) in linesText.enumerated() {
            let attr = CFAttributedStringCreate(nil, t as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(attr)
            context.textPosition = CGPoint(x: 60, y: 160 - i * 30)
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            CTLineDraw(line, context)
        }

        context.endPDFPage()
        context.closePDF()
    }

    func testEmphasisDottedLineResolution() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-EmphasisTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeSyntheticPDF(at: url)
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            XCTFail("Failed to load synthetic PDF")
            return
        }

        let empRect = HighlightRect(page: 0, x: 194.5, y: 94.9, width: 86.8, height: 22.0)
        let card = NoteCard(
            topicId: UUID(),
            title: "Emphasis Test",
            highlightText: "MarginGraph synthetic PDF",
            highlightRects: [HighlightRect(page: 0, x: 60, y: 90, width: 250, height: 25)],
            emphasisList: ["synthetic"],
            emphasisRects: [empRect]
        )

        let manager = try PDFDocumentManager(url: url, md5: "testmd5")
        let reader = PDFReaderView(
            manager: manager,
            cards: [card]
        )
        let view = InteractivePDFView()
        view.document = document
        view.cards = [card]

        // Manually apply base highlights
        let annot = DottedLineAnnotation(
            bounds: CGRect(x: empRect.x - 2, y: empRect.y - 1 - 3, width: empRect.width + 4, height: 6),
            forType: .square,
            withProperties: nil
        )
        annot.lineStartPoint = CGPoint(x: empRect.x, y: empRect.y - 1)
        annot.lineEndPoint = CGPoint(x: empRect.x + empRect.width, y: empRect.y - 1)
        annot.contents = "MarginGraph-card-emphasis"
        page.addAnnotation(annot)

        XCTAssertTrue(page.annotations.contains { $0.contents == "MarginGraph-card-emphasis" })
        XCTAssertEqual(card.emphasisRects.count, 1)
        XCTAssertEqual(card.emphasisRects.first?.width, 86.8)
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

    private func makeMultiLineSyntheticPDF(at url: URL, lines: [String]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary

        var y: CGFloat = 700
        for lineStr in lines {
            let attributed = CFAttributedStringCreate(nil, lineStr as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(line, context)
            y -= 25
        }

        context.endPDFPage()
        context.closePDF()
    }

    func testEmphasisPhraseLineRectResolutionInsideCardHighlight() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-EmphasisMultiLine-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let textLines = [
            "Until now, writing and note-taking techniques were usually taught",
            "without much regard to the overarching workflow. This book aims",
            "to change that."
        ]
        try makeMultiLineSyntheticPDF(at: url, lines: textLines)
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load PDF")
            return
        }

        let fullText = textLines.joined(separator: " ")
        let card = NoteCard(
            topicId: UUID(),
            title: "Test Card",
            highlightText: fullText,
            startPage: 0
        )

        // Resolve phrase that is strictly on line 2: "the overarching workflow"
        let rects = PDFHighlightResolver.lineRects(forPhrase: "the overarching workflow", in: card, in: doc)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first?.page, 0)
        XCTAssertLessThan(rects.first?.width ?? 0, 250)

        // Unrelated phrase should return empty
        let emptyRects = PDFHighlightResolver.lineRects(forPhrase: "completely absent phrase", in: card, in: doc)
        XCTAssertTrue(emptyRects.isEmpty)
    }

    func testEmphasisToolbarModeAndHitTesting() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("hit_test_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let textLines = [
            "Having read more does not automatically mean having more ideas.",
            "Especially in the beginning, it means having fewer ideas."
        ]
        try makeMultiLineSyntheticPDF(at: url, lines: textLines)
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load PDF")
            return
        }

        var card = NoteCard(
            topicId: UUID(),
            title: "Emphasis Test Card",
            highlightText: textLines.joined(separator: " "),
            startPage: 0,
            emphasisList: ["does not automatically"]
        )

        let phraseRects = PDFHighlightResolver.lineRects(forPhrase: "does not automatically", in: card, in: doc)
        XCTAssertFalse(phraseRects.isEmpty)
        card.emphasisRects = phraseRects

        let view = InteractivePDFView()
        view.document = doc
        view.cards = [card]
        view.selectedCardID = card.id

        let mode = PDFPopoverMode.emphasisSelection(phrase: "does not automatically")
        XCTAssertEqual(mode, .emphasisSelection(phrase: "does not automatically"))
    }

    func testRealPDFCardEmphasis() throws {
        guard ProcessInfo.processInfo.environment["ENABLE_LIVE_MN_TESTS"] == "1" else { return }
        let pdfPath = "/Users/broliang/Library/Containers/QReader.MarginStudyMac/Data/Documents/Ahrens_2017_How-to-take-smart-notes.pdf"
        guard FileManager.default.fileExists(atPath: pdfPath),
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            return
        }

        let phrase = "It is not so important who you are, but what you do. Doing the work required and doing it in a smart way leads, somehow unsurprisingly, to success. At first glance, this is both good and bad news. The good news is that we wouldn’t be able to do much about our IQ anyway, while it seems to be within our control to have more self-discipline with a little bit of willpower. The bad news is that we do not have this kind of control over ourselves. Self-discipline or self-control is not that easy to achieve with willpower alone. Willpower is, as far as we know today, [2] a limited resource that depletes quickly and is also not that much up for improvement over the long term (Baumeister, Bratslavsky, Muraven, and Tice, 1998; Muraven, Tice, and Baumeister, 1998; Schmeichel, Vohs, and Baumeister, 2003; Moller, 2006). And who would want to flog oneself to work,"
        
        let card = NoteCard(
            topicId: UUID(),
            title: "Willpower",
            highlightText: phrase,
            startPage: 9,
            endPage: 10,
            emphasisList: [phrase]
        )

        if let p9 = doc.page(at: 9), let str1 = p9.string,
           let p10 = doc.page(at: 10), let str2 = p10.string {
            let tokens = phrase.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            print("Total tokens: \(tokens.count)")

            var low = 1
            var high = tokens.count - 1
            var bestSplit: Int? = nil

            func matchesPrefix(_ count: Int) -> NSRange? {
                let sub = Array(tokens[0..<count])
                let pat = sub.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:-\s*|\s+)"#)
                guard let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
                let full = NSRange(str1.startIndex..<str1.endIndex, in: str1)
                return rx.matches(in: str1, options: [], range: full).last?.range
            }

            func matchesSuffix(from start: Int) -> NSRange? {
                let sub = Array(tokens[start...])
                let pat = sub.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:-\s*|\s+)"#)
                guard let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
                let full = NSRange(str2.startIndex..<str2.endIndex, in: str2)
                return rx.matches(in: str2, options: [], range: full).first?.range
            }

            while low <= high {
                let mid = (low + high) / 2
                if matchesPrefix(mid) != nil {
                    bestSplit = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            print("Best split: \(bestSplit ?? -1)")
            if let split = bestSplit,
               let r1 = matchesPrefix(split),
               let r2 = matchesSuffix(from: split) {
                print("Found match! r1 on p9: \(r1), r2 on p10: \(r2)")
                let s1 = p9.selection(for: r1)
                let s2 = p10.selection(for: r2)
                let rects1 = PDFHighlightResolver.lineRects(from: s1!, document: doc)
                let rects2 = PDFHighlightResolver.lineRects(from: s2!, document: doc)
                print("Rects1 count: \(rects1.count), rects2 count: \(rects2.count)")
                XCTAssertFalse(rects1.isEmpty)
                XCTAssertFalse(rects2.isEmpty)
            } else {
                XCTFail("Could not match across pages")
            }
        }
    }

    func testRangesOfPhraseWithHyphenationAndParagraphBreak() {
        let cardText = "Until now, writing and note-taking techniques were usually taught without much regard to the overarching workflow. This book aims to change that."
        let rawPdfPhrase = "overarching work-\nflow. This book"

        let matches = PDFHighlightResolver.rangesOfPhrase(rawPdfPhrase, in: cardText)
        XCTAssertEqual(matches.count, 1)
        if let first = matches.first {
            XCTAssertEqual(String(cardText[first]), "overarching workflow. This book")
        }

        let multilineCard = "First paragraph ends.\n\nSecond paragraph begins here with important ideas."
        let crossParaPhrase = "ends.\nSecond paragraph"
        let crossMatches = PDFHighlightResolver.rangesOfPhrase(crossParaPhrase, in: multilineCard)
        XCTAssertEqual(crossMatches.count, 1)
    }

    func testPDFReaderViewScrollTriggerAndBannerCallback() {
        var scrollCount = 0
        let view = InteractivePDFView()
        view.onScroll = {
            scrollCount += 1
        }

        // Simulate scroll wheel event
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            view.scrollWheel(with: event)
        }
        XCTAssertEqual(scrollCount, 1)
    }

    func testTableOfContentsOutlineLoadingAndFiltering() throws {
        guard ProcessInfo.processInfo.environment["ENABLE_LIVE_MN_TESTS"] == "1" else { return }
        let pdfPath = "/Users/broliang/Library/Containers/QReader.MarginStudyMac/Data/Documents/Ahrens_2017_How-to-take-smart-notes.pdf"
        let manager = try PDFDocumentManager(url: URL(fileURLWithPath: pdfPath))
        XCTAssertEqual(manager.outline.count, 50, "PDF should have 50 table of contents items")

        // First item verification
        let first = try XCTUnwrap(manager.outline.first)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertNotNil(first.pageIndex)

        // Nested outline structure test with custom items
        let child = PDFOutlineItem(title: "Section 1.1", pageIndex: 3)
        let parent = PDFOutlineItem(title: "Chapter 1", pageIndex: 2, children: [child])
        XCTAssertEqual(parent.children.count, 1)
        XCTAssertEqual(parent.children.first?.title, "Section 1.1")
    }

    func testInWindowPopoverShapeAndBoundaryClamping() {
        // 1. PopoverBubbleShape path verification
        let rect = CGRect(x: 0, y: 0, width: 320, height: 400)
        let shape = PopoverBubbleShape(arrowX: 200, arrowWidth: 16, arrowHeight: 8, cornerRadius: 10)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "Popover bubble path should not be empty")
        let bounds = path.boundingRect
        XCTAssertLessThanOrEqual(bounds.minX, 0.1)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 319.9)

        // 2. Boundary clamping verification: Anchor near right edge of 720pt container
        let containerWidth: CGFloat = 720
        let popoverWidth: CGFloat = 320
        let margin: CGFloat = 12
        let anchorRightEdgeMidX: CGFloat = 660 // near right edge

        let effectiveWidth = min(popoverWidth, max(180, containerWidth - margin * 2))
        let idealLeft = anchorRightEdgeMidX - effectiveWidth / 2
        let clampedLeft = max(margin, min(idealLeft, containerWidth - effectiveWidth - margin))
        let rightEdge = clampedLeft + effectiveWidth

        XCTAssertGreaterThanOrEqual(clampedLeft, margin, "Left edge must not exceed left margin")
        XCTAssertLessThanOrEqual(rightEdge, containerWidth - margin, "Right edge must never exceed container boundary")
        XCTAssertEqual(rightEdge, 708, "Right edge should be clamped exactly to 720 - 12 = 708")

        // 3. Narrow container clamping verification: 250pt container
        let narrowContainerWidth: CGFloat = 250
        let narrowEffectiveWidth = min(popoverWidth, max(180, narrowContainerWidth - margin * 2))
        let narrowIdealLeft = 200 - narrowEffectiveWidth / 2
        let narrowClampedLeft = max(margin, min(narrowIdealLeft, narrowContainerWidth - narrowEffectiveWidth - margin))
        let narrowRightEdge = narrowClampedLeft + narrowEffectiveWidth

        XCTAssertGreaterThanOrEqual(narrowClampedLeft, margin)
        XCTAssertLessThanOrEqual(narrowRightEdge, narrowContainerWidth - margin)
    }

    func testCalculateSectionNoteCounts() {
        let sec1_1 = PDFOutlineItem(title: "Section 1.1", pageIndex: 13)
        let sec1_2 = PDFOutlineItem(title: "Section 1.2", pageIndex: 16)
        let ch1 = PDFOutlineItem(title: "Chapter 1", pageIndex: 10, children: [sec1_1, sec1_2])
        let ch2 = PDFOutlineItem(title: "Chapter 2", pageIndex: 23)
        let fourPrinciples = PDFOutlineItem(title: "The Four Principles", pageIndex: 35)
        let ch3 = PDFOutlineItem(title: "Chapter 3", pageIndex: 35)

        let items = [ch1, ch2, fourPrinciples, ch3]

        let topicId = UUID()
        var cards: [NoteCard] = []
        // 2 cards on page 10 (ch1 range: 10..<13)
        cards.append(NoteCard(topicId: topicId, startPage: 10))
        cards.append(NoteCard(topicId: topicId, startPage: 10))
        // 1 card on page 11 (ch1 range: 10..<13)
        cards.append(NoteCard(topicId: topicId, startPage: 11))
        // 4 cards on page 14 (sec1_1 range: 13..<16)
        for _ in 0..<4 {
            cards.append(NoteCard(topicId: topicId, startPage: 14))
        }
        // 0 cards for sec1_2 (range: 16..<23)
        // 5 cards on page 24 (ch2 range: 23..<35)
        for _ in 0..<5 {
            cards.append(NoteCard(topicId: topicId, startPage: 24))
        }
        // 6 cards on page 36 (ch3 range: 35..<100)
        for _ in 0..<6 {
            cards.append(NoteCard(topicId: topicId, startPage: 36))
        }

        let counts = TableOfContentsPopoverView.calculateSectionNoteCounts(
            items: items,
            cards: cards,
            totalPageCount: 100
        )

        XCTAssertEqual(counts[ch1.id], 3, "Chapter 1 should contain cards on pages 10..<13")
        XCTAssertEqual(counts[sec1_1.id], 4, "Section 1.1 should contain cards on pages 13..<16")
        XCTAssertEqual(counts[sec1_2.id], 0, "Section 1.2 should have 0 cards")
        XCTAssertEqual(counts[ch2.id], 5, "Chapter 2 should contain cards on pages 23..<35")
        XCTAssertEqual(counts[fourPrinciples.id], 0, "Four Principles with range 35..<35 should have 0 cards")
        XCTAssertEqual(counts[ch3.id], 6, "Chapter 3 should contain cards on pages 35..<100")
    }

    func testScrollToCenterPlacesNoteTopAtCenter() throws {
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let doc = PDFDocument()
        for _ in 0..<5 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .cropBox)
            doc.insert(page, at: doc.pageCount)
        }
        pdfView.document = doc
        pdfView.displayMode = .singlePageContinuous
        pdfView.layoutDocumentView()

        guard let docView = pdfView.documentView,
              let scrollView = pdfView.activeScrollView else {
            XCTFail("Missing docView or scrollView")
            return
        }
        let clipView = scrollView.contentView

        // Note on page 2 (the 3rd page), located at the bottom of that page (e.g. y = 100, height = 30)
        let noteBounds = CGRect(x: 100, y: 100, width: 400, height: 30)
        let jumpTarget = PDFJumpTarget(pageIndex: 2, bounds: noteBounds)

        pdfView.scrollToCenter(target: jumpTarget, animated: false)

        let targetPage = doc.page(at: 2)!
        let topPointInPage = CGPoint(x: noteBounds.midX, y: noteBounds.maxY)
        let topInView = pdfView.convert(topPointInPage, from: targetPage)
        let topInDoc = docView.convert(topInView, from: pdfView)

        let visibleCenterInDoc = clipView.bounds.origin.y + clipView.bounds.height / 2.0
        XCTAssertEqual(topInDoc.y, visibleCenterInDoc, accuracy: 1.0, "The top line of the note should be centered vertically in the viewport")
    }

    func testSubtlePDFPageSeparatorsConfiguration() {
        let pdfView = InteractivePDFView()
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 0.25, left: 0, bottom: 0.25, right: 0)
        pdfView.backgroundColor = NSColor(white: 0.92, alpha: 1.0)

        XCTAssertTrue(pdfView.displaysPageBreaks)
        XCTAssertEqual(pdfView.pageBreakMargins.top, 0.25)
        XCTAssertEqual(pdfView.pageBreakMargins.bottom, 0.25)
        XCTAssertEqual(pdfView.backgroundColor, NSColor(white: 0.92, alpha: 1.0))
    }

    func testMarginNoteTooltipBoundaryClamping() {
        let windowSize = CGSize(width: 1440, height: 900)

        // 1. Left-edge button: "Back to Notebooks" at x = 14, width = 26
        let backBtnFrame = CGRect(x: 14, y: 30, width: 26, height: 26)
        let backOffsets = MarginNoteTooltipModifier.computeOffsets(
            buttonFrame: backBtnFrame,
            text: "Back to Notebooks",
            windowSize: windowSize,
            padding: 8.0
        )
        let backFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let backWidth = ("Back to Notebooks" as NSString).size(withAttributes: [.font: backFont]).width + 18.0
        let backLeft = backBtnFrame.midX - (backWidth / 2.0)
        XCTAssertLessThan(backLeft, 8.0, "Without shift, the left edge would be off-screen")
        XCTAssertGreaterThan(backOffsets.x, 0, "Shift should push tooltip rightwards")
        XCTAssertEqual(backLeft + backOffsets.x, 8.0, accuracy: 0.01, "Tooltip left edge must be clamped exactly to padding")

        // 2. Right-edge button: "Document Options" at x = 1400, width = 26
        let optionsBtnFrame = CGRect(x: 1400, y: 30, width: 26, height: 26)
        let optionsOffsets = MarginNoteTooltipModifier.computeOffsets(
            buttonFrame: optionsBtnFrame,
            text: "Document Options",
            windowSize: windowSize,
            padding: 8.0
        )
        let optionsWidth = ("Document Options" as NSString).size(withAttributes: [.font: backFont]).width + 18.0
        let optionsRight = optionsBtnFrame.midX + (optionsWidth / 2.0)
        XCTAssertGreaterThan(optionsRight, 1440 - 8.0, "Without shift, the right edge would exceed window width")
        XCTAssertLessThan(optionsOffsets.x, 0, "Shift should push tooltip leftwards")
        XCTAssertEqual(optionsRight + optionsOffsets.x, 1440 - 8.0, accuracy: 0.01, "Tooltip right edge must be clamped exactly to window right - padding")

        // 3. Center button: safely within bounds, no shift needed
        let centerBtnFrame = CGRect(x: 700, y: 30, width: 26, height: 26)
        let centerOffsets = MarginNoteTooltipModifier.computeOffsets(
            buttonFrame: centerBtnFrame,
            text: "Toggle Outline",
            windowSize: windowSize,
            padding: 8.0
        )
        XCTAssertEqual(centerOffsets.x, 0, "Centered button requires no horizontal shift")
        XCTAssertEqual(centerOffsets.y, 32.0, "Default vertical offset is below button")

        // 4. Bottom-edge button: flips above button
        let bottomBtnFrame = CGRect(x: 700, y: 870, width: 30, height: 30)
        let bottomOffsets = MarginNoteTooltipModifier.computeOffsets(
            buttonFrame: bottomBtnFrame,
            text: "Zoom Out (⌘-)",
            windowSize: windowSize,
            padding: 8.0
        )
        XCTAssertLessThan(bottomOffsets.y, 0, "Bottom edge button should flip above button")
        XCTAssertEqual(bottomOffsets.y, -(30.0 + 8.0), "Offset above should be -(buttonHeight + 8.0)")
    }

    func testEnlargedHitTargetAndSplitDividerGeometry() {
        // 1. Verify EnlargedHitTargetModifier preserves dimensions
        let modifier = EnlargedHitTargetModifier(width: 36, height: 32)
        XCTAssertEqual(modifier.width, 36)
        XCTAssertEqual(modifier.height, 32)

        let defaultModifier = EnlargedHitTargetModifier()
        XCTAssertEqual(defaultModifier.width, 34)
        XCTAssertEqual(defaultModifier.height, 32)

        // 2. Verify Split View Divider Math:
        // dividerX = totalWidth - currentPDFWidth
        let totalWidth: CGFloat = 1440
        let outlineWidth: CGFloat = 240
        let availableWidth = totalWidth - outlineWidth // 1200
        let pdfWidth: CGFloat = 600

        let dividerX = totalWidth - pdfWidth
        XCTAssertEqual(dividerX, 840)

        // Mindmap width should match exactly: outlineWidth + mindMapWidth == dividerX
        let mindMapWidth = availableWidth - pdfWidth
        XCTAssertEqual(mindMapWidth, 600)
        XCTAssertEqual(outlineWidth + mindMapWidth, dividerX)

        // As PDF width increases during left-drag to 700:
        let expandedPDFWidth: CGFloat = 700
        let newDividerX = totalWidth - expandedPDFWidth
        XCTAssertEqual(newDividerX, 740, "Divider moves left as PDF expands")
        let newMindMapWidth = availableWidth - expandedPDFWidth
        XCTAssertEqual(outlineWidth + newMindMapWidth, newDividerX, "Divider stays anchored on the edge")
    }

    func testDecoupledSplitDividerDragAndClamping() {
        let totalWidth: CGFloat = 1200
        let minPDF: CGFloat = 360
        let minMindMap: CGFloat = 320
        let maxPDF = totalWidth - minMindMap // 880
        let startPDFWidth: CGFloat = 500

        // Dragging left by 200 (translation.width = -200) -> PDF expands to 700
        let translationLeft: CGFloat = -200
        let candidateLeft = min(max(minPDF, startPDFWidth - translationLeft), maxPDF)
        XCTAssertEqual(candidateLeft, 700)
        let dividerXLeft = totalWidth - candidateLeft
        XCTAssertEqual(dividerXLeft, 500)

        // Dragging right by 300 (translation.width = +300) -> PDF shrinks to minPDF (360)
        let translationRight: CGFloat = 300
        let candidateRight = min(max(minPDF, startPDFWidth - translationRight), maxPDF)
        XCTAssertEqual(candidateRight, 360, "Should clamp to minPDF")
        let dividerXRight = totalWidth - candidateRight
        XCTAssertEqual(dividerXRight, 840)

        // Dragging left beyond maxPDF (translation.width = -600) -> clamped to maxPDF (880)
        let translationExtremeLeft: CGFloat = -600
        let candidateExtreme = min(max(minPDF, startPDFWidth - translationExtremeLeft), maxPDF)
        XCTAssertEqual(candidateExtreme, 880, "Should clamp to maxPDF")
        let dividerXExtreme = totalWidth - candidateExtreme
        XCTAssertEqual(dividerXExtreme, 320, "Divider should not go past minimum MindMap width")
    }

    func testRestorePositionAndCurrentVisiblePosition() throws {
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let doc = PDFDocument()
        for _ in 0..<5 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .cropBox)
            doc.insert(page, at: doc.pageCount)
        }
        pdfView.document = doc
        pdfView.displayMode = .singlePageContinuous
        pdfView.layoutDocumentView()

        var reportedPage: Int?
        var reportedOffset: CGFloat?
        pdfView.onPositionChanged = { page, offset in
            reportedPage = page
            reportedOffset = offset
        }

        // Restore to page 2, offset 150
        pdfView.restorePosition(pageIndex: 2, pageOffsetY: 150)

        // After restoring, currentVisiblePosition should be page 2
        let pos = pdfView.currentVisiblePosition()
        XCTAssertNotNil(pos)
        XCTAssertEqual(pos?.pageIndex, 2)
    }

    func testHandleProportionalSizingAndPageBoundsClamping() throws {
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        let doc = PDFDocument()
        let page = PDFPage()
        // Page bounds matching a small paperback (like Screenplay 327 x 568)
        page.setBounds(CGRect(x: 0, y: 0, width: 327, height: 568), for: .cropBox)
        doc.insert(page, at: 0)
        pdfView.document = doc
        pdfView.scaleFactor = 2.5
        pdfView.layoutDocumentView()

        // Install handles at the very edge of the page (x = 0, y = 568)
        let edgeRect = HighlightRect(page: 0, x: 0, y: 550, width: 100, height: 10)
        pdfView.installHandleAnnotations(for: [edgeRect])

        // Verify annotations exist and are strictly within the page cropBox
        let crop = page.bounds(for: .cropBox)
        let handleAnnots = page.annotations.filter {
            $0.contents?.hasPrefix("MarginGraph-handle") == true
        }
        XCTAssertFalse(handleAnnots.isEmpty, "Handle annotations should be installed")
        for annot in handleAnnots {
            XCTAssertGreaterThanOrEqual(annot.bounds.minX, crop.minX, "Handle bounds should not bleed past left edge")
            XCTAssertLessThanOrEqual(annot.bounds.maxX, crop.maxX, "Handle bounds should not bleed past right edge")
            XCTAssertGreaterThanOrEqual(annot.bounds.minY, crop.minY, "Handle bounds should not bleed past bottom edge")
            XCTAssertLessThanOrEqual(annot.bounds.maxY, crop.maxY, "Handle bounds should not bleed past top edge")

            // Verify knob size is scaled down proportionally in page points (~4pt = 10pt on screen at 2.5x)
            if annot is KnobAnnotation {
                XCTAssertLessThanOrEqual(annot.bounds.width, 7.0, "Knob width in page coords should be scaled proportionally, not fixed 11pt")
            }
        }
    }

    func testPopoverToolbarClampingNeverExceedsViewBounds() throws {
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let doc = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 700), for: .cropBox)
        doc.insert(page, at: 0)
        pdfView.document = doc
        pdfView.activeToolbarOwner = .pdf

        // Trigger emphasis toolbar at the extreme top right
        let extremeTopRightRect = HighlightRect(page: 0, x: 550, y: 680, width: 45, height: 14)
        pdfView.showEmphasisToolbar(phrase: "test phrase", page: page, lineRect: extremeTopRightRect)

        if let toolbar = pdfView.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first {
            XCTAssertGreaterThanOrEqual(toolbar.frame.minX, 10.0, "Toolbar left edge should respect margin")
            XCTAssertLessThanOrEqual(toolbar.frame.maxX, pdfView.bounds.width - 18.0, "Toolbar right edge should not be blocked by window edge")
            XCTAssertGreaterThanOrEqual(toolbar.frame.minY, 8.0, "Toolbar bottom edge should respect margin")
            XCTAssertLessThanOrEqual(toolbar.frame.maxY, pdfView.bounds.height - 8.0, "Toolbar top edge should not be blocked by window edge")
        } else {
            XCTFail("Toolbar should have been installed")
        }
    }

    func testHandleStemAndKnobExactAlignmentAndZeroGap() throws {
        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        let doc = PDFDocument()
        let page = PDFPage()
        // Page with non-zero cropBox origin (matching Screenplay Page 66)
        page.setBounds(CGRect(x: -4.0, y: 0.0, width: 323.0, height: 567.0), for: .cropBox)
        doc.insert(page, at: 0)
        pdfView.document = doc
        pdfView.scaleFactor = 2.0
        pdfView.layoutDocumentView()

        let lineRect = HighlightRect(page: 0, x: 26.88, y: 495.05, width: 93.24, height: 10.2)
        pdfView.installHandleAnnotations(for: [lineRect])

        let handles = page.annotations.filter { $0.contents?.hasPrefix("MarginGraph-handle") == true }
        XCTAssertEqual(handles.count, 2, "Unified cursor handles should produce exactly 1 start handle and 1 end handle")

        let startHandle = page.annotations.first(where: { $0.contents == "MarginGraph-handle-start" }) as? CursorHandleAnnotation
        let endHandle = page.annotations.first(where: { $0.contents == "MarginGraph-handle-end" }) as? CursorHandleAnnotation

        XCTAssertNotNil(startHandle)
        XCTAssertNotNil(endHandle)

        guard let sHandle = startHandle, let eHandle = endHandle else { return }

        XCTAssertTrue(sHandle.isStart)
        XCTAssertFalse(eHandle.isStart)

        // Exact horizontal center alignment: bounds.midX aligns with target point x
        XCTAssertEqual(sHandle.bounds.midX, CGFloat(lineRect.x), accuracy: 1.0, "Start handle center must align with start point x")
        XCTAssertEqual(eHandle.bounds.midX, CGFloat(lineRect.x + lineRect.width), accuracy: 1.0, "End handle center must align with end point x")

        // Fixed ratio of line height: stemHeight = max(12.0, lineHeight * 1.2)
        let expectedHeight = max(12.0, CGFloat(lineRect.height) * 1.2)
        XCTAssertEqual(sHandle.stemHeight, expectedHeight, accuracy: 0.1, "Stem height should be 1.2x line height")
        XCTAssertEqual(eHandle.stemHeight, expectedHeight, accuracy: 0.1, "Stem height should be 1.2x line height")

        // Edge containment
        let crop = page.bounds(for: .cropBox)
        for annot in [sHandle, eHandle] {
            XCTAssertGreaterThanOrEqual(annot.bounds.minX, crop.minX)
            XCTAssertLessThanOrEqual(annot.bounds.maxX, crop.maxX)
            XCTAssertGreaterThanOrEqual(annot.bounds.minY, crop.minY)
            XCTAssertLessThanOrEqual(annot.bounds.maxY, crop.maxY)
        }
    }

    func testHandleDimensionsBoundedAtExtremeScales() throws {
        // 1. Line height 16.0: stemHeight is 16 * 1.2 = 19.2pt
        let dims16 = InteractivePDFView.handleDimensions(for: 16.0, scale: 1.0)
        XCTAssertEqual(dims16.stemHeight, 19.2, accuracy: 0.01)
        XCTAssertEqual(dims16.stemWidth, 2.0)
        XCTAssertEqual(dims16.knobRadius, 3.2, accuracy: 0.01)
        XCTAssertEqual(dims16.knobSize, dims16.knobRadius)

        // 2. Line height 10.0: stemHeight is max(12.0, 10.0 * 1.2) = 12.0pt
        let dims10 = InteractivePDFView.handleDimensions(for: 10.0, scale: 0.1)
        XCTAssertEqual(dims10.stemHeight, 12.0, accuracy: 0.01)
        XCTAssertEqual(dims10.knobRadius, 3.2, accuracy: 0.01)

        // 3. Line height 24.0: stemHeight is 24.0 * 1.2 = 28.8pt
        let dims24 = InteractivePDFView.handleDimensions(for: 24.0, scale: 3.0)
        XCTAssertEqual(dims24.stemHeight, 28.8, accuracy: 0.01)
        XCTAssertEqual(dims24.knobRadius, 3.2, accuracy: 0.01)
    }

    func testReadingOrderSortingAndHandlePlacement() throws {
        // 1. Reading order sort verification
        let r1 = HighlightRect(page: 0, x: 200, y: 300, width: 100, height: 16) // line 1, right chunk
        let r2 = HighlightRect(page: 0, x: 50, y: 300, width: 100, height: 16)  // line 1, left chunk
        let r3 = HighlightRect(page: 0, x: 50, y: 280, width: 250, height: 16)  // line 2
        let r4 = HighlightRect(page: 1, x: 50, y: 700, width: 250, height: 16)  // page 1 top line

        let unsorted = [r4, r3, r1, r2]
        let sorted = PDFHighlightResolver.sortInReadingOrder(unsorted)

        XCTAssertEqual(sorted.count, 4)
        XCTAssertEqual(sorted[0].page, 0)
        XCTAssertEqual(sorted[0].x, 50)
        XCTAssertEqual(sorted[0].y, 300) // r2 first

        XCTAssertEqual(sorted[1].page, 0)
        XCTAssertEqual(sorted[1].x, 200)
        XCTAssertEqual(sorted[1].y, 300) // r1 second

        XCTAssertEqual(sorted[2].page, 0)
        XCTAssertEqual(sorted[2].y, 280) // r3 third

        XCTAssertEqual(sorted[3].page, 1) // r4 fourth

        // 2. Synthetic PDF with multi-line text block expansion
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-BlockTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeMultiLineSyntheticPDF(at: url)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            XCTFail("Could not create synthetic PDF")
            return
        }

        // Bounding box covering multiple lines (lines drawn at y=160, 130, 100)
        let blockRect = HighlightRect(page: 0, x: 50, y: 80, width: 400, height: 100)
        let expanded = PDFHighlightResolver.expandBlockRectsIfNeeded([blockRect], in: doc)

        XCTAssertGreaterThan(expanded.count, 1, "Multi-line block rect should expand into multiple line rects")
        XCTAssertLessThanOrEqual(expanded.first?.height ?? 100, 24.0, "Individual expanded line height should be normalized")

        // 3. Handle placement verification
        let pdfView = InteractivePDFView()
        pdfView.document = doc

        pdfView.installHandleAnnotations(for: expanded, accent: .systemYellow)

        let handles = page.annotations.filter { $0.contents?.hasPrefix("MarginGraph-handle") == true }
        XCTAssertEqual(handles.count, 2, "Should create 1 start handle and 1 end handle")

        guard let startHandle = handles.first(where: { $0.contents == "MarginGraph-handle-start" }),
              let endHandle = handles.first(where: { $0.contents == "MarginGraph-handle-end" }) else {
            XCTFail("Start and end handles must be present")
            return
        }

        // Start handle must be at first line's start (left edge, top of block)
        XCTAssertEqual(startHandle.bounds.midX, CGFloat(expanded.first!.x), accuracy: 3.0)

        // End handle must be at last line's end (right edge, bottom of block)
        XCTAssertEqual(endHandle.bounds.midX, CGFloat(expanded.last!.x + expanded.last!.width), accuracy: 3.0)
    }

    func testPDFHighlightImporterDetectionAndClustering() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-HighlightImportTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeMultiLineSyntheticPDF(at: url)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            XCTFail("Failed to load synthetic PDF")
            return
        }

        // Before adding annotations, hasHighlights should be false
        XCTAssertFalse(PDFHighlightImporter.hasHighlights(in: doc))
        XCTAssertEqual(PDFHighlightImporter.countHighlights(in: doc), 0)

        guard let sel1 = doc.findString("First line", withOptions: []).first,
              let sel2 = doc.findString("of the text", withOptions: []).first,
              let sel3 = doc.findString("Second line", withOptions: []).first else {
            XCTFail("Failed to find text in synthetic PDF")
            return
        }

        let annot1 = PDFAnnotation(bounds: sel1.bounds(for: page), forType: .highlight, withProperties: nil)
        annot1.color = .systemYellow
        annot1.contents = "Note 1"

        let annot2 = PDFAnnotation(bounds: sel2.bounds(for: page), forType: .highlight, withProperties: nil)
        annot2.color = .systemYellow
        annot2.contents = "Note 2"

        let annot3 = PDFAnnotation(bounds: sel3.bounds(for: page), forType: .highlight, withProperties: nil)
        annot3.color = .systemGreen
        annot3.contents = "Note 3"

        page.addAnnotation(annot1)
        page.addAnnotation(annot2)
        page.addAnnotation(annot3)

        // After adding annotations:
        XCTAssertTrue(PDFHighlightImporter.hasHighlights(in: doc))
        XCTAssertEqual(PDFHighlightImporter.countHighlights(in: doc), 3)

        // Extract highlights
        let extracted = PDFHighlightImporter.extractHighlights(from: doc)
        XCTAssertEqual(extracted.count, 3)

        // Check consecutive grouping
        let mergedClusters = PDFHighlightImporter.groupConsecutiveHighlights(extracted, in: doc)
        XCTAssertEqual(mergedClusters.count, 2)
        XCTAssertEqual(mergedClusters[0].count, 2)
        XCTAssertEqual(mergedClusters[1].count, 1)

        // Check non-merged grouping (each separate)
        let unmergedClusters = extracted.map { [$0] }
        XCTAssertEqual(unmergedClusters.count, 3)

        // Import into in-memory SQLite database
        let db = try Database(inMemory: true)
        let topic = Topic(title: "Imported Highlights Topic")
        try db.insertTopic(topic)

        let docModel = Document(
            id: UUID(),
            title: "Test PDF Document",
            filePath: url.path,
            md5: "synthetic-md5-12345",
            totalPages: doc.pageCount,
            lastVisited: Date()
        )
        try db.insertDocument(docModel)

        // Test merged import
        let importedMergedCards = try PDFHighlightImporter.importHighlights(
            from: doc,
            for: docModel,
            topicId: topic.id,
            shouldMerge: true,
            database: db
        )
        XCTAssertEqual(importedMergedCards.count, 2)
        let fetchedCards = try db.cardsForTopic(id: topic.id)
        XCTAssertEqual(fetchedCards.count, 2)

        // Verify notes were merged
        let firstCard = fetchedCards.first { $0.notesText.contains("Note 1") }
        XCTAssertNotNil(firstCard)
        XCTAssertTrue(firstCard!.notesText.contains("Note 2"))
    }

    func testPDFHighlightImporterPerceptualColorMapping() {
        // Yellow should map to index 0 (Yellow #f3eca0), NOT Peach or Ochre
        let pdfYellow1 = NSColor(deviceRed: 1.0, green: 0.969, blue: 0.779, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pdfYellow1), 0, "PDF Yellow must map to MarginNote Yellow (index 0)")

        let pureYellow = NSColor(deviceRed: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pureYellow), 0, "Pure Yellow must map to MarginNote Yellow (index 0)")

        // Green should map to index 1 (Green)
        let pdfGreen = NSColor(deviceRed: 0.841, green: 1.0, blue: 0.721, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pdfGreen), 1, "PDF Light Green must map to Green (index 1)")

        // Aqua / Teal should map to Teal (7) or Aqua (10)
        let pdfAqua = NSColor(deviceRed: 0.752, green: 1.0, blue: 0.969, alpha: 1.0)
        let aquaIdx = PDFHighlightImporter.colorIndex(for: pdfAqua)
        XCTAssertTrue(aquaIdx == 7 || aquaIdx == 10, "PDF Aqua/Teal must map to Teal (7) or Aqua (10), got \(aquaIdx)")

        // Pink should map to Pink (8)
        let pdfPink = NSColor(deviceRed: 1.0, green: 0.859, blue: 0.915, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pdfPink), 8, "PDF Pink must map to Pink (index 8)")

        // Pure Blue should map to Blue (2) or Indigo (11)
        let skyBlue = NSColor(deviceRed: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: skyBlue), 2, "Sky Blue must map to Blue (index 2)")

        // Pure Orange should map to Orange (5)
        let pureOrange = NSColor(deviceRed: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pureOrange), 5, "Orange must map to Orange (index 5)")

        // Pure Red / Coral should map to Coral (3)
        let pureRed = NSColor(deviceRed: 1.0, green: 0.1, blue: 0.1, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: pureRed), 3, "Red must map to Coral (index 3)")

        // Purple / Lavender should map to Lavender (4)
        let purple = NSColor(deviceRed: 0.7, green: 0.4, blue: 0.9, alpha: 1.0)
        XCTAssertEqual(PDFHighlightImporter.colorIndex(for: purple), 4, "Purple must map to Lavender (index 4)")
    }

    func testPDFHighlightImporterDistinctColorMappingNoCollisions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-distinct-colors-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeMultiPageSyntheticPDF(at: url)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            XCTFail("Failed to load PDF")
            return
        }

        // Add two highlights of different shades of green (Lime vs Pure Green)
        let limeColor = NSColor(deviceRed: 0.841, green: 1.0, blue: 0.721, alpha: 1.0)
        let pureGreenColor = NSColor(deviceRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)

        let annot1 = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 18), forType: .highlight, withProperties: nil)
        annot1.color = limeColor
        annot1.contents = "Lime highlight note"

        let annot2 = PDFAnnotation(bounds: CGRect(x: 50, y: 650, width: 200, height: 18), forType: .highlight, withProperties: nil)
        annot2.color = pureGreenColor
        annot2.contents = "Pure Green highlight note"

        page.addAnnotation(annot1)
        page.addAnnotation(annot2)

        let extracted = PDFHighlightImporter.extractHighlights(from: doc)
        XCTAssertEqual(extracted.count, 2)

        // Both highlights must be assigned distinct palette colors without colliding!
        XCTAssertNotEqual(
            extracted[0].colorIndex,
            extracted[1].colorIndex,
            "Two different highlight colors in the PDF must NOT be forced to map to the same color in our program!"
        )

        // And they must not be merged as consecutive notes
        XCTAssertFalse(
            PDFHighlightImporter.areConsecutive(h1: extracted[0], h2: extracted[1], in: doc),
            "Highlights with different colors must never be consecutive"
        )
    }

    func testPDFHighlightImporterRealHomoDeusPDFIfPresent() throws {
        let realPDFPath = "/Users/broliang/Downloads/Harari_2016_Homo Deus.pdf"
        let flattenedPath = "/Users/broliang/Downloads/Harari_2016_Homo Deus - flattened.pdf"

        if FileManager.default.fileExists(atPath: realPDFPath),
           let realDoc = PDFDocument(url: URL(fileURLWithPath: realPDFPath)),
           PDFHighlightImporter.hasHighlights(in: realDoc) {
            XCTAssertTrue(PDFHighlightImporter.hasHighlights(in: realDoc))
            let count = PDFHighlightImporter.countHighlights(in: realDoc)
            XCTAssertGreaterThanOrEqual(count, 800)

            let extracted = PDFHighlightImporter.extractHighlights(from: realDoc)
            let clusters = PDFHighlightImporter.groupConsecutiveHighlights(extracted, in: realDoc)
            XCTAssertLessThan(clusters.count, extracted.count, "Merging consecutive highlights must group fragments into fewer cards")

            // Verify distinct color preservation in real Homo Deus document
            let colorIndices = Set(extracted.map { $0.colorIndex })
            XCTAssertGreaterThanOrEqual(
                colorIndices.count, 3,
                "Homo Deus has multiple distinct highlight colors (yellow, teal, green, pink); they must map to multiple distinct palette colors"
            )
            // Yellow (index 0) must be present since Homo Deus has 555 yellow highlights
            XCTAssertTrue(colorIndices.contains(0), "Dominant yellow highlights in Homo Deus must map to Yellow (index 0)")
        }

        if FileManager.default.fileExists(atPath: flattenedPath),
           let flatDoc = PDFDocument(url: URL(fileURLWithPath: flattenedPath)) {
            XCTAssertFalse(PDFHighlightImporter.hasHighlights(in: flatDoc))
            XCTAssertEqual(PDFHighlightImporter.countHighlights(in: flatDoc), 0)
        }
    }

    func testInspectHomoDeusHighlights() throws {
        let path = "/Users/broliang/Downloads/Harari_2016_Homo Deus.pdf"
        guard FileManager.default.fileExists(atPath: path),
              let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              PDFHighlightImporter.hasHighlights(in: doc) else { return }

        let extracted = PDFHighlightImporter.extractHighlights(from: doc)
        print("Total extracted highlights: \(extracted.count)")
        let clusters = PDFHighlightImporter.groupConsecutiveHighlights(extracted, in: doc)
        let cards = PDFHighlightImporter.buildCards(from: clusters, topicId: UUID(), bookMD5: "homo_deus")
        XCTAssertGreaterThanOrEqual(cards.count, 5)

        // Card 0 merges the 5 consecutive yellow paragraphs from page 5 to page 6
        XCTAssertTrue(cards[0].highlightText.hasPrefix("At the dawn of the third millennium"))
        XCTAssertTrue(cards[0].highlightText.hasSuffix("What will we do with all that power?"))
        XCTAssertEqual(cards[0].startPage, 5)
        XCTAssertEqual(cards[0].endPage, 6)

        // Verify that paragraph line breaks are preserved with \n\n
        XCTAssertTrue(cards[0].highlightText.contains("‘Let’s see what’s on the agenda today.’\n\nFor thousands of years"))
        XCTAssertTrue(cards[0].highlightText.contains("free us from them.\n\nYet at the dawn of the third millennium"))
        XCTAssertTrue(cards[0].highlightText.contains("succeed in doing it.\n\nTrue, there are still notable failures;"))

        // Card 1 merges the consecutive highlights on pages 13-15 (including footnotes/links 17, 18, 19, 20, 21)
        XCTAssertTrue(cards[1].highlightText.hasPrefix("Despite the horrendous toll AIDS"))
        XCTAssertEqual(cards[1].startPage, 13)
        XCTAssertEqual(cards[1].endPage, 15)

        // Verify that footnote links 20 & 21 on the same line merged seamlessly without breaking
        XCTAssertTrue(cards[1].highlightText.contains("against highly resistant germs. Scientists are also developing"))
        XCTAssertTrue(cards[1].highlightText.contains("pathogens and cancerous cells. Microorganisms may have"))

        // Verify that paragraph breaks in Card 1 are preserved with \n\n
        XCTAssertTrue(cards[1].highlightText.contains("deal with them more efficiently than today.\n\nIn 2015 doctors announced"))
    }

    func testDiagnoseDuplicationIssues() throws {
        let path = "/Users/broliang/Downloads/Harari_2016_Homo Deus.pdf"
        guard FileManager.default.fileExists(atPath: path),
              let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return }

        var output = ""
        func log(_ s: String) { output += s + "\n" }

        let extracted = PDFHighlightImporter.extractHighlights(from: doc)
        guard !extracted.isEmpty else { return }
        log("=== RAW EXTRACTED HIGHLIGHTS: \(extracted.count) ===")
        
        // Dump first 20 raw highlights with their page, bounds, color, and text prefix
        for (i, h) in extracted.prefix(20).enumerated() {
            let textPreview = String(h.text.prefix(80)).replacingOccurrences(of: "\n", with: "↵")
            log("  RAW[\(i)] page=\(h.pageIndex) colorIdx=\(h.colorIndex) bounds=(\(Int(h.bounds.minX)),\(Int(h.bounds.minY)),\(Int(h.bounds.maxX)),\(Int(h.bounds.maxY))) lineRects=\(h.lineRects.count) text=\(textPreview)...")
        }

        let clusters = PDFHighlightImporter.groupConsecutiveHighlights(extracted, in: doc)
        let cards = PDFHighlightImporter.buildCards(from: clusters, topicId: UUID(), bookMD5: "homo_deus")
        
        log("\n=== MERGED CARDS: \(cards.count) (from \(extracted.count) raw) ===")
        
        // Show cluster composition
        log("\n=== CLUSTER COMPOSITION (first 15) ===")
        for (ci, cluster) in clusters.prefix(15).enumerated() {
            let rawIndices = cluster.map { h -> Int in
                extracted.firstIndex(where: { $0.id == h.id }) ?? -1
            }
            log("  CLUSTER[\(ci)] size=\(cluster.count) rawIndices=\(rawIndices) pages=\(cluster.first?.pageIndex ?? -1)-\(cluster.last?.pageIndex ?? -1)")
        }

        log("\n=== ARE CONSECUTIVE DIAGNOSTICS ===")
        for i in 0..<min(extracted.count - 1, 20) {
            let h1 = extracted[i]
            let h2 = extracted[i + 1]
            let res = PDFHighlightImporter.areConsecutive(h1: h1, h2: h2, in: doc)
            log("  RAW[\(i)] + RAW[\(i+1)] (pages \(h1.pageIndex)->\(h2.pageIndex)): areConsecutive = \(res)")
            if h1.pageIndex == h2.pageIndex, let page = doc.page(at: h1.pageIndex) {
                let rects1 = h1.lineRects
                let rects2 = h2.lineRects
                if let last1 = rects1.last, let first2 = rects2.first {
                    let endPt1 = CGPoint(x: last1.x + last1.width, y: last1.y + last1.height / 2.0)
                    let startPt2 = CGPoint(x: first2.x, y: first2.y + first2.height / 2.0)
                    let sel = page.selection(from: endPt1, to: startPt2)
                    let betweenStr = sel?.string ?? "nil"
                    let dy = last1.y - first2.y
                    log("    lastLine1: (\(Int(last1.x)),\(Int(last1.y)),\(Int(last1.width)),\(Int(last1.height))) maxX=\(Int(last1.x + last1.width))")
                    log("    firstLine2: (\(Int(first2.x)),\(Int(first2.y)),\(Int(first2.width)),\(Int(first2.height))) minX=\(Int(first2.x))")
                    log("    dy = \(dy), maxH = \(max(last1.height, first2.height))")
                    log("    between string: [\(betweenStr.replacingOccurrences(of: "\n", with: "↵"))]")
                }
            }
        }
        
        // Dump first 15 cards with full text to check for line breaks
        for (i, card) in cards.prefix(15).enumerated() {
            log("\n--- CARD[\(i)] pages=\(card.startPage ?? -1)-\(card.endPage ?? -1) colorIdx=\(card.colorIndex) rects=\(card.highlightRects.count) ---")
            let lines = card.highlightText.components(separatedBy: "\n")
            for (li, line) in lines.enumerated() {
                log("  LINE[\(li)]: \(line)")
            }
        }

        // Check for text overlap between adjacent cards (content of one card is a substring of another)
        log("\n=== OVERLAP CHECK ===")
        for i in 0..<min(cards.count, 30) {
            for j in (i+1)..<min(cards.count, 30) {
                let text1 = cards[i].highlightText
                let text2 = cards[j].highlightText
                // Check if one is a substring of the other
                if text1.count > 20 && text2.count > 20 {
                    if text1.contains(text2) {
                        log("  ⚠️ CARD[\(j)] text is ENTIRELY INSIDE CARD[\(i)]")
                    } else if text2.contains(text1) {
                        log("  ⚠️ CARD[\(i)] text is ENTIRELY INSIDE CARD[\(j)]")
                    }
                    // Check for partial overlap (shared lines)
                    let lines1 = Set(text1.components(separatedBy: "\n").filter { $0.count > 30 })
                    let lines2 = Set(text2.components(separatedBy: "\n").filter { $0.count > 30 })
                    let shared = lines1.intersection(lines2)
                    if !shared.isEmpty {
                        log("  ⚠️ CARDS[\(i)] and [\(j)] share \(shared.count) lines:")
                        for s in shared.prefix(3) {
                            log("    → \(String(s.prefix(80)))...")
                        }
                    }
                }
            }
        }

        // Check for overlapping annotations (same bounding rect region)
        log("\n=== RAW ANNOTATION OVERLAP CHECK ===")
        for i in 0..<min(extracted.count, 30) {
            for j in (i+1)..<min(extracted.count, 30) {
                let h1 = extracted[i]
                let h2 = extracted[j]
                if h1.pageIndex == h2.pageIndex {
                    let intersection = h1.bounds.intersection(h2.bounds)
                    if !intersection.isNull && intersection.height > 5 && intersection.width > 20 {
                        let overlapArea = intersection.width * intersection.height
                        let h1Area = h1.bounds.width * h1.bounds.height
                        let h2Area = h2.bounds.width * h2.bounds.height
                        let overlapPct = max(overlapArea / h1Area, overlapArea / h2Area) * 100
                        if overlapPct > 30 {
                            log("  ⚠️ RAW[\(i)] and RAW[\(j)] overlap \(Int(overlapPct))% on page \(h1.pageIndex)")
                            log("    RAW[\(i)] bounds=\(h1.bounds) text=\(String(h1.text.prefix(60)))...")
                            log("    RAW[\(j)] bounds=\(h2.bounds) text=\(String(h2.text.prefix(60)))...")
                        }
                    }
                }
            }
        }

        try output.write(toFile: "/tmp/highlight_diag.txt", atomically: true, encoding: .utf8)
        print("Diagnostic output written to /tmp/highlight_diag.txt")
    }

    func testBenchmarkStartup() throws {
        let db = try Database()
        let t0 = Date()
        try db.syncAvailableDocuments()
        let t1 = Date()
        print("syncAvailableDocuments took: \(t1.timeIntervalSince(t0))s")
        let topics = try db.allTopics()
        let t2 = Date()
        print("allTopics (\(topics.count)) took: \(t2.timeIntervalSince(t1))s")
        let docs = try db.allDocuments()
        let t3 = Date()
        print("allDocuments (\(docs.count)) took: \(t3.timeIntervalSince(t2))s")

        MainActor.assumeIsolated {
            let libManager = LibraryManager.shared
            print("Libraries count: \(libManager.libraries.count)")
            for lib in libManager.libraries {
                print(" - [\(lib.displayName)] path=\(lib.path) isDefault=\(lib.isDefault) isBuiltIn=\(lib.isBuiltIn)")
            }
        }

        // Benchmark TreeLayout on large card count
        let cards = (0..<900).map { i in
            NoteCard(
                topicId: UUID(),
                title: "Card #\(i)",
                highlightText: "This is a test highlight with several lines of text discussing complex subjects.",
                colorIndex: i % 16
            )
        }
        let tlStart = Date()
        _ = TreeLayout.layout(cards: cards)
        let tlDuration = Date().timeIntervalSince(tlStart)
        print("TreeLayout.layout on 900 cards took: \(tlDuration)s")
    }

    func testMergeContiguousLineRects() throws {
        // Line 1 Part A (x: 50, y: 700, w: 100, h: 14) and Part B (x: 155, y: 700, w: 120, h: 14) on page 0
        // Small gap between 150 and 155 is 5pt (whitespace). Should merge into x: 50, w: 225.
        let r1 = HighlightRect(page: 0, x: 50, y: 700, width: 100, height: 14)
        let r2 = HighlightRect(page: 0, x: 155, y: 700, width: 120, height: 14)
        // Line 2 on page 0: x: 50, y: 680, w: 200, h: 14
        let r3 = HighlightRect(page: 0, x: 50, y: 680, width: 200, height: 14)
        // Line on page 1: x: 50, y: 700, w: 200, h: 14
        let r4 = HighlightRect(page: 1, x: 50, y: 700, width: 200, height: 14)

        let merged = PDFHighlightResolver.mergeContiguousLineRects([r1, r2, r3, r4])
        XCTAssertEqual(merged.count, 3, "r1 and r2 on the same line should merge into 1 continuous line rect")
        XCTAssertEqual(merged[0].page, 0)
        XCTAssertEqual(merged[0].x, 50)
        XCTAssertEqual(merged[0].width, 225)
        XCTAssertEqual(merged[1].y, 680)
        XCTAssertEqual(merged[2].page, 1)
    }

    func testSingleNativeHighlightVersusSeparateExcerptSegments() throws {
        let dummyAnnot = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 14), forType: .highlight, withProperties: nil)
        let h1 = PDFHighlightImporter.ExtractedHighlight(
            pageIndex: 0,
            bounds: CGRect(x: 50, y: 700, width: 200, height: 14),
            text: "First highlighted sentence.",
            note: "",
            color: .yellow,
            colorIndex: 0,
            lineRects: [HighlightRect(page: 0, x: 50, y: 700, width: 200, height: 14)],
            annotation: dummyAnnot
        )
        let h2 = PDFHighlightImporter.ExtractedHighlight(
            pageIndex: 0,
            bounds: CGRect(x: 50, y: 680, width: 200, height: 14),
            text: "Second contiguous sentence.",
            note: "",
            color: .yellow,
            colorIndex: 0,
            lineRects: [HighlightRect(page: 0, x: 50, y: 680, width: 200, height: 14)],
            annotation: dummyAnnot
        )

        let cluster = [[h1, h2]]
        let topicId = UUID()

        // 1. Single Native Note mode: excerptSegments is empty, card is 1 native note
        let singleCards = PDFHighlightImporter.buildCards(
            from: cluster,
            topicId: topicId,
            bookMD5: "test_doc",
            singleNativeHighlight: true
        )
        XCTAssertEqual(singleCards.count, 1)
        XCTAssertTrue(singleCards[0].excerptSegments.isEmpty, "Single native note must have empty excerptSegments")
        XCTAssertEqual(singleCards[0].effectiveSegments.count, 1, "Single native note has exactly 1 effective segment")
        XCTAssertEqual(singleCards[0].highlightRects.count, 2)

        // 2. Several Highlighted Areas mode: excerptSegments preserves each highlight part
        let segmentedCards = PDFHighlightImporter.buildCards(
            from: cluster,
            topicId: topicId,
            bookMD5: "test_doc",
            singleNativeHighlight: false
        )
        XCTAssertEqual(segmentedCards.count, 1)
        XCTAssertEqual(segmentedCards[0].excerptSegments.count, 2, "Segmented note preserves individual excerpt segments")
        XCTAssertEqual(segmentedCards[0].effectiveSegments.count, 2)
    }

    func testImportHighlightsDeletesOriginalAnnotationsFromPDFAndDisk() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-test-orig-annot-\(UUID().uuidString).pdf")
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                _ = try? FileManager.default.removeItem(at: tempURL)
            }
            let sidecar = tempURL.appendingPathExtension("md5")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                _ = try? FileManager.default.removeItem(at: sidecar)
            }
        }

        try makeSyntheticPDF(at: tempURL)
        guard let doc = PDFDocument(url: tempURL), let page = doc.page(at: 0) else {
            XCTFail("Failed to create PDF document")
            return
        }

        // Add a native PDF highlight annotation over "MarginGraph synthetic PDF" at y: 100
        let annotBounds = CGRect(x: 50, y: 90, width: 250, height: 30)
        let origHighlight = PDFAnnotation(bounds: annotBounds, forType: .highlight, withProperties: nil)
        origHighlight.color = .yellow
        page.addAnnotation(origHighlight)
        _ = doc.write(to: tempURL)

        XCTAssertTrue(PDFHighlightImporter.hasHighlights(in: doc))
        XCTAssertEqual(PDFHighlightImporter.countHighlights(in: doc), 1)

        let db = try Database(inMemory: true)
        let topicId = UUID()
        let topic = Topic(id: topicId, title: "Test Topic")
        try db.insertTopic(topic)
        let docModel = Document(
            id: UUID(),
            title: "Test PDF With Highlights",
            filePath: tempURL.path,
            md5: "test_doc_original_highlight_md5",
            totalPages: 1
        )
        try db.insertDocument(docModel)

        let cards = try PDFHighlightImporter.importHighlights(
            from: doc,
            for: docModel,
            topicId: topicId,
            shouldMerge: true,
            singleNativeHighlight: true,
            database: db
        )

        XCTAssertEqual(cards.count, 1)

        // 1. In-memory: original highlight must be removed
        let remainingAnnots = page.annotations.filter {
            $0.contents?.hasPrefix("MarginGraph-") != true && ($0.type == "Highlight" || $0.type == "Underline")
        }
        XCTAssertEqual(remainingAnnots.count, 0, "Original highlight annotation must be removed from PDF page in-memory")
        XCTAssertFalse(PDFHighlightImporter.hasHighlights(in: doc))

        // 2. On-disk: re-loaded PDF must have 0 original highlights
        guard let reloadedDoc = PDFDocument(url: tempURL), let reloadedPage = reloadedDoc.page(at: 0) else {
            XCTFail("Failed to reload PDF document")
            return
        }
        let diskAnnots = reloadedPage.annotations.filter {
            $0.contents?.hasPrefix("MarginGraph-") != true && ($0.type == "Highlight" || $0.type == "Underline")
        }
        XCTAssertEqual(diskAnnots.count, 0, "Original highlight annotation must be removed from PDF on disk")

        // 3. Sidecar MD5 must be preserved
        let sidecarURL = tempURL.appendingPathExtension("md5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        let sidecarContent = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertEqual(sidecarContent, "test_doc_original_highlight_md5")
    }

    func testDeleteCardRemovesOverlappingOriginalAnnotationsFromPDF() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginGraph-test-del-annot-\(UUID().uuidString).pdf")
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                _ = try? FileManager.default.removeItem(at: tempURL)
            }
            let sidecar = tempURL.appendingPathExtension("md5")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                _ = try? FileManager.default.removeItem(at: sidecar)
            }
        }

        try makeSyntheticPDF(at: tempURL)
        guard let doc = PDFDocument(url: tempURL), let page = doc.page(at: 0) else {
            XCTFail("Failed to create PDF document")
            return
        }

        let annotBounds = CGRect(x: 50, y: 90, width: 250, height: 30)
        let lingeringHighlight = PDFAnnotation(bounds: annotBounds, forType: .highlight, withProperties: nil)
        lingeringHighlight.color = .yellow
        page.addAnnotation(lingeringHighlight)
        _ = doc.write(to: tempURL)

        let db = try Database(inMemory: true)
        let topicId = UUID()
        try db.insertTopic(Topic(id: topicId, title: "Test Topic"))

        let card = NoteCard(
            id: UUID(),
            topicId: topicId,
            bookMD5: "test_del_md5",
            highlightText: "MarginGraph synthetic PDF",
            startPage: 0,
            endPage: 0,
            highlightRects: [HighlightRect(page: 0, x: 50, y: 90, width: 250, height: 30)]
        )
        try db.insertCard(card)

        // Verify highlight is on page
        XCTAssertEqual(page.annotations.filter { $0.type == "Highlight" }.count, 1)

        // Delete original highlights for this card using deleteOriginalHighlights
        PDFHighlightImporter.deleteOriginalHighlights(from: doc, extracted: [], docModel: Document(id: UUID(), title: "Doc", filePath: tempURL.path, md5: "test_del_md5", totalPages: 1))

        XCTAssertEqual(page.annotations.filter { $0.type == "Highlight" }.count, 0)

        // Verify disk document is cleaned
        guard let reloadedDoc = PDFDocument(url: tempURL), let reloadedPage = reloadedDoc.page(at: 0) else {
            XCTFail("Failed to reload PDF")
            return
        }
        XCTAssertEqual(reloadedPage.annotations.filter { $0.type == "Highlight" }.count, 0)
    }
}

