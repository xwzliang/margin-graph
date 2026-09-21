import Foundation
import CoreGraphics
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case sqlite(String)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Unable to open SQLite database: \(message)"
        case .sqlite(let message): "SQLite error: \(message)"
        case .encoding: "Unable to encode or decode stored data."
        }
    }
}

public final class Database: @unchecked Sendable {
    public let path: String
    public var isInMemory: Bool { path == ":memory:" }
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "MarginGraph.Database")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init(inMemory: Bool) throws {
        try self.init(path: inMemory ? ":memory:" : nil)
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    public init(path: String? = nil) throws {
        let resolvedPath: String
        if let path {
            resolvedPath = path
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = base.appendingPathComponent("MarginGraph", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resolvedPath = directory.appendingPathComponent("MarginGraph.sqlite").path
        }
        self.path = resolvedPath

        if sqlite3_open_v2(resolvedPath, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw DatabaseError.open(message)
        }

        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
        if resolvedPath != ":memory:" {
            try? execute("PRAGMA journal_mode = WAL;")
        }
        try initializeSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    private func initializeSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY, title TEXT NOT NULL, file_path TEXT NOT NULL,
            md5 TEXT NOT NULL UNIQUE, total_pages INTEGER NOT NULL, last_visited REAL
        );
        CREATE TABLE IF NOT EXISTS topics(
            id TEXT PRIMARY KEY, title TEXT NOT NULL, book_md5_list TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cards(
            id TEXT PRIMARY KEY, topic_id TEXT NOT NULL, book_md5 TEXT, title TEXT NOT NULL,
            highlight_text TEXT NOT NULL, notes_text TEXT NOT NULL, group_note_id TEXT,
            mind_x REAL, mind_y REAL, mind_links TEXT NOT NULL, is_folded INTEGER NOT NULL,
            start_page INTEGER, end_page INTEGER, start_x REAL, start_y REAL, end_x REAL, end_y REAL,
            color_index INTEGER NOT NULL, tags TEXT NOT NULL, highlight_pic_hash TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            highlight_rects TEXT NOT NULL DEFAULT '[]',
            FOREIGN KEY(topic_id) REFERENCES topics(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cards_topic ON cards(topic_id);
        CREATE INDEX IF NOT EXISTS idx_cards_parent ON cards(topic_id, group_note_id);
        CREATE TABLE IF NOT EXISTS card_links(
            id TEXT PRIMARY KEY, topic_id TEXT NOT NULL, source_card_id TEXT NOT NULL,
            target_card_id TEXT NOT NULL, label TEXT, is_bidirectional INTEGER NOT NULL,
            FOREIGN KEY(topic_id) REFERENCES topics(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_links_topic ON card_links(topic_id);
        CREATE TABLE IF NOT EXISTS review_items(
            card_id TEXT PRIMARY KEY, ease_factor REAL NOT NULL, interval_days INTEGER NOT NULL,
            repetitions INTEGER NOT NULL, due_date REAL NOT NULL, last_reviewed REAL
        );
        CREATE INDEX IF NOT EXISTS idx_review_due ON review_items(due_date);
        CREATE TABLE IF NOT EXISTS document_bookmarks(
            document_md5 TEXT NOT NULL, page_index INTEGER NOT NULL, created_at REAL NOT NULL,
            PRIMARY KEY(document_md5, page_index)
        );
        CREATE TABLE IF NOT EXISTS card_decks(
            id TEXT PRIMARY KEY, title TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS deck_cards(
            deck_id TEXT NOT NULL, card_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY(deck_id, card_id),
            FOREIGN KEY(deck_id) REFERENCES card_decks(id) ON DELETE CASCADE,
            FOREIGN KEY(card_id) REFERENCES cards(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_deck_cards_deck ON deck_cards(deck_id);
        CREATE INDEX IF NOT EXISTS idx_deck_cards_card ON deck_cards(card_id);
        """)
        if try !hasColumn("highlight_rects", in: "cards") {
            try execute("ALTER TABLE cards ADD COLUMN highlight_rects TEXT NOT NULL DEFAULT '[]';")
        }
        if try !hasColumn("emphasis_list", in: "cards") {
            try execute("ALTER TABLE cards ADD COLUMN emphasis_list TEXT NOT NULL DEFAULT '[]';")
        }
        if try !hasColumn("excerpt_segments", in: "cards") {
            try execute("ALTER TABLE cards ADD COLUMN excerpt_segments TEXT NOT NULL DEFAULT '[]';")
        }
        if try !hasColumn("emphasis_rects", in: "cards") {
            try execute("ALTER TABLE cards ADD COLUMN emphasis_rects TEXT NOT NULL DEFAULT '[]';")
        }
        try repairDocumentIDs()
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = text(statement, 1), name == column {
                    return true
                }
            }
            return false
        }
    }

    internal func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(error)
                throw DatabaseError.sqlite(message)
            }
        }
    }

    internal func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            return try body(statement)
        }
    }

    internal func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    internal func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    internal func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    internal func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    internal func int(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }

    internal func double(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw DatabaseError.encoding
        }
        return string
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ string: String?) throws -> T {
        guard let string, let data = string.data(using: .utf8) else { throw DatabaseError.encoding }
        return try decoder.decode(type, from: data)
    }

    internal func requireDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func insertDocument(_ document: Document) throws {
        var doc = document

        // 1. Existing by MD5: preserve canonical ID and file path if incoming is empty
        if let existing = try getDocumentByMD5(md5: document.md5) {
            doc.id = existing.id
            if doc.filePath.isEmpty && !existing.filePath.isEmpty {
                doc.filePath = existing.filePath
            }
        } else if let collision = try getDocument(id: doc.id), collision.md5 != doc.md5 {
            doc.id = Document.stableUUID(doc.md5)
            if let stillCollision = try getDocument(id: doc.id), stillCollision.md5 != doc.md5 {
                doc.id = UUID()
            }
        }

        // 2. Existing by File Path: deduplicate if another document shares the same physical path
        if !doc.filePath.isEmpty, let existingByPath = try getDocumentByPath(filePath: doc.filePath), existingByPath.md5 != doc.md5 {
            let existingCards = (try? cardCountForDocument(md5: existingByPath.md5)) ?? 0
            let newCards = (try? cardCountForDocument(md5: doc.md5)) ?? 0

            // Prefer incoming if it has >= cards, or if existing has 0 cards, or if incoming is 64-char MarginNote hash vs 32-char fallback
            let preferNew = (newCards >= existingCards) || (existingCards == 0) || (doc.md5.count == 64 && existingByPath.md5.count == 32)
            if preferNew {
                try execute("DELETE FROM documents WHERE id = '\(existingByPath.id.uuidString)';")
                try migrateDocumentMD5(from: existingByPath.md5, to: doc.md5)
                let sidecar = URL(fileURLWithPath: doc.filePath).appendingPathExtension("md5")
                try? doc.md5.write(to: sidecar, atomically: true, encoding: .utf8)
            } else {
                // Existing has more cards; adopt existing MD5 and ID
                doc.md5 = existingByPath.md5
                doc.id = existingByPath.id
            }
        }

        // 3. Purge any duplicate rows that might share the same file_path with a different ID
        if !doc.filePath.isEmpty {
            try withStatement("DELETE FROM documents WHERE file_path = ? AND id != ?") { statement in
                bind(doc.filePath, to: 1, in: statement)
                bind(doc.id.uuidString, to: 2, in: statement)
                try requireDone(statement)
            }
        }

        try withStatement("INSERT OR REPLACE INTO documents(id,title,file_path,md5,total_pages,last_visited) VALUES(?,?,?,?,?,?)") { statement in
            bind(doc.id.uuidString, to: 1, in: statement)
            bind(doc.title, to: 2, in: statement)
            bind(doc.filePath, to: 3, in: statement)
            bind(doc.md5, to: 4, in: statement)
            bind(doc.totalPages, to: 5, in: statement)
            bind(doc.lastVisited?.timeIntervalSince1970, to: 6, in: statement)
            try requireDone(statement)
        }
    }

    public func repairDocumentIDs() throws {
        let docs = try allDocuments()
        for doc in docs {
            let canonicalID = Document.stableUUID(doc.md5)
            if doc.id != canonicalID {
                if let other = try getDocument(id: canonicalID), other.md5 != doc.md5 {
                    let tempID = UUID()
                    try execute("UPDATE documents SET id = '\(tempID.uuidString)' WHERE id = '\(other.id.uuidString)';")
                }
                try execute("UPDATE documents SET id = '\(canonicalID.uuidString)' WHERE id = '\(doc.id.uuidString)';")
            }
        }
    }

    public func getDocument(id: UUID) throws -> Document? {
        try document(where: "id = ?", value: id.uuidString)
    }

    public func getDocumentByMD5(md5: String) throws -> Document? {
        try document(where: "md5 = ?", value: md5)
    }

    public func getDocumentByPath(filePath: String) throws -> Document? {
        try document(where: "file_path = ?", value: filePath)
    }

    public func cardCountForDocument(md5: String) throws -> Int {
        try withStatement("SELECT count(*) FROM cards WHERE book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%')") { statement in
            bind(md5, to: 1, in: statement)
            bind("\(md5)%", to: 2, in: statement)
            bind(md5, to: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return int(statement, 0) ?? 0
        }
    }

    public func migrateDocumentMD5(from oldMD5: String, to newMD5: String) throws {
        guard oldMD5 != newMD5, !oldMD5.isEmpty, !newMD5.isEmpty else { return }
        try withStatement("UPDATE cards SET book_md5 = ? WHERE book_md5 = ?") { statement in
            bind(newMD5, to: 1, in: statement)
            bind(oldMD5, to: 2, in: statement)
            try requireDone(statement)
        }
        try withStatement("UPDATE document_bookmarks SET document_md5 = ? WHERE document_md5 = ?") { statement in
            bind(newMD5, to: 1, in: statement)
            bind(oldMD5, to: 2, in: statement)
            try requireDone(statement)
        }
        let topics = try allTopics()
        for var topic in topics {
            if topic.bookMD5List.contains(oldMD5) {
                topic.bookMD5List.removeAll { $0 == oldMD5 }
                if !topic.bookMD5List.contains(newMD5) {
                    topic.bookMD5List.append(newMD5)
                }
                try updateTopic(topic)
            }
        }
    }

    private func document(where clause: String, value: String) throws -> Document? {
        try withStatement("SELECT id,title,file_path,md5,total_pages,last_visited FROM documents WHERE \(clause) LIMIT 1") { statement in
            bind(value, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return decodeDocument(statement)
        }
    }

    public func allDocuments() throws -> [Document] {
        try withStatement("SELECT id,title,file_path,md5,total_pages,last_visited FROM documents ORDER BY title") { statement in
            var result: [Document] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let row = decodeDocument(statement) { result.append(row) }
            }
            return result
        }
    }

    private func decodeDocument(_ statement: OpaquePointer) -> Document? {
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
              let title = text(statement, 1),
              let path = text(statement, 2),
              let md5 = text(statement, 3) else { return nil }
        return Document(
            id: id,
            title: title,
            filePath: path,
            md5: md5,
            totalPages: int(statement, 4) ?? 0,
            lastVisited: double(statement, 5).map(Date.init(timeIntervalSince1970:))
        )
    }

    public func insertTopic(_ topic: Topic) throws {
        let books = try jsonString(topic.bookMD5List)
        try withStatement("INSERT OR REPLACE INTO topics(id,title,book_md5_list,created_at,updated_at) VALUES(?,?,?,?,?)") { statement in
            bind(topic.id.uuidString, to: 1, in: statement)
            bind(topic.title, to: 2, in: statement)
            bind(books, to: 3, in: statement)
            bind(topic.createdAt.timeIntervalSince1970, to: 4, in: statement)
            bind(topic.updatedAt.timeIntervalSince1970, to: 5, in: statement)
            try requireDone(statement)
        }
    }

    public func updateTopic(_ topic: Topic) throws {
        let books = try jsonString(topic.bookMD5List)
        try withStatement("UPDATE topics SET title=?,book_md5_list=?,created_at=?,updated_at=? WHERE id=?") { statement in
            bind(topic.title, to: 1, in: statement)
            bind(books, to: 2, in: statement)
            bind(topic.createdAt.timeIntervalSince1970, to: 3, in: statement)
            bind(topic.updatedAt.timeIntervalSince1970, to: 4, in: statement)
            bind(topic.id.uuidString, to: 5, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteTopic(id: UUID) throws {
        try delete("DELETE FROM topics WHERE id = ?", id.uuidString)
    }

    public func getTopic(id: UUID) throws -> Topic? {
        try withStatement("SELECT id,title,book_md5_list,created_at,updated_at FROM topics WHERE id=?") { statement in
            bind(id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeTopic(statement)
        }
    }

    public func allTopics() throws -> [Topic] {
        try withStatement("SELECT id,title,book_md5_list,created_at,updated_at FROM topics ORDER BY title") { statement in
            var result: [Topic] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let row = try decodeTopic(statement) { result.append(row) }
            }
            return result
        }
    }

    private func decodeTopic(_ statement: OpaquePointer) throws -> Topic? {
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
              let title = text(statement, 1) else { return nil }
        let books = (try? decodeJSON([String].self, text(statement, 2))) ?? []
        return Topic(
            id: id,
            title: title,
            bookMD5List: books,
            createdAt: Date(timeIntervalSince1970: double(statement, 3) ?? 0),
            updatedAt: Date(timeIntervalSince1970: double(statement, 4) ?? 0)
        )
    }

    public func insertCard(_ card: NoteCard) throws { try writeCard(card, replace: true) }
    public func updateCard(_ card: NoteCard) throws { try writeCard(card, replace: true) }

    private func writeCard(_ card: NoteCard, replace: Bool) throws {
        let links = try jsonString(card.mindLinks.map(\.uuidString))
        let tags = try jsonString(card.tags)
        let highlightRects = try jsonString(card.highlightRects)
        let emphasisList = try jsonString(card.emphasisList)
        let excerptSegments = try jsonString(card.excerptSegments)
        let emphasisRects = try jsonString(card.emphasisRects)
        let verb = replace ? "INSERT OR REPLACE" : "INSERT"
        let sql = """
        \(verb) INTO cards(id,topic_id,book_md5,title,highlight_text,notes_text,group_note_id,mind_x,mind_y,mind_links,is_folded,start_page,end_page,start_x,start_y,end_x,end_y,color_index,tags,highlight_pic_hash,created_at,updated_at,highlight_rects,emphasis_list,excerpt_segments,emphasis_rects)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        try withStatement(sql) { statement in
            bind(card.id.uuidString, to: 1, in: statement)
            bind(card.topicId.uuidString, to: 2, in: statement)
            bind(card.bookMD5, to: 3, in: statement)
            bind(card.title, to: 4, in: statement)
            bind(card.highlightText, to: 5, in: statement)
            bind(card.notesText, to: 6, in: statement)
            bind(card.groupNoteId?.uuidString, to: 7, in: statement)
            bind(card.mindPos.map { Double($0.x) }, to: 8, in: statement)
            bind(card.mindPos.map { Double($0.y) }, to: 9, in: statement)
            bind(links, to: 10, in: statement)
            bind(card.isFolded ? 1 : 0, to: 11, in: statement)
            bind(card.startPage, to: 12, in: statement)
            bind(card.endPage, to: 13, in: statement)
            bind(card.startPos.map { Double($0.x) }, to: 14, in: statement)
            bind(card.startPos.map { Double($0.y) }, to: 15, in: statement)
            bind(card.endPos.map { Double($0.x) }, to: 16, in: statement)
            bind(card.endPos.map { Double($0.y) }, to: 17, in: statement)
            bind(card.colorIndex, to: 18, in: statement)
            bind(tags, to: 19, in: statement)
            bind(card.highlightPicHash, to: 20, in: statement)
            bind(card.createdAt.timeIntervalSince1970, to: 21, in: statement)
            bind(card.updatedAt.timeIntervalSince1970, to: 22, in: statement)
            bind(highlightRects, to: 23, in: statement)
            bind(emphasisList, to: 24, in: statement)
            bind(excerptSegments, to: 25, in: statement)
            bind(emphasisRects, to: 26, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteCard(id: UUID) throws {
        try delete("DELETE FROM cards WHERE id=?", id.uuidString)
    }

    public func getCard(id: UUID) throws -> NoteCard? {
        try withStatement("SELECT * FROM cards WHERE id=?") { statement in
            bind(id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeCard(statement)
        }
    }

    public func totalCardCount() throws -> Int {
        try withStatement("SELECT count(*) FROM cards") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    public func cardCountsByTopic() throws -> [UUID: Int] {
        try withStatement("SELECT topic_id, count(*) FROM cards WHERE topic_id IS NOT NULL GROUP BY topic_id") { statement in
            var results: [UUID: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let topicIDStr = text(statement, 0), let topicID = UUID(uuidString: topicIDStr) {
                    results[topicID] = Int(sqlite3_column_int(statement, 1))
                }
            }
            return results
        }
    }

    public func dueCardCountsByTopic(asOf date: Date = Date()) throws -> [UUID: Int] {
        let sql = """
        SELECT c.topic_id, count(*)
        FROM cards c
        LEFT JOIN review_items r ON c.id = r.card_id
        WHERE c.topic_id IS NOT NULL AND (r.due_date IS NULL OR r.due_date <= ?)
        GROUP BY c.topic_id
        """
        return try withStatement(sql) { statement in
            bind(date.timeIntervalSince1970, to: 1, in: statement)
            var results: [UUID: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let topicIDStr = text(statement, 0), let topicID = UUID(uuidString: topicIDStr) {
                    results[topicID] = Int(sqlite3_column_int(statement, 1))
                }
            }
            return results
        }
    }

    public func cardsForTopic(id: UUID) throws -> [NoteCard] {
        try cards(sql: "SELECT * FROM cards WHERE topic_id=? ORDER BY created_at", values: [id.uuidString])
    }


    public func childCards(parentId: UUID?, topicId: UUID) throws -> [NoteCard] {
        if let parentId {
            return try cards(
                sql: "SELECT * FROM cards WHERE topic_id=? AND group_note_id=? ORDER BY created_at",
                values: [topicId.uuidString, parentId.uuidString]
            )
        }
        return try cards(
            sql: "SELECT * FROM cards WHERE topic_id=? AND group_note_id IS NULL ORDER BY created_at",
            values: [topicId.uuidString]
        )
    }

    func cards(sql: String, values: [String]) throws -> [NoteCard] {
        try withStatement(sql) { statement in
            for (offset, value) in values.enumerated() {
                bind(value, to: Int32(offset + 1), in: statement)
            }
            var result: [NoteCard] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let card = try decodeCard(statement) {
                    result.append(card)
                }
            }
            return result
        }
    }

    internal func decodeCard(_ statement: OpaquePointer) throws -> NoteCard? {
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
              let topicId = text(statement, 1).flatMap(UUID.init(uuidString:)) else { return nil }

        let mindPos: CGPoint? = if let x = double(statement, 7), let y = double(statement, 8) {
            CGPoint(x: x, y: y)
        } else { nil }
        let startPos: CGPoint? = if let x = double(statement, 13), let y = double(statement, 14) {
            CGPoint(x: x, y: y)
        } else { nil }
        let endPos: CGPoint? = if let x = double(statement, 15), let y = double(statement, 16) {
            CGPoint(x: x, y: y)
        } else { nil }

        let linkStrings = (try? decodeJSON([String].self, text(statement, 9))) ?? []
        let tags = (try? decodeJSON([String].self, text(statement, 18))) ?? []
        let highlightRects = (try? decodeJSON([HighlightRect].self, text(statement, 22))) ?? []
        let emphasisList = (try? decodeJSON([String].self, text(statement, 23))) ?? []
        let excerptSegments = (try? decodeJSON([ExcerptSegment].self, text(statement, 24))) ?? []
        let emphasisRects = (try? decodeJSON([HighlightRect].self, text(statement, 25))) ?? []

        return NoteCard(
            id: id,
            topicId: topicId,
            bookMD5: text(statement, 2),
            title: text(statement, 3) ?? "",
            highlightText: text(statement, 4) ?? "",
            notesText: text(statement, 5) ?? "",
            groupNoteId: text(statement, 6).flatMap(UUID.init(uuidString:)),
            mindPos: mindPos,
            mindLinks: linkStrings.compactMap(UUID.init(uuidString:)),
            isFolded: (int(statement, 10) ?? 0) != 0,
            startPage: int(statement, 11),
            endPage: int(statement, 12),
            startPos: startPos,
            endPos: endPos,
            colorIndex: int(statement, 17) ?? 0,
            tags: tags,
            highlightPicHash: text(statement, 19),
            highlightRects: highlightRects,
            emphasisList: emphasisList,
            emphasisRects: emphasisRects,
            excerptSegments: excerptSegments,
            createdAt: Date(timeIntervalSince1970: double(statement, 20) ?? 0),
            updatedAt: Date(timeIntervalSince1970: double(statement, 21) ?? 0)
        )
    }

    public func insertLink(_ link: CardLink) throws {
        try withStatement("INSERT OR REPLACE INTO card_links(id,topic_id,source_card_id,target_card_id,label,is_bidirectional) VALUES(?,?,?,?,?,?)") { statement in
            bind(link.id.uuidString, to: 1, in: statement)
            bind(link.topicId.uuidString, to: 2, in: statement)
            bind(link.sourceCardId.uuidString, to: 3, in: statement)
            bind(link.targetCardId.uuidString, to: 4, in: statement)
            bind(link.label, to: 5, in: statement)
            bind(link.isBidirectional ? 1 : 0, to: 6, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteLink(id: UUID) throws {
        try delete("DELETE FROM card_links WHERE id=?", id.uuidString)
    }

    public func linksForTopic(id: UUID) throws -> [CardLink] {
        try withStatement("SELECT id,topic_id,source_card_id,target_card_id,label,is_bidirectional FROM card_links WHERE topic_id=?") { statement in
            bind(id.uuidString, to: 1, in: statement)
            var result: [CardLink] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let linkId = text(statement, 0).flatMap(UUID.init(uuidString:)),
                   let topic = text(statement, 1).flatMap(UUID.init(uuidString:)),
                   let source = text(statement, 2).flatMap(UUID.init(uuidString:)),
                   let target = text(statement, 3).flatMap(UUID.init(uuidString:)) {
                    result.append(CardLink(
                        id: linkId,
                        topicId: topic,
                        sourceCardId: source,
                        targetCardId: target,
                        label: text(statement, 4),
                        isBidirectional: (int(statement, 5) ?? 0) != 0
                    ))
                }
            }
            return result
        }
    }

    public func upsertReviewItem(_ item: ReviewItem) throws {
        try withStatement("INSERT OR REPLACE INTO review_items(card_id,ease_factor,interval_days,repetitions,due_date,last_reviewed) VALUES(?,?,?,?,?,?)") { statement in
            bind(item.cardId.uuidString, to: 1, in: statement)
            bind(item.easeFactor, to: 2, in: statement)
            bind(item.intervalDays, to: 3, in: statement)
            bind(item.repetitions, to: 4, in: statement)
            bind(item.dueDate.timeIntervalSince1970, to: 5, in: statement)
            bind(item.lastReviewed?.timeIntervalSince1970, to: 6, in: statement)
            try requireDone(statement)
        }
    }

    public func dueReviewItems(asOf date: Date = Date()) throws -> [ReviewItem] {
        try withStatement("SELECT card_id,ease_factor,interval_days,repetitions,due_date,last_reviewed FROM review_items WHERE due_date<=? ORDER BY due_date") { statement in
            bind(date.timeIntervalSince1970, to: 1, in: statement)
            var result: [ReviewItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cardId = text(statement, 0).flatMap(UUID.init(uuidString:)) {
                    result.append(ReviewItem(
                        cardId: cardId,
                        easeFactor: double(statement, 1) ?? 2.5,
                        intervalDays: int(statement, 2) ?? 0,
                        repetitions: int(statement, 3) ?? 0,
                        dueDate: Date(timeIntervalSince1970: double(statement, 4) ?? 0),
                        lastReviewed: double(statement, 5).map(Date.init(timeIntervalSince1970:))
                    ))
                }
            }
            return result
        }
    }

    private func delete(_ sql: String, _ id: String) throws {
        try withStatement(sql) { statement in
            bind(id, to: 1, in: statement)
            try requireDone(statement)
        }
    }
}
