import Foundation
import XCTest
@testable import MarginGraphCore

final class ReferenceWorkflowTests: XCTestCase {
    func testBibTeXUpdatesOnlyTargetAndDetectsExternalEdits() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("refs.bib")
        let prefix = """
            % Ebib database; preserve the entire header.
            @String{press = "Book Press"}
            @preamble{"prefix"}
            @Comment{This is not an entry. @book{ignored, title={x}}}

            """
        let original = #"""
            @book(Snyder_2005_SaveTheCat,
              title = "{Save the Cat!}: The \"Last\" Book" # " on Screenwriting",
              file = {/old/path/Title @ work.pdf},
              publisher = press,
              year = 2005,
              isbn = 9781932907001
            )
            """#
        let other = "@movie{Film, title={Movie}, file={/old/video/folder}}"
        let text = (prefix + "\n" + original + "\n\n" + other + "\n").replacingOccurrences(of: "\n", with: "\r\n")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let library = try BibTeXLibrary.load(file)
        XCTAssertEqual(library.entries.map(\.key), ["Snyder_2005_SaveTheCat", "Film"])
        let selected = try XCTUnwrap(library.entries.first)
        XCTAssertEqual(selected.fields["publisher"], "Book Press")
        XCTAssertTrue(selected.fields["title"]?.hasSuffix(" on Screenwriting") == true)
        let edited = try BibTeXLibrary.entry("@book{Snyder_2005_SaveTheCat, title={Save the Cat!}}")
        try BibTeXLibrary.save(edited, replacing: selected, in: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       text.replacingOccurrences(of: selected.source, with: edited.source))
        XCTAssertThrowsError(try BibTeXLibrary.delete(selected, from: file))
        XCTAssertThrowsError(try BibTeXLibrary.save(edited, in: file))
        try BibTeXLibrary.delete(edited, from: file)
        XCTAssertEqual(try BibTeXLibrary.load(file).entries.map(\.key), ["Film"])
        try BibTeXLibrary.save(edited, in: file)
        XCTAssertEqual(try BibTeXLibrary.load(file).entries.map(\.key), ["Film", edited.key])
    }

    func testPDFTextResolutionAndISBNLookupPayload() throws {
        XCTAssertEqual(ISBN.canonical("0-14-032872-6"), "9780140328721")
        XCTAssertNil(ISBN.canonical("9780140328722"))
        XCTAssertEqual(ISBN.candidates(in: "ISBN-13: 978‑1‑932907‑00‑1"), ["9781932907001"])
        let localText = """
            Title: An Article
            Author: Jane O’Neil
            Journal: Example Journal
            DOI: 10.1234/ex.2020
            Copyright © 2020
            Published by Example Press
            """
        let local = ReferenceMetadata.fromPDFText(localText, frontMatter: localText, title: nil, author: nil,
                                                  fallback: "Opaque file name", path: "/tmp/article.pdf")
        XCTAssertEqual(local.type, "article")
        XCTAssertEqual(local.fields["title"], "An Article")
        XCTAssertEqual(local.fields["author"], "Jane O’Neil")
        XCTAssertEqual(local.fields["year"], "2020")
        XCTAssertEqual(local.fields["publisher"], "Example Press")
        XCTAssertEqual(local.fields["doi"], "10.1234/ex.2020")
        XCTAssertNil(local.fields["isbn"])

        let payload = Data("""
            {"ISBN:9780140328721":{"title":"Matilda","authors":[{"name":"Roald Dahl"}],
              "publishers":[{"name":"Puffin"}],"publish_date":"March 7, 1996"}}
            """.utf8)
        let book = try ISBNLookup.decode(payload, key: "ISBN:9780140328721", isbn: "9780140328721")
        let entry = try book.entry(avoiding: ["Dahl_1996_Matilda"])
        XCTAssertEqual(entry.key, "Dahl_1996_Matilda_2")
        XCTAssertEqual(entry.fields["author"], "Roald Dahl")
        XCTAssertEqual(ReferenceMetadata.match(ReferenceMetadata(fields: ["isbn": "0140328726"]),
                                               in: [entry])?.key, entry.key)
    }

    func testExistingEbibNoteIsReusedWithoutOverwritingEmacsEdits() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("old-capture.org")
        let entry = try BibTeXLibrary.entry("@book{Snyder_2005_SaveTheCat, title={Save the Cat!}}")
        let topic = Topic(title: "Notebook")
        let first = NoteCard(topicId: topic.id, title: "Existing parent")
        let sibling = NoteCard(topicId: topic.id, title: "New sibling", createdAt: Date(timeIntervalSince1970: 0))
        let child = NoteCard(topicId: topic.id, title: "New child", groupNoteId: first.id)
        let existing = """
            :PROPERTIES:
            :ID:       \(UUID().uuidString.lowercased())
            :ROAM_REFS: cite:&Snyder_2005_SaveTheCat
            :END:
            #+title: Save the Cat!
            #+filetags: :Snyder_2005_SaveTheCat:book:literature:

            * Save the Cat!
            Hand-edited introduction.

            ** Existing parent (renamed in Emacs)
            :PROPERTIES:
            :ID: \(first.id.uuidString.lowercased())
            :END:
            Hand-edited body.
            """
        try existing.write(to: file, atomically: true, encoding: .utf8)
        let generated = OrgExporter.export(topic: topic, cards: [sibling, first, child], reference: entry)
        let result = try OrgLiteratureLibrary.write(generated, reference: entry, filename: "new.org", directory: folder)
        XCTAssertEqual(result.lastPathComponent, file.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.org").path))
        let saved = try String(contentsOf: result, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix(existing))
        let headlines = saved.split(separator: "\n").filter { $0.hasPrefix("*") }.map(String.init)
        XCTAssertEqual(headlines, ["* Save the Cat!", "** Existing parent (renamed in Emacs)", "*** New child", "** New sibling"])
        _ = try OrgLiteratureLibrary.write(generated, reference: entry, filename: "new.org", directory: folder)
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), saved)
    }

    func testNewBookAndVideoUseTheEbibCaptureHeaders() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = try BibTeXLibrary.entry("@movie{Film_2024, title={Film}, file={/books/Film}}")
        let topic = Topic(title: "Notebook")
        let org = OrgExporter.export(topic: topic, cards: [], reference: entry)
        XCTAssertTrue(org.contains(":ROAM_REFS: cite:&Film_2024\n"))
        XCTAssertTrue(org.contains("#+filetags: :Film_2024:video:literature:\n\n* Film"))
        XCTAssertTrue(org.contains(":MPV_VIDEO_DIRECTORY: /books/Film"))
        let result = try OrgLiteratureLibrary.write(org, reference: entry, filename: "film.org", directory: folder)
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), org)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
