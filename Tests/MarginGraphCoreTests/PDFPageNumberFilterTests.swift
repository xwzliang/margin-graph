import XCTest
import CoreText
import PDFKit
@testable import MarginGraphCore

@MainActor
final class PDFPageNumberFilterTests: XCTestCase {
    func testFooterFilteringPreservesBodyNumbersAndHighlightGeometryAcrossPages() throws {
        let document = try makeDocument()
        let view = InteractivePDFView()
        view.document = document
        let first = try XCTUnwrap(document.page(at: 0))
        let last = try XCTUnwrap(document.page(at: 2))
        let start = CGPoint(x: 60, y: 704)
        let end = CGPoint(x: 400, y: 174)

        let original = try XCTUnwrap(view.makeMultiPageSelection(from: first, at: start, to: last, at: end))
        XCTAssertTrue(original.string?.contains("Page 42") == true)
        let originalBounds = first.bounds(for: .cropBox)
        let originalText = first.string
        let originalAnnotations = first.annotations.count

        view.hidesPageNumbers = true
        let clean = try XCTUnwrap(view.makeMultiPageSelection(from: first, at: start, to: last, at: end))
        let text = PDFHighlightResolver.normalizeExcerptParagraphs(clean)
        XCTAssertFalse(text.contains("Page 42"))
        XCTAssertFalse(text.contains("xiv"))
        XCTAssertFalse(text.contains("— 44 —"))
        XCTAssertTrue(text.contains("2026"))
        XCTAssertTrue(text.contains("123")) // Standalone number in the body.
        XCTAssertTrue(text.contains("Body ends with 42"))
        XCTAssertTrue(text.contains("A footnote with 99"))
        let rects = PDFHighlightResolver.lineRects(from: clean, document: document)
        XCTAssertEqual(Set(rects.map(\.page)), Set([0, 1, 2]))
        XCTAssertTrue(rects.allSatisfy { $0.y > 60 })
        let reverse = try XCTUnwrap(view.makeMultiPageSelection(from: last, at: end, to: first, at: start))
        XCTAssertEqual(PDFHighlightResolver.normalizeExcerptParagraphs(reverse), text)
        XCTAssertEqual(first.bounds(for: .cropBox), originalBounds)
        XCTAssertEqual(first.string, originalText)
        XCTAssertEqual(first.annotations.count, originalAnnotations)

        let numberInBody = try XCTUnwrap(first.selection(for: CGRect(x: 60, y: 84, width: 200, height: 20)))
        XCTAssertTrue(view.filteredSelection(numberInBody)?.string?.contains("42") == true)
        let footerOnly = try XCTUnwrap(first.selection(for: CGRect(x: 270, y: 30, width: 120, height: 25)))
        XCTAssertNil(view.filteredSelection(footerOnly))
        view.hidesPageNumbers = false
        XCTAssertEqual(view.filteredSelection(footerOnly)?.string, footerOnly.string)
    }

    func testCacheIsScopedToDocumentAndCropOrigin() throws {
        let filter = PDFPageNumberFilter()
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 20, width: 570, height: 750), for: .cropBox)
        XCTAssertEqual(filter.footers(on: page).count, 1)
        let other = try makeDocument(footers: ["Notes", "copyright 2026", ""])
        XCTAssertTrue(filter.footers(on: try XCTUnwrap(other.page(at: 0))).isEmpty)
        XCTAssertTrue(filter.footers(on: try XCTUnwrap(other.page(at: 1))).isEmpty)
        XCTAssertTrue(filter.footers(on: try XCTUnwrap(other.page(at: 2))).isEmpty)
        XCTAssertEqual(filter.footers(on: page).count, 1)
    }

    private func makeDocument(footers: [String] = ["Page 42", "xiv", "— 44 —"]) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for footer in footers {
            context.beginPDFPage(nil)
            for (text, x, y) in [
                ("Paragraph begins in 2026", 60.0, 700.0),
                ("123", 60.0, 300.0),
                ("Paragraph continues across pages", 60.0, 170.0),
                ("Body ends with 42", 60.0, 90.0),
                ("A footnote with 99", 60.0, 65.0),
                (footer, 280.0, 35.0)
            ] {
                let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
