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
        var mergesResolved: Bool?
        var richCommentsCaptured: Bool?
        var noteTagsCaptured: Bool?
        var tagCommentsCaptured: Bool?
    }

    private enum TagRecovery {
        case assignmentsAndComments, comments, complete

        init(assignments: Bool, comments: Bool) {
            self = !assignments ? .assignmentsAndComments : (comments ? .complete : .comments)
        }
    }

    private static func snapshot(document: Document, topicIDs: [UUID], database: Database,
                                 originalComments: [UUID: [RichNoteComment]] = [:],
                                 originalTags: [UUID: MarginNoteTags.Assignment] = [:],
                                 tagRecovery: TagRecovery = .complete) throws -> Data {
        let topics = try database.allTopics().filter {
            topicIDs.contains($0.id) || $0.bookMD5List.contains(document.md5)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        var cards = try topics.flatMap { try database.cardsForTopic(id: $0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var links = try topics.flatMap { try database.linksForTopic(id: $0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        installRichComments(originalComments, in: &cards)
        installTags(originalTags, in: &cards, recovery: tagRecovery)
        let groups = try database.legacyMergedNoteGroups(in: cards)
        _ = MarginNoteMergedNotes.combine(cards: &cards, links: &links, groups: groups)
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
        }, links: links, mergesResolved: true, richCommentsCaptured: true, noteTagsCaptured: true,
           tagCommentsCaptured: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private static func canonicalSnapshot(_ snapshot: Snapshot, originalComments: [UUID: [RichNoteComment]],
                                          originalTags: [UUID: MarginNoteTags.Assignment]) throws -> Data {
        var state = snapshot
        for index in state.topics.indices { state.topics[index].bookMD5List.sort() }
        if state.richCommentsCaptured != true {
            installRichComments(originalComments, in: &state.cards)
            state.richCommentsCaptured = true
        }
        let tagRecovery = TagRecovery(assignments: state.noteTagsCaptured == true, comments: state.tagCommentsCaptured == true)
        installTags(originalTags, in: &state.cards, recovery: tagRecovery)
        state.noteTagsCaptured = true
        state.tagCommentsCaptured = true
        if state.mergesResolved != true {
            let groups = MarginNoteMergedNotes.legacyGroups(in: state.cards)
            _ = MarginNoteMergedNotes.combine(cards: &state.cards, links: &state.links, groups: groups)
            state.mergesResolved = true
        }
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
            try markMetadataRecovered(md5: document.md5, database: database)
        }
    }

    static func recoverNoteMetadata(in cards: inout [NoteCard], database: Database) throws {
        let hashes = Set(cards.compactMap(\.bookMD5))
        for md5 in hashes {
            let pending: (archive: Data, richComments: Bool, tags: TagRecovery)? = try database.withStatement("""
                SELECT p.archive, c.document_md5 IS NULL, t.document_md5 IS NOT NULL, tc.document_md5 IS NOT NULL
                FROM imported_packages p
                LEFT JOIN imported_comment_recovery c ON c.document_md5 = p.document_md5
                LEFT JOIN imported_tag_assignment_recovery t ON t.document_md5 = p.document_md5
                LEFT JOIN imported_tag_comment_recovery tc ON tc.document_md5 = p.document_md5
                WHERE p.document_md5 = ? AND (c.document_md5 IS NULL OR t.document_md5 IS NULL OR tc.document_md5 IS NULL)
                """) { statement in
                database.bind(md5, to: 1, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
                return (Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))),
                        sqlite3_column_int(statement, 1) != 0,
                        TagRecovery(assignments: sqlite3_column_int(statement, 2) != 0,
                                    comments: sqlite3_column_int(statement, 3) != 0))
            }
            guard let pending, let metadata = try? MarginNoteImporter.archivedNoteMetadata(in: pending.archive) else { continue }
            if pending.richComments { installRichComments(metadata.richComments, in: &cards) }
            installTags(metadata.tags, in: &cards, recovery: pending.tags)
            try markMetadataRecovered(md5: md5, database: database)
        }
    }

    private static func installRichComments(_ comments: [UUID: [RichNoteComment]], in cards: inout [NoteCard]) {
        for index in cards.indices where cards[index].richComments == nil {
            if let blocks = comments[cards[index].id] {
                cards[index].richComments = RichNoteComment.matching(blocks, in: cards[index].notesText)
            }
        }
    }

    private static func installTags(_ tags: [UUID: MarginNoteTags.Assignment], in cards: inout [NoteCard],
                                    recovery: TagRecovery) {
        guard recovery != .complete, !tags.isEmpty else { return }
        for index in cards.indices {
            if let imported = tags[cards[index].id] {
                let needsAssignments = recovery == .assignmentsAndComments
                if needsAssignments {
                    cards[index].tags = MarginNoteTags.adding(imported.tags, to: cards[index].tags)
                }
                cards[index].notesText = imported.appendingComments(
                    to: cards[index].notesText, activeTags: cards[index].tags, moveArchivedEntries: needsAssignments
                )
            }
        }
    }

    private static func markMetadataRecovered(md5: String, database: Database) throws {
        for table in ["imported_comment_recovery", "imported_tag_assignment_recovery", "imported_tag_comment_recovery"] {
            try database.withStatement("INSERT OR IGNORE INTO \(table) VALUES (?)") { statement in
                database.bind(md5, to: 1, in: statement)
                try database.requireDone(statement)
            }
        }
    }

    private static func remainingTagRecovery(md5: String, database: Database) throws -> TagRecovery {
        try database.withStatement("""
            SELECT EXISTS (SELECT 1 FROM imported_tag_assignment_recovery WHERE document_md5 = ?1),
                   EXISTS (SELECT 1 FROM imported_tag_comment_recovery WHERE document_md5 = ?1)
            """) { statement in
            database.bind(md5, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sqlite("Cannot read tag recovery state") }
            return TagRecovery(assignments: sqlite3_column_int(statement, 0) != 0,
                               comments: sqlite3_column_int(statement, 1) != 0)
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
        let baseline = try JSONDecoder().decode(Snapshot.self, from: state)
        let metadata = baseline.richCommentsCaptured == true && baseline.tagCommentsCaptured == true
            ? MarginNoteImporter.ArchivedNoteMetadata()
            : ((try? MarginNoteImporter.archivedNoteMetadata(in: archive)) ?? MarginNoteImporter.ArchivedNoteMetadata())
        let originalComments = baseline.richCommentsCaptured == true ? [:] : metadata.richComments
        let tagRecovery: TagRecovery = metadata.tags.isEmpty ? .complete : try remainingTagRecovery(md5: document.md5, database: database)
        guard let storedDocument = try database.getDocumentByMD5(md5: document.md5),
              let current = try? snapshot(document: storedDocument, topicIDs: topicIDs, database: database,
                                          originalComments: originalComments, originalTags: metadata.tags, tagRecovery: tagRecovery),
              current == (try canonicalSnapshot(baseline, originalComments: originalComments,
                                                originalTags: metadata.tags)) else { return nil }
        return archive
    }
}
