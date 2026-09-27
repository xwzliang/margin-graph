import Foundation
import AppKit
import WebKit
import PDFKit
import CryptoKit

public struct ConvertedEPUBResult: Sendable {
    public let originalURL: URL
    public let pdfURL: URL
    public let md5: String
    public let title: String
    public let author: String
    public let pageCount: Int

    public init(
        originalURL: URL,
        pdfURL: URL,
        md5: String,
        title: String,
        author: String,
        pageCount: Int
    ) {
        self.originalURL = originalURL
        self.pdfURL = pdfURL
        self.md5 = md5
        self.title = title
        self.author = author
        self.pageCount = pageCount
    }
}

public enum EPUBConverterError: LocalizedError {
    case fileNotFound(String)
    case conversionFailed(String)
    case noConverterAvailable

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "EPUB file not found at: \(path)"
        case .conversionFailed(let message):
            return "Failed to convert EPUB to PDF: \(message)"
        case .noConverterAvailable:
            return "No converter available on system."
        }
    }
}

public final class EPUBConverter: Sendable {

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

    public static func ensureConvertedPDF(for epubURL: URL) throws -> ConvertedEPUBResult {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            throw EPUBConverterError.fileNotFound(epubURL.path)
        }

        let md5 = MediaDocumentHelper.computeFileMD5(url: epubURL)
        let docsDir = documentsDirectory()
        let targetPDF = docsDir.appendingPathComponent("\(md5).pdf")

        // If converted PDF already exists and is non-empty, use it immediately
        if FileManager.default.fileExists(atPath: targetPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: targetPDF.path),
           let size = attrs[.size] as? Int64, size > 1024,
           let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 {
            let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
            let fallbackTitle = epubURL.deletingPathExtension().lastPathComponent
            let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle
            return ConvertedEPUBResult(
                originalURL: epubURL,
                pdfURL: targetPDF,
                md5: md5,
                title: title,
                author: authorAttr ?? "",
                pageCount: doc.pageCount
            )
        }

        // Perform conversion with multi-tier engine:
        var conversionError: String? = nil

        // Method 1: PyMuPDF (fast, preserves Table of Contents & vector layout, if user has Python+PyMuPDF)
        if ProcessInfo.processInfo.environment["FORCE_NATIVE_EPUB"] != "1",
           let pythonURL = findExecutable(named: "python3") {
            do {
                try convertWithPyMuPDF(pythonURL: pythonURL, epubPath: epubURL.path, pdfPath: targetPDF.path)
            } catch {
                conversionError = error.localizedDescription
            }
        }

        // Method 2: Native WebKit-based engine (100% built-in, zero dependencies, requires no installed packages)
        let pdfCreated = FileManager.default.fileExists(atPath: targetPDF.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024

        if !pdfCreated {
            do {
                try convertWithNativeWebKit(epubURL: epubURL, targetPDF: targetPDF)
            } catch {
                conversionError = (conversionError != nil ? "\(conversionError!) | " : "") + "Native WebKit: \(error.localizedDescription)"
            }
        }

        // Method 3: Fallback to ebook-convert if target PDF wasn't created or failed
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
            throw EPUBConverterError.conversionFailed(conversionError ?? "Unknown conversion failure")
        }

        // Write MD5 sidecars
        let sidecarPDF = targetPDF.appendingPathExtension("md5")
        try? md5.write(to: sidecarPDF, atomically: true, encoding: .utf8)
        let sidecarEPUB = epubURL.appendingPathExtension("md5")
        try? md5.write(to: sidecarEPUB, atomically: true, encoding: .utf8)

        let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let fallbackTitle = epubURL.deletingPathExtension().lastPathComponent
        let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle

        return ConvertedEPUBResult(
            originalURL: epubURL,
            pdfURL: targetPDF,
            md5: md5,
            title: title,
            author: authorAttr ?? "",
            pageCount: doc.pageCount
        )
    }

    // MARK: - Native WebKit Converter (Zero Dependencies)

    public static func convertWithNativeWebKit(epubURL: URL, targetPDF: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUB_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 1. Unpack with /usr/bin/unzip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", epubURL.path, "-d", tempDir.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unzip failed"
            throw EPUBConverterError.conversionFailed("Failed to unpack EPUB: \(err)")
        }

        // 2. Locate OPF file via META-INF/container.xml
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path),
              let containerStr = try? String(contentsOf: containerURL, encoding: .utf8) else {
            throw EPUBConverterError.conversionFailed("Invalid EPUB: missing META-INF/container.xml")
        }

        var opfRelPath = "OEBPS/content.opf"
        if let match = containerStr.range(of: "full-path=\"([^\"]+)\"", options: .regularExpression) {
            let sub = containerStr[match]
            opfRelPath = String(sub.dropFirst(11).dropLast(1))
        }

        let opfURL = tempDir.appendingPathComponent(opfRelPath)
        guard FileManager.default.fileExists(atPath: opfURL.path),
              let opfStr = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw EPUBConverterError.conversionFailed("Invalid EPUB: OPF file not found at \(opfRelPath)")
        }

        let baseDir = opfURL.deletingLastPathComponent()

        // 3. Extract Book Metadata
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

        // 4. Parse Manifest (id -> href)
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

        // 5. Parse Spine (reading order)
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
            throw EPUBConverterError.conversionFailed("Invalid EPUB: no readable chapters found in spine")
        }

        // 6. Parse TOC if available
        var parsedTOC: [(title: String, href: String)] = []
        if let tocHref = tocHref {
            let tocURL = baseDir.appendingPathComponent(tocHref)
            if let tocData = try? Data(contentsOf: tocURL) {
                parsedTOC = parseTOCItems(data: tocData)
            }
        }

        let finalTitle = bookTitle
        let finalAuthor = bookAuthor
        let finalSpine = spineHrefs
        let finalTOC = parsedTOC

        // 7. Render chapters into PDFDocument using WebKit on Main Thread
        let masterDoc: PDFDocument = try runOnMainThread { (completion: @escaping (Result<PDFDocument, Error>) -> Void) in
            let masterPDF = PDFDocument()
            let renderer = WebKitChapterRenderer()
            var chapterIndex = 0
            var hrefToPageMap: [String: Int] = [:]

            @MainActor
            func processNext() {
                if chapterIndex >= finalSpine.count {
                    // Set metadata
                    let attrs: [PDFDocumentAttribute: Any] = [
                        .titleAttribute: finalTitle,
                        .authorAttribute: finalAuthor
                    ]
                    masterPDF.documentAttributes = attrs

                    // Assemble TOC outline
                    if !finalTOC.isEmpty {
                        let rootOutline = PDFOutline()
                        for item in finalTOC {
                            let cleanHref = item.href.components(separatedBy: "#").first ?? item.href
                            if let pIndex = hrefToPageMap[cleanHref] ?? hrefToPageMap[item.href],
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

                let relHref = finalSpine[chapterIndex]
                let chapterURL = baseDir.appendingPathComponent(relHref)
                guard FileManager.default.fileExists(atPath: chapterURL.path) else {
                    chapterIndex += 1
                    processNext()
                    return
                }

                let startPageIndex = masterPDF.pageCount
                hrefToPageMap[relHref] = startPageIndex
                let filenameOnly = URL(fileURLWithPath: relHref).lastPathComponent
                hrefToPageMap[filenameOnly] = startPageIndex

                renderer.render(url: chapterURL, readAccessURL: tempDir) { res in
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
            throw EPUBConverterError.conversionFailed("Rendered EPUB produced 0 pages")
        }

        guard masterDoc.write(to: targetPDF) else {
            throw EPUBConverterError.conversionFailed("Failed to save converted PDF to \(targetPDF.path)")
        }
    }

    private static func parseTOCItems(data: Data) -> [(title: String, href: String)] {
        var items: [(title: String, href: String)] = []
        let str = String(data: data, encoding: .utf8) ?? ""

        // Try HTML/XHTML nav anchors: <a href="([^"]+)">([^<]+)</a>
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

        // Try NCX navPoints: <navPoint ...><text>Title</text>...<content src="href"/>
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
                throw EPUBConverterError.conversionFailed("Conversion timed out on main thread")
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
                throw EPUBConverterError.conversionFailed("Conversion timed out on background thread")
            }
            guard let res = box.value else {
                throw EPUBConverterError.conversionFailed("Conversion failed to return result")
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
            throw NSError(domain: "EPUBConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
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
            throw NSError(domain: "EPUBConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }
}

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

