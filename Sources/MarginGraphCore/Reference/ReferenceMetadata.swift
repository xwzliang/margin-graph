import Foundation
import PDFKit
import Vision

public struct ReferenceMetadata: Sendable {
    public var type: String
    public var fields: [String: String]

    public init(type: String = "book", fields: [String: String]) {
        self.type = type
        self.fields = fields
    }

    public func entry(avoiding keys: Set<String>) throws -> BibTeXEntry {
        let author = (fields["author"] ?? fields["editor"] ?? "").components(separatedBy: " and ")[0]
        let surname = author.contains(",")
            ? String(author.split(separator: ",", maxSplits: 1)[0])
            : author.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let titleWords = (fields["title"] ?? "").components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let shortTitle = titleWords.prefix(5).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        let year = fields["year"] ?? String((fields["date"] ?? "").prefix(4))
        let base = [surname, year, shortTitle]
            .map { String($0.unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let stem = base.isEmpty ? "Reference" : String(base.prefix(80))
        var key = stem
        var number = 2
        while keys.contains(key) {
            key = "\(stem)_\(number)"
            number += 1
        }
        return try BibTeXLibrary.entry(BibTeXLibrary.rendered(type: type, key: key, fields: fields))
    }

    public static func inspect(_ url: URL, titleHint: String = "") -> Self {
        let fallback = titleHint.isEmpty ? url.deletingPathExtension().lastPathComponent : titleHint
        let path = url.path
        if url.pathExtension.lowercased() != "pdf" {
            let isVideo = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg"].contains(url.pathExtension.lowercased())
            return Self(type: isVideo ? "movie" : "misc", fields: [
                "title": fallback, "file": isVideo ? url.deletingLastPathComponent().path : path
            ])
        }
        guard let document = PDFDocument(url: url), !document.isLocked else {
            return Self(fields: ["title": fallback, "file": path])
        }
        let frontCount = min(16, document.pageCount)
        let end = max(frontCount, document.pageCount - 3)
        let pages = Array(0..<frontCount) + Array(end..<document.pageCount)
        var text = pages.compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        var scannedFrontMatter = ""
        if ISBN.candidates(in: text, allowBareISBN10: false).isEmpty {
            // Scanned front matter often lacks a text layer. OCR a bounded set of pages locally.
            let candidatePages = Set(Array(0..<min(8, frontCount)) + [document.pageCount - 1]).sorted()
            for index in candidatePages where index >= 0 {
                guard let page = document.page(at: index),
                      (page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) < 35 else { continue }
                if let recognized = recognize(page) {
                    text += "\n" + recognized
                    if index < 3 { scannedFrontMatter += "\n" + recognized }
                }
            }
        }

        let attributes = document.documentAttributes ?? [:]
        let pdfTitle = usable(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        let pdfAuthor = usable(attributes[PDFDocumentAttribute.authorAttribute] as? String)
        let firstPages = (0..<min(3, document.pageCount)).compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        return fromPDFText(text, frontMatter: firstPages + scannedFrontMatter,
                           title: pdfTitle, author: pdfAuthor, fallback: fallback, path: path)
    }

    static func fromPDFText(_ text: String, frontMatter: String, title: String?, author: String?,
                            fallback: String, path: String) -> Self {
        let explicitTitle = firstCapture(#"(?im)^\s*title\s*:\s*(\S[^\r\n]{2,180})"#, in: frontMatter)
        let explicitAuthor = firstCapture(#"(?im)^\s*(?:authors?\s*:|by\s+)\s*([^\r\n]{3,160})$"#, in: frontMatter)
        var fields = ["title": title ?? explicitTitle ?? fallback, "file": path]
        fields["author"] = author ?? explicitAuthor
        fields["isbn"] = ISBN.candidates(in: text, allowBareISBN10: false).first
        fields["doi"] = firstCapture(#"(?i)(10\.\d{4,9}/[-._;()/:\p{L}\p{N}]+)"#, in: frontMatter)?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        fields["year"] = firstCapture(#"(?im)(?:copyright|©|published\s+(?:in\s+)?)(?:[^\r\n0-9]{0,40})((?:18|19|20)\d{2})\b"#, in: text)
            ?? firstCapture(#"(?:^|[_ (])((?:18|19|20)\d{2})(?=[_ )-])"#, in: fallback)
        fields["publisher"] = firstCapture(#"(?im)^\s*published\s+by\s+([^\r\n]{3,160})"#, in: text)
        fields["journaltitle"] = firstCapture(#"(?im)^\s*journal\s*:\s*([^\r\n]{3,160})"#, in: frontMatter)
        return Self(type: fields["journaltitle"] == nil ? "book" : "article", fields: fields)
    }

    public static func match(_ metadata: Self, in entries: [BibTeXEntry], fileURL: URL? = nil) -> BibTeXEntry? {
        let canonicalISBN = metadata.fields["isbn"].flatMap(ISBN.canonical)
        let doi = metadata.fields["doi"]?.lowercased()
        let file = fileURL?.lastPathComponent ?? ""
        let title = normalized(metadata.fields["title"] ?? "")
        let author = normalized(metadata.fields["author"] ?? "")
        let year = metadata.fields["year"]
        func unique(_ matches: [BibTeXEntry]) -> BibTeXEntry? { matches.count == 1 ? matches.first : nil }

        if !file.isEmpty {
            let exactFiles = entries.filter { entry in
                (entry.fields["file"] ?? "").split(separator: ";").contains {
                    URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent == file
                }
            }
            if let entry = unique(exactFiles) { return entry }
        }
        if let canonicalISBN {
            let matches = entries.filter {
                ISBN.candidates(in: $0.fields["isbn"] ?? "").contains { ISBN.canonical($0) == canonicalISBN }
            }
            if let entry = unique(matches) { return entry }
        }
        if let doi, let entry = unique(entries.filter({ $0.fields["doi"]?.lowercased() == doi })) {
            return entry
        }
        guard !title.isEmpty else { return nil }
        return unique(entries.filter {
            normalized($0.title) == title && (year == nil || $0.year.isEmpty || $0.year == year) &&
                (author.isEmpty || $0.author.isEmpty || normalized($0.author) == author)
        })
    }

    private static func recognize(_ page: PDFPage) -> String? {
        let image = page.thumbnail(of: CGSize(width: 1250, height: 1600), for: .mediaBox)
        var bounds = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil else { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func firstCapture(_ expression: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !["untitled", "unknown", "none"].contains(value.lowercased()) else { return nil }
        return value
    }

    private static func normalized(_ value: String) -> String {
        BibTeXEntry.visibleText(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum ISBN {
    public static func canonical(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { !$0.isWhitespace && !"-‐‑–−".contains($0) }
        let digits = cleaned.utf8.map { $0 == 88 ? 10 : Int($0) - 48 }
        guard digits.dropLast().allSatisfy({ (0...9).contains($0) }) else { return nil }
        switch digits.count {
        case 13:
            guard cleaned.hasPrefix("978") || cleaned.hasPrefix("979"),
                  let last = digits.last, (0...9).contains(last),
                  digits.enumerated().reduce(0, { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }) % 10 == 0
            else { return nil }
            return cleaned
        case 10:
            guard let last = digits.last, (0...10).contains(last),
                  digits.enumerated().reduce(0, { $0 + $1.element * (10 - $1.offset) }) % 11 == 0
            else { return nil }
            let base = "978" + cleaned.dropLast()
            let sum = base.utf8.enumerated().reduce(0) { $0 + (Int($1.element) - 48) * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
            return base + String((10 - sum % 10) % 10)
        default: return nil
        }
    }

    public static func candidates(in text: String, allowBareISBN10: Bool = true) -> [String] {
        let separator = #"[ \t\n\r‐‑–−-]?"#
        let patterns = [
            #"(?i)\bISBN(?:[- ]?(?:1[03]))?\s*[:：]?\s*([0-9](?:"# + separator + #"[0-9X]){12})(?![0-9X])"#,
            #"(?i)\bISBN(?:[- ]?(?:1[03]))?\s*[:：]?\s*([0-9](?:"# + separator + #"[0-9X]){9})(?![0-9X])"#,
            #"(?<![0-9])(97[89](?:"# + separator + #"[0-9]){10})(?![0-9])"#,
            #"(?i)(?<![0-9])([0-9]{9}[0-9X])(?![0-9X])"#
        ]
        var result: [String] = []
        var seen = Set<String>()
        for pattern in (allowBareISBN10 ? patterns : Array(patterns.dropLast())) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text),
                      let number = canonical(String(text[range])), seen.insert(number).inserted else { continue }
                result.append(number)
            }
        }
        if let number = canonical(text), seen.insert(number).inserted { result.append(number) }
        return result
    }
}

public struct ISBNLookup: Sendable {
    public enum LookupError: LocalizedError {
        case invalidISBN, notFound, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidISBN: "Enter a valid ISBN-10 or ISBN-13."
            case .notFound: "No book was found for this ISBN."
            case .unavailable: "The online book catalog is unavailable. Try again later."
            }
        }
    }

    public static func fetch(_ isbn: String, session: URLSession = .shared) async throws -> ReferenceMetadata {
        guard let number = ISBN.canonical(isbn) else { throw LookupError.invalidISBN }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "openlibrary.org"
        components.path = "/api/books"
        let key = "ISBN:\(number)"
        components.queryItems = [URLQueryItem(name: "bibkeys", value: key),
                                 URLQueryItem(name: "jscmd", value: "data"),
                                 URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw LookupError.unavailable }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw LookupError.unavailable
        }
        return try decode(data, key: key, isbn: number)
    }

    static func decode(_ data: Data, key: String, isbn: String) throws -> ReferenceMetadata {
        let entries = try JSONDecoder().decode([String: Book].self, from: data)
        guard let book = entries[key], !book.title.isEmpty else { throw LookupError.notFound }
        var fields = ["title": book.title, "isbn": isbn]
        if let subtitle = book.subtitle, !subtitle.isEmpty { fields["subtitle"] = subtitle }
        if let authors = book.authors, !authors.isEmpty { fields["author"] = authors.map(\.name).joined(separator: " and ") }
        if let publishers = book.publishers, !publishers.isEmpty {
            fields["publisher"] = publishers.map(\.name).joined(separator: " and ")
        }
        if let date = book.publish_date, let range = date.range(of: #"\b(?:18|19|20)\d{2}\b"#, options: .regularExpression) {
            fields["year"] = String(date[range])
        }
        fields["url"] = book.url
        return ReferenceMetadata(fields: fields)
    }

    private struct Book: Decodable {
        struct Name: Decodable { let name: String }
        let title: String
        let subtitle: String?
        let authors: [Name]?
        let publishers: [Name]?
        let publish_date: String?
        let url: String?
    }
}
