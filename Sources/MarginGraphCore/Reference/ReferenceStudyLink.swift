import Foundation
import SQLite3

public struct ReferenceStudyLink: Equatable, Sendable {
    public var topicID: UUID
    public var bookMD5: String?

    public init(topicID: UUID, bookMD5: String? = nil) {
        self.topicID = topicID
        self.bookMD5 = bookMD5
    }
}

public struct ReferenceStudyCitation: Hashable, Sendable {
    public let bibliography: URL
    public let key: String
}

public extension Database {
    func referenceStudyLink(bibliography: URL, key: String) throws -> ReferenceStudyLink? {
        try withStatement("""
            SELECT topic_id, book_md5 FROM reference_study_links
            WHERE bibliography_path = ? AND citation_key = ?
            """) { statement in
            bind(bibliography.standardizedFileURL.path, to: 1, in: statement)
            bind(key, to: 2, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw DatabaseError.sqlite("Could not read reference link.") }
            guard let raw = text(statement, 0), let topicID = UUID(uuidString: raw) else { return nil }
            return ReferenceStudyLink(topicID: topicID, bookMD5: text(statement, 1))
        }
    }

    func referenceStudyCitations(bookMD5: String, topicID: UUID?, includesNotebookLink: Bool) throws -> [ReferenceStudyCitation] {
        guard !bookMD5.isEmpty else { return [] }
        return try withStatement("""
            SELECT bibliography_path, citation_key FROM reference_study_links
            WHERE (book_md5 <> '' AND (instr(book_md5, ?1) = 1 OR instr(?1, book_md5) = 1))
               OR (?3 AND topic_id = ?2 AND book_md5 IS NULL)
            ORDER BY CASE WHEN book_md5 IS NULL THEN 2 WHEN topic_id = ?2 THEN 0 ELSE 1 END,
                     bibliography_path, citation_key
            """) { statement in
            bind(bookMD5, to: 1, in: statement)
            bind(topicID?.uuidString, to: 2, in: statement)
            bind(includesNotebookLink ? 1 : 0, to: 3, in: statement)
            var citations: [ReferenceStudyCitation] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let path = text(statement, 0), let key = text(statement, 1) else { continue }
                    citations.append(ReferenceStudyCitation(bibliography: URL(fileURLWithPath: path), key: key))
                case SQLITE_DONE: return citations
                default: throw DatabaseError.sqlite("Could not read document reference links.")
                }
            }
        }
    }

    func saveReferenceStudyLink(_ link: ReferenceStudyLink, bibliography: URL, key: String) throws {
        try withStatement("""
            INSERT INTO reference_study_links (bibliography_path, citation_key, topic_id, book_md5)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(bibliography_path, citation_key) DO UPDATE
            SET topic_id = excluded.topic_id, book_md5 = excluded.book_md5
            """) { statement in
            bind(bibliography.standardizedFileURL.path, to: 1, in: statement)
            bind(key, to: 2, in: statement)
            bind(link.topicID.uuidString, to: 3, in: statement)
            if let md5 = link.bookMD5 { bind(md5, to: 4, in: statement) }
            else { sqlite3_bind_null(statement, 4) }
            try requireDone(statement)
        }
    }

    func removeReferenceStudyLink(bibliography: URL, key: String) throws {
        try withStatement("""
            DELETE FROM reference_study_links WHERE bibliography_path = ? AND citation_key = ?
            """) { statement in
            bind(bibliography.standardizedFileURL.path, to: 1, in: statement)
            bind(key, to: 2, in: statement)
            try requireDone(statement)
        }
    }
}

public enum ReferenceStudyMatcher {
    /// Ebib accepts multiple attachments, relative paths, and filenames under its files directory.
    /// Zotero-style values may also include a description and a trailing MIME type.
    public static func pdfAttachments(for entry: BibTeXEntry, bibliography: URL) -> [URL] {
        let raw = entry.fields["file"] ?? ""
        let base = bibliography.deletingLastPathComponent()
        return raw.split(separator: ";").flatMap { value -> [URL] in
            var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let zotero = path.range(of: #"(?i)\.pdf(?=:(?:application/pdf|pdf)$)"#, options: .regularExpression) {
                path = String(path[..<zotero.upperBound])
                if !path.hasPrefix("/"), let delimiter = path.range(of: ":/") {
                    path = String(path[delimiter.upperBound...])
                    path = "/" + path
                }
            }
            if path.lowercased().hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
                return url.pathExtension.lowercased() == "pdf" ? [url.standardizedFileURL] : []
            }
            path = path.replacingOccurrences(of: #"\\([{}])"#, with: "$1", options: .regularExpression)
            path = (path as NSString).expandingTildeInPath
            guard (path as NSString).pathExtension.lowercased() == "pdf" else { return [] }
            if (path as NSString).isAbsolutePath { return [URL(fileURLWithPath: path).standardizedFileURL] }
            return [base, base.appendingPathComponent("files", isDirectory: true)]
                .map { $0.appendingPathComponent(path).standardizedFileURL }
        }
    }

    public static func document(for entry: BibTeXEntry, attachments: [URL], in documents: [Document],
                                isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> Document? {
        let candidates = documents.filter {
            !$0.filePath.isEmpty && ($0.documentType == "pdf" ||
                                    URL(fileURLWithPath: $0.filePath).pathExtension.lowercased() == "pdf")
        }
        let referenceWords = normalizedWords(entry.title)
        let ranked = candidates.map { document -> (Document, Int) in
            let url = URL(fileURLWithPath: document.filePath).standardizedFileURL
            if attachments.contains(url) { return (document, 4) }
            if attachments.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame }) {
                return (document, 3)
            }
            let titleScore = titleRank(referenceWords, matches: document.title)
            let filenameScore = titleRank(referenceWords, matches: url.deletingPathExtension().lastPathComponent)
            return (document, max(titleScore, filenameScore))
        }
        // Check only candidates with positive evidence. A shelf can hold many files on a network share.
        for rank in [4, 3, 2, 1] {
            let matches = ranked.filter { $0.1 == rank && isReadable($0.0.filePath) }.map(\.0)
            if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
        }
        return nil
    }

    public static func topic(for entry: BibTeXEntry, in topics: [Topic]) -> Topic? {
        let referenceWords = normalizedWords(entry.title)
        let ranked = topics.map { ($0, titleRank(referenceWords, matches: $0.title)) }
        for rank in [2, 1] {
            let matches = ranked.filter { $0.1 == rank }
            if !matches.isEmpty { return matches.count == 1 ? matches.first?.0 : nil }
        }
        return nil
    }

    private static func titleRank(_ referenceWords: [String], matches libraryTitle: String) -> Int {
        guard !referenceWords.isEmpty else { return 0 }
        let libraryWords = normalizedWords(libraryTitle)
        if referenceWords == libraryWords { return 2 }
        // MarginNote/imported filenames often append publisher and author information after “ -- ”.
        let filenameTitle = libraryTitle.components(separatedBy: " -- ")[0]
        let sourceWords = normalizedWords(filenameTitle)
        if referenceWords == sourceWords { return 2 }
        let shorter = min(referenceWords.count, sourceWords.count)
        // Allow substantial, unambiguous-looking prefixes, but not generic titles such as "Introduction".
        if shorter >= 6 && referenceWords.prefix(shorter) == sourceWords.prefix(shorter) { return 1 }
        return 0
    }

    private static func normalizedWords(_ title: String) -> [String] {
        BibTeXEntry.visibleText(title)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
