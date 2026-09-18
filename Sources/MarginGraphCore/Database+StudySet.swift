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

        return results
    }
}
