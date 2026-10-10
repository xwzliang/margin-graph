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
        "cbz", "cbr", "cbt",
        "fb2", "zfb2",
        "txt", "text",
        "md", "markdown",
        "rtf", "rtfd",
        "html", "htm", "xhtml", "webarchive",
        "mobi", "prc", "azw", "azw3", "kf8", "pdb",
        "docx", "doc", "odt",
        "chm",
        "djvu", "djv",
        "tex", "latex",
        "adoc", "asciidoc",
        "org",
        "rst"
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

    public nonisolated(unsafe) static var customDocumentsDirectory: URL? = nil

    public static func documentsDirectory() -> URL {
        if let custom = customDocumentsDirectory {
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let docs = appSupport.appendingPathComponent("MarginGraph/Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    public static func existingConvertedPDFURL(for ebookURL: URL) -> URL? {
        guard isSupported(url: ebookURL) else { return nil }

        let docsDir = documentsDirectory()
        let sidecar1 = ebookURL.appendingPathExtension("md5")
        let sidecar2 = ebookURL.deletingPathExtension().appendingPathExtension("md5")
        var md5: String? = nil
        if FileManager.default.fileExists(atPath: sidecar1.path),
           let content = try? String(contentsOf: sidecar1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            md5 = content
        } else if FileManager.default.fileExists(atPath: sidecar2.path),
                  let content = try? String(contentsOf: sidecar2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty {
            md5 = content
        }

        if md5 == nil {
            if Database.isNetworkVolume(url: ebookURL) {
                return nil
            }
            md5 = MediaDocumentHelper.computeFileMD5(url: ebookURL)
        }

        guard let validMD5 = md5, !validMD5.isEmpty else { return nil }
        let targetPDF = docsDir.appendingPathComponent("\(validMD5).pdf")
        if FileManager.default.fileExists(atPath: targetPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: targetPDF.path),
           let size = attrs[.size] as? Int64, size > 1024 {
            return targetPDF
        }
        return nil
    }

    public static func ensureConvertedPDF(for ebookURL: URL, options: TypographyOptions = .default) throws -> ConvertedEBookResult {
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

        let isReflowable = MediaDocumentHelper.isReflowableFormat(ext)
        let currentLayoutVersion = isReflowable ? options.cacheKey : "v1_fixed"
        let variantPDF = docsDir.appendingPathComponent("\(md5)_\(currentLayoutVersion).pdf")
        let sidecarVer = targetPDF.deletingPathExtension().appendingPathExtension("layout_ver")
        let sidecarSource = targetPDF.deletingPathExtension().appendingPathExtension("source_path")
        let sidecarFormat = targetPDF.deletingPathExtension().appendingPathExtension("format")

        // 1. If targetPDF already exists, has valid layout_ver matching currentLayoutVersion, use it immediately
        if FileManager.default.fileExists(atPath: targetPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: targetPDF.path),
           let size = attrs[.size] as? Int64, size > 1024,
           let doc = PDFDocument(url: targetPDF), doc.pageCount > 0,
           (!isReflowable || (try? String(contentsOf: sidecarVer, encoding: .utf8)) == currentLayoutVersion) {
            try? ebookURL.path.write(to: sidecarSource, atomically: true, encoding: .utf8)
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

        // 2. If variantPDF already exists for this layout version, copy it to targetPDF instantly
        if isReflowable && FileManager.default.fileExists(atPath: variantPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: variantPDF.path),
           let size = attrs[.size] as? Int64, size > 1024,
           let doc = PDFDocument(url: variantPDF), doc.pageCount > 0 {
            try? FileManager.default.removeItem(at: targetPDF)
            try? FileManager.default.copyItem(at: variantPDF, to: targetPDF)
            try? currentLayoutVersion.write(to: sidecarVer, atomically: true, encoding: .utf8)
            try? ebookURL.path.write(to: sidecarSource, atomically: true, encoding: .utf8)
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

        if FileManager.default.fileExists(atPath: targetPDF.path) {
            try? FileManager.default.removeItem(at: targetPDF)
        }

        // Perform format-specific native conversion
        switch ext {
        case "epub":
            try convertEPUB(epubURL: ebookURL, targetPDF: targetPDF, options: options)
        case "cbz", "cbr":
            try convertCBZ(cbzURL: ebookURL, targetPDF: targetPDF)
        case "cbt":
            try convertCBT(cbtURL: ebookURL, targetPDF: targetPDF)
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
        case "azw", "azw3", "kf8":
            try convertAZW3(azwURL: ebookURL, targetPDF: targetPDF)
        case "pdb":
            try convertPDB(pdbURL: ebookURL, targetPDF: targetPDF)
        case "docx", "doc", "odt":
            try convertOfficeDocument(officeURL: ebookURL, targetPDF: targetPDF)
        case "chm":
            try convertCHM(chmURL: ebookURL, targetPDF: targetPDF)
        case "djvu", "djv":
            try convertDJVU(djvuURL: ebookURL, targetPDF: targetPDF)
        case "tex", "latex":
            try convertLaTeX(texURL: ebookURL, targetPDF: targetPDF)
        case "adoc", "asciidoc":
            try convertAsciiDoc(adocURL: ebookURL, targetPDF: targetPDF)
        case "org":
            try convertOrgMode(orgURL: ebookURL, targetPDF: targetPDF)
        case "rst":
            try convertRST(rstURL: ebookURL, targetPDF: targetPDF)
        default:
            throw EBookConverterError.unsupportedFormat(ext)
        }

        guard FileManager.default.fileExists(atPath: targetPDF.path),
              let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 else {
            throw EBookConverterError.conversionFailed("Conversion produced empty or invalid PDF")
        }

        // Cache variant if reflowable
        if isReflowable {
            try? FileManager.default.removeItem(at: variantPDF)
            try? FileManager.default.copyItem(at: targetPDF, to: variantPDF)
        }

        // Write MD5 sidecars
        let sidecarPDF = targetPDF.appendingPathExtension("md5")
        try? md5.write(to: sidecarPDF, atomically: true, encoding: .utf8)
        let sidecarEBook = ebookURL.appendingPathExtension("md5")
        try? md5.write(to: sidecarEBook, atomically: true, encoding: .utf8)
        try? ext.write(to: sidecarFormat, atomically: true, encoding: .utf8)
        try? currentLayoutVersion.write(to: sidecarVer, atomically: true, encoding: .utf8)
        try? ebookURL.path.write(to: sidecarSource, atomically: true, encoding: .utf8)

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

    public static func convertEPUB(epubURL: URL, targetPDF: URL, options: TypographyOptions = .default) throws {
        var conversionError: String? = nil

        // Method 1: PyMuPDF (fast, if user has Python+PyMuPDF)
        if ProcessInfo.processInfo.environment["FORCE_NATIVE_EPUB"] != "1",
           let pythonURL = findExecutable(named: "python3") {
            do {
                try convertWithPyMuPDF(pythonURL: pythonURL, epubPath: epubURL.path, pdfPath: targetPDF.path, options: options)
            } catch {
                conversionError = error.localizedDescription
            }
        }

        // Method 2: Native WebKit-based engine (100% built-in, zero dependencies)
        let pdfCreated = FileManager.default.fileExists(atPath: targetPDF.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024

        if !pdfCreated {
            do {
                try convertWithNativeWebKitEPUB(epubURL: epubURL, targetPDF: targetPDF, options: options)
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

    public static func convertWithNativeWebKit(epubURL: URL, targetPDF: URL, options: TypographyOptions = .default) throws {
        try convertWithNativeWebKitEPUB(epubURL: epubURL, targetPDF: targetPDF, options: options)
    }

    private static func convertWithNativeWebKitEPUB(epubURL: URL, targetPDF: URL, options: TypographyOptions = .default) throws {
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
            targetPDF: targetPDF,
            options: options
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

    // MARK: - 2b. CBT (Comic Book TAR) Converter

    public static func convertCBT(cbtURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CBT_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xf", cbtURL.path, "-C", tempDir.path]
        let errPipe = Pipe()
        untar.standardError = errPipe
        try untar.run()
        untar.waitUntilExit()

        guard untar.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Tar unpack failed"
            throw EBookConverterError.conversionFailed("Failed to unpack comic tar archive: \(err)")
        }

        let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "tiff", "tif", "bmp"]
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw EBookConverterError.conversionFailed("Unable to read extracted comic tar contents")
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
            throw EBookConverterError.conversionFailed("No valid comic page images found in tar archive")
        }

        imageURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let masterPDF = PDFDocument()
        for imgURL in imageURLs {
            if let image = NSImage(contentsOf: imgURL), let page = PDFPage(image: image) {
                masterPDF.insert(page, at: masterPDF.pageCount)
            }
        }

        guard masterPDF.pageCount > 0 else {
            throw EBookConverterError.conversionFailed("Failed to create PDF pages from comic tar images")
        }

        let fallbackTitle = cbtURL.deletingPathExtension().lastPathComponent
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
              table { border-collapse: collapse; width: 100%; margin: 16pt 0; }
              th, td { border: 1px solid #d0d7de; padding: 6pt 10pt; text-align: left; }
              th { background: #f6f8fa; font-weight: 600; }
              tr:nth-child(even) { background: #fcfcfc; }
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

    // MARK: - 9. AZW / AZW3 / KF8 (Kindle Format 8) Converter

    public static func convertAZW3(azwURL: URL, targetPDF: URL) throws {
        // Optional Attempt: Calibre or PyMuPDF if present
        if let calibreURL = findExecutable(named: "ebook-convert") {
            do {
                try convertWithCalibre(calibreURL: calibreURL, epubPath: azwURL.path, pdfPath: targetPDF.path)
                if FileManager.default.fileExists(atPath: targetPDF.path) &&
                   ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024 {
                    return
                }
            } catch {}
        }

        guard let data = try? Data(contentsOf: azwURL), data.count >= 78 else {
            throw EBookConverterError.conversionFailed("Invalid or empty AZW3 file")
        }

        let numRecords = Int(data[76]) << 8 | Int(data[77])
        guard numRecords >= 2 else {
            throw EBookConverterError.conversionFailed("Invalid AZW3: record count < 2")
        }

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
            throw EBookConverterError.conversionFailed("AZW3 record offset table corrupt")
        }

        // Search for KF8 boundary record ("BOUNDARY")
        var kf8HeaderRecordIndex: Int? = nil
        for i in 0..<recordOffsets.count {
            let start = recordOffsets[i]
            let end = (i + 1 < recordOffsets.count) ? recordOffsets[i + 1] : data.count
            guard start < data.count, end <= data.count, end - start >= 8 else { continue }
            let slice = data.subdata(in: start..<min(start + 16, end))
            if let str = String(data: slice, encoding: .ascii), str.hasPrefix("BOUNDARY") {
                kf8HeaderRecordIndex = i + 1
                break
            }
        }

        let baseRecord = kf8HeaderRecordIndex ?? 0
        let recStart = recordOffsets[baseRecord]
        let recEnd = (baseRecord + 1 < recordOffsets.count) ? recordOffsets[baseRecord + 1] : data.count
        guard recStart < data.count, recEnd <= data.count, recEnd > recStart else {
            throw EBookConverterError.conversionFailed("Invalid AZW3 record boundaries")
        }
        let headerData = data.subdata(in: recStart..<recEnd)
        guard headerData.count >= 10 else {
            throw EBookConverterError.conversionFailed("AZW3 header record too short")
        }

        let compression = Int(headerData[0]) << 8 | Int(headerData[1])
        let numTextRecords = Int(headerData[8]) << 8 | Int(headerData[9])

        var bookTitle = azwURL.deletingPathExtension().lastPathComponent
        // Check MOBI header title
        if headerData.count >= 92 &&
           headerData[16] == 0x4D && headerData[17] == 0x4F && headerData[18] == 0x42 && headerData[19] == 0x49 {
            let titleOffset = Int(headerData[84]) << 24 | Int(headerData[85]) << 16 | Int(headerData[86]) << 8 | Int(headerData[87])
            let titleLength = Int(headerData[88]) << 24 | Int(headerData[89]) << 16 | Int(headerData[90]) << 8 | Int(headerData[91])
            if titleOffset + titleLength <= headerData.count && titleLength > 0 {
                let titleBytes = headerData.subdata(in: titleOffset..<(titleOffset + titleLength))
                if let t = String(data: titleBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    bookTitle = t
                }
            }
        }

        var decompressedTextData = Data()
        let startTextIndex = baseRecord + 1
        let endTextIndex = min(baseRecord + numTextRecords, recordOffsets.count - 1)

        if startTextIndex <= endTextIndex {
            for i in startTextIndex...endTextIndex {
                let start = recordOffsets[i]
                let end = (i + 1 < recordOffsets.count) ? recordOffsets[i + 1] : data.count
                guard start < data.count, end <= data.count, end > start else { continue }
                let recordData = data.subdata(in: start..<end)

                if compression == 1 {
                    decompressedTextData.append(recordData)
                } else if compression == 2 {
                    let decomp = decompressPalmDOC(data: recordData)
                    decompressedTextData.append(decomp)
                } else {
                    // Try zlib deflate first, then PalmDOC
                    if let zlibDecomp = try? (recordData as NSData).decompressed(using: .zlib) as Data {
                        decompressedTextData.append(zlibDecomp)
                    } else {
                        let decomp = decompressPalmDOC(data: recordData)
                        decompressedTextData.append(decomp)
                    }
                }
            }
        }

        // If decompressed data is empty and we had a KF8 boundary, fall back to MOBI7 (baseRecord 0)
        if decompressedTextData.isEmpty && baseRecord > 0 {
            try convertMOBI(mobiURL: azwURL, targetPDF: targetPDF)
            return
        }

        guard !decompressedTextData.isEmpty else {
            throw EBookConverterError.conversionFailed("AZW3 decompressed text is empty")
        }

        var fullHTML = String(data: decompressedTextData, encoding: .utf8) ??
                       String(data: decompressedTextData, encoding: .windowsCP1252) ??
                       String(decoding: decompressedTextData, as: UTF8.self)

        fullHTML = fullHTML.replacingOccurrences(of: "<mbp:pagebreak/>", with: "<div class=\"page-break\"></div>")
        fullHTML = fullHTML.replacingOccurrences(of: "<mbp:pagebreak>", with: "<div class=\"page-break\"></div>")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AZW3_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var rawChapters: [String] = []
        if fullHTML.contains("<div class=\"page-break\"></div>") {
            rawChapters = fullHTML.components(separatedBy: "<div class=\"page-break\"></div>")
        } else {
            var remaining = fullHTML[...]
            let chunkSize = 20000
            while !remaining.isEmpty {
                let take = min(chunkSize, remaining.count)
                rawChapters.append(String(remaining.prefix(take)))
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
            title: bookTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 10. PalmDOC / eReader (PDB) Converter

    public static func convertPDB(pdbURL: URL, targetPDF: URL) throws {
        guard let data = try? Data(contentsOf: pdbURL), data.count >= 78 else {
            throw EBookConverterError.conversionFailed("Invalid or empty PDB file")
        }

        let rawName = data.subdata(in: 0..<32)
        let pdbName = (String(data: rawName, encoding: .ascii) ?? "")
            .components(separatedBy: "\0").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let docTitle = (pdbName?.isEmpty == false ? pdbName : nil) ?? pdbURL.deletingPathExtension().lastPathComponent

        let numRecords = Int(data[76]) << 8 | Int(data[77])
        guard numRecords >= 2 else {
            throw EBookConverterError.conversionFailed("PDB record count < 2")
        }

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
            throw EBookConverterError.conversionFailed("PDB record offset table corrupt")
        }

        let rec0Start = recordOffsets[0]
        let rec0End = recordOffsets[1]
        guard rec0Start < data.count, rec0End <= data.count, rec0End > rec0Start else {
            throw EBookConverterError.conversionFailed("Invalid PDB record 0 boundaries")
        }
        let rec0Data = data.subdata(in: rec0Start..<rec0End)

        // Delegate to MOBI if MOBI magic is present
        if rec0Data.count >= 20 &&
           rec0Data[16] == 0x4D && rec0Data[17] == 0x4F && rec0Data[18] == 0x42 && rec0Data[19] == 0x49 {
            try convertMOBI(mobiURL: pdbURL, targetPDF: targetPDF)
            return
        }

        guard rec0Data.count >= 10 else {
            throw EBookConverterError.conversionFailed("PDB record 0 too short")
        }

        let compression = Int(rec0Data[0]) << 8 | Int(rec0Data[1])
        let numTextRecords = Int(rec0Data[8]) << 8 | Int(rec0Data[9])

        var decompressedTextData = Data()
        let maxTextRecord = min(numTextRecords, recordOffsets.count - 1)

        for i in 1...maxTextRecord {
            let start = recordOffsets[i]
            let end = (i + 1 < recordOffsets.count) ? recordOffsets[i + 1] : data.count
            guard start < data.count, end <= data.count, end > start else { continue }
            let recordData = data.subdata(in: start..<end)

            if compression == 1 {
                decompressedTextData.append(recordData)
            } else if compression == 2 {
                let decomp = decompressPalmDOC(data: recordData)
                decompressedTextData.append(decomp)
            } else {
                if let zlibDecomp = try? (recordData as NSData).decompressed(using: .zlib) as Data {
                    decompressedTextData.append(zlibDecomp)
                } else {
                    let decomp = decompressPalmDOC(data: recordData)
                    decompressedTextData.append(decomp)
                }
            }
        }

        guard !decompressedTextData.isEmpty else {
            throw EBookConverterError.conversionFailed("PDB decompressed text is empty")
        }

        var text = String(data: decompressedTextData, encoding: .utf8) ??
                   String(data: decompressedTextData, encoding: .windowsCP1252) ??
                   String(data: decompressedTextData, encoding: .isoLatin1) ??
                   String(decoding: decompressedTextData, as: UTF8.self)

        let isPML = text.contains("\\p") || text.contains("\\h") || text.contains("\\b")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PDB_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        if isPML {
            text = text.replacingOccurrences(of: "\\b", with: "<strong>")
            text = text.replacingOccurrences(of: "\\i", with: "<em>")
            text = text.replacingOccurrences(of: "\\u", with: "<u>")
            text = text.replacingOccurrences(of: "\\c", with: "<div style=\"text-align:center\">")
            text = text.replacingOccurrences(of: "\\r", with: "<br/>")
            text = text.replacingOccurrences(of: "\\p", with: "<div class=\"page-break\"></div>")
            text = text.replacingOccurrences(of: "\\P", with: "<div class=\"page-break\"></div>")
            text = text.replacingOccurrences(of: "\\\\h=([^\\\\]*)\\\\", with: "<h2>$1</h2>", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\\\[a-zA-Z0-9=\"]+", with: "", options: .regularExpression)
        }

        var rawChapters: [String] = []
        if text.contains("<div class=\"page-break\"></div>") {
            rawChapters = text.components(separatedBy: "<div class=\"page-break\"></div>")
        } else {
            var remaining = text[...]
            let chunkSize = 20000
            while !remaining.isEmpty {
                let take = min(chunkSize, remaining.count)
                rawChapters.append(String(remaining.prefix(take)))
                remaining = remaining.dropFirst(take)
            }
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, chapContent) in rawChapters.enumerated() {
            let chapTitle = "Section \(idx + 1)"
            let contentHTML = isPML ? chapContent : chapContent.components(separatedBy: .newlines).map {
                let tr = $0.trimmingCharacters(in: .whitespaces)
                return tr.isEmpty ? "" : "<p>\(escapeHTML(tr))</p>"
            }.joined(separator: "\n")

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
              h1, h2, h3 { font-family: -apple-system, sans-serif; font-weight: 600; margin-top: 14pt; margin-bottom: 10pt; color: #111; }
              p { margin-top: 0; margin-bottom: 10pt; text-indent: 1.5em; text-align: justify; }
            </style>
            </head>
            <body>
              \(idx == 0 ? "<h1>\(escapeHTML(docTitle))</h1>" : "")
              \(contentHTML)
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
            title: docTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 11. Office Documents (DOCX / DOC / ODT) Converter

    public static func convertOfficeDocument(officeURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OFFICE_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let htmlURL = tempDir.appendingPathComponent("index.html")
        var htmlGenerated = false

        // Attempt 1: Native macOS /usr/bin/textutil
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "html", officeURL.path, "-output", htmlURL.path]
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: htmlURL.path) {
                htmlGenerated = true
            }
        }

        // Attempt 2: AppKit NSAttributedString fallback
        if !htmlGenerated {
            let ext = officeURL.pathExtension.lowercased()
            let docType: NSAttributedString.DocumentType
            if ext == "docx" {
                docType = .officeOpenXML
            } else if ext == "odt" {
                docType = .openDocument
            } else {
                docType = .wordML
            }
            if let attrStr = (try? NSAttributedString(url: officeURL, options: [.documentType: docType], documentAttributes: nil)) ??
                             (try? NSAttributedString(url: officeURL, options: [:], documentAttributes: nil)),
               let htmlData = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
                try? htmlData.write(to: htmlURL)
                htmlGenerated = true
            }
        }

        guard htmlGenerated, let rawHTML = try? String(contentsOf: htmlURL, encoding: .utf8) else {
            throw EBookConverterError.conversionFailed("Unable to convert office document to HTML")
        }

        let fallbackTitle = officeURL.deletingPathExtension().lastPathComponent
        var docTitle = fallbackTitle
        if let titleRange = rawHTML.range(of: "<title>([^<]+)</title>", options: .regularExpression) {
            let sub = rawHTML[titleRange]
            if let s = sub.firstIndex(of: ">"), let e = sub.lastIndex(of: "<"), s < e {
                let parsed = String(sub[sub.index(after: s)..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !parsed.isEmpty { docTitle = parsed }
            }
        }

        var tocItems: [(title: String, targetURL: URL)] = []
        let headingRegex = try? NSRegularExpression(pattern: "<h[1-3][^>]*>([\\s\\S]*?)</h[1-3]>", options: .caseInsensitive)
        if let matches = headingRegex?.matches(in: rawHTML, options: [], range: NSRange(location: 0, length: rawHTML.utf16.count)) {
            for m in matches {
                if let r = Range(m.range(at: 1), in: rawHTML) {
                    let hText = String(rawHTML[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hText.isEmpty {
                        tocItems.append((title: hText, targetURL: htmlURL))
                    }
                }
            }
        }
        if tocItems.isEmpty {
            tocItems.append((title: docTitle, targetURL: htmlURL))
        }

        let styledCSS = """
        <style>
          @page { margin: 40pt 48pt; size: letter; }
          body {
            font-family: -apple-system, "Georgia", "Times New Roman", serif;
            font-size: 13.5pt;
            line-height: 1.65;
            color: #1a1a1a;
            margin: 0;
            padding: 40pt 48pt;
          }
          h1, h2, h3, h4 { font-family: -apple-system, sans-serif; font-weight: 600; color: #111; margin-top: 18pt; margin-bottom: 8pt; }
          h1 { font-size: 22pt; border-bottom: 1px solid #e0e0e0; padding-bottom: 6pt; }
          h2 { font-size: 17pt; }
          p { margin-top: 0; margin-bottom: 10pt; text-align: justify; }
          table { border-collapse: collapse; width: 100%; margin: 16pt 0; }
          th, td { border: 1px solid #ddd; padding: 6pt 10pt; text-align: left; }
          th { background: #f5f5f5; font-weight: 600; }
          img { max-width: 100%; height: auto; display: block; margin: 12pt auto; border-radius: 4pt; }
        </style>
        """

        var finalHTML = rawHTML
        if let headIndex = finalHTML.range(of: "</head>", options: .caseInsensitive)?.lowerBound {
            finalHTML.insert(contentsOf: styledCSS, at: headIndex)
        } else {
            finalHTML = styledCSS + finalHTML
        }
        try finalHTML.write(to: htmlURL, atomically: true, encoding: .utf8)

        try renderHTMLChapters(
            chapterURLs: [htmlURL],
            readAccessURL: tempDir,
            title: docTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 12. Compiled HTML Help (CHM) Converter

    public static func convertCHM(chmURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CHM_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var extracted = false

        // Method 1: extract_chmLib if present
        if let chmLib = findExecutable(named: "extract_chmLib") {
            let proc = Process()
            proc.executableURL = chmLib
            proc.arguments = [chmURL.path, tempDir.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                extracted = true
            }
        }

        // Method 2: 7z if present
        if !extracted, let sevenZip = findExecutable(named: "7z") {
            let proc = Process()
            proc.executableURL = sevenZip
            proc.arguments = ["x", "-y", chmURL.path, "-o\(tempDir.path)"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                extracted = true
            }
        }

        // Method 3: Built-in ITSF / HTML string extractor
        if !extracted {
            guard let data = try? Data(contentsOf: chmURL), data.count >= 100 else {
                throw EBookConverterError.conversionFailed("CHM file is empty or unreadable")
            }
            let isITSF = data[0] == 0x49 && data[1] == 0x54 && data[2] == 0x53 && data[3] == 0x46
            guard isITSF else {
                throw EBookConverterError.conversionFailed("Not a valid ITSF CHM file")
            }

            let text = String(decoding: data, as: UTF8.self)
            var htmlChunks: [String] = []
            let htmlRegex = try? NSRegularExpression(pattern: "<html[\\s\\S]*?</html>", options: .caseInsensitive)
            if let matches = htmlRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)), !matches.isEmpty {
                for m in matches {
                    if let r = Range(m.range, in: text) {
                        htmlChunks.append(String(text[r]))
                    }
                }
            }

            if !htmlChunks.isEmpty {
                for (i, chunk) in htmlChunks.enumerated() {
                    let finalHTML: String
                    let lower = chunk.lowercased()
                    if lower.contains("<!doctype") || lower.contains("<html") {
                        if !lower.contains("charset") && lower.contains("<head>") {
                            finalHTML = chunk.replacingOccurrences(of: "<head>", with: "<head><meta charset=\"utf-8\">", options: .caseInsensitive)
                        } else {
                            finalHTML = chunk
                        }
                    } else {
                        finalHTML = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(chunk)</body></html>"
                    }
                    let file = tempDir.appendingPathComponent("extracted_\(i).html")
                    try? finalHTML.write(to: file, atomically: true, encoding: .utf8)
                }
                extracted = true
            }
        }

        guard extracted else {
            throw EBookConverterError.conversionFailed("Failed to unpack CHM archive")
        }

        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw EBookConverterError.conversionFailed("Unable to read extracted CHM directory")
        }

        var htmlFiles: [URL] = []
        var hhcFile: URL? = nil

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "html" || ext == "htm" || ext == "xhtml" {
                htmlFiles.append(fileURL)
            } else if ext == "hhc" {
                hhcFile = fileURL
            }
        }

        guard !htmlFiles.isEmpty else {
            throw EBookConverterError.conversionFailed("No readable HTML topics found in CHM file")
        }

        let fallbackTitle = chmURL.deletingPathExtension().lastPathComponent
        let docTitle = fallbackTitle
        var tocItems: [(title: String, targetURL: URL)] = []
        var orderedURLs: [URL] = []

        if let hhcURL = hhcFile, let hhcContent = (try? String(contentsOf: hhcURL, encoding: .utf8)) ?? (try? String(contentsOf: hhcURL, encoding: .windowsCP1252)) {
            let itemRegex = try? NSRegularExpression(pattern: "<param\\s+name=\"Name\"\\s+value=\"([^\"]+)\"[^>]*>\\s*(?:<param\\s+name=\"Local\"\\s+value=\"([^\"]+)\")?", options: .caseInsensitive)
            if let matches = itemRegex?.matches(in: hhcContent, options: [], range: NSRange(location: 0, length: hhcContent.utf16.count)) {
                for m in matches {
                    if let nameR = Range(m.range(at: 1), in: hhcContent) {
                        let name = String(hhcContent[nameR]).trimmingCharacters(in: .whitespacesAndNewlines)
                        var localURL: URL? = nil
                        if m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound,
                           let localR = Range(m.range(at: 2), in: hhcContent) {
                            let localPath = String(hhcContent[localR]).components(separatedBy: "#").first ?? ""
                            let cleanPath = localPath.replacingOccurrences(of: "\\", with: "/")
                            let candidate = tempDir.appendingPathComponent(cleanPath)
                            if FileManager.default.fileExists(atPath: candidate.path) {
                                localURL = candidate
                            }
                        }
                        if let u = localURL {
                            tocItems.append((title: name, targetURL: u))
                            if !orderedURLs.contains(u) {
                                orderedURLs.append(u)
                            }
                        }
                    }
                }
            }
        }

        if orderedURLs.isEmpty {
            htmlFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            orderedURLs = htmlFiles
            for u in htmlFiles {
                let name = u.deletingPathExtension().lastPathComponent
                tocItems.append((title: name, targetURL: u))
            }
        }

        try renderHTMLChapters(
            chapterURLs: orderedURLs,
            readAccessURL: tempDir,
            title: docTitle,
            author: "",
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    // MARK: - 13. DjVu Document (DJVU / DJV) Converter

    public static func convertDJVU(djvuURL: URL, targetPDF: URL) throws {
        // Method 1: ddjvu if present
        if let ddjvu = findExecutable(named: "ddjvu") {
            let proc = Process()
            proc.executableURL = ddjvu
            proc.arguments = ["-format=pdf", "-quality=100", djvuURL.path, targetPDF.path]
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 &&
               FileManager.default.fileExists(atPath: targetPDF.path) &&
               ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024 {
                return
            }
        }

        // Method 2: Native pure-Swift DjVu parser (extract OCR text layer)
        guard let data = try? Data(contentsOf: djvuURL), data.count >= 16 else {
            throw EBookConverterError.conversionFailed("DjVu file is empty or unreadable")
        }

        let isATT = data[0] == 0x41 && data[1] == 0x54 && data[2] == 0x26 && data[3] == 0x54
        guard isATT else {
            throw EBookConverterError.conversionFailed("Not a valid DjVu document (missing AT&T header)")
        }

        let docTitle = djvuURL.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DJVU_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var extractedPages: [String] = []
        var offset = 4

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self)
            let chunkSize = Int(data[offset + 4]) << 24 |
                            Int(data[offset + 5]) << 16 |
                            Int(data[offset + 6]) << 8 |
                            Int(data[offset + 7])
            let nextOffset = offset + 8 + chunkSize + (chunkSize % 2)

            if chunkID == "FORM" || chunkID == "DJVM" || chunkID == "DJVU" {
                offset += 12
                continue
            }

            if chunkID == "TXTz" {
                let chunkStart = offset + 8
                let chunkEnd = min(chunkStart + chunkSize, data.count)
                if chunkEnd > chunkStart {
                    let chunkData = data.subdata(in: chunkStart..<chunkEnd)
                    if let decompressed = try? (chunkData as NSData).decompressed(using: .zlib) as Data {
                        let text = parseDjVuSExpression(data: decompressed)
                        if !text.isEmpty {
                            extractedPages.append(text)
                        }
                    }
                }
            } else if chunkID == "TX3t" {
                let chunkStart = offset + 8
                let chunkEnd = min(chunkStart + chunkSize, data.count)
                if chunkEnd > chunkStart {
                    let chunkData = data.subdata(in: chunkStart..<chunkEnd)
                    let text = parseDjVuSExpression(data: chunkData)
                    if !text.isEmpty {
                        extractedPages.append(text)
                    }
                }
            }

            offset = nextOffset
        }

        if extractedPages.isEmpty {
            extractedPages.append("This DjVu document does not contain an embedded OCR text layer.")
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, pageText) in extractedPages.enumerated() {
            let pageNum = idx + 1
            let pageHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, "Georgia", "Times New Roman", serif;
                font-size: 13.5pt;
                line-height: 1.6;
                color: #1a1a1a;
                margin: 0;
                padding: 40pt 48pt;
              }
              .page-header { font-size: 9pt; color: #888; border-bottom: 1px solid #e0e0e0; padding-bottom: 4pt; margin-bottom: 16pt; }
              p { margin-top: 0; margin-bottom: 8pt; text-align: justify; }
            </style>
            </head>
            <body>
              <div class="page-header">\(escapeHTML(docTitle)) – Page \(pageNum)</div>
              \(pageText.components(separatedBy: .newlines).map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n"))
            </body>
            </html>
            """
            let chapURL = tempDir.appendingPathComponent("page_\(idx).html")
            try pageHTML.write(to: chapURL, atomically: true, encoding: .utf8)
            chapterURLs.append(chapURL)
            tocItems.append((title: "Page \(pageNum)", targetURL: chapURL))
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

    private static func parseDjVuSExpression(data: Data) -> String {
        guard let rawStr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ""
        }
        var words: [String] = []
        let wordRegex = try? NSRegularExpression(pattern: "\"([^\"]+)\"", options: [])
        if let matches = wordRegex?.matches(in: rawStr, options: [], range: NSRange(location: 0, length: rawStr.utf16.count)) {
            for m in matches {
                if let r = Range(m.range(at: 1), in: rawStr) {
                    words.append(String(rawStr[r]))
                }
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: - 14. LaTeX (TEX / LATEX) Converter

    public static func convertLaTeX(texURL: URL, targetPDF: URL) throws {
        guard let texStr = (try? String(contentsOf: texURL, encoding: .utf8)) ?? (try? String(contentsOf: texURL, encoding: .isoLatin1)) else {
            throw EBookConverterError.fileNotFound(texURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TEX_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallbackTitle = texURL.deletingPathExtension().lastPathComponent
        var docTitle = fallbackTitle
        var docAuthor = ""

        if let tRange = texStr.range(of: "\\\\title\\{([^\\}]+)\\}", options: .regularExpression) {
            let sub = texStr[tRange]
            if let s = sub.firstIndex(of: "{"), let e = sub.lastIndex(of: "}"), s < e {
                docTitle = String(sub[sub.index(after: s)..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let aRange = texStr.range(of: "\\\\author\\{([^\\}]+)\\}", options: .regularExpression) {
            let sub = texStr[aRange]
            if let s = sub.firstIndex(of: "{"), let e = sub.lastIndex(of: "}"), s < e {
                docAuthor = String(sub[sub.index(after: s)..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lines = texStr.components(separatedBy: .newlines)
        var sections: [(title: String, content: String)] = []
        var curTitle = docTitle
        var curLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\chapter{") || trimmed.hasPrefix("\\section{") {
                if !curLines.isEmpty {
                    sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
                    curLines = []
                }
                if let s = trimmed.firstIndex(of: "{"), let e = trimmed.lastIndex(of: "}"), s < e {
                    curTitle = String(trimmed[trimmed.index(after: s)..<e])
                }
            }
            curLines.append(line)
        }
        if !curLines.isEmpty {
            sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
        }
        if sections.isEmpty {
            sections.append((title: docTitle, content: texStr))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, sec) in sections.enumerated() {
            let renderedBody = latexToHTML(sec.content)
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: "Latin Modern Roman", "Cambria", "Georgia", "Times New Roman", serif;
                font-size: 13pt;
                line-height: 1.65;
                color: #111;
                margin: 0;
                padding: 40pt 48pt;
              }
              .doc-header { text-align: center; margin-bottom: 24pt; padding-bottom: 16pt; border-bottom: 1px solid #ccc; }
              .doc-title { font-size: 22pt; font-weight: 700; margin-bottom: 6pt; }
              .doc-author { font-size: 14pt; color: #444; font-style: italic; }
              h1, h2, h3, h4 { font-family: "Latin Modern Roman", serif; font-weight: 700; color: #000; margin-top: 18pt; margin-bottom: 8pt; }
              h1 { font-size: 19pt; }
              h2 { font-size: 16pt; }
              h3 { font-size: 14pt; }
              p { margin-top: 0; margin-bottom: 8pt; text-indent: 1.5em; text-align: justify; }
              .equation { text-align: center; margin: 14pt 0; font-style: italic; font-family: "Cambria Math", "Latin Modern Math", serif; }
              blockquote { margin: 12pt 24pt; font-style: italic; color: #333; }
              pre { background: #f8f8f8; border: 1px solid #e0e0e0; padding: 10pt; border-radius: 4pt; font-family: monospace; font-size: 11pt; }
              ul, ol { padding-left: 24pt; margin-bottom: 10pt; }
              li { margin-bottom: 4pt; }
            </style>
            </head>
            <body>
              \(idx == 0 ? """
              <div class="doc-header">
                <div class="doc-title">\(escapeHTML(docTitle))</div>
                \(docAuthor.isEmpty ? "" : "<div class=\"doc-author\">\(escapeHTML(docAuthor))</div>")
              </div>
              """ : "")
              \(renderedBody)
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
            author: docAuthor,
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    public static func latexToHTML(_ latex: String) -> String {
        var text = latex

        // Remove comments
        text = text.replacingOccurrences(of: "(?m)^\\s*%.*$", with: "", options: .regularExpression)

        // Equations and math
        text = text.replacingOccurrences(of: "\\\\begin\\{equation\\*?\\}([\\s\\S]*?)\\\\end\\{equation\\*?\\}", with: "<div class=\"equation\">$1</div>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\begin\\{align\\*?\\}([\\s\\S]*?)\\\\end\\{align\\*?\\}", with: "<div class=\"equation\">$1</div>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\\\[([\\s\\S]*?)\\\\\\]", with: "<div class=\"equation\">$1</div>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\$\\$([\\s\\S]*?)\\$\\$", with: "<div class=\"equation\">$1</div>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\$([^\\$]+)\\$", with: "<em>$1</em>", options: .regularExpression)

        // Sectioning
        text = text.replacingOccurrences(of: "\\\\chapter\\*?\\{([^\\}]+)\\}", with: "<h1>$1</h1>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\section\\*?\\{([^\\}]+)\\}", with: "<h2>$1</h2>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\subsection\\*?\\{([^\\}]+)\\}", with: "<h3>$1</h3>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\subsubsection\\*?\\{([^\\}]+)\\}", with: "<h4>$1</h4>", options: .regularExpression)

        // Styling
        text = text.replacingOccurrences(of: "\\\\textbf\\{([^\\}]+)\\}", with: "<strong>$1</strong>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\textit\\{([^\\}]+)\\}", with: "<em>$1</em>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\emph\\{([^\\}]+)\\}", with: "<em>$1</em>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\underline\\{([^\\}]+)\\}", with: "<u>$1</u>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\texttt\\{([^\\}]+)\\}", with: "<code>$1</code>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\href\\{([^\\}]+)\\}\\{([^\\}]+)\\}", with: "<a href=\"$1\">$2</a>", options: .regularExpression)

        // Environments
        text = text.replacingOccurrences(of: "\\\\begin\\{itemize\\}", with: "<ul>")
        text = text.replacingOccurrences(of: "\\\\end\\{itemize\\}", with: "</ul>")
        text = text.replacingOccurrences(of: "\\\\begin\\{enumerate\\}", with: "<ol>")
        text = text.replacingOccurrences(of: "\\\\end\\{enumerate\\}", with: "</ol>")
        text = text.replacingOccurrences(of: "\\\\item\\s*", with: "<li>", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\\\begin\\{quote\\}", with: "<blockquote>")
        text = text.replacingOccurrences(of: "\\\\end\\{quote\\}", with: "</blockquote>")
        text = text.replacingOccurrences(of: "\\\\begin\\{verbatim\\}([\\s\\S]*?)\\\\end\\{verbatim\\}", with: "<pre><code>$1</code></pre>", options: .regularExpression)

        let paras = text.components(separatedBy: "\n\n")
        let htmlParas = paras.map { p -> String in
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("<h") || trimmed.hasPrefix("<div") || trimmed.hasPrefix("<ul") || trimmed.hasPrefix("<ol") || trimmed.hasPrefix("<pre") || trimmed.hasPrefix("<block") {
                return trimmed
            }
            return "<p>\(trimmed)</p>"
        }
        return htmlParas.joined(separator: "\n")
    }

    // MARK: - 15. AsciiDoc (ADOC / ASCIIDOC) Converter

    public static func convertAsciiDoc(adocURL: URL, targetPDF: URL) throws {
        guard let adocStr = try? String(contentsOf: adocURL, encoding: .utf8) else {
            throw EBookConverterError.fileNotFound(adocURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ADOC_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallbackTitle = adocURL.deletingPathExtension().lastPathComponent
        var docTitle = fallbackTitle
        var docAuthor = ""

        let lines = adocStr.components(separatedBy: .newlines)
        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("= ") && !tr.hasPrefix("== ") {
                docTitle = String(tr.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if tr.hasPrefix(":author:") {
                docAuthor = String(tr.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            }
        }

        var sections: [(title: String, content: String)] = []
        var curTitle = docTitle
        var curLines: [String] = []

        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("== ") {
                if !curLines.isEmpty {
                    sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
                    curLines = []
                }
                curTitle = String(tr.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            curLines.append(line)
        }
        if !curLines.isEmpty {
            sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
        }
        if sections.isEmpty {
            sections.append((title: docTitle, content: adocStr))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, sec) in sections.enumerated() {
            let renderedBody = asciiDocToHTML(sec.content)
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                font-size: 13.5pt;
                line-height: 1.6;
                color: #262626;
                margin: 0;
                padding: 40pt 48pt;
              }
              h1, h2, h3, h4 { color: #ba3925; font-weight: 600; margin-top: 20pt; margin-bottom: 8pt; }
              h1 { font-size: 22pt; border-bottom: 1px solid #dddddd; padding-bottom: 6pt; }
              h2 { font-size: 17pt; border-bottom: 1px solid #eeeeee; padding-bottom: 4pt; }
              h3 { font-size: 14pt; }
              p { margin-top: 0; margin-bottom: 10pt; }
              .admonition { border-left: 4px solid #ba3925; background: #fafafa; padding: 10pt 14pt; margin: 12pt 0; border-radius: 0 4pt 4pt 0; }
              .admonition-title { font-weight: bold; margin-bottom: 4pt; color: #ba3925; }
              pre { background: #f5f5f5; border: 1px solid #e5e5e5; padding: 10pt; border-radius: 4pt; font-family: monospace; font-size: 11pt; }
              code { background: #f5f5f5; padding: 2pt 4pt; border-radius: 3pt; font-family: monospace; font-size: 11pt; }
              ul, ol { padding-left: 20pt; margin-bottom: 10pt; }
            </style>
            </head>
            <body>
              \(idx == 0 ? "<h1>\(escapeHTML(docTitle))</h1>" : "")
              \(renderedBody)
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
            author: docAuthor,
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    public static func asciiDocToHTML(_ adoc: String) -> String {
        var html = ""
        let lines = adoc.components(separatedBy: .newlines)
        var inSourceBlock = false
        var inList = false

        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)

            if tr == "----" || tr == "...." {
                if inSourceBlock {
                    html += "</code></pre>\n"
                    inSourceBlock = false
                } else {
                    html += "<pre><code>"
                    inSourceBlock = true
                }
                continue
            }

            if inSourceBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            if tr.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                continue
            }

            if tr.hasPrefix("== ") {
                html += "<h2>\(escapeHTML(String(tr.dropFirst(3))))</h2>\n"
            } else if tr.hasPrefix("=== ") {
                html += "<h3>\(escapeHTML(String(tr.dropFirst(4))))</h3>\n"
            } else if tr.hasPrefix("==== ") {
                html += "<h4>\(escapeHTML(String(tr.dropFirst(5))))</h4>\n"
            } else if tr.hasPrefix("NOTE:") || tr.hasPrefix("TIP:") || tr.hasPrefix("WARNING:") || tr.hasPrefix("IMPORTANT:") || tr.hasPrefix("CAUTION:") {
                let parts = tr.components(separatedBy: ":")
                let tag = parts.first ?? "NOTE"
                let body = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                html += "<div class=\"admonition\"><div class=\"admonition-title\">\(tag)</div><p>\(escapeHTML(body))</p></div>\n"
            } else if tr.hasPrefix("* ") {
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(parseInlineAsciiDoc(String(tr.dropFirst(2))))</li>\n"
            } else {
                html += "<p>\(parseInlineAsciiDoc(tr))</p>\n"
            }
        }

        if inSourceBlock { html += "</code></pre>\n" }
        if inList { html += "</ul>\n" }
        return html
    }

    private static func parseInlineAsciiDoc(_ text: String) -> String {
        var res = escapeHTML(text)
        res = res.replacingOccurrences(of: "\\*(.*?)\\*", with: "<strong>$1</strong>", options: .regularExpression)
        res = res.replacingOccurrences(of: "_(.*?)_", with: "<em>$1</em>", options: .regularExpression)
        res = res.replacingOccurrences(of: "`(.*?)`", with: "<code>$1</code>", options: .regularExpression)
        res = res.replacingOccurrences(of: "(https?://[^\\s\\[]+)\\[([^\\]]+)\\]", with: "<a href=\"$1\">$2</a>", options: .regularExpression)
        return res
    }

    // MARK: - 16. Emacs Org-Mode (ORG) Converter

    public static func convertOrgMode(orgURL: URL, targetPDF: URL) throws {
        guard let orgStr = try? String(contentsOf: orgURL, encoding: .utf8) else {
            throw EBookConverterError.fileNotFound(orgURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ORG_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallbackTitle = orgURL.deletingPathExtension().lastPathComponent
        var docTitle = fallbackTitle
        var docAuthor = ""

        let lines = orgStr.components(separatedBy: .newlines)
        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.uppercased().hasPrefix("#+TITLE:") {
                docTitle = String(tr.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if tr.uppercased().hasPrefix("#+AUTHOR:") {
                docAuthor = String(tr.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        var sections: [(title: String, content: String)] = []
        var curTitle = docTitle
        var curLines: [String] = []

        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("* ") {
                if !curLines.isEmpty {
                    sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
                    curLines = []
                }
                curTitle = String(tr.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            curLines.append(line)
        }
        if !curLines.isEmpty {
            sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
        }
        if sections.isEmpty {
            sections.append((title: docTitle, content: orgStr))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, sec) in sections.enumerated() {
            let renderedBody = orgModeToHTML(sec.content)
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                font-size: 13.5pt;
                line-height: 1.6;
                color: #2f363d;
                margin: 0;
                padding: 40pt 48pt;
              }
              h1, h2, h3, h4 { color: #0366d6; font-weight: 600; margin-top: 20pt; margin-bottom: 8pt; }
              h1 { font-size: 22pt; border-bottom: 1px solid #e1e4e8; padding-bottom: 6pt; }
              h2 { font-size: 17pt; border-bottom: 1px solid #eaecef; padding-bottom: 4pt; }
              h3 { font-size: 14pt; }
              p { margin-top: 0; margin-bottom: 10pt; }
              .org-todo { background: #d73a49; color: white; padding: 2pt 5pt; border-radius: 3pt; font-size: 9pt; font-weight: bold; margin-right: 6pt; }
              .org-done { background: #28a745; color: white; padding: 2pt 5pt; border-radius: 3pt; font-size: 9pt; font-weight: bold; margin-right: 6pt; }
              pre { background: #f6f8fa; border: 1px solid #e1e4e8; padding: 10pt; border-radius: 6pt; font-family: monospace; font-size: 11pt; }
              code { background: #f6f8fa; padding: 2pt 4pt; border-radius: 3pt; font-family: monospace; font-size: 11pt; }
              table { border-collapse: collapse; width: 100%; margin: 12pt 0; }
              th, td { border: 1px solid #dfe2e5; padding: 6pt 10pt; }
              th { background: #f6f8fa; font-weight: 600; }
            </style>
            </head>
            <body>
              \(idx == 0 ? "<h1>\(escapeHTML(docTitle))</h1>" : "")
              \(renderedBody)
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
            author: docAuthor,
            tocItems: tocItems,
            targetPDF: targetPDF
        )
    }

    public static func orgModeToHTML(_ org: String) -> String {
        var html = ""
        let lines = org.components(separatedBy: .newlines)
        var inSrcBlock = false
        var inList = false

        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)

            if tr.uppercased().hasPrefix("#+BEGIN_SRC") {
                inSrcBlock = true
                html += "<pre><code>"
                continue
            }
            if tr.uppercased().hasPrefix("#+END_SRC") {
                inSrcBlock = false
                html += "</code></pre>\n"
                continue
            }
            if inSrcBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            if tr.hasPrefix("#+") { continue }
            if tr.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                continue
            }

            if tr.hasPrefix("* ") {
                html += "<h2>\(formatOrgHeadline(String(tr.dropFirst(2))))</h2>\n"
            } else if tr.hasPrefix("** ") {
                html += "<h3>\(formatOrgHeadline(String(tr.dropFirst(3))))</h3>\n"
            } else if tr.hasPrefix("*** ") {
                html += "<h4>\(formatOrgHeadline(String(tr.dropFirst(4))))</h4>\n"
            } else if tr.hasPrefix("- ") || tr.hasPrefix("+ ") {
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(parseInlineOrg(String(tr.dropFirst(2))))</li>\n"
            } else {
                html += "<p>\(parseInlineOrg(tr))</p>\n"
            }
        }

        if inSrcBlock { html += "</code></pre>\n" }
        if inList { html += "</ul>\n" }
        return html
    }

    private static func formatOrgHeadline(_ text: String) -> String {
        var str = text
        if str.hasPrefix("TODO ") {
            str = "<span class=\"org-todo\">TODO</span> " + escapeHTML(String(str.dropFirst(5)))
        } else if str.hasPrefix("DONE ") {
            str = "<span class=\"org-done\">DONE</span> " + escapeHTML(String(str.dropFirst(5)))
        } else {
            str = escapeHTML(str)
        }
        return str
    }

    private static func parseInlineOrg(_ text: String) -> String {
        var res = escapeHTML(text)
        res = res.replacingOccurrences(of: "\\[\\[(.*?)\\]\\[(.*?)\\]\\]", with: "<a href=\"$1\">$2</a>", options: .regularExpression)
        res = res.replacingOccurrences(of: "\\*(.*?)\\*", with: "<strong>$1</strong>", options: .regularExpression)
        res = res.replacingOccurrences(of: "/(.*?)/", with: "<em>$1</em>", options: .regularExpression)
        res = res.replacingOccurrences(of: "~(.*?)~", with: "<code>$1</code>", options: .regularExpression)
        return res
    }

    // MARK: - 17. reStructuredText (RST) Converter

    public static func convertRST(rstURL: URL, targetPDF: URL) throws {
        guard let rstStr = try? String(contentsOf: rstURL, encoding: .utf8) else {
            throw EBookConverterError.fileNotFound(rstURL.path)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RST_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallbackTitle = rstURL.deletingPathExtension().lastPathComponent
        let lines = rstStr.components(separatedBy: .newlines)

        var docTitle = fallbackTitle
        for i in 0..<lines.count - 1 {
            let cur = lines[i].trimmingCharacters(in: .whitespaces)
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if !cur.isEmpty && next.count >= cur.count && (next.allSatisfy { $0 == "=" } || next.allSatisfy { $0 == "-" }) {
                docTitle = cur
                break
            }
        }

        var sections: [(title: String, content: String)] = []
        var curTitle = docTitle
        var curLines: [String] = []

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let tr = line.trimmingCharacters(in: .whitespaces)
            if i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !tr.isEmpty && next.count >= 3 && next.count >= tr.count && (next.allSatisfy { $0 == "=" } || next.allSatisfy { $0 == "-" }) {
                    if !curLines.isEmpty {
                        sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
                        curLines = []
                    }
                    curTitle = tr
                    curLines.append(line)
                    curLines.append(lines[i + 1])
                    i += 2
                    continue
                }
            }
            curLines.append(line)
            i += 1
        }
        if !curLines.isEmpty {
            sections.append((title: curTitle, content: curLines.joined(separator: "\n")))
        }
        if sections.isEmpty {
            sections.append((title: docTitle, content: rstStr))
        }

        var chapterURLs: [URL] = []
        var tocItems: [(title: String, targetURL: URL)] = []

        for (idx, sec) in sections.enumerated() {
            let renderedBody = rstToHTML(sec.content)
            let fullHTML = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
              @page { margin: 40pt 48pt; size: letter; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                font-size: 13.5pt;
                line-height: 1.6;
                color: #333;
                margin: 0;
                padding: 40pt 48pt;
              }
              h1, h2, h3, h4 { color: #2980b9; font-weight: 600; margin-top: 20pt; margin-bottom: 8pt; }
              h1 { font-size: 22pt; border-bottom: 2px solid #2980b9; padding-bottom: 6pt; }
              h2 { font-size: 17pt; border-bottom: 1px solid #ddd; padding-bottom: 4pt; }
              h3 { font-size: 14pt; }
              p { margin-top: 0; margin-bottom: 10pt; }
              .rst-directive { background: #eef7fa; border-left: 4px solid #2980b9; padding: 10pt 14pt; margin: 12pt 0; border-radius: 0 4pt 4pt 0; }
              .rst-directive-title { font-weight: bold; color: #2980b9; margin-bottom: 4pt; }
              pre { background: #f8f8f8; border: 1px solid #e1e4e8; padding: 10pt; border-radius: 4pt; font-family: monospace; font-size: 11pt; }
              code { background: #f8f8f8; padding: 2pt 4pt; border-radius: 3pt; font-family: monospace; font-size: 11pt; }
              ul, ol { padding-left: 20pt; margin-bottom: 10pt; }
            </style>
            </head>
            <body>
              \(idx == 0 ? "<h1>\(escapeHTML(docTitle))</h1>" : "")
              \(renderedBody)
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

    public static func rstToHTML(_ rst: String) -> String {
        var html = ""
        let lines = rst.components(separatedBy: .newlines)
        var i = 0
        var inCode = false
        var inList = false

        while i < lines.count {
            let line = lines[i]
            let tr = line.trimmingCharacters(in: .whitespaces)

            if i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !tr.isEmpty && next.count >= 3 && next.count >= tr.count && next.allSatisfy({ $0 == "=" }) {
                    html += "<h2>\(escapeHTML(tr))</h2>\n"
                    i += 2
                    continue
                } else if !tr.isEmpty && next.count >= 3 && next.count >= tr.count && next.allSatisfy({ $0 == "-" }) {
                    html += "<h3>\(escapeHTML(tr))</h3>\n"
                    i += 2
                    continue
                }
            }

            if tr.hasPrefix(".. code-block::") || tr.hasPrefix(".. code::") {
                html += "<pre><code>"
                inCode = true
                i += 1
                continue
            }

            if inCode {
                if tr.isEmpty {
                    html += "</code></pre>\n"
                    inCode = false
                } else {
                    html += escapeHTML(line) + "\n"
                }
                i += 1
                continue
            }

            if tr.hasPrefix(".. note::") || tr.hasPrefix(".. warning::") || tr.hasPrefix(".. tip::") || tr.hasPrefix(".. important::") {
                let directive = tr.components(separatedBy: "::").first?.dropFirst(3).trimmingCharacters(in: .whitespaces).capitalized ?? "Note"
                html += "<div class=\"rst-directive\"><div class=\"rst-directive-title\">\(directive)</div>"
                i += 1
                while i < lines.count && (lines[i].hasPrefix("   ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                    let dLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !dLine.isEmpty {
                        html += "<p>\(escapeHTML(dLine))</p>"
                    }
                    i += 1
                }
                html += "</div>\n"
                continue
            }

            if tr.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                i += 1
                continue
            }

            if tr.hasPrefix("* ") || tr.hasPrefix("- ") {
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(parseInlineRST(String(tr.dropFirst(2))))</li>\n"
            } else {
                html += "<p>\(parseInlineRST(tr))</p>\n"
            }
            i += 1
        }

        if inCode { html += "</code></pre>\n" }
        if inList { html += "</ul>\n" }
        return html
    }

    private static func parseInlineRST(_ text: String) -> String {
        var res = escapeHTML(text)
        res = res.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        res = res.replacingOccurrences(of: "\\*(.*?)\\*", with: "<em>$1</em>", options: .regularExpression)
        res = res.replacingOccurrences(of: "``(.*?)``", with: "<code>$1</code>", options: .regularExpression)
        res = res.replacingOccurrences(of: "`([^`<]+)\\s+<([^>]+)>`_", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return res
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
        targetPDF: URL,
        options: TypographyOptions = .default
    ) throws {
        let masterDoc: PDFDocument = try runOnMainThread { (completion: @escaping (Result<PDFDocument, Error>) -> Void) in
            let masterPDF = PDFDocument()
            let renderer = WebKitChapterRenderer(options: options)
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

                let resolvedChap = chapURL.resolvingSymlinksInPath()
                let resolvedAccess = readAccessURL.resolvingSymlinksInPath()
                renderer.render(url: resolvedChap, readAccessURL: resolvedAccess) { res in
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
        var inTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    if inList { html += "</ul>\n"; inList = false }
                    if inBlockquote { html += "</blockquote>\n"; inBlockquote = false }
                    if inTable { html += "</tbody></table>\n"; inTable = false }
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            // Tables: | col1 | col2 |
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 {
                if inList { html += "</ul>\n"; inList = false }
                if inBlockquote { html += "</blockquote>\n"; inBlockquote = false }

                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }

                let isSeparator = cells.allSatisfy { cell in
                    let clean = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                    return clean.isEmpty && !cell.isEmpty
                }

                if isSeparator {
                    continue
                }

                if !inTable {
                    html += "<table><thead><tr>\n"
                    for cell in cells {
                        html += "<th>\(parseInlineMarkdown(cell))</th>\n"
                    }
                    html += "</tr></thead><tbody>\n"
                    inTable = true
                } else {
                    html += "<tr>\n"
                    for cell in cells {
                        html += "<td>\(parseInlineMarkdown(cell))</td>\n"
                    }
                    html += "</tr>\n"
                }
                continue
            } else if inTable {
                html += "</tbody></table>\n"
                inTable = false
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
            } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
                if !inList {
                    html += "<ul class=\"task-list\">\n"
                    inList = true
                }
                html += "<li style=\"list-style: none;\"><input type=\"checkbox\" disabled/> \(parseInlineMarkdown(String(trimmed.dropFirst(6))))</li>\n"
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") || trimmed.hasPrefix("* [x] ") || trimmed.hasPrefix("* [X] ") {
                if !inList {
                    html += "<ul class=\"task-list\">\n"
                    inList = true
                }
                html += "<li style=\"list-style: none;\"><input type=\"checkbox\" checked disabled/> \(parseInlineMarkdown(String(trimmed.dropFirst(6))))</li>\n"
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
        if inTable { html += "</tbody></table>\n" }

        return html
    }

    private static func parseInlineMarkdown(_ text: String) -> String {
        var res = escapeHTML(text)
        // Strikethrough: ~~text~~
        res = res.replacingOccurrences(of: "~~(.*?)~~", with: "<del>$1</del>", options: .regularExpression)
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
            while box.value == nil && Date().timeIntervalSince(start) < 30.0 {
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
            let waitRes = sema.wait(timeout: .now() + 30.0)
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

    public static func normalizingCSS(for options: TypographyOptions = .default) -> String {
        let fs = options.fontSize
        let ls = options.lineSpacing
        let h1 = round(fs * 1.7)
        let h2 = round(fs * 1.4)
        let h3 = round(fs * 1.2)
        let h4 = round(fs * 1.05)
        let h5_6 = fs
        let codeFs = max(9.0, round(fs * 0.85))
        let smallFs = max(8.0, round(fs * 0.8))
        let subFs = max(7.0, round(fs * 0.7))
        let ff = options.fontStyle.cssFontFamily

        return """
        body, p, div, li, a, td, th {
            font-size: \(fs)pt !important;
            line-height: \(ls) !important;
            font-family: \(ff) !important;
        }
        h1, h1 * { font-size: \(h1)pt !important; line-height: 1.25 !important; font-family: \(ff) !important; }
        h2, h2 * { font-size: \(h2)pt !important; line-height: 1.3 !important; font-family: \(ff) !important; }
        h3, h3 * { font-size: \(h3)pt !important; line-height: 1.35 !important; font-family: \(ff) !important; }
        h4, h4 * { font-size: \(h4)pt !important; line-height: 1.35 !important; font-family: \(ff) !important; }
        h5, h5 *, h6, h6 * { font-size: \(h5_6)pt !important; line-height: 1.35 !important; font-family: \(ff) !important; }
        code, pre, tt, kbd, samp, code *, pre * { font-size: \(codeFs)pt !important; font-family: Menlo, Monaco, Consolas, 'Courier New', monospace !important; }
        pre { white-space: pre-wrap !important; word-break: break-all !important; }
        small, small * { font-size: \(smallFs)pt !important; }
        sup, sub, sup *, sub * { font-size: \(subFs)pt !important; }
        img { max-width: 100% !important; height: auto !important; }
        """
    }

    private static func convertWithPyMuPDF(pythonURL: URL, epubPath: String, pdfPath: String, options: TypographyOptions = .default) throws {
        let script = """
import pymupdf, sys, os, base64

try:
    pymupdf.TOOLS.mupdf_display_errors(False)
    pymupdf.TOOLS.mupdf_display_warnings(False)
except Exception:
    pass

epub_path = sys.argv[1]
pdf_path = sys.argv[2]
css_str = base64.b64decode(sys.argv[3]).decode('utf-8') if len(sys.argv) > 3 else ''
base_fs = float(sys.argv[4]) if len(sys.argv) > 4 else 15.0

doc = pymupdf.open(epub_path)

is_reflowable = getattr(doc, 'is_refl', getattr(doc, 'is_reflowable', False))
if is_reflowable:
    if css_str:
        try:
            doc.apply_css(css_str, append=True)
        except Exception:
            pass
    try:
        doc.layout(width=595, height=842, fontsize=base_fs)
    except Exception:
        pass

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
        let cssData = Data(normalizingCSS(for: options).utf8)
        let cssBase64 = cssData.base64EncodedString()
        let fsStr = String(format: "%.1f", options.fontSize)

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, epubPath, pdfPath, cssBase64, fsStr]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let dataBox = ThreadSafeBox<Data>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            dataBox.value = data
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        if process.terminationStatus != 0 {
            let data = dataBox.value ?? Data()
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
    private var completionHandler: ((Result<Data, Error>) -> Void)?
    private var isCompleted = false
    private var timeoutWorkItem: DispatchWorkItem?
    private let options: TypographyOptions
    private let customCSS: String

    @MainActor
    init(options: TypographyOptions = .default) {
        self.options = options
        let css = EBookConverter.normalizingCSS(for: options)
        self.customCSS = css
        let config = WKWebViewConfiguration()
        let scriptSource = """
        (function() {
            var style = document.createElement('style');
            style.id = 'mg-standard-typography';
            style.type = 'text/css';
            style.appendChild(document.createTextNode(`\(css)`));
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    @MainActor
    func render(url: URL, readAccessURL: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        self.isCompleted = false
        self.timeoutWorkItem?.cancel()

        let safeCompletion: (Result<Data, Error>) -> Void = { [weak self] res in
            guard let self = self, !self.isCompleted else { return }
            self.isCompleted = true
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.completionHandler = nil
            completion(res)
        }
        self.completionHandler = safeCompletion

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isCompleted else { return }
            self.safeFinish(result: .failure(EBookConverterError.conversionFailed("WebKit page render timed out for \(url.lastPathComponent)")))
        }
        self.timeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutItem)

        let targetURL = url.resolvingSymlinksInPath()
        let accessURL = readAccessURL.resolvingSymlinksInPath()
        self.webView.loadFileURL(targetURL, allowingReadAccessTo: accessURL)
    }

    @MainActor
    private func safeFinish(result: Result<Data, Error>) {
        guard !isCompleted else { return }
        completionHandler?(result)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        (function() {
            if (!document.getElementById('mg-standard-typography')) {
                var style = document.createElement('style');
                style.id = 'mg-standard-typography';
                style.type = 'text/css';
                style.appendChild(document.createTextNode(`\(self.customCSS)`));
                (document.head || document.documentElement).appendChild(style);
            }
            return Math.max(document.body ? document.body.scrollHeight : 842, document.documentElement ? document.documentElement.scrollHeight : 842, 842);
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] heightVal, _ in
            guard let self = self, !self.isCompleted else { return }
            let h = max(842, (heightVal as? CGFloat) ?? 842)
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 595, height: h)
            self.webView.createPDF(configuration: config) { [weak self] res in
                guard let self = self, !self.isCompleted else { return }
                self.safeFinish(result: res)
            }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        safeFinish(result: .failure(error))
    }

    @MainActor
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        safeFinish(result: .failure(error))
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
