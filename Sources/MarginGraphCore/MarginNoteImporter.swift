import Foundation
import CoreGraphics
import SQLite3
import PDFKit

public struct MarginNoteImportResult: Sendable {
    public var topics: [Topic]
    public var documents: [Document]
    public var cards: [NoteCard]

    public init(topics: [Topic], documents: [Document], cards: [NoteCard]) {
        self.topics = topics
        self.documents = documents
        self.cards = cards
    }
}

public final class MarginNoteImporter {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> MarginNoteImportResult {
        var source: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(source)
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(source) }

        let noteRows = try rows(in: source, table: "ZBOOKNOTE")
        var noteKeyMap: [String: UUID] = [:]
        var topicToBookMD5s: [String: Set<String>] = [:]
        for row in noteRows {
            let key = first(row, ["ZNOTEID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            noteKeyMap[key] = stableUUID(key)
            if let topicKey = first(row, ["ZTOPICID", "ZTOPIC", "ZTOPIC_PK"]),
               let bookMD5 = first(row, ["ZBOOKMD5", "ZMD5"]) {
                topicToBookMD5s[topicKey, default: []].insert(bookMD5)
            }
        }

        let documentSearchPaths: [URL] = [
            url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QReader.MarginStudyMac/Documents")
        ]

        let documents = try rows(in: source, table: "ZBOOK").map { row in
            let rawKey = first(row, ["ZBOOKID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let rawTitle = first(row, ["ZFILE", "ZTITLE", "ZNAME"]) ?? "Untitled Document"
            let cleanTitle = rawTitle.hasSuffix(".pdf") ? String(rawTitle.dropLast(4)) : rawTitle
            var filePath = first(row, ["ZFILEPATH", "ZPATH", "ZLOCALPATH"]) ?? ""

            if filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath) {
                let fileName = first(row, ["ZFILE", "ZPATH"]) ?? ""
                if !fileName.isEmpty {
                    for dir in documentSearchPaths {
                        let candidate = dir.appendingPathComponent(fileName).path
                        if FileManager.default.fileExists(atPath: candidate) {
                            filePath = candidate
                            break
                        }
                    }
                }
            }

            let md5 = first(row, ["ZMD5LONG", "ZMD5", "ZBOOKMD5", "ZMD5STRING"]) ?? rawKey
            var totalPages = Int(first(row, ["ZTOTALPAGES", "ZPAGECOUNT"]) ?? "0") ?? 0
            if totalPages <= 0, !filePath.isEmpty, let doc = PDFKit.PDFDocument(url: URL(fileURLWithPath: filePath)) {
                totalPages = doc.pageCount
            }

            return Document(
                id: stableUUID(rawKey),
                title: cleanTitle,
                filePath: filePath,
                md5: md5,
                totalPages: totalPages,
                lastVisited: parseDate(first(row, ["ZLASTVISITED", "ZLASTOPENDATE"]))
            )
        }

        let topicRows = try rows(in: source, table: "ZTOPIC")
        var topicKeyMap: [String: UUID] = [:]
        var topics: [Topic] = topicRows.map { row in
            let rawKey = first(row, ["ZTOPICID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let id = stableUUID(rawKey)
            topicKeyMap[rawKey] = id
            var books = parseStringList(first(row, ["ZBOOKMD5LIST", "ZBOOKLIST", "ZBOOKMD5S"]))
                .map { $0.replacingOccurrences(of: "BREAK_", with: "") }
            if let localMD5 = first(row, ["ZLOCALBOOKMD5"]), !localMD5.isEmpty, !books.contains(localMD5) {
                books.append(localMD5)
            }
            if let noteBooks = topicToBookMD5s[rawKey] {
                for nb in noteBooks where !books.contains(nb) {
                    books.append(nb)
                }
            }
            let created = parseDate(first(row, ["ZDATE", "ZCREATEDAT", "ZCREATEDATE", "ZCREATED"])) ?? Date()
            let updated = parseDate(first(row, ["ZLASTVISIT", "ZHISTORYDATE", "ZUPDATEDAT", "ZMODIFIEDDATE", "ZUPDATED"])) ?? created
            return Topic(
                id: id,
                title: first(row, ["ZTITLE", "ZNAME"]) ?? "Untitled Notebook",
                bookMD5List: books,
                createdAt: created,
                updatedAt: updated
            )
        }

        if topics.isEmpty {
            topics = [Topic(title: "Imported Notes")]
        }
        let fallbackTopic = topics[0].id

        var cards: [NoteCard] = []
        for row in noteRows {
            let key = first(row, ["ZNOTEID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let topicKey = first(row, ["ZTOPICID", "ZTOPIC", "ZTOPIC_PK"])
            let topicId = topicKey.flatMap { topicKeyMap[$0] } ?? topicKey.map(stableUUID) ?? fallbackTopic
            let parentKey = first(row, ["ZGROUPNOTEID", "ZGROUPNOTE", "ZPARENTNOTEID"])
            let parentId = parentKey.flatMap { noteKeyMap[$0] ?? UUID(uuidString: $0) }
            let mindLinks = parseStringList(first(row, ["ZMINDLINKS"])).map { noteKeyMap[$0] ?? stableUUID($0) }
            let created = parseDate(first(row, ["ZCREATEDAT", "ZCREATEDATE", "ZCREATED"])) ?? Date()
            let updated = parseDate(first(row, ["ZUPDATEDAT", "ZMODIFIEDDATE", "ZUPDATED"])) ?? created

            cards.append(NoteCard(
                id: noteKeyMap[key] ?? stableUUID(key),
                topicId: topicId,
                bookMD5: first(row, ["ZBOOKMD5", "ZMD5"]),
                title: first(row, ["ZNOTETITLE", "ZTITLE"]) ?? "",
                highlightText: first(row, ["ZHIGHLIGHT_TEXT", "ZHIGHLIGHTTEXT"]) ?? "",
                notesText: first(row, ["ZNOTES_TEXT", "ZNOTESTEXT", "ZCOMMENTS"]) ?? "",
                groupNoteId: parentId,
                mindPos: parsePoint(first(row, ["ZMINDPOS"])),
                mindLinks: mindLinks,
                isFolded: (Int(first(row, ["ZISFOLDED", "ZFOLDED"]) ?? "0") ?? 0) != 0,
                startPage: Int(first(row, ["ZSTARTPAGE"]) ?? ""),
                endPage: Int(first(row, ["ZENDPAGE"]) ?? ""),
                startPos: parsePoint(first(row, ["ZSTARTPOS"])),
                endPos: parsePoint(first(row, ["ZENDPOS"])),
                colorIndex: Int(first(row, ["ZCOLORINDEX", "ZCOLOR"]) ?? "0") ?? 0,
                tags: parseStringList(first(row, ["ZTAGS"])),
                highlightPicHash: first(row, ["ZHIGHLIGHTPICHASH"]),
                createdAt: created,
                updatedAt: updated
            ))
        }

        return MarginNoteImportResult(topics: topics, documents: documents, cards: cards)
    }

    public func importInto(_ database: Database) throws -> MarginNoteImportResult {
        let result = try read()
        for topic in result.topics { try database.insertTopic(topic) }
        for document in result.documents { try database.insertDocument(document) }
        for card in result.cards { try database.insertCard(card) }
        return result
    }

    private func rows(in db: OpaquePointer, table: String) throws -> [[String: String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [[String: String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index)).uppercased()
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    row[name] = nil
                } else if let text = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = String(sqlite3_column_double(statement, index))
                }
            }
            result.append(row)
        }
        return result
    }

    private func first(_ row: [String: String?], _ keys: [String]) -> String? {
        for key in keys {
            if let wrapped = row[key.uppercased()],
               let value = wrapped,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func parseStringList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return value
        }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parsePoint(_ raw: String?) -> CGPoint? {
        guard let raw else { return nil }
        let values = raw
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .compactMap { Double($0) }
        guard values.count >= 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, let value = Double(raw) else { return nil }
        if value > 1_200_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private func stableUUID(_ raw: String) -> UUID {
        if let uuid = UUID(uuidString: raw) { return uuid }

        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for byte in raw.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte)) &* 0x100000001b3
        }

        var bytes = withUnsafeBytes(of: a.bigEndian, Array.init)
            + withUnsafeBytes(of: b.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
