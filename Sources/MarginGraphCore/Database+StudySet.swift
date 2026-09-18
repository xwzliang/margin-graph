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
        let byMD5 = Dictionary(uniqueKeysWithValues: try allDocuments().map { ($0.md5, $0) })
        return topic.bookMD5List.compactMap { byMD5[$0] }
    }
}
