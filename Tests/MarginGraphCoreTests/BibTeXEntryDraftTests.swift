import Foundation
import XCTest
@testable import MarginGraphCore

final class BibTeXEntryDraftTests: XCTestCase {
    func testEditingUsesSeparateFieldsAndPreservesUntouchedSourceAndMacros() throws {
        let source = """
            % Ebib database header
            @string{press = "Independent Press"}
            @Book (Example,
                Title = "{A Book}" # " for Readers",
                publisher = press,
                year = 2021,
                % Keep this comment.
                isbn = {12345}
            )
            @misc{Other, title={Untouched}}
            """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bib")
        defer { try? FileManager.default.removeItem(at: file) }
        try source.write(to: file, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(BibTeXLibrary.load(file).entries.first)
        var draft = try BibTeXEntryDraft(original)
        XCTAssertEqual(draft.fields.map(\.name), ["Title", "publisher", "year", "isbn"])
        XCTAssertEqual(draft.fields[0].value, "{A Book} for Readers")
        XCTAssertEqual(draft.fields[1].value, "Independent Press")
        XCTAssertEqual(try draft.entry(), original)

        draft.fields[2].value = "2025"
        draft.fields[3].name = "eprint"
        draft.fields.append(.init(name: "abstract", value: "First line.\nSecond line, with an apostrophe."))
        try BibTeXLibrary.save(draft.entry(), replacing: original, in: file)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(saved, source
            .replacingOccurrences(of: "year = 2021", with: "year = {2025}")
            .replacingOccurrences(of: "isbn = {12345}\n)", with:
                "eprint = {12345},\n    abstract = {First line.\nSecond line, with an apostrophe.}\n)"))
        XCTAssertEqual(try BibTeXLibrary.load(file).entries[0].fields["publisher"], "Independent Press")
        XCTAssertThrowsError(try BibTeXLibrary.save(draft.entry(), replacing: original, in: file))
    }

    func testDeletingFieldAndAddingAnotherKeepsCRLFAroundComments() throws {
        let source = "@article{Key,\r\n    title = {Title}, % title comment\r\n    note = {Delete me},\r\n    year = 2026\r\n}"
        var draft = try BibTeXEntryDraft(BibTeXLibrary.entry(source))
        draft.fields.remove(at: 1)
        draft.fields.append(.init(name: "doi", value: "10.1000/182"))
        let saved = try draft.entry()
        XCTAssertEqual(saved.source,
            "@article{Key,\r\n    title = {Title}, % title comment\r\n    year = 2026,\r\n    doi = {10.1000/182}\r\n}")
        draft.fields.removeAll()
        XCTAssertTrue(try draft.entry().fields.isEmpty)
    }

    func testAddingToOneLineAndBareEntries() throws {
        for source in ["@misc{Key}", "@misc{Key,}", "@misc{Key, title={Old}}", "@misc(Key, title={Old},)"] {
            var draft = try BibTeXEntryDraft(BibTeXLibrary.entry(source))
            draft.fields.removeAll()
            draft.fields.append(.init(name: "title", value: "New"))
            XCTAssertEqual(try draft.entry().fields, ["title": "New"], source)
        }
        var draft = try BibTeXEntryDraft(BibTeXLibrary.entry("@misc{Key,title={Old}}"))
        draft.fields[0].value = "A New Title"
        draft.fields.append(.init(name: "note", value: "Added"))
        XCTAssertEqual(try draft.entry().fields, ["title": "A New Title", "note": "Added"])
    }

    func testNewEntryHandlesPlainTextAndValidatesNamesAndDuplicates() throws {
        var draft = BibTeXEntryDraft()
        XCTAssertThrowsError(try draft.entry())
        draft.key = "New_2026"
        draft.type = "article"
        draft.fields[0].value = #"Notes, 100% {Draft} with a literal } and a trailing \"#
        let original = try draft.entry()
        XCTAssertEqual(original.fields["title"], #"Notes, 100% {Draft} with a literal \} and a trailing \\"#)
        XCTAssertNil(original.fields["author"])
        draft.fields.append(.init(name: "TITLE", value: "Duplicate"))
        XCTAssertThrowsError(try draft.entry()) { error in
            XCTAssertEqual(error.localizedDescription, "The field “title” is already in this entry.")
        }
        draft.fields[3].name = "invalid name"
        XCTAssertThrowsError(try draft.entry())
        draft.fields[3].name = "custom-label"
        XCTAssertEqual(try draft.entry().fields["custom-label"], "Duplicate")
    }
}
