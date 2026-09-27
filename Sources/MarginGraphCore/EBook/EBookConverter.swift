import Foundation
import AppKit
import WebKit
import PDFKit
import CryptoKit

public struct ConvertedEBookResult: Sendable {
    public let originalURL: URL
    public let pdfURL: URL
    public let md5: String
    public let title: String
    public let author: String
    public let pageCount: Int
    public let format: String

    public init(
        originalURL: URL,
        pdfURL: URL,
        md5: String,
        title: String,
        author: String,
        pageCount: Int,
        format: String = "ebook"
    ) {
        self.originalURL = originalURL
        self.pdfURL = pdfURL
        self.md5 = md5
        self.title = title
        self.author = author
        self.pageCount = pageCount
        self.format = format
    }
}

public typealias ConvertedEPUBResult = ConvertedEBookResult

public enum EBookConverterError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case noConverterAvailable

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "EBook file not found at: \(path)"
        case .unsupportedFormat(let ext):
            return "Unsupported ebook format: .\(ext)"
        case .conversionFailed(let message):
            return "Failed to convert ebook to PDF: \(message)"
        case .noConverterAvailable:
            return "No converter available on system."
        }
    }
}

public typealias EPUBConverterError = EBookConverterError

public final class EBookConverter: Sendable {

    public static let supportedExtensions: Set<String> = [
        "epub",
        "cbz", "cbr",
        "fb2", "zfb2",
        "txt", "text",
        "md", "markdown",
        "rtf", "rtfd",
        "html", "htm", "xhtml", "webarchive",
        "mobi", "prc"
    ]

    public static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/homebrew/opt/python/libexec/bin/\(name)"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty, FileManager.default.isExecutableFile(atPath: str) {
                    return URL(fileURLWithPath: str)
                }
            }
        }
        return nil
    }

    public static func documentsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let docs = appSupport.appendingPathComponent("MarginGraph/Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    public static func ensureConvertedPDF(for ebookURL: URL) throws -> ConvertedEBookResult {
        guard FileManager.default.fileExists(atPath: ebookURL.path) else {
            throw EBookConverterError.fileNotFound(ebookURL.path)
        }

        let ext = ebookURL.pathExtension.lowercased()
        guard isSupported(url: ebookURL) else {
            throw EBookConverterError.unsupportedFormat(ext)
        }

        let md5 = MediaDocumentHelper.computeFileMD5(url: ebookURL)
        let docsDir = documentsDirectory()
        let targetPDF = docsDir.appendingPathComponent("\(md5).pdf")

        // If converted PDF already exists and is non-empty, use it immediately
        if FileManager.default.fileExists(atPath: targetPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: targetPDF.path),
           let size = attrs[.size] as? Int64, size > 1024,
           let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 {
            let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
            let fallbackTitle = ebookURL.deletingPathExtension().lastPathComponent
            let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle
            return ConvertedEBookResult(
                originalURL: ebookURL,
                pdfURL: targetPDF,
                md5: md5,
                title: title,
                author: authorAttr ?? "",
                pageCount: doc.pageCount,
                format: ext
            )
        }

        // Perform format-specific native conversion
        switch ext {
        case "epub":
            try convertEPUB(epubURL: ebookURL, targetPDF: targetPDF)
        case "cbz", "cbr":
            try convertCBZ(cbzURL: ebookURL, targetPDF: targetPDF)
        case "fb2", "zfb2":
            try convertFB2(fb2URL: ebookURL, targetPDF: targetPDF)
        case "txt", "text":
            try convertTXT(txtURL: ebookURL, targetPDF: targetPDF)
        case "md", "markdown":
            try convertMarkdown(mdURL: ebookURL, targetPDF: targetPDF)
        case "rtf", "rtfd":
            try convertRTF(rtfURL: ebookURL, targetPDF: targetPDF)
        case "html", "htm", "xhtml", "webarchive":
            try convertHTML(htmlURL: ebookURL, targetPDF: targetPDF)
        case "mobi", "prc":
            try convertMOBI(mobiURL: ebookURL, targetPDF: targetPDF)
        default:
            throw EBookConverterError.unsupportedFormat(ext)
        }

        guard FileManager.default.fileExists(atPath: targetPDF.path),
              let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 else {
            throw EBookConverterError.conversionFailed("Conversion produced empty or invalid PDF")
        }

        // Write MD5 sidecars
        let sidecarPDF = targetPDF.appendingPathExtension("md5")
        try? md5.write(to: sidecarPDF, atomically: true, encoding: .utf8)
        let sidecarEBook = ebookURL.appendingPathExtension("md5")
        try? md5.write(to: sidecarEBook, atomically: true, encoding: .utf8)
        let sidecarFormat = targetPDF.deletingPathExtension().appendingPathExtension("format")
        try? ext.write(to: sidecarFormat, atomically: true, encoding: .utf8)

        let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let fallbackTitle = ebookURL.deletingPathExtension().lastPathComponent
        let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle

        return ConvertedEBookResult(
            originalURL: ebookURL,
            pdfURL: targetPDF,
            md5: md5,
            title: title,
            author: authorAttr ?? "",
            pageCount: doc.pageCount,
            format: ext
        )
    }

    // MARK: - 1. EPUB Converter

    public static func convertEPUB(epubURL: URL, targetPDF: URL) throws {
        var conversionError: String? = nil

        // Method 1: PyMuPDF (fast, if user has Python+PyMuPDF)
        if ProcessInfo.processInfo.environment["FORCE_NATIVE_EPUB"] != "1",
           let pythonURL = findExecutable(named: "python3") {
            do {
                try convertWithPyMuPDF(pythonURL: pythonURL, epubPath: epubURL.path, pdfPath: targetPDF.path)
            } catch {
                conversionError = error.localizedDescription
            }
        }

        // Method 2: Native WebKit-based engine (100% built-in, zero dependencies)
        let pdfCreated = FileManager.default.fileExists(atPath: targetPDF.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024

        if !pdfCreated {
            do {
                try convertWithNativeWebKitEPUB(epubURL: epubURL, targetPDF: targetPDF)
            } catch {
                conversionError = (conversionError != nil ? "\(conversionError!) | " : "") + "Native WebKit: \(error.localizedDescription)"
            }
        }

        // Method 3: Calibre fallback if available
        let nativeCreated = FileManager.default.fileExists(atPath: targetPDF.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024

        if !nativeCreated {
            if let calibreURL = findExecutable(named: "ebook-convert") {
                do {
                    try convertWithCalibre(calibreURL: calibreURL, epubPath: epubURL.path, pdfPath: targetPDF.path)
                } catch {
                    conversionError = (conversionError != nil ? "\(conversionError!) | " : "") + "Calibre: \(error.localizedDescription)"
                }
            }
        }

        guard FileManager.default.fileExists(atPath: targetPDF.path),
              let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 else {
            throw EBookConverterError.conversionFailed(conversionError ?? "Unknown EPUB conversion failure")
        }
    }

    public static func convertWithNativeWebKit(epubURL: URL, targetPDF: URL) throws {
        try convertWithNativeWebKitEPUB(epubURL: epubURL, targetPDF: targetPDF)
    }

    private static func convertWithNativeWebKitEPUB(epubURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUB_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", epubURL.path, "-d", tempDir.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unzip failed"
            throw EBookConverterError.conversionFailed("Failed to unpack EPUB: \(err)")
        }

        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path),
              let containerStr = try? String(contentsOf: containerURL, encoding: .utf8) else {
            throw EBookConverterError.conversionFailed("Invalid EPUB: missing META-INF/container.xml")
        }

        var opfRelPath = "OEBPS/content.opf"
        if let match = containerStr.range(of: "full-path=\"([^\"]+)\"", options: .regularExpression) {
            let sub = containerStr[match]
            opfRelPath = String(sub.dropFirst(11).dropLast(1))
        }

        let opfURL = tempDir.appendingPathComponent(opfRelPath)
        guard FileManager.default.fileExists(atPath: opfURL.path),
              let opfStr = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw EBookConverterError.conversionFailed("Invalid EPUB: OPF file not found at \(opfRelPath)")
        }

        let baseDir = opfURL.deletingLastPathComponent()

        var bookTitle = epubURL.deletingPathExtension().lastPathComponent
        if let tRange = opfStr.range(of: "<dc:title[^>]*>([^<]+)</dc:title>", options: .regularExpression) {
            let raw = opfStr[tRange]
            if let start = raw.firstIndex(of: ">"), let end = raw.lastIndex(of: "<"), start < end {
                let extracted = String(raw[raw.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty { bookTitle = extracted }
            }
        }

        var bookAuthor = ""
        if let aRange = opfStr.range(of: "<dc:creator[^>]*>([^<]+)</dc:creator>", options: .regularExpression) {
            let raw = opfStr[aRange]
            if let start = raw.firstIndex(of: ">"), let end = raw.lastIndex(of: "<"), start < end {
                bookAuthor = String(raw[raw.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var manifest: [String: String] = [:]
        var tocHref: String? = nil

        let itemRegex1 = try NSRegularExpression(pattern: "<item\\s+[^>]*id=\"([^\"]+)\"[^>]*href=\"([^\"]+)\"", options: .caseInsensitive)
        let matches1 = itemRegex1.matches(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count))
        for m in matches1 {
            if let idR = Range(m.range(at: 1), in: opfStr), let hrefR = Range(m.range(at: 2), in: opfStr) {
                let id = String(opfStr[idR])
                let href = String(opfStr[hrefR])
                manifest[id] = href
                if id.lowercased() == "ncx" || href.lowercased().hasSuffix(".ncx") || href.lowercased().contains("toc.") {
                    tocHref = href
                }
            }
        }
        let itemRegex2 = try NSRegularExpression(pattern: "<item\\s+[^>]*href=\"([^\"]+)\"[^>]*id=\"([^\"]+)\"", options: .caseInsensitive)
        let matches2 = itemRegex2.matches(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count))
        for m in matches2 {
            if let hrefR = Range(m.range(at: 1), in: opfStr), let idR = Range(m.range(at: 2), in: opfStr) {
                let id = String(opfStr[idR])
                let href = String(opfStr[hrefR])
                manifest[id] = href
                if id.lowercased() == "ncx" || href.lowercased().hasSuffix(".ncx") || href.lowercased().contains("toc.") {
                    tocHref = href
                }
            }
        }

        var spineHrefs: [String] = []
        let spineRegex = try NSRegularExpression(pattern: "<itemref\\s+[^>]*idref=\"([^\"]+)\"", options: .caseInsensitive)
        let spineMatches = spineRegex.matches(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count))
        for m in spineMatches {
            if let idrefR = Range(m.range(at: 1), in: opfStr) {
                let idref = String(opfStr[idrefR])
                if let href = manifest[idref] {
                    spineHrefs.append(href)
                }
            }
        }

        guard !spineHrefs.isEmpty else {
            throw EBookConverterError.conversionFailed("Invalid EPUB: no readable chapters found in spine")
        }

        var parsedTOC: [(title: String, href: String)] = []
        if let tocHref = tocHref {
            let tocURL = baseDir.appendingPathComponent(tocHref)
            if let tocData = try? Data(contentsOf: tocURL) {
                parsedTOC = parseTOCItems(data: tocData)
            }
        }

        let chapterURLs = spineHrefs.map { baseDir.appendingPathComponent($0) }
        let tocMapped = parsedTOC.map { item -> (title: String, targetURL: URL) in
            let cleanHref = item.href.components(separatedBy: "#").first ?? item.href
            return (title: item.title, targetURL: baseDir.appendingPathComponent(cleanHref))
        }

        try renderHTMLChapters(
            chapterURLs: chapterURLs,
            readAccessURL: tempDir,
            title: bookTitle,
            author: bookAuthor,
            tocItems: tocMapped,
            targetPDF: targetPDF
        )
    }

    // MARK: - 2. CBZ / CBR (Comic Book Archive) Converter

    public static func convertCBZ(cbzURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("COMIC_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", cbzURL.path, "-d", tempDir.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unzip failed"
            throw EBookConverterError.conversionFailed("Failed to unpack comic archive: \(err)")
        }

        let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "tiff", "tif", "bmp"]
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw EBookConverterError.conversionFailed("Unable to read extracted comic contents")
        }

        var imageURLs: [URL] = []
        var comicTitle: String? = nil
        var comicWriter: String? = nil

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            if filename.hasPrefix(".") || fileURL.path.contains("__MACOSX") { continue }

            if filename.lowercased() == "comicinfo.xml",
               let xmlStr = try? String(contentsOf: fileURL, encoding: .utf8) {
                if let tRange = xmlStr.range(of: "<Title>([^<]+)</Title>", options: .regularExpression) {
                    let sub = xmlStr[tRange]
                    if let start = sub.firstIndex(of: ">"), let end = sub.lastIndex(of: "<"), start < end {
                        comicTitle = String(sub[sub.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if let wRange = xmlStr.range(of: "<Writer>([^<]+)</Writer>", options: .regularExpression) {
                    let sub = xmlStr[wRange]
                    if let start = sub.firstIndex(of: ">"), let end = sub.lastIndex(of: "<"), start < end {
                        comicWriter = String(sub[sub.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }

            let ext = fileURL.pathExtension.lowercased()
            if supportedImageExtensions.contains(ext) {
                imageURLs.append(fileURL)
            }
        }

        guard !imageURLs.isEmpty else {
            throw EBookConverterError.conversionFailed("No valid comic page images found in archive")
        }

        // Sort images in natural reading order (page_1, page_2, page_10...)
        imageURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let masterPDF = PDFDocument()
        for imgURL in imageURLs {
            if let image = NSImage(contentsOf: imgURL), let page = PDFPage(image: image) {
                masterPDF.insert(page, at: masterPDF.pageCount)
            }
        }

        guard masterPDF.pageCount > 0 else {
            throw EBookConverterError.conversionFailed("Failed to create PDF pages from comic images")
        }

        let fallbackTitle = cbzURL.deletingPathExtension().lastPathComponent
        let finalTitle = (comicTitle?.isEmpty == false ? comicTitle : nil) ?? fallbackTitle
        let finalAuthor = comicWriter ?? ""

        masterPDF.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: finalTitle,
            PDFDocumentAttribute.authorAttribute: finalAuthor
        ]

        guard masterPDF.write(to: targetPDF) else {
            throw EBookConverterError.conversionFailed("Failed to save comic PDF to \(targetPDF.path)")
        }
    }

    // MARK: - 3. FB2 / FB2.ZIP (FictionBook 2.0) Converter

    public static func convertFB2(fb2URL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FB2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var rawXMLData: Data? = nil
        if fb2URL.pathExtension.lowercased() == "zfb2" || fb2URL.path.lowercased().hasSuffix(".fb2.zip") {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", fb2URL.path, "-d", tempDir.path]
            try unzip.run()
            unzip.waitUntilExit()

            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension.lowercased() == "fb2" {
                        rawXMLData = try? Data(contentsOf: fileURL)
                        break
                    }
                }
            }
        } else {
            rawXMLData = try? Data(contentsOf: fb2URL)
        }

        guard let xmlData = rawXMLData, let xmlStr = String(data: xmlData, encoding: .utf8) ?? String(data: xmlData, encoding: .windowsCP1251) ?? String(data: xmlData, encoding: .isoLatin1) else {
            throw EBookConverterError.conversionFailed("Unable to decode FB2 XML text")
        }

        // 1. Metadata
        var title = fb2URL.deletingPathExtension().lastPathComponent
        if let tRange = xmlStr.range(of: "<book-title>([^<]+)</book-title>", options: .regularExpression) {
            let sub = xmlStr[tRange]
            if let start = sub.firstIndex(of: ">"), let end = sub.lastIndex(of: "<"), start < end {
                let parsed = String(sub[sub.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !parsed.isEmpty { title = parsed }
            }
        }

        var author = ""
        var firstName = ""
        var lastName = ""
        if let fnRange = xmlStr.range(of: "<first-name>([^<]+)</first-name>", options: .regularExpression) {
            let sub = xmlStr[fnRange]
            if let s = sub.firstIndex(of: ">"), let e = sub.lastIndex(of: "<"), s < e {
                firstName = String(sub[sub.index(after: s)..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let lnRange = xmlStr.range(of: "<last-name>([^<]+)</last-name>", options: .regularExpression) {
            let sub = xmlStr[lnRange]
            if let s = sub.firstIndex(of: ">"), let e = sub.lastIndex(of: "<"), s < e {
                lastName = String(sub[sub.index(after: s)..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        author = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")

        // 2. Extract Base64 Binaries
        let binaryRegex = try NSRegularExpression(pattern: "<binary\\s+[^>]*id=\"([^\"]+)\"[^>]*>([A-Za-z0-9+/=\\s]+)</binary>", options: .caseInsensitive)
        let binMatches = binaryRegex.matches(in: xmlStr, options: [], range: NSRange(location: 0, length: xmlStr.utf16.count))
        for m in binMatches {
            if let idR = Range(m.range(at: 1), in: xmlStr), let dataR = Range(m.range(at: 2), in: xmlStr) {
                let binID = String(xmlStr[idR])
                let base64 = String(xmlStr[dataR]).components(separatedBy: .whitespacesAndNewlines).joined()
                if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    let outURL = tempDir.appendingPathComponent(binID)
                    try? data.write(to: outURL)
                }
            }
        }

        // 3. Extract Sections / Chapters
        var sections: [String] = []
        let sectionRegex = try NSRegularExpression(pattern: "<section>([\\s\\S]*?)</section>", options: .caseInsensitive)
        let sMatches = sectionRegex.matches(in: xmlStr, options: [], range: NSRange(location: 0, length: xmlStr.utf16.count))
        for m in sMatches {
            if let r = Range(m.range(at: 1), in: xmlStr) {
                sections.append(String(xmlStr[r]))
            }
        }

        if sections.isEmpty {
            if let bodyRange = xmlStr.range(of: "<body>([\\s\\S]*?)</body>", options: .regularExpression) {
                let sub = xmlStr[bodyRange]
                sections.append(String(sub))
            } else {
                sections.append(xmlStr)
            }
        }

        // 4. Generate Chapter HTML files
        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        let bookHeaderHTML = """
        <div class="book-cover-header">
            <h1 class="book-title">\(escapeHTML(title))</h1>
            \(author.isEmpty ? "" : "<p class=\"book-author\">\(escapeHTML(author))</p>")
        </div>
        """

        for (idx, rawSec) in sections.enumerated() {
            var chapTitle = "Section \(idx + 1)"
            if let tRange = rawSec.range(of: "<title>\\s*<p>([^<]+)</p>\\s*</title>", options: .regularExpression) {
                let sub = rawSec[tRange]
                if let s = sub.range(of: "<p>")?.upperBound, let e = sub.range(of: "</p>")?.lowerBound, s < e {
                    chapTitle = String(sub[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            var htmlSec = rawSec
            // Transform FB2 tags into HTML
            htmlSec = htmlSec.replacingOccurrences(of: "<empty-line/>", with: "<br/>")
            htmlSec = htmlSec.replacingOccurrences(of: "<empty-line\\s*/>", with: "<br/>", options: .regularExpression)
            htmlSec = htmlSec.replacingOccurrences(of: "l:href=\"#([^\"]+)\"", with: "src=\"$1\"", options: .regularExpression)
            htmlSec = htmlSec.replacingOccurrences(of: "<image\\s+([^>]*)/?>", with: "<img $1/>", options: .regularExpression)
            htmlSec = htmlSec.replacingOccurrences(of: "<title>\\s*<p>([\\s\\S]*?)</p>\\s*</title>", with: "<h2 class=\"chapter-title\">$1</h2>", options: .regularExpression)
            htmlSec = htmlSec.replacingOccurrences(of: "<epigraph>", with: "<blockquote>")
            htmlSec = htmlSec.replacingOccurrences(of: "</epigraph>", with: "</blockquote>")

            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, "Georgia", "Times New Roman", serif;
                font-size: 14pt;
                line-height: 1.65;
                color: #1a1a1a;
                margin: 0;
                padding: 40pt 48pt;
              }
              .book-cover-header { text-align: center; margin-bottom: 30pt; padding-bottom: 20pt; border-bottom: 1px solid #e0e0e0; }
              .book-title { font-size: 26pt; font-family: -apple-system, sans-serif; font-weight: 700; margin-bottom: 8pt; }
              .book-author { font-size: 15pt; color: #555; font-style: italic; }
              .chapter-title { font-size: 20pt; font-family: -apple-system, sans-serif; font-weight: 600; margin-top: 10pt; margin-bottom: 16pt; color: #111; }
              p { margin-top: 0; margin-bottom: 10pt; text-indent: 1.5em; text-align: justify; }
              img { max-width: 100%; height: auto; display: block; margin: 16pt auto; border-radius: 4px; }
              blockquote { margin: 16pt 24pt; font-style: italic; color: #444; border-left: 3px solid #ccc; padding-left: 12pt; }
            </style>
            </head>
            <body>
              \(idx == 0 ? bookHeaderHTML : "")
              \(htmlSec)
            </body>
            </html>
            """

            let chapURL = tempDir.appendingPathComponent("chapter_\(idx).html")
            try fullHTML.write(to: chapURL, atomically: true, encoding: .utf8)
            chapterURLs.append(chapURL)
            tocItems.append((title: chapTitle, targetURL: chapURL))
        }

        try renderHTMLChapters(
            chapterURLs: chapterURLs,
            readAccessURL: tempDir,
            title: title,
            author: author,
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 4. TXT / Plain Text Converter

    public static func convertTXT(txtURL: URL, targetPDF: URL) throws {
        guard let data = try? Data(contentsOf: txtURL) else {
            throw EBookConverterError.fileNotFound(txtURL.path)
        }

        let str = String(data: data, encoding: .utf8) ??
                  String(data: data, encoding: .utf16) ??
                  String(data: data, encoding: .isoLatin1) ??
                  String(data: data, encoding: .windowsCP1252) ??
                  String(decoding: data, as: UTF8.self)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TXT_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookTitle = txtURL.deletingPathExtension().lastPathComponent
        let lines = str.components(separatedBy: .newlines)

        let chapterPattern = "^(?:\\s*)(Chapter\\s+[0-9IVXLCDM]+.*|Book\\s+[0-9IVXLCDM]+.*|Section\\s+[0-9IVXLCDM]+.*|Part\\s+[0-9IVXLCDM]+.*|Prologue.*|Epilogue.*|ACT\\s+[0-9IVXLCDM]+.*|第[0-9一二三四五六七八九十百千万]+[章节回卷集部].*)$"
        let chapRegex = try? NSRegularExpression(pattern: chapterPattern, options: .caseInsensitive)

        var chapters: [(title: String, paragraphs: [String])] = []
        var currentTitle = "Beginning"
        var currentParas: [String] = []

        func commitChapter() {
            if !currentParas.isEmpty {
                chapters.append((title: currentTitle, paragraphs: currentParas))
                currentParas = []
            }
        }

        var currentPara = ""
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !currentPara.isEmpty {
                    currentParas.append(currentPara)
                    currentPara = ""
                }
                continue
            }

            var isHeading = false
            if let chapRegex = chapRegex {
                let range = NSRange(location: 0, length: line.utf16.count)
                if chapRegex.firstMatch(in: line, options: [], range: range) != nil {
                    isHeading = true
                }
            }

            if isHeading {
                if !currentPara.isEmpty {
                    currentParas.append(currentPara)
                    currentPara = ""
                }
                commitChapter()
                currentTitle = line
            } else {
                if currentPara.isEmpty {
                    currentPara = line
                } else {
                    currentPara += " " + line
                }
            }
        }
        if !currentPara.isEmpty {
            currentParas.append(currentPara)
        }
        commitChapter()

        // If no chapters detected, chunk paragraphs into groups of 50
        if chapters.count <= 1 && (chapters.first?.paragraphs.count ?? 0) > 60 {
            let allParas = chapters.first?.paragraphs ?? []
            chapters = []
            let chunkSize = 50
            for idx in stride(from: 0, to: allParas.count, by: chunkSize) {
                let end = min(idx + chunkSize, allParas.count)
                let chunk = Array(allParas[idx..<end])
                let partNum = (idx / chunkSize) + 1
                chapters.append((title: "Part \(partNum)", paragraphs: chunk))
            }
        }

        if chapters.isEmpty {
            chapters.append((title: bookTitle, paragraphs: ["(Empty Document)"]))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, chap) in chapters.enumerated() {
            let bodyHTML = chap.paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, "Georgia", "Times New Roman", serif;
                font-size: 14pt;
                line-height: 1.65;
                color: #1a1a1a;
                margin: 0;
                padding: 40pt 48pt;
              }
              .chapter-title { font-size: 20pt; font-family: -apple-system, sans-serif; font-weight: 600; margin-top: 10pt; margin-bottom: 20pt; color: #111; }
              p { margin-top: 0; margin-bottom: 11pt; text-indent: 1.5em; text-align: justify; }
            </style>
            </head>
            <body>
              <h2 class="chapter-title">\(escapeHTML(chap.title))</h2>
              \(bodyHTML)
            </body>
            </html>
            """
            let chapURL = tempDir.appendingPathComponent("chapter_\(idx).html")
            try fullHTML.write(to: chapURL, atomically: true, encoding: .utf8)
            chapterURLs.append(chapURL)
            tocItems.append((title: chap.title, targetURL: chapURL))
        }

        try renderHTMLChapters(
            chapterURLs: chapterURLs,
            readAccessURL: tempDir,
            title: bookTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 5. Markdown Converter

    public static func convertMarkdown(mdURL: URL, targetPDF: URL) throws {
        guard let mdStr = try? String(contentsOf: mdURL, encoding: .utf8) else {
            throw EBookConverterError.fileNotFound(mdURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MD_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallbackTitle = mdURL.deletingPathExtension().lastPathComponent
        var docTitle = fallbackTitle

        // Extract first # title if present
        let lines = mdStr.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                docTitle = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Split into sections by # or ##
        var sections: [(title: String, content: String)] = []
        var curTitle = docTitle
        var curLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
                if !curLines.isEmpty {
                    sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
                    curLines = []
                }
                curTitle = trimmed.hasPrefix("# ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(3))
            }
            curLines.append(line)
        }
        if !curLines.isEmpty {
            sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
        }

        if sections.isEmpty {
            sections.append((title: docTitle, content: mdStr))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, sec) in sections.enumerated() {
            let renderedHTML = markdownToHTML(sec.content)
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                font-size: 13.5pt;
                line-height: 1.6;
                color: #24292f;
                margin: 0;
                padding: 40pt 48pt;
              }
              h1, h2, h3, h4 { font-weight: 600; color: #1f2328; margin-top: 24pt; margin-bottom: 12pt; }
              h1 { font-size: 24pt; border-bottom: 1px solid #d0d7de; padding-bottom: 8pt; }
              h2 { font-size: 18pt; border-bottom: 1px solid #d0d7de; padding-bottom: 6pt; }
              h3 { font-size: 15pt; }
              p { margin-top: 0; margin-bottom: 12pt; }
              code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 11.5pt; background: #f6f8fa; padding: 2pt 4pt; border-radius: 4pt; }
              pre { background: #f6f8fa; padding: 12pt; border-radius: 6pt; overflow-x: auto; font-family: monospace; font-size: 11.5pt; line-height: 1.45; }
              pre code { background: none; padding: 0; }
              blockquote { margin: 12pt 0; padding: 0 16pt; color: #57606a; border-left: 4px solid #d0d7de; }
              ul, ol { padding-left: 24pt; margin-bottom: 12pt; }
              li { margin-bottom: 4pt; }
              hr { height: 1px; background: #d0d7de; border: none; margin: 24pt 0; }
              img { max-width: 100%; border-radius: 4pt; }
            </style>
            </head>
            <body>
              \(renderedHTML)
            </body>
            </html>
            """
            let chapURL = tempDir.appendingPathComponent("chapter_\(idx).html")
            try fullHTML.write(to: chapURL, atomically: true, encoding: .utf8)
            chapterURLs.append(chapURL)
            tocItems.append((title: sec.title, targetURL: chapURL))
        }

        try renderHTMLChapters(
            chapterURLs: chapterURLs,
            readAccessURL: tempDir,
            title: docTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 6. RTF / RTFD Converter

    public static func convertRTF(rtfURL: URL, targetPDF: URL) throws {
        let isRTFD = rtfURL.pathExtension.lowercased() == "rtfd"
        let docType: NSAttributedString.DocumentType = isRTFD ? .rtfd : .rtf

        guard let attrStr = try? NSAttributedString(url: rtfURL, options: [.documentType: docType], documentAttributes: nil) else {
            throw EBookConverterError.conversionFailed("Unable to parse RTF document")
        }

        let htmlData: Data
        do {
            htmlData = try attrStr.data(
                from: NSRange(location: 0, length: attrStr.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            )
        } catch {
            throw EBookConverterError.conversionFailed("Failed to export RTF to HTML: \(error.localizedDescription)")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RTF_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent("index.html")
        try htmlData.write(to: indexURL)

        let title = rtfURL.deletingPathExtension().lastPathComponent
        try renderHTMLChapters(
            chapterURLs: [indexURL],
            readAccessURL: tempDir,
            title: title,
            author: "",
            tocItems: [(title: title, targetURL: indexURL)],
            targetPDF: targetPDF
        )
    }

    // MARK: - 7. HTML / WebArchive Converter

    public static func convertHTML(htmlURL: URL, targetPDF: URL) throws {
        let title = htmlURL.deletingPathExtension().lastPathComponent
        try renderHTMLChapters(
            chapterURLs: [htmlURL],
            readAccessURL: htmlURL.deletingLastPathComponent(),
            title: title,
            author: "",
            tocItems: [(title: title, targetURL: htmlURL)],
            targetPDF: targetPDF
        )
    }

    // MARK: - 8. MOBI / PRC (Mobipocket & PalmDOC) Converter

    public static func convertMOBI(mobiURL: URL, targetPDF: URL) throws {
        guard let data = try? Data(contentsOf: mobiURL), data.count >= 78 else {
            throw EBookConverterError.conversionFailed("Invalid or empty MOBI file")
        }

        // 1. Read PDB Header (numRecords at offset 76)
        let numRecords = Int(data[76]) << 8 | Int(data[77])
        guard numRecords >= 2 else {
            throw EBookConverterError.conversionFailed("Invalid MOBI: record count < 2")
        }

        // 2. Read Record Offsets
        var recordOffsets: [Int] = []
        for i in 0..<numRecords {
            let offsetIndex = 78 + (i * 8)
            guard offsetIndex + 4 <= data.count else { break }
            let off = Int(data[offsetIndex]) << 24 |
                      Int(data[offsetIndex + 1]) << 16 |
                      Int(data[offsetIndex + 2]) << 8 |
                      Int(data[offsetIndex + 3])
            recordOffsets.append(off)
        }

        guard recordOffsets.count >= 2 else {
            throw EBookConverterError.conversionFailed("MOBI record offset table corrupt")
        }

        // 3. Record 0: Header & Compression
        let rec0Start = recordOffsets[0]
        let rec0End = recordOffsets[1]
        guard rec0Start < data.count, rec0End <= data.count, rec0End > rec0Start else {
            throw EBookConverterError.conversionFailed("Invalid MOBI record 0 boundaries")
        }
        let rec0Data = data.subdata(in: rec0Start..<rec0End)
        guard rec0Data.count >= 10 else {
            throw EBookConverterError.conversionFailed("Record 0 header too short")
        }

        let compression = Int(rec0Data[0]) << 8 | Int(rec0Data[1])
        let numTextRecords = Int(rec0Data[8]) << 8 | Int(rec0Data[9])

        var mobiTitle = mobiURL.deletingPathExtension().lastPathComponent
        // Check for "MOBI" header at offset 16
        if rec0Data.count >= 92 &&
           rec0Data[16] == 0x4D && rec0Data[17] == 0x4F && rec0Data[18] == 0x42 && rec0Data[19] == 0x49 {
            let titleOffset = Int(rec0Data[84]) << 24 | Int(rec0Data[85]) << 16 | Int(rec0Data[86]) << 8 | Int(rec0Data[87])
            let titleLength = Int(rec0Data[88]) << 24 | Int(rec0Data[89]) << 16 | Int(rec0Data[90]) << 8 | Int(rec0Data[91])
            if titleOffset + titleLength <= rec0Data.count && titleLength > 0 {
                let titleBytes = rec0Data.subdata(in: titleOffset..<(titleOffset + titleLength))
                if let t = String(data: titleBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    mobiTitle = t
                }
            }
        }

        // 4. Decompress Text Records
        var decompressedTextData = Data()
        let maxTextRecord = min(numTextRecords, recordOffsets.count - 1)

        for i in 1...maxTextRecord {
            let start = recordOffsets[i]
            let end = (i + 1 < recordOffsets.count) ? recordOffsets[i + 1] : data.count
            guard start < data.count, end <= data.count, end > start else { continue }
            let recordData = data.subdata(in: start..<end)

            if compression == 1 {
                // No compression
                decompressedTextData.append(recordData)
            } else if compression == 2 {
                // PalmDOC LZ77 compression
                let decomp = decompressPalmDOC(data: recordData)
                decompressedTextData.append(decomp)
            } else {
                throw EBookConverterError.conversionFailed("Unsupported MOBI compression type: \(compression)")
            }
        }

        guard !decompressedTextData.isEmpty else {
            throw EBookConverterError.conversionFailed("MOBI decompressed text is empty")
        }

        var fullHTML = String(data: decompressedTextData, encoding: .utf8) ??
                       String(data: decompressedTextData, encoding: .windowsCP1252) ??
                       String(decoding: decompressedTextData, as: UTF8.self)

        // Clean MOBI pagebreak tags
        fullHTML = fullHTML.replacingOccurrences(of: "<mbp:pagebreak/>", with: "<div class=\"page-break\"></div>")
        fullHTML = fullHTML.replacingOccurrences(of: "<mbp:pagebreak>", with: "<div class=\"page-break\"></div>")

        // Split into chapters by page breaks or h1/h2
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MOBI_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var rawChapters: [String] = []
        if fullHTML.contains("<div class=\"page-break\"></div>") {
            rawChapters = fullHTML.components(separatedBy: "<div class=\"page-break\"></div>")
        } else {
            // Split into manageable chunks of ~20,000 characters
            var remaining = fullHTML[...]
            let chunkSize = 20000
            while !remaining.isEmpty {
                let take = min(chunkSize, remaining.count)
                let sub = remaining.prefix(take)
                rawChapters.append(String(sub))
                remaining = remaining.dropFirst(take)
            }
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, chapContent) in rawChapters.enumerated() {
            let chapTitle = "Chapter \(idx + 1)"
            let styledChap = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, "Georgia", "Times New Roman", serif;
                font-size: 14pt;
                line-height: 1.65;
                color: #1a1a1a;
                margin: 0;
                padding: 40pt 48pt;
              }
              h1, h2, h3 { font-family: -apple-system, sans-serif; font-weight: 600; margin-top: 16pt; margin-bottom: 12pt; color: #111; }
              p { margin-top: 0; margin-bottom: 10pt; text-indent: 1.5em; text-align: justify; }
              img { max-width: 100%; height: auto; display: block; margin: 16pt auto; }
            </style>
            </head>
            <body>
              \(chapContent)
            </body>
            </html>
            """
            let chapURL = tempDir.appendingPathComponent("chapter_\(idx).html")
            try styledChap.write(to: chapURL, atomically: true, encoding: .utf8)
            chapterURLs.append(chapURL)
            tocItems.append((title: chapTitle, targetURL: chapURL))
        }

        try renderHTMLChapters(
            chapterURLs: chapterURLs,
            readAccessURL: tempDir,
            title: mobiTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - PalmDOC LZ77 Decompressor

    public static func decompressPalmDOC(data: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        var i = 0
        let count = data.count

        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while i < count {
                let b = ptr[i]
                i += 1
                if b == 0x00 {
                    // literal null byte
                    out.append(0)
                } else if b >= 0x01 && b <= 0x08 {
                    // copy next b literal bytes
                    let literalCount = Int(b)
                    for _ in 0..<literalCount {
                        if i < count {
                            out.append(ptr[i])
                            i += 1
                        }
                    }
                } else if b <= 0x7F {
                    // literal byte
                    out.append(b)
                } else if b <= 0xBF {
                    // LZ77 distance/length pair
                    if i < count {
                        let b2 = ptr[i]
                        i += 1
                        let distance = ((Int(b) & 0x03) << 8) | Int(b2)
                        let length = ((Int(b) >> 2) & 0x07) + 3
                        let startIndex = out.count - distance
                        if startIndex >= 0 {
                            for k in 0..<length {
                                let srcIdx = startIndex + k
                                if srcIdx < out.count {
                                    out.append(out[srcIdx])
                                }
                            }
                        }
                    }
                } else {
                    // 0xC0...0xFF: space + char
                    out.append(0x20)
                    out.append(b ^ 0x80)
                }
            }
        }
        return Data(out)
    }

    // MARK: - HTML Chapter Batch Renderer

    public static func renderHTMLChapters(
        chapterURLs: [URL],
        readAccessURL: URL,
        title: String,
        author: String,
        tocItems: [(title: String, targetURL: URL)],
        targetPDF: URL
    ) throws {
        let masterDoc: PDFDocument = try runOnMainThread { (completion: @escaping (Result<PDFDocument, Error>) -> Void) in
            let masterPDF = PDFDocument()
            let renderer = WebKitChapterRenderer()
            var chapterIndex = 0
            var urlToPageMap: [URL: Int] = [:]

            @MainActor
            func processNext() {
                if chapterIndex >= chapterURLs.count {
                    let attrs: [PDFDocumentAttribute: Any] = [
                        .titleAttribute: title,
                        .authorAttribute: author
                    ]
                    masterPDF.documentAttributes = attrs

                    if !tocItems.isEmpty {
                        let rootOutline = PDFOutline()
                        for item in tocItems {
                            if let pIndex = urlToPageMap[item.targetURL],
                               let page = masterPDF.page(at: pIndex) {
                                let outlineItem = PDFOutline()
                                outlineItem.label = item.title
                                outlineItem.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY))
                                rootOutline.insertChild(outlineItem, at: rootOutline.numberOfChildren)
                            }
                        }
                        if rootOutline.numberOfChildren > 0 {
                            masterPDF.outlineRoot = rootOutline
                        }
                    }

                    completion(.success(masterPDF))
                    return
                }

                let chapURL = chapterURLs[chapterIndex]
                guard FileManager.default.fileExists(atPath: chapURL.path) else {
                    chapterIndex += 1
                    processNext()
                    return
                }

                let startPageIndex = masterPDF.pageCount
                urlToPageMap[chapURL] = startPageIndex

                renderer.render(url: chapURL, readAccessURL: readAccessURL) { res in
                    switch res {
                    case .success(let data):
                        if let chapDoc = PDFDocument(data: data) {
                            for p in 0..<chapDoc.pageCount {
                                if let page = chapDoc.page(at: p) {
                                    masterPDF.insert(page, at: masterPDF.pageCount)
                                }
                            }
                        }
                    case .failure:
                        break
                    }
                    chapterIndex += 1
                    processNext()
                }
            }

            processNext()
        }

        guard masterDoc.pageCount > 0 else {
            throw EBookConverterError.conversionFailed("Rendered ebook produced 0 pages")
        }

        guard masterDoc.write(to: targetPDF) else {
            throw EBookConverterError.conversionFailed("Failed to save converted PDF to \(targetPDF.path)")
        }
    }

    // MARK: - Helpers

    public static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
              .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        let lines = markdown.components(separatedBy: .newlines)
        var inCodeBlock = false
        var inList = false
        var inBlockquote = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    if inList { html += "</ul>\n"; inList = false }
                    if inBlockquote { html += "</blockquote>\n"; inBlockquote = false }
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            if trimmed.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                if inBlockquote { html += "</blockquote>\n"; inBlockquote = false }
                continue
            }

            if trimmed.hasPrefix("# ") {
                html += "<h1>\(parseInlineMarkdown(String(trimmed.dropFirst(2))))</h1>\n"
            } else if trimmed.hasPrefix("## ") {
                html += "<h2>\(parseInlineMarkdown(String(trimmed.dropFirst(3))))</h2>\n"
            } else if trimmed.hasPrefix("### ") {
                html += "<h3>\(parseInlineMarkdown(String(trimmed.dropFirst(4))))</h3>\n"
            } else if trimmed.hasPrefix("#### ") {
                html += "<h4>\(parseInlineMarkdown(String(trimmed.dropFirst(5))))</h4>\n"
            } else if trimmed.hasPrefix("> ") {
                if !inBlockquote {
                    html += "<blockquote>"
                    inBlockquote = true
                }
                html += "<p>\(parseInlineMarkdown(String(trimmed.dropFirst(2))))</p>\n"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList {
                    html += "<ul>\n"
                    inList = true
                }
                html += "<li>\(parseInlineMarkdown(String(trimmed.dropFirst(2))))</li>\n"
            } else if trimmed == "---" || trimmed == "***" {
                html += "<hr/>\n"
            } else {
                html += "<p>\(parseInlineMarkdown(trimmed))</p>\n"
            }
        }

        if inCodeBlock { html += "</code></pre>\n" }
        if inList { html += "</ul>\n" }
        if inBlockquote { html += "</blockquote>\n" }

        return html
    }

    private static func parseInlineMarkdown(_ text: String) -> String {
        var res = escapeHTML(text)
        // Bold: **text**
        res = res.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        // Italic: *text*
        res = res.replacingOccurrences(of: "\\*(.*?)\\*", with: "<em>$1</em>", options: .regularExpression)
        // Inline code: `text`
        res = res.replacingOccurrences(of: "`(.*?)`", with: "<code>$1</code>", options: .regularExpression)
        // Links: [text](url)
        res = res.replacingOccurrences(of: "\\[(.*?)\\]\\((.*?)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return res
    }

    private static func parseTOCItems(data: Data) -> [(title: String, href: String)] {
        var items: [(title: String, href: String)] = []
        let str = String(data: data, encoding: .utf8) ?? ""

        let aRegex = try? NSRegularExpression(pattern: "<a\\s+[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>", options: .caseInsensitive)
        if let matches = aRegex?.matches(in: str, options: [], range: NSRange(location: 0, length: str.utf16.count)), !matches.isEmpty {
            for m in matches {
                if let hrefR = Range(m.range(at: 1), in: str), let titleR = Range(m.range(at: 2), in: str) {
                    let href = String(str[hrefR]).components(separatedBy: "#").first ?? String(str[hrefR])
                    let title = String(str[titleR]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        items.append((title: title, href: href))
                    }
                }
            }
        }

        if items.isEmpty {
            let ncxRegex = try? NSRegularExpression(pattern: "<navPoint[^>]*>[\\s\\S]*?<text>([^<]+)<\\/text>[\\s\\S]*?<content[^>]*src=\"([^\"]+)\"", options: .caseInsensitive)
            if let matches = ncxRegex?.matches(in: str, options: [], range: NSRange(location: 0, length: str.utf16.count)) {
                for m in matches {
                    if let textR = Range(m.range(at: 1), in: str), let srcR = Range(m.range(at: 2), in: str) {
                        let title = String(str[textR]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let href = String(str[srcR]).components(separatedBy: "#").first ?? String(str[srcR])
                        if !title.isEmpty {
                            items.append((title: title, href: href))
                        }
                    }
                }
            }
        }
        return items
    }

    private static func runOnMainThread<T>(_ block: @escaping @MainActor (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let box = ThreadSafeBox<Result<T, Error>>()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                block { res in
                    box.value = res
                }
            }
            let start = Date()
            while box.value == nil && Date().timeIntervalSince(start) < 90.0 {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            guard let res = box.value else {
                throw EBookConverterError.conversionFailed("Conversion timed out on main thread")
            }
            return try res.get()
        } else {
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    block { res in
                        box.value = res
                        sema.signal()
                    }
                }
            }
            let waitRes = sema.wait(timeout: .now() + 90.0)
            if waitRes == .timedOut {
                throw EBookConverterError.conversionFailed("Conversion timed out on background thread")
            }
            guard let res = box.value else {
                throw EBookConverterError.conversionFailed("Conversion failed to return result")
            }
            return try res.get()
        }
    }

    // MARK: - Legacy / Optional External Converters

    private static func convertWithPyMuPDF(pythonURL: URL, epubPath: String, pdfPath: String) throws {
        let script = """
import pymupdf, sys
epub_path = sys.argv[1]
pdf_path = sys.argv[2]
doc = pymupdf.open(epub_path)
pdf_bytes = doc.convert_to_pdf()
pdf_doc = pymupdf.open('pdf', pdf_bytes)
toc = doc.get_toc()
if toc:
    pdf_doc.set_toc(toc)
meta = doc.metadata
if meta:
    pdf_doc.set_metadata(meta)
pdf_doc.save(pdf_path)
"""
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, epubPath, pdfPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: data, encoding: .utf8) ?? "PyMuPDF exited with code \(process.terminationStatus)"
            throw NSError(domain: "EBookConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }

    private static func convertWithCalibre(calibreURL: URL, epubPath: String, pdfPath: String) throws {
        let process = Process()
        process.executableURL = calibreURL
        process.arguments = [
            epubPath,
            pdfPath,
            "--paper-size", "letter",
            "--pdf-page-numbers",
            "--pdf-footer-template", "<p style=\"text-align:center; font-size:9pt; color:#666;\">_PAGENUM_</p>",
            "--margin-top", "36",
            "--margin-bottom", "36",
            "--margin-left", "48",
            "--margin-right", "48"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: data, encoding: .utf8) ?? "ebook-convert exited with code \(process.terminationStatus)"
            throw NSError(domain: "EBookConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }
}

// Backward Compatibility Aliases
public typealias EPUBConverter = EBookConverter

// MARK: - Private WebKit Chapter Renderer

private final class WebKitChapterRenderer: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private let webView: WKWebView
    private var finishCallback: (() -> Void)?

    @MainActor
    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    @MainActor
    func render(url: URL, readAccessURL: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        self.finishCallback = { [weak self] in
            guard let self = self else { return }
            self.webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 792)") { heightVal, _ in
                let h = max(792, (heightVal as? CGFloat) ?? 792)
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: 612, height: h)
                self.webView.createPDF(configuration: config) { res in
                    completion(res)
                }
            }
        }
        self.webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishCallback?()
        finishCallback = nil
    }

    @MainActor
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishCallback?()
        finishCallback = nil
    }

    @MainActor
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishCallback?()
        finishCallback = nil
    }
}

// MARK: - Thread-Safe Value Box

private final class ThreadSafeBox<V>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: V?

    var value: V? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
