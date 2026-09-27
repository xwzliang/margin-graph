import XCTest
import PDFKit
import AppKit
@testable import MarginGraphCore

final class EBookConverterTests: XCTestCase {

    func testSupportedExtensionsAndMediaDocumentHelper() {
        let extensions = [
            ("book.epub", "epub", true),
            ("comic.cbz", "comic", true),
            ("manga.cbr", "comic", true),
            ("story.fb2", "fb2", true),
            ("story.zfb2", "fb2", true),
            ("novel.txt", "text", true),
            ("notes.text", "text", true),
            ("guide.md", "markdown", true),
            ("manual.markdown", "markdown", true),
            ("letter.rtf", "rtf", true),
            ("letter.rtfd", "rtf", true),
            ("page.html", "html", true),
            ("page.htm", "html", true),
            ("doc.xhtml", "html", true),
            ("archive.webarchive", "html", true),
            ("kindle.mobi", "mobi", true),
            ("palm.prc", "mobi", true),
            ("document.pdf", "pdf", false),
            ("video.mp4", "video", false)
        ]

        for (filename, expectedType, expectedIsEBook) in extensions {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertEqual(MediaDocumentHelper.documentType(for: url), expectedType, "Failed docType for \(filename)")
            XCTAssertEqual(MediaDocumentHelper.isEBook(url: url), expectedIsEBook, "Failed isEBook for \(filename)")
            XCTAssertTrue(MediaDocumentHelper.isSupportedFile(url: url), "Should be supported file: \(filename)")
        }
    }

    func testCBZArchiveConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CBZ_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 2 test page images
        for i in 1...2 {
            let img = NSImage(size: NSSize(width: 400, height: 600))
            img.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 400, height: 600).fill()
            let str = "Comic Page \(i)" as NSString
            str.draw(at: NSPoint(x: 50, y: 500), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            img.unlockFocus()

            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
                XCTFail("Failed to encode test image")
                return
            }
            let imgPath = tempDir.appendingPathComponent("page_\(i).jpg")
            try jpeg.write(to: imgPath)
        }

        // Zip images into .cbz archive using /usr/bin/zip
        let cbzURL = tempDir.appendingPathComponent("TestComic.cbz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-q", cbzURL.path, "page_1.jpg", "page_2.jpg"]
        try zip.run()
        zip.waitUntilExit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cbzURL.path))

        // Convert via EBookConverter
        let result = try EBookConverter.ensureConvertedPDF(for: cbzURL)
        XCTAssertEqual(result.format, "cbz")
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.title, "TestComic")

        // Verify PDFDocumentManager opens it transparently
        let manager = try PDFDocumentManager(url: cbzURL)
        XCTAssertEqual(manager.pageCount, 2)
        XCTAssertEqual(manager.document.page(at: 0)?.bounds(for: .mediaBox).width, 400)
        XCTAssertEqual(manager.document.page(at: 0)?.bounds(for: .mediaBox).height, 600)
    }

    func testTXTDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TXT_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let txtContent = """
        Chapter 1: The Beginning
        In the quiet town of Riverdale, the morning mist hovered over the cobblestone streets.
        Arthur opened his journal and noted the strange events of the previous night.

        Chapter 2: The Journey
        By midday, the train was speeding toward the capital city.
        New faces entered the carriage, each carrying secrets waiting to be unraveled.
        """

        let txtURL = tempDir.appendingPathComponent("TheMysteriousChronicles.txt")
        try txtContent.write(to: txtURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: txtURL)
        XCTAssertEqual(result.format, "txt")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)
        XCTAssertEqual(result.title, "TheMysteriousChronicles")

        let manager = try PDFDocumentManager(url: txtURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertEqual(manager.outline.count, 2)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Chapter 1") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Chapter 2") }))
    }

    func testMarkdownDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MD_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mdContent = """
        # Swift Systems Programming

        ## Chapter 1: Memory Management
        Swift uses Automatic Reference Counting (ARC) to track and manage app memory usage.

        ```swift
        class Node {
            weak var parent: Node?
        }
        ```

        ## Chapter 2: Concurrency
        Swift 6 introduces strict data race safety and Sendable checking.

        > Safe concurrency eliminates runtime race conditions at compile time.
        """

        let mdURL = tempDir.appendingPathComponent("SwiftBook.md")
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: mdURL)
        XCTAssertEqual(result.format, "md")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)
        XCTAssertEqual(result.title, "Swift Systems Programming")

        let manager = try PDFDocumentManager(url: mdURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertGreaterThanOrEqual(manager.outline.count, 2)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Memory Management") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Concurrency") }))
    }

    func testFB2DocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FB2_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fb2Content = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description>
            <title-info>
              <book-title>Adventures of Sherlock Holmes</book-title>
              <author>
                <first-name>Arthur</first-name>
                <last-name>Conan Doyle</last-name>
              </author>
            </title-info>
          </description>
          <body>
            <section>
              <title><p>Chapter I: A Scandal in Bohemia</p></title>
              <p>To Sherlock Holmes she is always THE woman. I have seldom heard him mention her under any other name.</p>
            </section>
            <section>
              <title><p>Chapter II: The Red-Headed League</p></title>
              <p>I had called upon my friend, Mr. Sherlock Holmes, one day in the autumn of last year.</p>
            </section>
          </body>
        </FictionBook>
        """

        let fb2URL = tempDir.appendingPathComponent("Holmes.fb2")
        try fb2Content.write(to: fb2URL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: fb2URL)
        XCTAssertEqual(result.format, "fb2")
        XCTAssertEqual(result.title, "Adventures of Sherlock Holmes")
        XCTAssertEqual(result.author, "Arthur Conan Doyle")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)

        let manager = try PDFDocumentManager(url: fb2URL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertEqual(manager.title, "Adventures of Sherlock Holmes")
        XCTAssertEqual(manager.outline.count, 2)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Scandal in Bohemia") }))
    }

    func testRTFDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RTF_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let attrStr = NSAttributedString(string: "A Study in Scarlet - Rich Text Format Edition.\n\nBeing a reprint from the reminiscences of John H. Watson, M.D.")
        let rtfData = try attrStr.data(
            from: NSRange(location: 0, length: attrStr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        let rtfURL = tempDir.appendingPathComponent("Scarlet.rtf")
        try rtfData.write(to: rtfURL)

        let result = try EBookConverter.ensureConvertedPDF(for: rtfURL)
        XCTAssertEqual(result.format, "rtf")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)
        XCTAssertEqual(result.title, "Scarlet")

        let manager = try PDFDocumentManager(url: rtfURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testHTMLDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HTML_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Web Programming Guide</title>
        </head>
        <body style="font-family: -apple-system, sans-serif; padding: 40px;">
          <h1>Web Programming Guide</h1>
          <p>This is a complete standalone web manual converted directly to vector PDF.</p>
        </body>
        </html>
        """

        let htmlURL = tempDir.appendingPathComponent("Guide.html")
        try htmlContent.write(to: htmlURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: htmlURL)
        XCTAssertEqual(result.format, "html")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: htmlURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testMOBIDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MOBI_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Construct synthetic PalmDOC / MOBI file:
        // PDB header (78 bytes) + Record offsets (2 records * 8 bytes = 16 bytes)
        // Record 0: Header (PalmDOC compression=1, numTextRecords=1)
        // Record 1: Text HTML content
        var mobiData = Data(count: 78)
        // Set PDB name: "MobiBook"
        let nameBytes = [UInt8]("MobiBook".utf8)
        mobiData.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        // Set numRecords = 2 at offset 76 (UInt16 big endian)
        mobiData[76] = 0x00
        mobiData[77] = 0x02

        // Record 0 offset: 78 + 16 = 94
        let rec0Offset: UInt32 = 94
        var rec0Bytes = [UInt8](repeating: 0, count: 100)
        // Compression = 1 (Uncompressed) at bytes 0..1
        rec0Bytes[0] = 0x00
        rec0Bytes[1] = 0x01
        // Num text records = 1 at bytes 8..9
        rec0Bytes[8] = 0x00
        rec0Bytes[9] = 0x01
        // "MOBI" header at bytes 16..19
        rec0Bytes[16] = 0x4D
        rec0Bytes[17] = 0x4F
        rec0Bytes[18] = 0x42
        rec0Bytes[19] = 0x49
        // Title offset at bytes 84..87 = 92
        rec0Bytes[84] = 0x00
        rec0Bytes[85] = 0x00
        rec0Bytes[86] = 0x00
        rec0Bytes[87] = 92
        // Title length at bytes 88..91 = 8
        rec0Bytes[88] = 0x00
        rec0Bytes[89] = 0x00
        rec0Bytes[90] = 0x00
        rec0Bytes[91] = 8
        // Title text "MobiBook" at bytes 92..99
        for (i, b) in nameBytes.enumerated() {
            rec0Bytes[92 + i] = b
        }

        let htmlText = "<html><body><h1>Mobi Book Chapter</h1><p>This is a native Mobipocket book converted to PDF without dependencies.</p></body></html>"
        let rec1Data = Data(htmlText.utf8)
        let rec1Offset: UInt32 = rec0Offset + UInt32(rec0Bytes.count)

        // Record offset table: 2 entries of 8 bytes each
        var offsetTable = Data()
        // Record 0
        offsetTable.append(contentsOf: [
            UInt8((rec0Offset >> 24) & 0xFF),
            UInt8((rec0Offset >> 16) & 0xFF),
            UInt8((rec0Offset >> 8) & 0xFF),
            UInt8(rec0Offset & 0xFF),
            0, 0, 0, 0
        ])
        // Record 1
        offsetTable.append(contentsOf: [
            UInt8((rec1Offset >> 24) & 0xFF),
            UInt8((rec1Offset >> 16) & 0xFF),
            UInt8((rec1Offset >> 8) & 0xFF),
            UInt8(rec1Offset & 0xFF),
            0, 0, 0, 0
        ])

        mobiData.append(offsetTable)
        mobiData.append(contentsOf: rec0Bytes)
        mobiData.append(rec1Data)

        let mobiURL = tempDir.appendingPathComponent("MobiBook.mobi")
        try mobiData.write(to: mobiURL)

        let result = try EBookConverter.ensureConvertedPDF(for: mobiURL)
        XCTAssertEqual(result.format, "mobi")
        XCTAssertEqual(result.title, "MobiBook")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: mobiURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testPalmDOCLZ77Decompressor() {
        // "ABCD" + distance=4, length=4 (4-3=1 << 2 = 4)
        let testData = Data([0x04, 0x41, 0x42, 0x43, 0x44, 0x84, 0x04])
        let decomp = EBookConverter.decompressPalmDOC(data: testData)
        let str = String(data: decomp, encoding: .ascii)
        XCTAssertEqual(str, "ABCDABCD")
    }
}
