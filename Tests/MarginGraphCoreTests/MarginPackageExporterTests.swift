import XCTest
import Foundation
import SQLite3
@testable import MarginGraphCore

final class MarginPackageExporterTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mn_exp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSuggestedFilenameSanitizesBookAndFolderTitles() {
        XCTAssertEqual(MarginPackageExporter.sanitizeFilename("Homo Deus: A Brief History of Tomorrow"),
                       "Homo Deus_ A Brief History of Tomorrow")
        XCTAssertEqual(MarginPackageExporter.sanitizeFilename("Homo Deus/ A Brief History of Tomorrow"),
                       "Homo Deus_ A Brief History of Tomorrow")
        XCTAssertEqual(MarginPackageExporter.sanitizeFilename("   "), "Notes")
        XCTAssertFalse(MarginPackageExporter.sanitizeFilename("folder/book\\name").contains("/"))
    }

    func testExportDocumentAndImportBack() throws {
        let db = try Database(inMemory: true)
        let mediaStorage = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))

        let pdfFile = tempDir.appendingPathComponent("SampleBook.pdf")
        try "dummy pdf content for testing".write(to: pdfFile, atomically: true, encoding: .utf8)

        let docMD5 = "sample_doc_md5_1234567890abcdef1234567890abcdef1234567890abcdef12345678"
        let doc = Document(
            id: Document.stableUUID(docMD5),
            title: "SampleBook: Display Title",
            filePath: pdfFile.path,
            md5: docMD5,
            totalPages: 5,
            lastVisited: Date(),
            documentType: "pdf"
        )
        try db.insertDocument(doc)

        let topic = Topic(
            id: UUID(),
            title: "Sample Study Notebook",
            bookMD5List: [docMD5]
        )
        try db.insertTopic(topic)

        let card = NoteCard(
            id: UUID(),
            topicId: topic.id,
            bookMD5: docMD5,
            title: "Concept A",
            highlightText: "This is highlighted text in the document.",
            notesText: "My personal study commentary.",
            startPage: 2,
            endPage: 2,
            colorIndex: 3,
            highlightRects: [
                HighlightRect(page: 2, x: 50, y: 100, width: 200, height: 18)
            ]
        )
        try db.insertCard(card)

        let exportURL = tempDir.appendingPathComponent("SampleBook_Export.marginpkg")
        try MarginPackageExporter.exportDocument(
            document: doc,
            database: db,
            mediaStorage: mediaStorage,
            destinationURL: exportURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int64 ?? 0, 1000)

        // Validate the native package contract, independently of our importer.
        let unpacked = tempDir.appendingPathComponent("native_package")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", exportURL.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let notesURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "marginnotes" })
        var nativeDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(notesURL.path, &nativeDB), SQLITE_OK)
        defer { sqlite3_close(nativeDB) }
        func scalar(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(nativeDB, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }
        XCTAssertNotEqual(scalar("SELECT Z_UUID FROM Z_METADATA"), "6470D715-D0C6-4BEE-885D-BD40CAE72134")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("__MACOSX").path))
        XCTAssertEqual(scalar("SELECT ZTITLE FROM ZBOOKCONFIG"), "SampleBook")
        XCTAssertEqual(scalar("SELECT count(*) FROM ZTOPIC t JOIN ZBOOKNOTE n ON n.ZNOTEID=t.ZMINDLINKS AND n.ZTOPICID=t.ZTOPICID"), "1")
        XCTAssertEqual(scalar("SELECT n.ZMINDLINKS FROM ZBOOKNOTE n JOIN ZTOPIC t ON n.ZNOTEID=t.ZMINDLINKS"), card.id.uuidString)
        XCTAssertEqual(scalar("SELECT count(*) FROM ZBOOKNOTE WHERE ZMINDPOS IS NOT NULL"), "2")

        // Read package back using MarginNoteImporter
        let destDocs = tempDir.appendingPathComponent("imported_docs")
        let importer = MarginNoteImporter(
            url: exportURL,
            documentsDestinationDirectory: destDocs,
            mediaStorage: mediaStorage,
            copyDocuments: true,
            copyMedia: true
        )
        let result = try importer.read()

        XCTAssertFalse(result.documents.isEmpty)
        XCTAssertEqual(result.documents[0].md5, docMD5)
        XCTAssertEqual(result.documents[0].title, "SampleBook")

        XCTAssertFalse(result.topics.isEmpty)
        XCTAssertEqual(result.topics[0].title, "Sample Study Notebook")

        XCTAssertFalse(result.cards.isEmpty)
        let importedCard = result.cards.first(where: { $0.title == "Concept A" })
        XCTAssertNotNil(importedCard)
        XCTAssertEqual(importedCard?.highlightText, "This is highlighted text in the document.")
        XCTAssertEqual(importedCard?.notesText, "My personal study commentary.")
        XCTAssertEqual(importedCard?.startPage, 2)
    }

    func testExportFolderAndImportBack() throws {
        let db = try Database(inMemory: true)
        let mediaStorage = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))

        let folder = DocumentFolder(id: UUID(), parentId: nil, name: "AI Course")
        try db.insertFolder(folder)

        let pdf1 = tempDir.appendingPathComponent("Lecture1.pdf")
        let pdf2 = tempDir.appendingPathComponent("Lecture2.pdf")
        try "lecture 1 content".write(to: pdf1, atomically: true, encoding: .utf8)
        try "lecture 2 content".write(to: pdf2, atomically: true, encoding: .utf8)

        let md5_1 = "doc_lecture1_md5_1234567890abcdef1234567890abcdef1234567890abcdef123456"
        let md5_2 = "doc_lecture2_md5_1234567890abcdef1234567890abcdef1234567890abcdef123456"

        let doc1 = Document(id: Document.stableUUID(md5_1), title: "Lecture1", filePath: pdf1.path, md5: md5_1, totalPages: 1, folderId: folder.id)
        let doc2 = Document(id: Document.stableUUID(md5_2), title: "Lecture2", filePath: pdf2.path, md5: md5_2, totalPages: 1, folderId: folder.id)
        try db.insertDocument(doc1)
        try db.insertDocument(doc2)

        let topic = Topic(id: UUID(), title: "AI Notebook", bookMD5List: [md5_1, md5_2])
        try db.insertTopic(topic)

        let card1 = NoteCard(id: UUID(), topicId: topic.id, bookMD5: md5_1, title: "L1 Card", highlightText: "Text 1")
        let card2 = NoteCard(id: UUID(), topicId: topic.id, bookMD5: md5_2, title: "L2 Card", highlightText: "Text 2")
        try db.insertCard(card1)
        try db.insertCard(card2)

        let exportURL = tempDir.appendingPathComponent("AICourse.marginpkg")
        try MarginPackageExporter.exportFolder(
            folder: folder,
            allFolders: [folder],
            allDocuments: [doc1, doc2],
            database: db,
            mediaStorage: mediaStorage,
            destinationURL: exportURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        let destDocs = tempDir.appendingPathComponent("imported_folder_docs")
        let importer = MarginNoteImporter(
            url: exportURL,
            documentsDestinationDirectory: destDocs,
            mediaStorage: mediaStorage,
            copyDocuments: true,
            copyMedia: true
        )
        let result = try importer.read()

        XCTAssertEqual(result.documents.count, 2)
        XCTAssertEqual(result.cards.count, 3) // Includes the notebook entry root.
    }

    @MainActor
    func testLibraryManagerOperations() {
        let lm = LibraryManager()
        // Ensure default built-in exists
        XCTAssertTrue(lm.libraries.contains(where: { $0.isBuiltIn }))

        let testPath = "/Volumes/backups/TestBackup.marginbackupall"
        let entry = lm.addOrUpdateLibrary(path: testPath, alias: "Test Alias", setAsDefault: false)
        XCTAssertEqual(entry.displayName, "Test Alias")
        XCTAssertFalse(entry.isDefault)

        // Set default
        lm.setDefault(id: entry.id)
        XCTAssertTrue(lm.entry(forId: entry.id)?.isDefault == true)
        XCTAssertFalse(lm.libraries.first(where: { $0.isBuiltIn })?.isDefault == true)

        // Sidecar folder URL resolution
        let backupURL = URL(fileURLWithPath: testPath)
        let sidecarURL = LibraryManager.resolveSidecarFolderURL(for: backupURL, alias: "Test Alias")
        XCTAssertEqual(sidecarURL.lastPathComponent, "Test Alias")
        XCTAssertEqual(sidecarURL.deletingLastPathComponent().path, backupURL.deletingLastPathComponent().path)

        let sidecarNoAlias = LibraryManager.resolveSidecarFolderURL(for: backupURL, alias: "")
        XCTAssertEqual(sidecarNoAlias.lastPathComponent, "TestBackup")

        // Delete library
        lm.deleteLibrary(id: entry.id)
        XCTAssertNil(lm.entry(forId: entry.id))
        XCTAssertTrue(lm.libraries.first(where: { $0.isBuiltIn })?.isDefault == true)
    }
}
