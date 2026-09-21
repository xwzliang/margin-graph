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
}
