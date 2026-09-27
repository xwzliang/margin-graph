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
            ("report.docx", "docx", true),
            ("legacy.doc", "docx", true),
            ("paper.odt", "odt", true),
            ("comic.cbt", "comic", true),
            ("palm.pdb", "pdb", true),
            ("kindle.azw", "azw3", true),
            ("book.azw3", "azw3", true),
            ("book.kf8", "azw3", true),
            ("help.chm", "chm", true),
            ("scan.djvu", "djvu", true),
            ("scan.djv", "djvu", true),
            ("math.tex", "latex", true),
            ("paper.latex", "latex", true),
            ("docs.adoc", "asciidoc", true),
            ("manual.asciidoc", "asciidoc", true),
            ("notes.org", "org", true),
            ("spec.rst", "rst", true),
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

    func testOfficeDOCXAndODTConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OFFICE_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Test DOCX
        let docxText = NSAttributedString(string: "Quantum Computing Principles\n\nChapter 1: Superposition\nQubits can exist in a linear combination of states |0> and |1>.")
        let docxData = try docxText.data(from: NSRange(location: 0, length: docxText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let docxURL = tempDir.appendingPathComponent("QuantumComputing.docx")
        try docxData.write(to: docxURL)

        let docxResult = try EBookConverter.ensureConvertedPDF(for: docxURL)
        XCTAssertEqual(docxResult.format, "docx")
        XCTAssertGreaterThanOrEqual(docxResult.pageCount, 1)
        let docxManager = try PDFDocumentManager(url: docxURL)
        XCTAssertEqual(docxManager.pageCount, docxResult.pageCount)

        // 2. Test ODT
        let odtText = NSAttributedString(string: "Open Document Specification\n\nSection 1: XML Schema\nOpenDocument formats are zipped XML packages.")
        let odtData = try odtText.data(from: NSRange(location: 0, length: odtText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        let odtURL = tempDir.appendingPathComponent("OpenDoc.odt")
        try odtData.write(to: odtURL)

        let odtResult = try EBookConverter.ensureConvertedPDF(for: odtURL)
        XCTAssertEqual(odtResult.format, "odt")
        XCTAssertGreaterThanOrEqual(odtResult.pageCount, 1)
        let odtManager = try PDFDocumentManager(url: odtURL)
        XCTAssertEqual(odtManager.pageCount, odtResult.pageCount)
    }

    func testCBTComicTarConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CBT_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 2 test comic images
        for i in 1...2 {
            let img = NSImage(size: NSSize(width: 420, height: 620))
            img.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 420, height: 620).fill()
            let str = "CBT Comic Page \(i)" as NSString
            str.draw(at: NSPoint(x: 40, y: 520), withAttributes: [.font: NSFont.systemFont(ofSize: 22)])
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

        // Create .cbt tar archive using /usr/bin/tar
        let cbtURL = tempDir.appendingPathComponent("SpiderHero.cbt")
        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProc.currentDirectoryURL = tempDir
        tarProc.arguments = ["-cf", cbtURL.path, "page_1.jpg", "page_2.jpg"]
        try tarProc.run()
        tarProc.waitUntilExit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cbtURL.path))

        let result = try EBookConverter.ensureConvertedPDF(for: cbtURL)
        XCTAssertEqual(result.format, "cbt")
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.title, "SpiderHero")

        let manager = try PDFDocumentManager(url: cbtURL)
        XCTAssertEqual(manager.pageCount, 2)
    }

    func testPDBDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PDB_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var pdbData = Data(count: 78)
        let nameBytes = [UInt8]("PalmDocBook".utf8)
        pdbData.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        pdbData[76] = 0x00
        pdbData[77] = 0x02 // numRecords = 2

        let rec0Offset: UInt32 = 94
        var rec0Bytes = [UInt8](repeating: 0, count: 16)
        rec0Bytes[0] = 0x00
        rec0Bytes[1] = 0x01 // compression = 1 (Uncompressed)
        rec0Bytes[8] = 0x00
        rec0Bytes[9] = 0x01 // numTextRecords = 1

        let textContent = "\\h=Prologue\\This is a PalmDOC eBook formatted with Peanut Markup Language.\\p\\h=Chapter One\\The adventure begins under the Palm OS system."
        let rec1Data = Data(textContent.utf8)
        let rec1Offset: UInt32 = rec0Offset + UInt32(rec0Bytes.count)

        var offsetTable = Data()
        offsetTable.append(contentsOf: [
            UInt8((rec0Offset >> 24) & 0xFF), UInt8((rec0Offset >> 16) & 0xFF),
            UInt8((rec0Offset >> 8) & 0xFF), UInt8(rec0Offset & 0xFF),
            0, 0, 0, 0
        ])
        offsetTable.append(contentsOf: [
            UInt8((rec1Offset >> 24) & 0xFF), UInt8((rec1Offset >> 16) & 0xFF),
            UInt8((rec1Offset >> 8) & 0xFF), UInt8(rec1Offset & 0xFF),
            0, 0, 0, 0
        ])

        pdbData.append(offsetTable)
        pdbData.append(contentsOf: rec0Bytes)
        pdbData.append(rec1Data)

        let pdbURL = tempDir.appendingPathComponent("PalmDocBook.pdb")
        try pdbData.write(to: pdbURL)

        let result = try EBookConverter.ensureConvertedPDF(for: pdbURL)
        XCTAssertEqual(result.format, "pdb")
        XCTAssertEqual(result.title, "PalmDocBook")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: pdbURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testAZW3DocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AZW3_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var azwData = Data(count: 78)
        let nameBytes = [UInt8]("KindleKF8Book".utf8)
        azwData.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        azwData[76] = 0x00
        azwData[77] = 0x02

        let rec0Offset: UInt32 = 94
        var rec0Bytes = [UInt8](repeating: 0, count: 100)
        rec0Bytes[0] = 0x00
        rec0Bytes[1] = 0x01 // compression = 1
        rec0Bytes[8] = 0x00
        rec0Bytes[9] = 0x01
        rec0Bytes[16] = 0x4D; rec0Bytes[17] = 0x4F; rec0Bytes[18] = 0x42; rec0Bytes[19] = 0x49 // "MOBI"
        rec0Bytes[84] = 0x00; rec0Bytes[85] = 0x00; rec0Bytes[86] = 0x00; rec0Bytes[87] = 92
        rec0Bytes[88] = 0x00; rec0Bytes[89] = 0x00; rec0Bytes[90] = 0x00; rec0Bytes[91] = 8
        for (i, b) in [UInt8]("KF8Title".utf8).enumerated() {
            rec0Bytes[92 + i] = b
        }

        let htmlText = "<html><body><h1>KF8 Chapter</h1><p>Amazon Kindle Format 8 natively supported.</p><mbp:pagebreak/><h1>KF8 Chapter 2</h1><p>Second chapter.</p></body></html>"
        let rec1Data = Data(htmlText.utf8)
        let rec1Offset: UInt32 = rec0Offset + UInt32(rec0Bytes.count)

        var offsetTable = Data()
        offsetTable.append(contentsOf: [
            UInt8((rec0Offset >> 24) & 0xFF), UInt8((rec0Offset >> 16) & 0xFF),
            UInt8((rec0Offset >> 8) & 0xFF), UInt8(rec0Offset & 0xFF),
            0, 0, 0, 0
        ])
        offsetTable.append(contentsOf: [
            UInt8((rec1Offset >> 24) & 0xFF), UInt8((rec1Offset >> 16) & 0xFF),
            UInt8((rec1Offset >> 8) & 0xFF), UInt8(rec1Offset & 0xFF),
            0, 0, 0, 0
        ])

        azwData.append(offsetTable)
        azwData.append(contentsOf: rec0Bytes)
        azwData.append(rec1Data)

        let azwURL = tempDir.appendingPathComponent("KindleBook.azw3")
        try azwData.write(to: azwURL)

        let result = try EBookConverter.ensureConvertedPDF(for: azwURL)
        XCTAssertEqual(result.format, "azw3")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: azwURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testLaTeXDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TEX_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let latexSource = """
        \\documentclass{article}
        \\title{Advanced Quantum Computing}
        \\author{Richard Feynman}
        \\date{May 1982}
        \\begin{document}
        \\maketitle

        \\section{Quantum Simulators}
        Nature isn't classical, dammit, and if you want to make a simulation of nature, you'd better make it quantum mechanical.

        \\begin{equation}
        i \\hbar \\frac{\\partial}{\\partial t} \\Psi = \\hat{H} \\Psi
        \\end{equation}

        \\section{Computational Complexity}
        BQP denotes bounded-error quantum polynomial time.
        \\begin{itemize}
        \\item Shor's algorithm for factoring
        \\item Grover's algorithm for database search
        \\end{itemize}
        \\end{document}
        """

        let texURL = tempDir.appendingPathComponent("QuantumPaper.tex")
        try latexSource.write(to: texURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: texURL)
        XCTAssertEqual(result.format, "tex")
        XCTAssertEqual(result.title, "Advanced Quantum Computing")
        XCTAssertEqual(result.author, "Richard Feynman")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)

        let manager = try PDFDocumentManager(url: texURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertEqual(manager.title, "Advanced Quantum Computing")
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Quantum Simulators") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Computational Complexity") }))
    }

    func testAsciiDocDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ADOC_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let adocSource = """
        = Cloud Native Architecture
        :author: Martin Fowler

        == Microservices Overview
        Microservices structure an application as a collection of loosely coupled services.

        NOTE: Ensure independent deployment pipelines for each service.

        == Data Management
        Each microservice should own its private database schema.

        [source,swift]
        ----
        struct ServiceConfig {
            let host: String
            let port: Int
        }
        ----
        """

        let adocURL = tempDir.appendingPathComponent("Architecture.adoc")
        try adocSource.write(to: adocURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: adocURL)
        XCTAssertEqual(result.format, "adoc")
        XCTAssertEqual(result.title, "Cloud Native Architecture")
        XCTAssertEqual(result.author, "Martin Fowler")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)

        let manager = try PDFDocumentManager(url: adocURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Microservices Overview") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Data Management") }))
    }

    func testOrgModeDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ORG_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let orgSource = """
        #+TITLE: Systems Research Notes
        #+AUTHOR: Alan Turing

        * Machine Intelligence
        TODO Propose the imitation game for computing machinery.
        The question whether machines can think is investigated.

        * Cryptanalysis
        DONE Formalize banburismus statistical metric.
        Decryption of Enigma traffic achieved with Bombe machines.
        """

        let orgURL = tempDir.appendingPathComponent("Research.org")
        try orgSource.write(to: orgURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: orgURL)
        XCTAssertEqual(result.format, "org")
        XCTAssertEqual(result.title, "Systems Research Notes")
        XCTAssertEqual(result.author, "Alan Turing")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)

        let manager = try PDFDocumentManager(url: orgURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Machine Intelligence") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Cryptanalysis") }))
    }

    func testRSTDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RST_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rstSource = """
        Sphinx Documentation Guide
        ==========================

        Getting Started
        ---------------
        Install the package using standard package tools.

        .. note::
           Make sure python 3.10 or later is installed.

        Configuration
        -------------
        Customize your ``conf.py`` file with project metadata.
        """

        let rstURL = tempDir.appendingPathComponent("Guide.rst")
        try rstSource.write(to: rstURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: rstURL)
        XCTAssertEqual(result.format, "rst")
        XCTAssertEqual(result.title, "Sphinx Documentation Guide")
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)

        let manager = try PDFDocumentManager(url: rstURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Getting Started") }))
        XCTAssertTrue(manager.outline.contains(where: { $0.title.contains("Configuration") }))
    }

    func testMarkdownTablesTaskListsAndStrikethrough() throws {
        let md = """
        # Specifications

        ## Component Table
        | Component | Status | Speed |
        | --- | --- | --- |
        | Parser | Active | Fast |
        | Renderer | Stable | Optimal |

        ## Project Tasks
        - [x] Implement Office formats
        - [ ] Verify DJVU rendering
        - [x] Enhanced ~~old~~ modern Markdown
        """

        let html = EBookConverter.markdownToHTML(md)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>Component</th>"))
        XCTAssertTrue(html.contains("<td>Active</td>"))
        XCTAssertTrue(html.contains("type=\"checkbox\" checked"))
        XCTAssertTrue(html.contains("type=\"checkbox\" disabled"))
        XCTAssertTrue(html.contains("<del>old</del>"))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MD_EXT_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mdURL = tempDir.appendingPathComponent("Specs.md")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try EBookConverter.ensureConvertedPDF(for: mdURL)
        XCTAssertGreaterThanOrEqual(result.pageCount, 2)
    }

    func testCHMDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CHM_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Construct synthetic ITSF CHM file with embedded HTML topics
        var chmData = Data([0x49, 0x54, 0x53, 0x46]) // "ITSF"
        chmData.append(contentsOf: [UInt8](repeating: 0, count: 120))
        let htmlTopic = "<html><head><title>Help Topic 1</title></head><body><h1>Help Topic 1</h1><p>CHM native documentation topic.</p></body></html>"
        chmData.append(Data(htmlTopic.utf8))

        let chmURL = tempDir.appendingPathComponent("SoftwareHelp.chm")
        try chmData.write(to: chmURL)

        let result = try EBookConverter.ensureConvertedPDF(for: chmURL)
        XCTAssertEqual(result.format, "chm")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: chmURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }

    func testDjVuDocumentConversion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DJVU_TEST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Construct synthetic AT&T FORM DJVU chunk with INFO and TXTz chunk
        var djvuData = Data([0x41, 0x54, 0x26, 0x54]) // "AT&T"
        djvuData.append(contentsOf: [0x46, 0x4F, 0x52, 0x4D]) // "FORM"
        // Form length placeholder
        djvuData.append(contentsOf: [0x00, 0x00, 0x00, 0x80])
        djvuData.append(contentsOf: [0x44, 0x4A, 0x56, 0x55]) // "DJVU"

        // INFO chunk (10 bytes)
        djvuData.append(contentsOf: [0x49, 0x4E, 0x46, 0x4F]) // "INFO"
        djvuData.append(contentsOf: [0x00, 0x00, 0x00, 0x0A]) // length 10
        djvuData.append(contentsOf: [0x06, 0x40, 0x08, 0x20, 0x18, 0x00, 0x01, 0x2C, 0x00, 0x00])

        // TXTz chunk with zlib compressed text
        let sexpr = "(page 0 0 1600 2200 (para (line (word \"DjVu\") (word \"Scanned\") (word \"Document\"))))"
        let compressedText = try! (Data(sexpr.utf8) as NSData).compressed(using: .zlib) as Data
        djvuData.append(contentsOf: [0x54, 0x58, 0x54, 0x7A]) // "TXTz"
        let txtLen = UInt32(compressedText.count)
        djvuData.append(contentsOf: [
            UInt8((txtLen >> 24) & 0xFF), UInt8((txtLen >> 16) & 0xFF),
            UInt8((txtLen >> 8) & 0xFF), UInt8(txtLen & 0xFF)
        ])
        djvuData.append(compressedText)

        let djvuURL = tempDir.appendingPathComponent("ScannedBook.djvu")
        try djvuData.write(to: djvuURL)

        let result = try EBookConverter.ensureConvertedPDF(for: djvuURL)
        XCTAssertEqual(result.format, "djvu")
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)

        let manager = try PDFDocumentManager(url: djvuURL)
        XCTAssertEqual(manager.pageCount, result.pageCount)
    }
}
