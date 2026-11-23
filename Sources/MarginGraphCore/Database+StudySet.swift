import Foundation
import SQLite3

public extension Database {
    func addDocument(to topicId: UUID, md5: String) throws {
        guard var topic = try getTopic(id: topicId) else { return }
        try withStatement("DELETE FROM topic_document_exclusions WHERE topic_id = ? AND book_md5 = ?") { stmt in
            bind(topicId.uuidString, to: 1, in: stmt)
            bind(md5, to: 2, in: stmt)
            try requireDone(stmt)
        }
        guard !topic.bookMD5List.contains(md5) else { return }
        topic.bookMD5List.append(md5)
        topic.updatedAt = Date()
        try updateTopic(topic)
    }

    func removeDocument(from topicId: UUID, md5: String) throws {
        guard var topic = try getTopic(id: topicId) else { return }
        try withStatement("INSERT OR IGNORE INTO topic_document_exclusions(topic_id, book_md5) VALUES(?, ?)") { stmt in
            bind(topicId.uuidString, to: 1, in: stmt)
            bind(md5, to: 2, in: stmt)
            try requireDone(stmt)
        }
        topic.bookMD5List.removeAll { Self.bookHashesMatch($0, md5) }
        if let last = topic.lastDocumentMD5, Self.bookHashesMatch(last, md5) {
            topic.lastDocumentMD5 = nil
        }
        topic.updatedAt = Date()
        try updateTopic(topic)
    }

    func documentsForTopic(id: UUID) throws -> [Document] {
        guard let topic = try getTopic(id: id) else { return [] }
        let excluded = try excludedDocumentHashes(topicID: id)
        let allDocs = try allDocuments()
            .filter { doc in !excluded.contains { Self.bookHashesMatch($0, doc.md5) } }
            .filter { !$0.filePath.isEmpty }
        func preferredDocument(matching predicate: (Document) -> Bool) -> Document? {
            let matches = allDocs.filter(predicate)
            guard matches.count > 1 else { return matches.first }
            return matches.first { FileManager.default.fileExists(atPath: $0.filePath) } ?? matches.first
        }
        var results: [Document] = []

        // 1. Direct or prefix match with topic.bookMD5List
        for bookMD5 in topic.bookMD5List {
            if let found = preferredDocument(matching: {
                $0.md5 == bookMD5 ||
                $0.md5.hasPrefix(bookMD5) ||
                bookMD5.hasPrefix($0.md5)
            }) {
                if !results.contains(where: { $0.id == found.id }) {
                    results.append(found)
                }
            }
        }

        // 2. Fallback to cards in this topic if no direct book match found
        if results.isEmpty {
            let cards = try cardsForTopic(id: id)
            let cardBookMD5s = Set(cards.compactMap { $0.bookMD5 })
            for bookMD5 in cardBookMD5s {
                if let found = preferredDocument(matching: {
                    $0.md5 == bookMD5 ||
                    $0.md5.hasPrefix(bookMD5) ||
                    bookMD5.hasPrefix($0.md5)
                }) {
                    if !results.contains(where: { $0.id == found.id }) {
                        results.append(found)
                    }
                }
            }
        }

        // 3. Fallback to matching document by title or file name
        if results.isEmpty {
            let cleanTopicTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let found = preferredDocument(matching: {
                let cleanDocTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let dFileName = URL(fileURLWithPath: $0.filePath).deletingPathExtension().lastPathComponent
                return cleanDocTitle.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame ||
                       cleanDocTitle.localizedCaseInsensitiveContains(cleanTopicTitle) ||
                       cleanTopicTitle.localizedCaseInsensitiveContains(cleanDocTitle) ||
                       dFileName.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame ||
                       cleanTopicTitle.localizedCaseInsensitiveContains(dFileName) ||
                       dFileName.localizedCaseInsensitiveContains(cleanTopicTitle)
            }) {
                results.append(found)
            }
        }

        return results
    }

    static func bookHashesMatch(_ first: String, _ second: String) -> Bool {
        !first.isEmpty && !second.isEmpty && (first.hasPrefix(second) || second.hasPrefix(first))
    }

    func excludedDocumentHashes(topicID: UUID) throws -> [String] {
        try withStatement("SELECT book_md5 FROM topic_document_exclusions WHERE topic_id = ?") { stmt in
            bind(topicID.uuidString, to: 1, in: stmt)
            var hashes: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let hash = text(stmt, 0) { hashes.append(hash) }
            }
            return hashes
        }
    }

    /// Rank by cards from this book, never by unrelated cards in a notebook.
    func preferredTopic(for document: Document, topics: [Topic]) throws -> Topic? {
        let counts: [UUID: Int] = try withStatement("SELECT topic_id, COUNT(*) FROM cards WHERE book_md5 IN (SELECT DISTINCT book_md5 FROM cards WHERE book_md5 != '' AND (book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%'))) GROUP BY topic_id") { stmt in
            bind(document.md5, to: 1, in: stmt)
            bind(document.md5 + "%", to: 2, in: stmt)
            bind(document.md5, to: 3, in: stmt)
            var result: [UUID: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = text(stmt, 0), let id = UUID(uuidString: value) {
                    result[id] = Int(sqlite3_column_int(stmt, 1))
                }
            }
            return result
        }
        let excluded: Set<UUID> = try withStatement("SELECT topic_id FROM topic_document_exclusions WHERE book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%')") { stmt in
            bind(document.md5, to: 1, in: stmt)
            bind(document.md5 + "%", to: 2, in: stmt)
            bind(document.md5, to: 3, in: stmt)
            var result = Set<UUID>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = text(stmt, 0), let id = UUID(uuidString: value) { result.insert(id) }
            }
            return result
        }
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = URL(fileURLWithPath: document.filePath).deletingPathExtension().lastPathComponent
        func rank(_ topic: Topic) -> (Int, Int, Int) {
            let attached = topic.bookMD5List.contains { Self.bookHashesMatch($0, document.md5) }
            let topicTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = !topicTitle.isEmpty && ((!title.isEmpty && topicTitle.localizedCaseInsensitiveCompare(title) == .orderedSame) || (!fileName.isEmpty && topicTitle.localizedCaseInsensitiveCompare(fileName) == .orderedSame))
            return (counts[topic.id] ?? 0, attached ? 1 : 0, named ? 1 : 0)
        }
        return topics.filter { !excluded.contains($0.id) && rank($0) > (0, 0, 0) }
            .sorted { lhs, rhs in
                let left = rank(lhs), right = rank(rhs)
                return left == right ? lhs.id.uuidString < rhs.id.uuidString : left > right
            }.first
    }

    func updateTopicUpdatedAt(id: UUID, date: Date = Date()) throws {
        try withStatement("UPDATE topics SET updated_at = ? WHERE id = ?") { stmt in
            bind(date.timeIntervalSince1970, to: 1, in: stmt)
            bind(id.uuidString, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }
}
