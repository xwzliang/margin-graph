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

    func testNativeSampledBookHashAndHexPalette() throws {
        let file = tempDir.appendingPathComponent("samples.pdf")
        var bytes = Data()
        for index in 0..<100000 {
            let value = (index * 17 + index / 997) % 256
            bytes.append(UInt8(value))
        }
        try bytes.write(to: file)
        // Independently calculated MD5 of first 61440 bytes + tail/middle samples.
        XCTAssertEqual(try MarginPackageExporter.nativeBookHash(url: file), "4f1cc3e263c03b76d3e0f4b7b37b68cacb285c681178d88b9ba6327397000e06")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try MarginPackageExporter.nativeBookHash(url: file), "900150983cd24fb0d6963f7d28e17f72900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MarginPackageExporter.nativeHighlightStyle(colorIndex: 7), "mbooks-annotationa")
        XCTAssertEqual(MarginPackageExporter.nativeHighlightStyle(colorIndex: 4), "mbooks-annotationf")
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
            colorIndex: 7,
            highlightRects: [HighlightRect(page: 2, x: 50, y: 100, width: 200, height: 18),
                             HighlightRect(page: 3, x: 50, y: 200, width: 200, height: 18)],
            excerptSegments: [ExcerptSegment(text: "First selection", rects: [HighlightRect(page: 2, x: 50, y: 100, width: 200, height: 18)]),
                              ExcerptSegment(text: "Second selection", rects: [HighlightRect(page: 3, x: 50, y: 200, width: 200, height: 18)])]
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
        XCTAssertEqual(scalar("SELECT ZTITLE FROM ZBOOKCONFIG"), "SampleBook_ Display Title")
        XCTAssertEqual(scalar("SELECT count(*) FROM ZTOPIC WHERE ZHISTORYDATE IS NOT NULL"), "0")
        XCTAssertEqual(scalar("SELECT count(*) FROM ZTOPIC WHERE ZLASTVISIT IS NOT NULL AND ZDATE IS NOT NULL"), "1")
        XCTAssertEqual(scalar("SELECT count(*) FROM ZTOPIC t JOIN ZBOOKNOTE n ON n.ZNOTEID=t.ZMINDLINKS AND n.ZTOPICID=t.ZTOPICID"), "1")
        XCTAssertEqual(scalar("SELECT n.ZMINDLINKS FROM ZBOOKNOTE n JOIN ZTOPIC t ON n.ZNOTEID=t.ZMINDLINKS"), card.id.uuidString)
        XCTAssertEqual(scalar("SELECT count(*) FROM ZBOOKNOTE WHERE ZMINDPOS IS NOT NULL"), "2")
        XCTAssertEqual(scalar("SELECT n.ZZINDEX FROM ZBOOKNOTE n JOIN ZTOPIC t ON n.ZNOTEID=t.ZMINDLINKS"), "4096")
        XCTAssertEqual(scalar("SELECT ZZINDEX FROM ZBOOKNOTE WHERE ZNOTETITLE='Concept A'"), "0")
        var highlightStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(nativeDB, "SELECT ZHIGHLIGHTS FROM ZBOOKNOTE WHERE ZHIGHLIGHTS IS NOT NULL", -1, &highlightStatement, nil), SQLITE_OK)
        defer { sqlite3_finalize(highlightStatement) }
        XCTAssertEqual(sqlite3_step(highlightStatement), SQLITE_ROW)
        let blob = try XCTUnwrap(sqlite3_column_blob(highlightStatement, 0))
        let archive = Data(bytes: blob, count: Int(sqlite3_column_bytes(highlightStatement, 0)))
        let nativeHighlights = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive) as? [[String: Any]])
        XCTAssertEqual(nativeHighlights.count, 2)
        XCTAssertEqual(nativeHighlights[0]["highlight_text"] as? String, "First selection")
        XCTAssertEqual(nativeHighlights[1]["highlight_text"] as? String, "Second selection")
        let secondJSON = try XCTUnwrap(MarginPackageExporter.decompressGzip(try XCTUnwrap(nativeHighlights[1]["textSelData"] as? Data)))
        let secondRects = try XCTUnwrap(JSONSerialization.jsonObject(with: secondJSON) as? [[String: Any]])
        XCTAssertEqual(secondRects.first?["pageNo"] as? Int, 4)
        XCTAssertEqual(scalar("SELECT ZHIGHLIGHT_STYLE FROM ZBOOKNOTE WHERE ZNOTETITLE='Concept A'"), "mbooks-annotationa")
        let nativeHash = try MarginPackageExporter.nativeBookHash(url: pdfFile)
        XCTAssertEqual(scalar("SELECT ZMD5LONG FROM ZBOOKCONFIG"), nativeHash)
        XCTAssertEqual(scalar("SELECT ZLOCALBOOKMD5 FROM ZTOPIC"), nativeHash)
        XCTAssertEqual(scalar("SELECT ZBOOKMD5 FROM ZBOOKNOTE WHERE ZNOTETITLE='Concept A'"), nativeHash)
        let owner = try XCTUnwrap(scalar("SELECT ZFORUMOWNER FROM ZTOPIC"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(owner.utf8)) as? [String: Any])
        let groups = try XCTUnwrap(metadata["bookGroupNotes"] as? [String: [String: String]])
        XCTAssertEqual(groups[nativeHash]?["noteid"], scalar("SELECT ZMINDLINKS FROM ZTOPIC"))
        let selectionData = try XCTUnwrap(nativeHighlights[0]["textSelData"] as? Data)
        XCTAssertEqual(Array(selectionData.prefix(2)), [0x1f, 0x8b])
        XCTAssertNil(nativeHighlights[0]["textSelLst"])


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
        XCTAssertEqual(result.documents[0].md5, try MarginPackageExporter.nativeBookHash(url: pdfFile))
        XCTAssertEqual(result.documents[0].title, "SampleBook_ Display Title")

        XCTAssertFalse(result.topics.isEmpty)
        XCTAssertEqual(result.topics[0].title, "Sample Study Notebook")

        XCTAssertFalse(result.cards.isEmpty)
        let importedCard = result.cards.first(where: { $0.title == "Concept A" })
        XCTAssertNotNil(importedCard)
        XCTAssertEqual(importedCard?.highlightText, "This is highlighted text in the document.")
        XCTAssertEqual(importedCard?.notesText, "My personal study commentary.")
        XCTAssertEqual(importedCard?.startPage, 2)
    }

    func testConvertedEPUBExportsOriginalSourceAndReadableFilename() throws {
        let db = try Database(inMemory: true)
        let media = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))
        let cached = tempDir.appendingPathComponent("abcdef.pdf")
        try Data("PDF cache".utf8).write(to: cached)
        let source = tempDir.appendingPathComponent("original.epub")
        let originalData = Data("Original EPUB bytes".utf8)
        try originalData.write(to: source)
        try source.path.write(to: cached.deletingPathExtension().appendingPathExtension("source_path"), atomically: true, encoding: .utf8)
        let doc = Document(title: "A Proper Book Name", filePath: cached.path, md5: "abcdef", totalPages: 1, documentType: "epub")
        try db.insertDocument(doc)
        let package = tempDir.appendingPathComponent("ebook.marginpkg")
        try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: package)
        let unpacked = tempDir.appendingPathComponent("ebook_unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", package.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("A Proper Book Name.epub")), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("abcdef.pdf").path))
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: tempDir.appendingPathComponent("missing.marginpkg")))
    }

    func testUnchangedImportedPackageExportsIdenticalBytesAndEditsInvalidateIt() throws {
        let db = try Database(inMemory: true)
        let media = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))
        let pdf = tempDir.appendingPathComponent("source.pdf")
        try Data("document bytes".utf8).write(to: pdf)
        let doc = Document(title: "Native Source", filePath: pdf.path, md5: "native-book", totalPages: 1)
        try db.insertDocument(doc)
        let topic = Topic(title: "Native Notebook", bookMD5List: [doc.md5])
        try db.insertTopic(topic)
        let card = NoteCard(topicId: topic.id, bookMD5: doc.md5, title: "Original note")
        try db.insertCard(card)
        let original = tempDir.appendingPathComponent("original.marginpkg")
        try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: original)
        let importedDB = try Database(inMemory: true)
        let result = try MarginNoteImporter(url: original, documentsDestinationDirectory: tempDir.appendingPathComponent("documents"), mediaStorage: media).importInto(importedDB)
        let imported = try XCTUnwrap(result.documents.first)
        let retainedDocument = try XCTUnwrap(importedDB.getDocumentByMD5(md5: imported.md5))
        var visitedTopic = try XCTUnwrap(importedDB.allTopics().first)
        visitedTopic.updatedAt = Date()
        visitedTopic.mindPanX = 123
        visitedTopic.mindZoomScale = 2
        visitedTopic.lastDocumentMD5 = imported.md5
        visitedTopic.bookMD5List.reverse()
        try importedDB.updateTopic(visitedTopic)
        let output = tempDir.appendingPathComponent("reexport.marginpkg")
        try MarginPackageExporter.exportDocument(document: retainedDocument, database: importedDB, mediaStorage: media, destinationURL: output)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: output))
        var edited = try XCTUnwrap(importedDB.getCard(id: card.id))
        edited.notesText = "A new edit must not be lost"
        try importedDB.updateCard(edited)
        XCTAssertNil(try ImportedPackageStore.originalArchive(document: retainedDocument, database: importedDB))
        try MarginPackageExporter.exportDocument(document: retainedDocument, database: importedDB, mediaStorage: media, destinationURL: output)
        XCTAssertNotEqual(try Data(contentsOf: original), try Data(contentsOf: output))
        let editedResult = try MarginNoteImporter(url: output, documentsDestinationDirectory: tempDir.appendingPathComponent("edited_documents")).read()
        XCTAssertEqual(editedResult.cards.first { $0.id == card.id }?.notesText, edited.notesText)
    }

    func testThreeNativeReferencePackagesRoundTripExactly() throws {
        let names = [
            "Ahrens_2017_How-to-take-smart-notes(2026-09-18-19-49-00).marginpkg",
            "Adler_Doren_2014_How to Read a Book(2026-09-18-19-48-24).marginpkg",
            "Save the Cat! _ The Last Book on Screenwriting You'll Ever -- Snyder, Blake -- Lightning Source Inc_ (Tier 1), [N_p_], 2005 -- Michael Wiese(2026-09-18-19-47-30).marginpkg"
        ]
        let sourceDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: sourceDirectory.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Local native reference packages are unavailable")
        }
        let db = try Database(inMemory: true)
        let media = try MediaStorage(directoryURL: tempDir.appendingPathComponent("media"))
        var importedDocuments: [Document] = []
        for name in names {
            let result = try MarginNoteImporter(url: sourceDirectory.appendingPathComponent(name),
                documentsDestinationDirectory: tempDir.appendingPathComponent("documents"), mediaStorage: media).importInto(db)
            importedDocuments.append(try XCTUnwrap(result.documents.first { !$0.filePath.isEmpty }))
        }
        for (index, document) in importedDocuments.enumerated() {
            let stored = try XCTUnwrap(db.getDocumentByMD5(md5: document.md5))
            let output = tempDir.appendingPathComponent("exact-\(index).marginpkg")
            try MarginPackageExporter.exportDocument(document: stored, database: db, mediaStorage: media, destinationURL: output)
            XCTAssertEqual(try Data(contentsOf: sourceDirectory.appendingPathComponent(names[index])), try Data(contentsOf: output), names[index])
        }
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
        XCTAssertEqual(result.cards.filter { $0.title == "L1 Card" || $0.title == "L2 Card" }.count, 2)
        let bookRoots = result.cards.filter { $0.title == "Lecture1" || $0.title == "Lecture2" }
        XCTAssertEqual(bookRoots.count, 2)
        for root in bookRoots {
            XCTAssertEqual(root.mindLinks.count, 1)
            let child = try XCTUnwrap(result.cards.first { $0.id == root.mindLinks.first })
            XCTAssertEqual(child.bookMD5, root.bookMD5)
        }
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
