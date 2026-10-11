import Foundation
import CoreGraphics
import SQLite3
import zlib
import CryptoKit

public enum MarginPackageExportError: LocalizedError {
    case templateDecompressionFailed
    case sqliteError(String)
    case archiveCreationFailed(String)
    case documentNotFound(String)
    case emptyExport

    public var errorDescription: String? {
        switch self {
        case .templateDecompressionFailed:
            return "Failed to decompress the MarginNote SQLite package template."
        case .sqliteError(let msg):
            return "SQLite error during export: \(msg)"
        case .archiveCreationFailed(let msg):
            return "Failed to package .marginpkg archive: \(msg)"
        case .documentNotFound(let path):
            return "Document file not found at: \(path)"
        case .emptyExport:
            return "No documents found to export."
        }
    }
}

public enum MarginPackageExporter {
    private static let base64TemplateGzip: String = "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"

    public static func decompressTemplate() -> Data? {
        guard let compressedData = Data(base64Encoded: base64TemplateGzip) else { return nil }
        return decompressGzip(compressedData)
    }

    public static func decompressGzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var decompressed = Data()
        let bufferSize = 8192
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

    public static func exportDocument(
        document: Document,
        database: Database,
        mediaStorage: MediaStorage,
        destinationURL: URL
    ) throws {
        if let original = try ImportedPackageStore.originalArchive(document: document, database: database) {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: destinationURL, options: .atomic)
            return
        }

        let allTopics = (try? database.allTopics()) ?? []
        let topics = allTopics.filter { $0.bookMD5List.contains(document.md5) }
        let targetTopics: [Topic]
        if !topics.isEmpty {
            targetTopics = topics
        } else {
            targetTopics = [Topic(id: UUID(), title: document.title, bookMD5List: [document.md5])]
        }

        let allCards = targetTopics.flatMap { (try? database.cardsForTopic(id: $0.id)) ?? [] }
        let matchingCards = allCards.filter { $0.bookMD5 == document.md5 || ($0.bookMD5 == nil && targetTopics.count == 1) }

        try exportPackage(
            baseName: document.title,
            documents: [document],
            relativePaths: [document.id: (document.filePath as NSString).lastPathComponent],
            topics: targetTopics,
            cards: matchingCards,
            database: database,
            mediaStorage: mediaStorage,
            destinationURL: destinationURL
        )
    }

    public static func exportFolder(
        folder: DocumentFolder,
        allFolders: [DocumentFolder],
        allDocuments: [Document],
        database: Database,
        mediaStorage: MediaStorage,
        destinationURL: URL
    ) throws {
        var folderIDs: Set<UUID> = [folder.id]
        var addedMore = true
        while addedMore {
            addedMore = false
            for f in allFolders {
                if let pid = f.parentId, folderIDs.contains(pid), !folderIDs.contains(f.id) {
                    folderIDs.insert(f.id)
                    addedMore = true
                }
            }
        }

        let docsInFolder = allDocuments.filter { doc in
            guard let fid = doc.folderId else { return false }
            return folderIDs.contains(fid)
        }

        guard !docsInFolder.isEmpty else {
            throw MarginPackageExportError.emptyExport
        }

        var relativePaths: [UUID: String] = [:]
        func pathForFolder(_ fid: UUID) -> String {
            guard let current = allFolders.first(where: { $0.id == fid }) else { return "" }
            if current.id == folder.id {
                return current.name
            }
            if let pid = current.parentId {
                let parentPath = pathForFolder(pid)
                return parentPath.isEmpty ? current.name : "\(parentPath)/\(current.name)"
            }
            return current.name
        }

        for doc in docsInFolder {
            let filename = (doc.filePath as NSString).lastPathComponent
            if let fid = doc.folderId {
                let folderRel = pathForFolder(fid)
                relativePaths[doc.id] = folderRel.isEmpty ? "\(folder.name)/\(filename)" : "\(folderRel)/\(filename)"
            } else {
                relativePaths[doc.id] = "\(folder.name)/\(filename)"
            }
        }

        let docMD5s = Set(docsInFolder.map { $0.md5 })
        let allTopics = (try? database.allTopics()) ?? []
        let topics = allTopics.filter { t in
            t.bookMD5List.contains(where: { docMD5s.contains($0) })
        }

        var matchingCards: [NoteCard] = []
        for t in topics {
            let tCards = (try? database.cardsForTopic(id: t.id)) ?? []
            matchingCards.append(contentsOf: tCards.filter { c in
                if let b = c.bookMD5 { return docMD5s.contains(b) }
                return false
            })
        }

        try exportPackage(
            baseName: folder.name,
            documents: docsInFolder,
            relativePaths: relativePaths,
            topics: topics,
            cards: matchingCards,
            database: database,
            mediaStorage: mediaStorage,
            destinationURL: destinationURL
        )
    }

    private static func exportPackage(
        baseName: String,
        documents: [Document],
        relativePaths: [UUID: String],
        topics: [Topic],
        cards: [NoteCard],
        database: Database,
        mediaStorage: MediaStorage,
        destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("marginpkg_exp_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let stagingDir = tempDir.appendingPathComponent("pkg")
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        guard let templateData = decompressTemplate() else {
            throw MarginPackageExportError.templateDecompressionFailed
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = dateFormatter.string(from: Date())

        let sanitizedBase = sanitizeFilename(baseName)
        let notesFileName = "\(sanitizedBase)(\(timestamp)).marginnotes"
        let notesDBURL = stagingDir.appendingPathComponent(notesFileName)
        try templateData.write(to: notesDBURL)

        var packagedDocuments = documents
        var usedPaths = Set<String>()
        var convertedEPUBHashes = Set<String>()
        for index in packagedDocuments.indices {
            let doc = documents[index]
            let currentURL = URL(fileURLWithPath: doc.filePath)
            let sourceURL: URL
            if doc.documentType == "epub", currentURL.pathExtension.lowercased() != "epub" {
                guard let original = MediaDocumentHelper.resolveSourceURL(for: currentURL),
                      original.pathExtension.lowercased() == "epub" else {
                    throw MarginPackageExportError.documentNotFound("Original EPUB for " + doc.title)
                }
                sourceURL = original
                convertedEPUBHashes.insert(doc.md5)
            } else {
                sourceURL = currentURL
            }
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw MarginPackageExportError.documentNotFound(sourceURL.path)
            }
            let folder = ((relativePaths[doc.id] ?? "") as NSString).deletingLastPathComponent
            var filename = sanitizeFilename(doc.title) + "." + sourceURL.pathExtension
            var rel = folder.isEmpty ? filename : folder + "/" + filename
            if usedPaths.contains(rel) {
                filename = sanitizeFilename(doc.title) + "-" + doc.id.uuidString + "." + sourceURL.pathExtension
                rel = folder.isEmpty ? filename : folder + "/" + filename
            }
            usedPaths.insert(rel)
            let targetURL = stagingDir.appendingPathComponent(rel)
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            packagedDocuments[index].filePath = targetURL.path
        }

        // MarginNote enters a notebook through ZTOPIC.ZMINDLINKS, rather than
        // discovering arbitrary notes solely by their topic ID.
        var exportCards = cards.map { original -> NoteCard in
            var card = original
            if let hash = card.bookMD5, convertedEPUBHashes.contains(hash) {
                // Cached PDF page coordinates cannot identify EPUB text ranges.
                // Retain the excerpt and notebook, without bogus PDF anchors.
                card.startPage = nil
                card.endPage = nil
                card.startPos = nil
                card.endPos = nil
                card.highlightRects = []
            }
            return card
        }
        var topicRoots: [UUID: UUID] = [:]
        for topic in topics {
            let topicCards = cards.filter { $0.topicId == topic.id }
            let cardIDs = Set(topicCards.map(\.id))
            let childrenByParent = Dictionary(grouping: topicCards, by: \.groupNoteId)
            let roots = topicCards.filter { $0.groupNoteId == nil || !cardIDs.contains($0.groupNoteId!) }
                .sorted(by: TreeLayout.cardOrder)
            let rootID = Document.stableUUID("marginpkg-root-" + topic.id.uuidString)
            topicRoots[topic.id] = rootID
            var root = NoteCard(id: rootID, topicId: topic.id,
                                bookMD5: documents.first?.md5, title: topic.title)
            root.mindLinks = roots.map(\.id)
            root.mindPos = CGPoint(x: 10000, y: 10000)
            exportCards.append(root)
            let layout = TreeLayout.layout(cards: topicCards)
            for index in exportCards.indices where exportCards[index].topicId == topic.id && exportCards[index].id != rootID {
                exportCards[index].mindLinks.removeAll { !cardIDs.contains($0) }
                let children = (childrenByParent[exportCards[index].id] ?? [])
                    .sorted(by: TreeLayout.cardOrder).map(\.id)
                for child in children where !exportCards[index].mindLinks.contains(child) {
                    exportCards[index].mindLinks.append(child)
                }
                if exportCards[index].mindPos == nil, let frame = layout.frames[exportCards[index].id] {
                    exportCards[index].mindPos = CGPoint(x: 10300 + frame.minX, y: 10000 + frame.minY)
                }
            }
        }

        try populateDatabase(
            dbURL: notesDBURL,
            documents: packagedDocuments,
            topics: topics,
            cards: exportCards,
            topicRoots: topicRoots,
            mediaStorage: mediaStorage
        )

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", stagingDir.path, destinationURL.path]
        try ditto.run()
        ditto.waitUntilExit()

        if ditto.terminationStatus != 0 {
            throw MarginPackageExportError.archiveCreationFailed("ditto failed with exit code \(ditto.terminationStatus)")
        }
    }

    private static func populateDatabase(
        dbURL: URL,
        documents: [Document],
        topics: [Topic],
        cards: [NoteCard],
        topicRoots: [UUID: UUID],
        mediaStorage: MediaStorage
    ) throws {
        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            let err = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw MarginPackageExportError.sqliteError(err)
        }
        guard let db else { throw MarginPackageExportError.sqliteError("Cannot open db") }
        defer { sqlite3_close(db) }

        // Each export is a new Core Data store, not the template's store.
        let storeUUID = UUID().uuidString
        if sqlite3_exec(db, "UPDATE Z_METADATA SET Z_UUID = '\(storeUUID)'", nil, nil, nil) != SQLITE_OK {
            throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // 1. Insert ZBOOKCONFIG
        var bookConfigStmt: OpaquePointer?
        let bookSql = """
        INSERT INTO ZBOOKCONFIG (
            Z_PK, Z_ENT, Z_OPT, ZCURRPAGE, ZCURRPAGEOFF, ZSYNCMODE, ZUSN,
            ZCURRPAGEPERCENT, ZFONTSCALE, ZMD5, ZMD5LONG, ZTITLE
        ) VALUES (?, 4, 1, 0, 0, 0, 0, 0.0, 1.0, ?, ?, ?);
        """
        if sqlite3_prepare_v2(db, bookSql, -1, &bookConfigStmt, nil) != SQLITE_OK {
            throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(bookConfigStmt) }

        for (idx, doc) in documents.enumerated() {
            sqlite3_reset(bookConfigStmt)
            sqlite3_bind_int(bookConfigStmt, 1, Int32(idx + 1))
            let md5Short = String(doc.md5.prefix(32))
            sqlite3_bind_text(bookConfigStmt, 2, md5Short, -1, transient)
            sqlite3_bind_text(bookConfigStmt, 3, doc.md5, -1, transient)
            sqlite3_bind_text(bookConfigStmt, 4, URL(fileURLWithPath: doc.filePath).deletingPathExtension().lastPathComponent, -1, transient)
            if sqlite3_step(bookConfigStmt) != SQLITE_DONE {
                throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
            }
        }

        // 2. Insert ZTOPIC
        var topicStmt: OpaquePointer?
        let topicSql = """
        INSERT INTO ZTOPIC (
            Z_PK, Z_ENT, Z_OPT, ZISCHINA, ZISLINK, ZPRIVATEFORUM, ZSYNCDIRTY, ZSYNCMODE, ZUSN,
            ZDATE, ZHISTORYDATE, ZLASTVISIT, ZBOOKLIST, ZLOCALBOOKMD5, ZTITLE, ZTOPICID, ZMINDLINKS
        ) VALUES (?, 11, 1, 0, 0, 0, 0, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        if sqlite3_prepare_v2(db, topicSql, -1, &topicStmt, nil) != SQLITE_OK {
            throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(topicStmt) }

        let allDocMD5s = documents.map { $0.md5 }.joined(separator: "|")
        for (idx, topic) in topics.enumerated() {
            sqlite3_reset(topicStmt)
            sqlite3_bind_int(topicStmt, 1, Int32(idx + 1))
            sqlite3_bind_double(topicStmt, 2, topic.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(topicStmt, 3, topic.updatedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(topicStmt, 4, topic.updatedAt.timeIntervalSinceReferenceDate)
            let exportedBooks = topic.bookMD5List.filter { hash in documents.contains { $0.md5 == hash } }
            let bList = exportedBooks.isEmpty ? allDocMD5s : exportedBooks.joined(separator: "|")
            sqlite3_bind_text(topicStmt, 5, bList, -1, transient)
            sqlite3_bind_text(topicStmt, 6, bList, -1, transient)
            sqlite3_bind_text(topicStmt, 7, topic.title, -1, transient)
            sqlite3_bind_text(topicStmt, 8, topic.id.uuidString, -1, transient)
            if let rootID = topicRoots[topic.id] {
                sqlite3_bind_text(topicStmt, 9, rootID.uuidString, -1, transient)
            }
            if sqlite3_step(topicStmt) != SQLITE_DONE {
                throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
            }
        }

        // 3. Insert ZBOOKNOTE
        var noteStmt: OpaquePointer?
        let noteSql = """
        INSERT INTO ZBOOKNOTE (
            Z_PK, Z_ENT, Z_OPT, ZENDPAGE, ZMINDCLOSE, ZSTARTPAGE, ZUSN, ZZINDEX,
            ZHIGHLIGHT_DATE, ZNOTE_DATE, ZBOOKMD5, ZENDPOS, ZGROUPNOTEID,
            ZHIGHLIGHT_STYLE, ZHIGHLIGHT_TEXT, ZMEDIA_LIST, ZMINDLINKS, ZMINDPOS,
            ZNOTEID, ZNOTES_TEXT, ZNOTETITLE, ZSTARTPOS, ZTOPICID,
            ZHIGHLIGHT_PIC, ZHIGHLIGHTS
        ) VALUES (
            ?, 5, 1, ?, ?, ?, 0, 0,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?
        );
        """
        if sqlite3_prepare_v2(db, noteSql, -1, &noteStmt, nil) != SQLITE_OK {
            throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(noteStmt) }

        var mediaToExport: Set<String> = []

        for (idx, card) in cards.enumerated() {
            sqlite3_reset(noteStmt)
            sqlite3_bind_int(noteStmt, 1, Int32(idx + 1))

            if let page = card.endPage ?? card.startPage {
                sqlite3_bind_int(noteStmt, 2, Int32(page + 1))
            } else {
                sqlite3_bind_null(noteStmt, 2)
            }
            sqlite3_bind_int(noteStmt, 3, card.isFolded ? 1 : 0)
            if let page = card.startPage {
                sqlite3_bind_int(noteStmt, 4, Int32(page + 1))
            } else {
                sqlite3_bind_null(noteStmt, 4)
            }

            sqlite3_bind_double(noteStmt, 5, card.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(noteStmt, 6, card.updatedAt.timeIntervalSinceReferenceDate)

            let bookMD5 = card.bookMD5 ?? documents.first?.md5 ?? ""
            sqlite3_bind_text(noteStmt, 7, bookMD5, -1, transient)

            var startPosStr = ""
            var endPosStr = ""
            if let st = card.videoStartTime {
                startPosStr = "MN3VIDEO|\(st)|1.0"
                let et = card.videoEndTime ?? st
                endPosStr = "MN3VIDEO|\(et)|1.0"
            } else if let sp = card.startPos {
                startPosStr = "\(sp.x),\(sp.y)"
                if let ep = card.endPos {
                    endPosStr = "\(ep.x),\(ep.y)"
                }
            }
            sqlite3_bind_text(noteStmt, 8, endPosStr, -1, transient)

            if let gid = card.groupNoteId {
                sqlite3_bind_text(noteStmt, 9, gid.uuidString, -1, transient)
            } else {
                sqlite3_bind_null(noteStmt, 9)
            }

            let styleStr = "mbooks-annotation\(card.colorIndex)"
            sqlite3_bind_text(noteStmt, 10, styleStr, -1, transient)
            sqlite3_bind_text(noteStmt, 11, card.highlightText, -1, transient)

            if let picHash = card.highlightPicHash {
                mediaToExport.insert(picHash)
                sqlite3_bind_text(noteStmt, 12, "\(picHash)-", -1, transient)
            } else {
                sqlite3_bind_null(noteStmt, 12)
            }

            if !card.mindLinks.isEmpty {
                let linksStr = card.mindLinks.map { $0.uuidString }.joined(separator: "|")
                sqlite3_bind_text(noteStmt, 13, linksStr, -1, transient)
            } else {
                sqlite3_bind_null(noteStmt, 13)
            }

            if let pos = card.mindPos {
                sqlite3_bind_text(noteStmt, 14, "\(pos.x),\(pos.y)", -1, transient)
            } else {
                sqlite3_bind_null(noteStmt, 14)
            }

            sqlite3_bind_text(noteStmt, 15, card.id.uuidString, -1, transient)
            sqlite3_bind_text(noteStmt, 16, card.notesText, -1, transient)
            sqlite3_bind_text(noteStmt, 17, card.title, -1, transient)
            sqlite3_bind_text(noteStmt, 18, startPosStr, -1, transient)
            sqlite3_bind_text(noteStmt, 19, card.topicId.uuidString, -1, transient)

            // ZHIGHLIGHT_PIC
            if let picHash = card.highlightPicHash {
                var picDict: [String: Any] = ["paint": picHash]
                if let st = card.videoStartTime {
                    picDict["video_offset"] = st
                    picDict["video"] = bookMD5
                    picDict["video_ext"] = "mp4"
                }
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: picDict, requiringSecureCoding: false) {
                    _ = data.withUnsafeBytes { rawBuf in
                        sqlite3_bind_blob(noteStmt, 20, rawBuf.baseAddress, Int32(data.count), transient)
                    }
                } else {
                    sqlite3_bind_null(noteStmt, 20)
                }
            } else {
                sqlite3_bind_null(noteStmt, 20)
            }

            // ZHIGHLIGHTS
            if !card.highlightRects.isEmpty {
                let rectsList = card.highlightRects.map { r -> [String: Any] in
                    ["pageNo": r.page + 1,
                     "rect": ["_jsonvalueType": "CGRect", "x": r.x, "y": r.y,
                              "w": r.width, "h": r.height]]
                }
                let json = try JSONSerialization.data(withJSONObject: rectsList, options: [.sortedKeys])
                let compressed = try gzip(json)
                let hlDict = NSMutableDictionary(dictionary: [
                    "highlight_text": NSMutableString(string: card.highlightText),
                    "textSelData": NSMutableData(data: compressed),
                    "coords_hash": Insecure.MD5.hash(data: json).map { String(format: "%02x", $0) }.joined()
                ])
                // Native MarginNote archives an ARRAY of highlight dictionaries.
                let highlights = NSMutableArray(object: hlDict)
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: highlights, requiringSecureCoding: false) {
                    _ = data.withUnsafeBytes { rawBuf in
                        sqlite3_bind_blob(noteStmt, 21, rawBuf.baseAddress, Int32(data.count), transient)
                    }
                } else {
                    sqlite3_bind_null(noteStmt, 21)
                }
            } else {
                sqlite3_bind_null(noteStmt, 21)
            }

            if sqlite3_step(noteStmt) != SQLITE_DONE {
                throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
            }
        }

        // 4. Insert ZMEDIA
        var mediaStmt: OpaquePointer?
        let mediaSql = "INSERT INTO ZMEDIA (Z_PK, Z_ENT, Z_OPT, ZMD5, ZDATA) VALUES (?, 9, 1, ?, ?);"
        if sqlite3_prepare_v2(db, mediaSql, -1, &mediaStmt, nil) != SQLITE_OK {
            throw MarginPackageExportError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(mediaStmt) }

        var mediaCount = 0
        for (mIdx, hash) in mediaToExport.enumerated() {
            if let data = mediaStorage.loadImage(hash: hash) {
                sqlite3_reset(mediaStmt)
                sqlite3_bind_int(mediaStmt, 1, Int32(mIdx + 1))
                sqlite3_bind_text(mediaStmt, 2, hash, -1, transient)
                _ = data.withUnsafeBytes { rawBuf in
                    sqlite3_bind_blob(mediaStmt, 3, rawBuf.baseAddress, Int32(data.count), transient)
                }
                if sqlite3_step(mediaStmt) == SQLITE_DONE {
                    mediaCount += 1
                }
            }
        }

        // 5. Update Z_PRIMARYKEY
        var pkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = ?;", -1, &pkStmt, nil) == SQLITE_OK, let pkStmt {
            defer { sqlite3_finalize(pkStmt) }

            func updateMax(entity: String, max: Int) {
                sqlite3_reset(pkStmt)
                sqlite3_bind_int(pkStmt, 1, Int32(max))
                sqlite3_bind_text(pkStmt, 2, entity, -1, transient)
                sqlite3_step(pkStmt)
            }

            updateMax(entity: "BookConfig", max: documents.count)
            updateMax(entity: "Topic", max: topics.count)
            updateMax(entity: "BookNote", max: cards.count)
            updateMax(entity: "Media", max: mediaCount)
        }
    }

    private static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS,
                           8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MarginPackageExportError.archiveCreationFailed("Cannot initialize highlight compression")
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw MarginPackageExportError.archiveCreationFailed("Cannot compress highlight coordinates")
        }
        output.count = Int(stream.total_out)
        return output
    }

    public static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Notes" : trimmed
    }
}
