import XCTest
import SQLite3
@testable import MarginGraphCore

final class MarginNoteImporterTests: XCTestCase {
    func testImportsTopicsBooksCardsAndParentRelationship() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let topicID = UUID()
        let parentID = UUID()
        let childID = UUID()

        try exec(db, """
        CREATE TABLE ZTOPIC (Z_PK INTEGER, ZTOPICID TEXT, ZTITLE TEXT, ZBOOKMD5LIST TEXT);
        CREATE TABLE ZBOOK (Z_PK INTEGER, ZBOOKID TEXT, ZTITLE TEXT, ZFILEPATH TEXT, ZMD5 TEXT, ZTOTALPAGES INTEGER);
        CREATE TABLE ZBOOKNOTE (
            Z_PK INTEGER, ZNOTEID TEXT, ZTOPICID TEXT, ZBOOKMD5 TEXT, ZNOTETITLE TEXT,
            ZHIGHLIGHT_TEXT TEXT, ZNOTES_TEXT TEXT, ZGROUPNOTEID TEXT, ZMINDPOS TEXT, ZMINDLINKS TEXT
        );
        INSERT INTO ZTOPIC VALUES(1, '\(topicID.uuidString)', 'Notebook', '["book-md5"]');
        INSERT INTO ZBOOK VALUES(1, '\(UUID().uuidString)', 'Book', '/tmp/book.pdf', 'book-md5', 99);
        INSERT INTO ZBOOKNOTE VALUES(
            1, '\(parentID.uuidString)', '\(topicID.uuidString)', 'book-md5',
            'Parent', 'quote', 'note', NULL, '{10,20}', '["\(childID.uuidString)"]'
        );
        INSERT INTO ZBOOKNOTE VALUES(
            2, '\(childID.uuidString)', '\(topicID.uuidString)', 'book-md5',
            'Child', '', '', '\(parentID.uuidString)', '{30,40}', '[]'
        );
        """)

        let destination = try Database(inMemory: true)
        let result = try MarginNoteImporter(url: url).importInto(destination)

        XCTAssertEqual(result.topics.count, 1)
        XCTAssertEqual(result.documents.first?.totalPages, 99)
        XCTAssertEqual(result.cards.count, 2)

        let parent = try XCTUnwrap(result.cards.first(where: { $0.id == parentID }))
        let child = try XCTUnwrap(result.cards.first(where: { $0.id == childID }))

        XCTAssertEqual(parent.mindPos?.x, 10)
        XCTAssertEqual(parent.mindLinks, [childID])
        XCTAssertEqual(child.groupNoteId, parentID)
        XCTAssertEqual(
            try destination.childCards(parentId: parentID, topicId: topicID).first?.id,
            childID
        )
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            XCTFail(message)
            throw NSError(
                domain: "SQLite",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func testLiveMarginNoteDatabaseImportIfExists() throws {
        let livePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Library/Application Support/QReader.MarginNoteMac/MarginNotes.sqlite")
        guard FileManager.default.fileExists(atPath: livePath.path) else {
            print("Live MarginNotes.sqlite not found, skipping live test.")
            return
        }
        let destination = try Database(inMemory: true)
        let result = try MarginNoteImporter(url: livePath).importInto(destination)
        print("Live import result: \(result.topics.count) topics, \(result.documents.count) books, \(result.cards.count) cards")
        XCTAssertGreaterThan(result.topics.count, 0)
        XCTAssertGreaterThan(result.cards.count, 0)
    }
}
