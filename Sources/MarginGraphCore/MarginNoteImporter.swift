import Foundation
import CoreGraphics
import SQLite3
import PDFKit
import zlib


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

public enum NotebookConflictResolution: Sendable {
    case merge
    case replace
    case cancel
}

public final class MarginNoteImporter {
    private let url: URL
    public let documentsDestinationDirectory: URL

    public init(url: URL, documentsDestinationDirectory: URL? = nil) {
        self.url = url
        if let dir = documentsDestinationDirectory {
            self.documentsDestinationDirectory = dir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.documentsDestinationDirectory = base
                .appendingPathComponent("MarginGraph", isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        }
    }

    public func read() throws -> MarginNoteImportResult {
        if isPackage(url) {
            return try readPackage()
        } else {
            return try readDatabase(from: url, extractedDocuments: [])
        }
    }

    private func isPackage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "marginpkg" { return true }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4), data.count >= 4 {
                return data[0] == 0x50 && data[1] == 0x4b && data[2] == 0x03 && data[3] == 0x04
            }
        }
        return false
    }

    private func readPackage() throws -> MarginNoteImportResult {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("marginpkg_unpack_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        try extractArchive(from: url, to: tempDir)

        guard let enumerator = fileManager.enumerator(at: tempDir, includingPropertiesForKeys: nil) else {
            throw DatabaseError.open("Failed to inspect unpacked package at \(tempDir.path)")
        }

        var noteURL: URL?
        var extractedDocuments: [URL] = []

        try fileManager.createDirectory(at: documentsDestinationDirectory, withIntermediateDirectories: true)

        for case let itemURL as URL in enumerator {
            let ext = itemURL.pathExtension.lowercased()
            if ext == "marginnotes" || ext == "sqlite" {
                if noteURL == nil {
                    noteURL = itemURL
                }
            } else if ext == "pdf" || ext == "epub" {
                let fileName = itemURL.lastPathComponent
                var destinationURL = documentsDestinationDirectory.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    let itemData = try? Data(contentsOf: itemURL)
                    let existingData = try? Data(contentsOf: destinationURL)
                    if itemData != existingData {
                        let uniqueName = "\(destinationURL.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(6)).\(ext)"
                        destinationURL = documentsDestinationDirectory.appendingPathComponent(uniqueName)
                        try? fileManager.copyItem(at: itemURL, to: destinationURL)
                    }
                } else {
                    try? fileManager.copyItem(at: itemURL, to: destinationURL)
                }
                extractedDocuments.append(destinationURL)
            }
        }

        guard let noteURL else {
            throw DatabaseError.open("No .marginnotes database found inside .marginpkg archive")
        }

        return try readDatabase(from: noteURL, extractedDocuments: extractedDocuments)
    }

    private func extractArchive(from sourceURL: URL, to destURL: URL) throws {
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-x", "-k", sourceURL.path, destURL.path]
        try dittoProcess.run()
        dittoProcess.waitUntilExit()

        if dittoProcess.terminationStatus == 0 {
            return
        }

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-q", "-o", sourceURL.path, "-d", destURL.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        if unzipProcess.terminationStatus != 0 {
            throw DatabaseError.open("Failed to extract .marginpkg archive (exit code \(unzipProcess.terminationStatus))")
        }
    }

    private func readDatabase(from dbURL: URL, extractedDocuments: [URL]) throws -> MarginNoteImportResult {
        var source: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(source)
            throw DatabaseError.open(message)
        }
        defer { sqlite3_close(source) }

        let noteRows = (try? rows(in: source, table: "ZBOOKNOTE")) ?? []
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
            documentsDestinationDirectory,
            dbURL.deletingLastPathComponent(),
            dbURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QReader.MarginStudyMac/Documents")
        ]

        var rawBookRows = (try? rows(in: source, table: "ZBOOK")) ?? []
        if rawBookRows.isEmpty {
            rawBookRows = (try? rows(in: source, table: "ZBOOKCONFIG")) ?? []
        }

        var documents: [Document] = []
        for row in rawBookRows {
            let rawKey = first(row, ["ZBOOKID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let rawTitle = first(row, ["ZFILE", "ZTITLE", "ZNAME"]) ?? "Untitled Document"
            let cleanTitle = rawTitle.hasSuffix(".pdf") ? String(rawTitle.dropLast(4)) : rawTitle
            var filePath = first(row, ["ZFILEPATH", "ZPATH", "ZLOCALPATH"]) ?? ""

            if filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath) {
                let fileName = first(row, ["ZFILE", "ZPATH"]) ?? ""
                if let match = extractedDocuments.first(where: {
                    let name = $0.lastPathComponent
                    let titleWithoutExt = $0.deletingPathExtension().lastPathComponent
                    return (!fileName.isEmpty && name == fileName) ||
                           name == rawTitle ||
                           name == (cleanTitle + ".pdf") ||
                           titleWithoutExt.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame
                }) {
                    filePath = match.path
                } else if extractedDocuments.count == 1 {
                    filePath = extractedDocuments[0].path
                } else if !fileName.isEmpty {
                    for dir in documentSearchPaths {
                        let candidate = dir.appendingPathComponent(fileName).path
                        if FileManager.default.fileExists(atPath: candidate) {
                            filePath = candidate
                            break
                        }
                    }
                }
            }

            // Only add documents that have a file path
            guard !filePath.isEmpty else {
                continue
            }

            let md5 = first(row, ["ZMD5LONG", "ZMD5", "ZBOOKMD5", "ZMD5STRING"]) ?? rawKey
            var totalPages = Int(first(row, ["ZTOTALPAGES", "ZPAGECOUNT"]) ?? "0") ?? 0
            if totalPages <= 0, FileManager.default.fileExists(atPath: filePath), let doc = PDFKit.PDFDocument(url: URL(fileURLWithPath: filePath)) {
                totalPages = doc.pageCount
            }

            if FileManager.default.fileExists(atPath: filePath) {
                let sidecar = URL(fileURLWithPath: filePath).appendingPathExtension("md5")
                try? md5.write(to: sidecar, atomically: true, encoding: .utf8)
            }

            documents.append(Document(
                id: Document.stableUUID(md5),
                title: cleanTitle,
                filePath: filePath,
                md5: md5,
                totalPages: totalPages,
                lastVisited: parseDate(first(row, ["ZLASTVISITED", "ZLASTOPENDATE"]))
            ))
        }

        if documents.isEmpty && !extractedDocuments.isEmpty {
            for docURL in extractedDocuments {
                let cleanTitle = docURL.deletingPathExtension().lastPathComponent
                let totalPages = PDFKit.PDFDocument(url: docURL)?.pageCount ?? 0
                let md5 = topicToBookMD5s.values.first?.first ?? UUID().uuidString
                let sidecar = docURL.appendingPathExtension("md5")
                if !FileManager.default.fileExists(atPath: sidecar.path) {
                    try? md5.write(to: sidecar, atomically: true, encoding: .utf8)
                }
                documents.append(Document(
                    id: Document.stableUUID(md5),
                    title: cleanTitle,
                    filePath: docURL.path,
                    md5: md5,
                    totalPages: totalPages,
                    lastVisited: Date()
                ))
            }
        }

        let topicRows = (try? rows(in: source, table: "ZTOPIC")) ?? []
        var topicKeyMap: [String: UUID] = [:]
        var topics: [Topic] = topicRows.map { row in
            let rawKey = first(row, ["ZTOPICID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let id = stableUUID(rawKey)
            topicKeyMap[rawKey] = id
            var books = parseStringList(first(row, ["ZBOOKMD5LIST", "ZBOOKLIST", "ZBOOKMD5S"]))
                .map { $0.replacingOccurrences(of: "BREAK_", with: "") }
            if let localMD5 = first(row, ["ZLOCALBOOKMD5"]), !localMD5.isEmpty {
                let parts = localMD5.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for p in parts where !p.isEmpty && !books.contains(p) {
                    books.append(p)
                }
            }
            if let noteBooks = topicToBookMD5s[rawKey] {
                for nb in noteBooks where !books.contains(nb) {
                    books.append(nb)
                }
            }
            if books.isEmpty && documents.count == 1 {
                books.append(documents[0].md5)
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
            let topicId = topicKey.flatMap { topicKeyMap[$0] } ?? fallbackTopic
            let parentKey = first(row, ["ZGROUPNOTEID", "ZGROUPNOTE", "ZPARENTNOTEID"])
            let parentId = parentKey.flatMap { noteKeyMap[$0] ?? UUID(uuidString: $0) }
            let mindLinks = parseStringList(first(row, ["ZMINDLINKS"])).map { noteKeyMap[$0] ?? stableUUID($0) }
            let created = parseDate(first(row, ["ZCREATEDAT", "ZCREATEDATE", "ZCREATED"])) ?? Date()
            let updated = parseDate(first(row, ["ZUPDATEDAT", "ZMODIFIEDDATE", "ZUPDATED"])) ?? created

            var colorIndex = Int(first(row, ["ZCOLORINDEX", "ZCOLOR"]) ?? "") ?? -1
            if colorIndex < 0 || colorIndex == 0 {
                if let style = first(row, ["ZHIGHLIGHT_STYLE", "ZHIGHLIGHTSTYLE", "ZSTYLE"]),
                   let last = style.last,
                   let hex = Int(String(last), radix: 16) {
                    colorIndex = hex
                }
            }
            if colorIndex < 0 { colorIndex = 0 }

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
                startPage: zeroBasedPage(first(row, ["ZSTARTPAGE"])),
                endPage: zeroBasedPage(first(row, ["ZENDPAGE"])),
                startPos: parsePoint(first(row, ["ZSTARTPOS"])),
                endPos: parsePoint(first(row, ["ZENDPOS"])),
                colorIndex: colorIndex,
                tags: parseStringList(first(row, ["ZTAGS"])),
                highlightPicHash: first(row, ["ZHIGHLIGHTPICHASH"]),
                highlightRects: parseHighlightRects(first(row, ["ZHIGHLIGHTS"])),
                createdAt: created,
                updatedAt: updated
            ))
        }

        return MarginNoteImportResult(topics: topics, documents: documents, cards: cards)
    }

    @discardableResult
    public func importInto(
        _ database: Database,
        conflictResolver: ((_ existingTopic: Topic, _ importedTopic: Topic) -> NotebookConflictResolution)?
    ) throws -> MarginNoteImportResult? {
        let result = try read()
        let existingTopics = (try? database.allTopics()) ?? []

        var topicsToInsert: [Topic] = []
        var topicIdMapping: [UUID: UUID] = [:]

        for importedTopic in result.topics {
            let matchingExisting = existingTopics.first {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(
                    importedTopic.title.trimmingCharacters(in: .whitespacesAndNewlines)
                ) == .orderedSame
            }

            if let existing = matchingExisting {
                let resolution = conflictResolver?(existing, importedTopic) ?? .replace
                switch resolution {
                case .cancel:
                    return nil
                case .replace:
                    let oldCards = (try? database.cardsForTopic(id: existing.id)) ?? []
                    for c in oldCards { try? database.deleteCard(id: c.id) }
                    let oldLinks = (try? database.linksForTopic(id: existing.id)) ?? []
                    for l in oldLinks { try? database.deleteLink(id: l.id) }
                    try? database.deleteTopic(id: existing.id)

                    // Also delete any orphan/dummy topics with matching title that have 0 cards
                    for other in existingTopics where other.id != existing.id {
                        let cleanOther = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanImp = importedTopic.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleanOther.localizedCaseInsensitiveCompare(cleanImp) == .orderedSame ||
                           cleanOther.localizedCaseInsensitiveContains(cleanImp) ||
                           cleanImp.localizedCaseInsensitiveContains(cleanOther) {
                            let otherCards = (try? database.cardsForTopic(id: other.id)) ?? []
                            if otherCards.isEmpty {
                                try? database.deleteTopic(id: other.id)
                            }
                        }
                    }

                    topicsToInsert.append(importedTopic)
                    topicIdMapping[importedTopic.id] = importedTopic.id

                case .merge:
                    var merged = existing
                    for bmd5 in importedTopic.bookMD5List where !merged.bookMD5List.contains(bmd5) {
                        merged.bookMD5List.append(bmd5)
                    }
                    merged.updatedAt = Date()
                    try database.updateTopic(merged)
                    topicIdMapping[importedTopic.id] = existing.id
                }
            } else {
                topicsToInsert.append(importedTopic)
                topicIdMapping[importedTopic.id] = importedTopic.id
            }
        }

        for topic in topicsToInsert {
            try database.insertTopic(topic)
        }
        for document in result.documents {
            try database.insertDocument(document)
        }
        for card in result.cards {
            var cardToInsert = card
            if let targetTopicId = topicIdMapping[card.topicId] {
                cardToInsert.topicId = targetTopicId
            }
            try database.insertCard(cardToInsert)
        }

        return result
    }

    @discardableResult
    public func importInto(_ database: Database) throws -> MarginNoteImportResult {
        guard let result = try importInto(database, conflictResolver: nil) else {
            throw DatabaseError.sqlite("Import cancelled")
        }
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
                let type = sqlite3_column_type(statement, index)
                if type == SQLITE_NULL {
                    row[name] = nil
                } else if type == SQLITE_BLOB,
                          let bytes = sqlite3_column_blob(statement, index) {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    let data = Data(bytes: bytes, count: count)
                    row[name] = "base64:" + data.base64EncodedString()
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

    private func zeroBasedPage(_ raw: String?) -> Int? {
        guard let raw, let page = Int(raw) else { return nil }
        return max(0, page - 1)
    }

    private func parseHighlightRects(_ raw: String?) -> [HighlightRect] {
        guard let raw, raw.hasPrefix("base64:"),
              let data = Data(base64Encoded: String(raw.dropFirst("base64:".count)))
        else { return [] }

        var result: [HighlightRect] = []

        func addRect(page: Int, rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            result.append(HighlightRect(
                page: max(0, page - 1),
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            ))
        }

        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let gzData = dict["textSelData"] as? Data,
                   let decompressed = decompressGzip(gzData),
                   let jsonArr = try? JSONSerialization.jsonObject(with: decompressed) as? [[String: Any]] {
                    for item in jsonArr {
                        let page = (item["pageNo"] as? NSNumber)?.intValue ?? Int(item["pageNo"] as? String ?? "")
                        if let page, let rObj = item["rect"], let r = parseRect(rObj) {
                            addRect(page: page, rect: r)
                        }
                    }
                }
                if let list = dict["textSelLst"] as? [Any] {
                    for item in list {
                        if let d = item as? [String: Any] {
                            let page = (d["pageNo"] as? NSNumber)?.intValue ?? Int(d["pageNo"] as? String ?? "")
                            if let page, let rObj = d["rect"], let r = parseRect(rObj) {
                                addRect(page: page, rect: r)
                            }
                        }
                    }
                }
                if let pageValue = dict["pageNo"],
                   let rectObj = dict["rect"],
                   let rect = parseRect(rectObj) {
                    let page: Int?
                    if let number = pageValue as? NSNumber {
                        page = number.intValue
                    } else if let string = pageValue as? String {
                        page = Int(string)
                    } else {
                        page = nil
                    }
                    if let page {
                        addRect(page: page, rect: rect)
                    }
                }
                for child in dict.values {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }

        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            if let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                walk(root)
            }
        } else if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            walk(plist)
        }

        var seen = Set<String>()
        var unique: [HighlightRect] = []
        for r in result {
            let key = "\(r.page)_\(Int((r.y / 2).rounded()))_\(Int((r.x / 4).rounded()))_\(Int((r.width / 4).rounded()))"
            if seen.insert(key).inserted {
                unique.append(r)
            }
        }
        return unique
    }

    private func decompressGzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var decompressed = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        data.withUnsafeBytes { rawBufferPointer in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawBufferPointer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            while true {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                if status != Z_OK && status != Z_STREAM_END {
                    break
                }
                let count = bufferSize - Int(stream.avail_out)
                decompressed.append(buffer, count: count)
                if status == Z_STREAM_END { break }
                if stream.avail_out > 0 { break }
            }
        }

        return decompressed.isEmpty ? nil : decompressed
    }

    private func parseRect(_ raw: Any) -> CGRect? {
        if let val = raw as? NSValue {
            return val.rectValue
        }
        if let dict = raw as? [String: Any] {
            if let x = (dict["x"] as? NSNumber)?.doubleValue,
               let y = (dict["y"] as? NSNumber)?.doubleValue,
               let w = (dict["w"] as? NSNumber)?.doubleValue,
               let h = (dict["h"] as? NSNumber)?.doubleValue {
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        if let str = raw as? String {
            let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
            let nsRange = NSRange(str.startIndex..<str.endIndex, in: str)
            let values = regex?.matches(in: str, range: nsRange).compactMap { match -> Double? in
                guard let range = Range(match.range, in: str) else { return nil }
                return Double(str[range])
            } ?? []
            guard values.count >= 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        return nil
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
