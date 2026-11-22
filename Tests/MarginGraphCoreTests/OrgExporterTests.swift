import XCTest
@testable import MarginGraphCore

final class OrgExporterTests: XCTestCase {
    func testFilenameMatchesOrgRoamTimestampAndSlugConvention() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)
        let book = Topic(title: "Save the cat!: the last book on screenwriting you&#39;ll ever need", createdAt: date)
        XCTAssertEqual(
            OrgExporter.suggestedFilename(for: book, timeZone: utc),
            "19700101000000-save_the_cat_the_last_book_on_screenwriting_you_39_ll_ever_n.org"
        )
        let unicode = Topic(title: "Café / " + String(repeating: "读", count: 35), createdAt: date)
        XCTAssertEqual(
            OrgExporter.suggestedFilename(for: unicode, timeZone: utc),
            "19700101000000-cafe_" + String(repeating: "读", count: 27) + ".org"
        )
        XCTAssertEqual(
            OrgExporter.suggestedFilename(for: Topic(title: "!!!", createdAt: date), timeZone: utc),
            "19700101000000-untitled.org"
        )
    }

    func testNoterSourcesAreInheritedForOnePDFAndSpecificForMultipleDocuments() {
        let topic = Topic(title: "Notebook")
        let first = Document(title: "First", filePath: "/tmp/first.pdf", md5: "first", totalPages: 4)
        let second = Document(title: "Second", filePath: "/tmp/second.pdf", md5: "second", totalPages: 4)
        let note = NoteCard(topicId: topic.id, bookMD5: second.md5, title: "Excerpt", startPage: 1)

        let single = OrgExporter.export(topic: topic, cards: [note], documents: [second])
        XCTAssertTrue(single.contains("* Notebook\n:PROPERTIES:\n:NOTER_DOCUMENT: /tmp/second.pdf\n:END:"))
        let multiple = OrgExporter.export(topic: topic, cards: [note], documents: [first, second])
        XCTAssertTrue(multiple.contains("* Notebook\n:PROPERTIES:\n:NOTER_DOCUMENT:\n:END:"))
        XCTAssertTrue(multiple.contains(":NOTER_DOCUMENT: /tmp/second.pdf\n:NOTER_PAGE: 2\n"))
        XCTAssertFalse(multiple.contains("/tmp/first.pdf"))
    }

    func testExportPreservesHierarchyMetadataAndText() {
        let topic = Topic(title: "Reading\r\nNotes")
        let date = Date(timeIntervalSince1970: 0)
        let childID = UUID()
        let parent = NoteCard(
            topicId: topic.id,
            title: "Chapter\nOne",
            highlightText: "读书笔记\r\n* A quoted heading\n#+TITLE: A quoted directive",
            notesText: "See [the detail](margin-graph://note/\(childID.uuidString)).\n:END:",
            isFolded: true,
            startPage: 0,
            endPage: 2,
            colorIndex: 5,
            tags: ["research", "reading notes"],
            createdAt: date,
            updatedAt: date.addingTimeInterval(60)
        )
        let child = NoteCard(
            id: childID, topicId: topic.id, groupNoteId: parent.id,
            excerptSegments: [ExcerptSegment(text: "First excerpt"), ExcerptSegment(text: "Second excerpt")]
        )

        let output = OrgExporter.export(topic: topic, cards: [child, parent], timeZone: TimeZone(secondsFromGMT: 0)!)
        let headings = output.split(separator: "\n").filter { $0.hasPrefix("*") }.map(String.init)
        XCTAssertEqual(headings, ["* Reading Notes", "** Chapter One :research:", "*** First excerpt"])
        XCTAssertTrue(output.hasPrefix("""
            :PROPERTIES:
            :ID:       \(topic.id.uuidString.lowercased())
            :END:
            #+title: Reading Notes
            #+filetags: :book:literature:

            * Reading Notes
            :PROPERTIES:
            :NOTER_DOCUMENT:
            :END:

            """))
        XCTAssertTrue(output.contains(":PROPERTIES:\n:ID:       \(parent.id.uuidString)\n"))
        XCTAssertTrue(output.contains(":ID:       \(childID.uuidString)\n"))
        XCTAssertTrue(output.contains(":CREATED: [1970-01-01 Thu 00:00]\n:MODIFIED: [1970-01-01 Thu 00:01]"))
        XCTAssertTrue(output.contains(":MARGINNOTE_LINK: marginnote3app://note/\(parent.id.uuidString)"))
        XCTAssertTrue(output.contains(":MARGINGRAPH_LINK: \(parent.deepLinkURL.absoluteString)"))
        XCTAssertTrue(output.contains(":NOTER_PAGE: 1\n:NOTER_PAGE_END: 3\n:HIGHLIGHT_COLOR_INDEX: 5"))
        XCTAssertTrue(output.contains(":IS_MERGED: true\n:MARGINGRAPH_TAGS: reading notes\n"))
        XCTAssertTrue(output.contains("读书笔记\n: * A quoted heading\n: #+TITLE: A quoted directive"))
        XCTAssertTrue(output.contains("See [[id:\(childID.uuidString)][the detail]].\n: :END:"))
        XCTAssertTrue(output.contains("First excerpt\n\nSecond excerpt"))
    }

    func testExportIncludesChildMapsAndRecoversMissingParentsAndCycles() {
        let topic = Topic(title: "Notebook")
        let mapRootID = UUID(), mapDetailID = UUID()
        let map = NoteCard(topicId: topic.id, title: "Child Map 0", mindLinks: [mapRootID])
        let mapRoot = NoteCard(id: mapRootID, topicId: topic.id, title: "Map root", mindLinks: [mapDetailID])
        let mapDetail = NoteCard(id: mapDetailID, topicId: topic.id, title: "Map detail", mindLinks: [mapRootID])
        let orphan = NoteCard(topicId: topic.id, title: "Orphan", groupNoteId: UUID())
        let cycleID = UUID(), otherCycleID = UUID()
        let cycle = NoteCard(id: cycleID, topicId: topic.id, title: "Cycle", groupNoteId: otherCycleID)
        let otherCycle = NoteCard(id: otherCycleID, topicId: topic.id, title: "Other cycle", groupNoteId: cycleID)
        let cards = [mapDetail, mapRoot, map, orphan, cycle, otherCycle]

        let output = OrgExporter.export(topic: topic, cards: cards)
        let headings = output.split(separator: "\n").filter { $0.hasPrefix("*") }.map(String.init)
        XCTAssertEqual(headings.count, cards.count + 1)
        XCTAssertTrue(headings.contains("** Orphan"))
        XCTAssertTrue(headings.contains("** Child Map 0"))
        XCTAssertTrue(headings.contains("*** Map root"))
        XCTAssertTrue(headings.contains("**** Map detail"))
        for card in cards {
            XCTAssertEqual(output.components(separatedBy: ":ID:       \(card.id.uuidString)\n").count, 2)
        }
    }

    func testExportVideoMetadataUsesTheNotesSourceFile() {
        let topic = Topic(title: "Screenings")
        let first = Document(title: "First", filePath: "/tmp/first.mp4", md5: "first-video", totalPages: 0, documentType: "video")
        let second = Document(title: "Second", filePath: "/tmp/second.mp4", md5: "second-video", totalPages: 0, documentType: "video")
        let video = NoteCard(
            topicId: topic.id, bookMD5: second.md5, title: "Screening",
            startPage: 0, endPage: 0, mediaType: "video", videoStartTime: 3_723.7, videoEndTime: 7_382
        )
        let output = OrgExporter.export(topic: topic, cards: [video], documents: [first, second])
        XCTAssertTrue(output.contains("#+filetags: :video:literature:\n"))
        XCTAssertTrue(output.contains(":MPV_VIDEO_FILENAME: second.mp4\n"))
        XCTAssertTrue(output.contains(":MPV_POSITION_START: 01:02:03\n:MPV_POSITION_END: 02:03:02\n"))
        XCTAssertFalse(output.contains(":NOTER_PAGE"))
        XCTAssertFalse(output.contains("first.mp4"))
    }
}
