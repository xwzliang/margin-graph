import XCTest
import PDFKit
import SQLite3
@testable import MarginGraphCore

@MainActor
final class PDFPageNumberExportTests: XCTestCase {
    func testExportRemovesTextAndPreservesVectorsFormsMetadataAndCoordinates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        let output = root.appendingPathComponent("clean.pdf")
        let original = fixture()
        try original.write(to: source)
        let before = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(PDFPageNumberFilter().footers(on: try XCTUnwrap(before.page(at: 0))).count, 1)
        XCTAssertEqual(PDFPageNumberFilter().footers(on: try XCTUnwrap(before.page(at: 1))).count, 1)
        try PDFPageNumberExport.write(source: source, destination: output, hidingPageNumbers: true)
        let after = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(after.pageCount, before.pageCount)
        XCTAssertEqual(after.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Footer export test")
        for index in 0..<after.pageCount {
            let old = try XCTUnwrap(before.page(at: index))
            let new = try XCTUnwrap(after.page(at: index))
            XCTAssertEqual(new.bounds(for: .mediaBox), old.bounds(for: .mediaBox))
            XCTAssertEqual(new.bounds(for: .cropBox), old.bounds(for: .cropBox))
            XCTAssertEqual(new.rotation, old.rotation)
            XCTAssertEqual(new.annotations.count, old.annotations.count)
            XCTAssertTrue(PDFPageNumberFilter().footers(on: new).isEmpty)
            XCTAssertNil(new.selection(for: CGRect(x: 0, y: 20, width: 612, height: 45))?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            XCTAssertTrue(new.string?.contains("Body number 42") == true)
        }
        XCTAssertTrue(after.page(at: 0)?.string?.contains("After footer") == true)
        XCTAssertEqual(after.page(at: 0)?.annotations.first?.url?.absoluteString, "https://example.com/")
        // A shared form's second invocation places its number in the body. It must remain selectable.
        XCTAssertTrue(after.page(at: 1)?.selection(for: CGRect(x: 0, y: 220, width: 612, height: 45))?.string?.contains("73") == true)
        let boundsBefore = try XCTUnwrap(before.findString("After footer", withOptions: []).first?.bounds(for: before.page(at: 0)!))
        let boundsAfter = try XCTUnwrap(after.findString("After footer", withOptions: []).first?.bounds(for: after.page(at: 0)!))
        XCTAssertEqual(boundsAfter, boundsBefore)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try PDFPageNumberExport.write(source: source, destination: output, hidingPageNumbers: false)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testPackageUsesSettingAndRecomputesNativeHashIncludingRetainedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Book.pdf")
        try fixture().write(to: source)
        let db = try Database(inMemory: true)
        let md5 = UUID().uuidString
        let doc = Document(id: Document.stableUUID(md5), title: "Book", filePath: source.path, md5: md5, totalPages: 2, documentType: "pdf")
        try db.insertDocument(doc)
        let topic = Topic(title: "Notes", bookMD5List: [md5]); try db.insertTopic(topic)
        let originalPDF = try XCTUnwrap(PDFDocument(url: source))
        let selection = try XCTUnwrap(originalPDF.page(at: 0)?.selection(for: CGRect(x: 0, y: 0, width: 612, height: 792)))
        let card = NoteCard(topicId: topic.id, bookMD5: md5,
            highlightText: PDFHighlightResolver.normalizeExcerptParagraphs(selection), startPage: 0,
            highlightRects: PDFHighlightResolver.lineRects(from: selection, document: originalPDF))
        try db.insertCard(card)
        let media = try MediaStorage(directoryURL: root.appendingPathComponent("media"))
        let originalPackage = root.appendingPathComponent("Original.marginpkg")
        try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: originalPackage, hidesPageNumbers: false)
        // Retain the exact native package just as an unchanged import would.
        let result = MarginNoteImportResult(topics: [topic], documents: [doc], cards: [card], links: [])
        try ImportedPackageStore.retain(url: originalPackage, result: result, database: db)
        XCTAssertNotNil(try ImportedPackageStore.originalArchive(document: doc, database: db))
        let cleanPackage = root.appendingPathComponent("Clean.marginpkg")
        let key = PDFPageNumberPreferences.key(for: md5)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: cleanPackage)
        let unpacked = root.appendingPathComponent("unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", cleanPackage.path, unpacked.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let files = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        let pdfURL = try XCTUnwrap(files.first { $0.pathExtension == "pdf" })
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertTrue(PDFPageNumberFilter().footers(on: pdf.page(at: 0)!).isEmpty)
        let notes = try XCTUnwrap(files.first { $0.pathExtension == "marginnotes" })
        var sqlite: OpaquePointer?; XCTAssertEqual(sqlite3_open(notes.path, &sqlite), SQLITE_OK)
        defer { sqlite3_close(sqlite) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(sqlite, "SELECT ZMD5LONG FROM ZBOOKCONFIG LIMIT 1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), try MarginPackageExporter.nativeBookHash(url: pdfURL))
        var noteStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(sqlite, "SELECT ZHIGHLIGHT_TEXT FROM ZBOOKNOTE WHERE ZHIGHLIGHT_TEXT IS NOT NULL", -1, &noteStatement, nil), SQLITE_OK)
        defer { sqlite3_finalize(noteStatement) }
        XCTAssertEqual(sqlite3_step(noteStatement), SQLITE_ROW)
        let exportedText = String(cString: sqlite3_column_text(noteStatement, 0))
        XCTAssertEqual(exportedText, PDFNotePageNumberCleaner(document: originalPDF).clean(card).highlightText)
        XCTAssertNotEqual(exportedText, card.highlightText)
        UserDefaults.standard.set(false, forKey: key)
        try MarginPackageExporter.exportDocument(document: doc, database: db, mediaStorage: media, destinationURL: cleanPackage)
        XCTAssertEqual(try Data(contentsOf: cleanPackage), try Data(contentsOf: originalPackage))
        XCTAssertEqual(try Data(contentsOf: source), fixture())
    }

    func testFolderHonorsEachDocumentsSetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try fixture().write(to: source)
        let folder = DocumentFolder(name: "Books")
        let hidden = Document(title: "Hidden", filePath: source.path, md5: "hidden", totalPages: 2, folderId: folder.id)
        let visible = Document(title: "Visible", filePath: source.path, md5: "visible", totalPages: 2, folderId: folder.id)
        let db = try Database(inMemory: true)
        let media = try MediaStorage(directoryURL: root.appendingPathComponent("media"))
        let output = root.appendingPathComponent("Folder.marginpkg")
        try MarginPackageExporter.exportFolder(folder: folder, allFolders: [folder], allDocuments: [hidden, visible],
            database: db, mediaStorage: media, destinationURL: output, hiddenPageNumberDocumentMD5s: [hidden.md5])
        let unpacked = root.appendingPathComponent("unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, unpacked.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let clean = try XCTUnwrap(PDFDocument(url: unpacked.appendingPathComponent("Books/Hidden.pdf")))
        XCTAssertTrue(PDFPageNumberFilter().footers(on: clean.page(at: 0)!).isEmpty)
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("Books/Visible.pdf")), fixture())
    }

    func testUnsupportedContentFailsWithoutOverwritingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("output.pdf")
        try fixture(inlineImage: true).write(to: source)
        let sentinel = Data("existing export".utf8); try sentinel.write(to: output)
        XCTAssertThrowsError(try PDFPageNumberExport.write(source: source, destination: output, hidingPageNumbers: true))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertThrowsError(try PDFPageNumberExport.write(source: source, destination: source, hidingPageNumbers: true))
    }

    private func fixture(inlineImage: Bool = false) -> Data {
        func stream(_ content: String, extra: String = "") -> String {
            "<< /Length \(content.utf8.count) \(extra) >>\nstream\n\(content)\nendstream"
        }
        let first = "0.2 0.5 0.8 rg 20 350 80 30 re f 0 g BT /F1 14 Tf 1 0 0 1 50 700 Tm (Body number 42) Tj 0 -650 Td [(4) 10 (2)] TJ"
        let second = "0 550 Td (After footer) Tj ET" + (inlineImage ? "\nq 1 0 0 1 300 300 cm BI /W 1 /H 1 /BPC 8 /CS /G ID x EI Q" : "")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /Contents [6 0 R 7 0 R] /Annots [10 0 R] /CropBox [10 10 602 782] >>",
            "<< /Type /Page /Parent 2 0 R /Contents 8 0 R /Resources << /XObject << /Shared 9 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream(first), stream(second),
            stream("q /Shared Do Q q 1 0 0 1 0 200 cm /Shared Do Q"),
            stream("BT /F1 14 Tf 1 0 0 1 50 450 Tm (Body number 42) Tj 0 -430 Td (73) Tj ET",
                   extra: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 0 20] /Resources << /Font << /F1 5 0 R >> >>"),
            "<< /Type /Annot /Subtype /Link /Rect [50 697 160 715] /Border [0 0 0] /A << /S /URI /URI (https://example.com/) >> /P 3 0 R >>",
            "<< /Title (Footer export test) >>"
        ]
        var result = "%PDF-1.7\n", offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(result.utf8.count); result += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let xref = result.utf8.count
        result += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { result += String(format: "%010d 00000 n \n", offset) }
        result += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 11 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(result.utf8)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
