import Foundation
import CryptoKit
import SQLite3

/// Retains native fields that are not represented by MarginGraph's editing model.
/// The original ZIP is returned only while the imported notebook is unchanged.
enum ImportedPackageStore {
    private struct Snapshot: Codable {
        var documentMD5: String
        var documentTitle: String
        var documentType: String
        var fileHash: String
        var topics: [Topic]
        var cards: [NoteCard]
        var links: [CardLink]
    }

    private static func snapshot(document: Document, topicIDs: [UUID], database: Database) throws -> Data {
        let topics = try database.allTopics().filter {
            topicIDs.contains($0.id) || $0.bookMD5List.contains(document.md5)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        var cards = try topics.flatMap { try database.cardsForTopic(id: $0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var links = try topics.flatMap { try database.linksForTopic(id: $0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        MarginNoteHierarchy.restore(cards: &cards, links: &links)
        let source = MediaDocumentHelper.resolveSourceURL(for: URL(fileURLWithPath: document.filePath))
            ?? URL(fileURLWithPath: document.filePath)
        let fileData = try Data(contentsOf: source, options: .mappedIfSafe)
        let state = Snapshot(documentMD5: document.md5, documentTitle: document.title,
                             documentType: document.documentType,
                             fileHash: SHA256.hash(data: fileData).description,
                             topics: topics.map {
            var topic = $0
            topic.bookMD5List.sort()
            topic.updatedAt = topic.createdAt
            topic.mindPanX = nil
            topic.mindPanY = nil
            topic.mindZoomScale = nil
            topic.lastDocumentMD5 = nil
            return topic
        }, cards: cards.map {
            var card = $0
            card.updatedAt = card.createdAt
            return card
        }, links: links)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private static func canonicalSnapshot(_ data: Data) throws -> Data {
        var state = try JSONDecoder().decode(Snapshot.self, from: data)
        for index in state.topics.indices { state.topics[index].bookMD5List.sort() }
        MarginNoteHierarchy.restore(cards: &state.cards, links: &state.links)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    static func retain(url: URL, result: MarginNoteImportResult, database: Database) throws {
        guard url.pathExtension.lowercased() == "marginpkg" else { return }
        let topicIDs = result.topics.map(\.id)
        // A merge into another topic or a topic containing additional cards is
        // not an unchanged round trip of the original package.
        let storedCards = try topicIDs.flatMap { try database.cardsForTopic(id: $0) }
        guard Set(storedCards.map(\.id)) == Set(result.cards.map(\.id)) else { return }
        let archive = try Data(contentsOf: url)
        let ids = try JSONEncoder().encode(topicIDs)
        let idsText = String(decoding: ids, as: UTF8.self)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for importedDocument in result.documents {
            guard let document = try database.getDocumentByMD5(md5: importedDocument.md5) else { continue }
            let state = try snapshot(document: document, topicIDs: topicIDs, database: database)
            try database.withStatement("INSERT OR REPLACE INTO imported_packages(document_md5, topic_ids, snapshot, archive) VALUES (?, ?, ?, ?)") { stmt in
                database.bind(document.md5, to: 1, in: stmt)
                database.bind(idsText, to: 2, in: stmt)
                _ = state.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(state.count), transient) }
                _ = archive.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(archive.count), transient) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sqlite("Cannot retain native package") }
            }
        }
    }

    static func originalArchive(document: Document, database: Database) throws -> Data? {
        let stored: (String, Data, Data)? = try database.withStatement("SELECT topic_ids, snapshot, archive FROM imported_packages WHERE document_md5 = ?") { stmt in
            database.bind(document.md5, to: 1, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let ids = sqlite3_column_text(stmt, 0),
                  let state = sqlite3_column_blob(stmt, 1),
                  let archive = sqlite3_column_blob(stmt, 2) else { return nil }
            return (String(cString: ids),
                    Data(bytes: state, count: Int(sqlite3_column_bytes(stmt, 1))),
                    Data(bytes: archive, count: Int(sqlite3_column_bytes(stmt, 2))))
        }
        guard let (ids, state, archive) = stored else { return nil }
        let topicIDs = try JSONDecoder().decode([UUID].self, from: Data(ids.utf8))
        guard let storedDocument = try database.getDocumentByMD5(md5: document.md5),
              let current = try? snapshot(document: storedDocument, topicIDs: topicIDs, database: database),
              current == (try canonicalSnapshot(state)) else { return nil }
        return archive
    }
}
