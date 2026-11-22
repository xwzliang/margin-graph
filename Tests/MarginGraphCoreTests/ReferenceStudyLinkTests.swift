import Foundation
import XCTest
@testable import MarginGraphCore

final class ReferenceStudyLinkTests: XCTestCase {
    private let bibliography = URL(fileURLWithPath: "/sample/refs.bib")

    func testAttachmentsPreserveExistingFieldsAndAreIdempotent() throws {
        let source = "@book(Key,\r\n  title = \"A Study\",\r\n  publisher = press,\r\n  file = \"old.pdf; notes.txt\"\r\n)"
        let pdf = URL(fileURLWithPath: "/new/A {Study}; revision.PDF")
        let entry = try BibTeXLibrary.entry(source)
        let updated = try BibTeXLibrary.attachingPDF(pdf, to: entry, bibliography: bibliography)
        XCTAssertEqual(updated.source, source.replacingOccurrences(of: "\"old.pdf; notes.txt\"",
            with: "{old.pdf; notes.txt; \(pdf.absoluteString.replacingOccurrences(of: ";", with: "%3B"))}"))
        XCTAssertEqual(updated.key, entry.key)
        XCTAssertTrue(ReferenceStudyMatcher.pdfAttachments(for: updated, bibliography: bibliography).contains(pdf))
        XCTAssertEqual(try BibTeXLibrary.attachingPDF(pdf, to: updated, bibliography: bibliography), updated)
    }

    func testAddingMissingFileFieldPreservesCRLFAndHandlesBareEntry() throws {
        let source = "@book{Key,\r\n  title={A Study}\r\n}"
        let file = URL(fileURLWithPath: "/new/A {Study}.pdf")
        let entry = try BibTeXLibrary.entry(source)
        let updated = try BibTeXLibrary.attachingPDF(file, to: entry, bibliography: bibliography)
        XCTAssertEqual(updated.source, "@book{Key,\r\n    file = {/new/A \\{Study\\}.pdf},\r\n  title={A Study}\r\n}")
        XCTAssertEqual(ReferenceStudyMatcher.pdfAttachments(for: updated, bibliography: bibliography), [file])
        let bare = try BibTeXLibrary.entry("@book{Key}")
        let attached = try BibTeXLibrary.attachingPDF(file, to: bare, bibliography: bibliography)
        XCTAssertEqual(attached.key, "Key")
        XCTAssertEqual(ReferenceStudyMatcher.pdfAttachments(for: attached, bibliography: bibliography), [file])
    }

    func testLegacyAttachmentAndTitleMatchingDisambiguatePDFs() throws {
        let entry = try BibTeXLibrary.entry("""
            @book{Key, title = {A Short Story About the Moon and Stars}, file = {/old/The Moon.pdf; notes.txt}}
            """)
        let title = Document(title: "A Short Story About the Moon and Stars -- Author", filePath: "/books/other.pdf",
                             md5: "title", totalPages: 10)
        let moved = Document(title: "Alternate title", filePath: "/books/The Moon.pdf", md5: "moved", totalPages: 10)
        let exact = Document(title: "Exact", filePath: "/old/The Moon.pdf", md5: "exact", totalPages: 10)
        let attachments = ReferenceStudyMatcher.pdfAttachments(for: entry, bibliography: bibliography)
        XCTAssertEqual(ReferenceStudyMatcher.document(for: entry, attachments: attachments,
                                                       in: [title, moved, exact], isReadable: { _ in true }), exact)
        XCTAssertEqual(ReferenceStudyMatcher.document(for: entry, attachments: attachments,
                                                       in: [title, moved, exact], isReadable: { $0 != exact.filePath }), moved)
        XCTAssertEqual(ReferenceStudyMatcher.document(for: entry, attachments: [],
                                                       in: [title, moved], isReadable: { _ in true }), title)
        var duplicate = title
        duplicate.id = UUID()
        duplicate.filePath = "/other/duplicate.pdf"
        XCTAssertNil(ReferenceStudyMatcher.document(for: entry, attachments: [], in: [title, duplicate],
                                                    isReadable: { _ in true }))
    }

    func testLinksAreScopedToBibliographyAndSurviveTopicUpdates() throws {
        let database = try Database(inMemory: true)
        var topic = Topic(title: "Notebook")
        try database.insertTopic(topic)
        let other = URL(fileURLWithPath: "/sample/story.bib")
        let key = "Key"
        let link = ReferenceStudyLink(topicID: topic.id, bookMD5: "pdf")
        try database.saveReferenceStudyLink(link, bibliography: bibliography, key: key)
        XCTAssertNil(try database.referenceStudyLink(bibliography: other, key: key))
        topic.title = "Renamed"
        try database.insertTopic(topic)
        XCTAssertEqual(try database.referenceStudyLink(bibliography: bibliography, key: key), link)
        try database.saveReferenceStudyLink(link, bibliography: other, key: key)
        try database.removeReferenceStudyLink(bibliography: bibliography, key: key)
        XCTAssertNil(try database.referenceStudyLink(bibliography: bibliography, key: key))
        XCTAssertEqual(try database.referenceStudyLink(bibliography: other, key: key), link)
        try database.deleteTopic(id: topic.id)
        XCTAssertNil(try database.referenceStudyLink(bibliography: other, key: key))
    }
}
