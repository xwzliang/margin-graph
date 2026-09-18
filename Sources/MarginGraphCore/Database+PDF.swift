import Foundation

public extension Database {
    func cardsForDocument(md5: String) throws -> [NoteCard] {
        var result: [NoteCard] = []
        for topic in try allTopics() {
            result.append(contentsOf: try cardsForTopic(id: topic.id).filter { $0.bookMD5 == md5 })
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
}
