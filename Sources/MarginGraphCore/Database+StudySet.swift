import Foundation

public extension Database {
    func addDocument(to topicId: UUID, md5: String) throws {
        guard var topic = try getTopic(id: topicId) else { return }
        guard !topic.bookMD5List.contains(md5) else { return }
        topic.bookMD5List.append(md5)
        topic.updatedAt = Date()
        try updateTopic(topic)
    }

    func removeDocument(from topicId: UUID, md5: String) throws {
        guard var topic = try getTopic(id: topicId) else { return }
        topic.bookMD5List.removeAll { $0 == md5 }
        topic.updatedAt = Date()
        try updateTopic(topic)
    }

    func documentsForTopic(id: UUID) throws -> [Document] {
        guard let topic = try getTopic(id: id) else { return [] }
        let allDocs = try allDocuments()
            .filter { !$0.filePath.isEmpty }
            .sorted { (FileManager.default.fileExists(atPath: $0.filePath) ? 1 : 0) > (FileManager.default.fileExists(atPath: $1.filePath) ? 1 : 0) }
        var results: [Document] = []

        // 1. Direct or prefix match with topic.bookMD5List
        for bookMD5 in topic.bookMD5List {
            if let found = allDocs.first(where: {
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
                if let found = allDocs.first(where: {
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
            if let found = allDocs.first(where: {
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

    func updateTopicUpdatedAt(id: UUID, date: Date = Date()) throws {
        try withStatement("UPDATE topics SET updated_at = ? WHERE id = ?") { stmt in
            bind(date.timeIntervalSince1970, to: 1, in: stmt)
            bind(id.uuidString, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }
}
