import Foundation
import CoreGraphics
import SQLite3
import PDFKit
import zlib
import AVFoundation


public struct MarginNoteImportResult: Sendable {
    public var topics: [Topic]
    public var documents: [Document]
    public var cards: [NoteCard]
    public var links: [CardLink]
    public var reviewItems: [ReviewItem]
    public var folders: [DocumentFolder]

    public init(
        topics: [Topic],
        documents: [Document],
        cards: [NoteCard],
        links: [CardLink] = [],
        reviewItems: [ReviewItem] = [],
        folders: [DocumentFolder] = []
    ) {
        self.topics = topics
        self.documents = documents
        self.cards = cards
        self.links = links
        self.reviewItems = reviewItems
        self.folders = folders
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
    public let mediaStorage: MediaStorage?
    public let copyDocuments: Bool
    public let copyMedia: Bool

    public init(
        url: URL,
        documentsDestinationDirectory: URL? = nil,
        mediaStorage: MediaStorage? = nil,
        copyDocuments: Bool = true,
        copyMedia: Bool = true
    ) {
        self.url = url
        self.mediaStorage = mediaStorage
        self.copyDocuments = copyDocuments
        self.copyMedia = copyMedia
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
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // It's a directory (such as a .marginbackupall folder)
            let sqliteCandidate = url.appendingPathComponent("MarginNotes.sqlite")
            if FileManager.default.fileExists(atPath: sqliteCandidate.path) {
                return try readDatabase(from: sqliteCandidate, extractedDocuments: [])
            }
            if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                if let db = items.first(where: { ["sqlite", "marginnotes"].contains($0.pathExtension.lowercased()) }) {
                    return try readDatabase(from: db, extractedDocuments: [])
                }
            }
            throw DatabaseError.open("No MarginNotes.sqlite database found inside folder \(url.path)")
        } else if isPackage(url) {
            return try readPackage()
        } else {
            return try readDatabase(from: url, extractedDocuments: [])
        }
    }

    private func isPackage(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if ext == "marginpkg" || ext == "marginbackup" || ext == "marginbackupall" { return true }
        if ext == "sqlite" || ext == "marginnotes" { return false }
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
            } else if ext == "pdf" || ext == "epub" || ext == "mp4" || ext == "mov" || ext == "m4v" {
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
        let uriPath = "file:\(dbURL.path)?immutable=1"
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(uriPath, &source, openFlags, nil) != SQLITE_OK {
            if sqlite3_open_v2(dbURL.path, &source, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                sqlite3_close(source)
                throw DatabaseError.open(message)
            }
        }
        guard let source else {
            throw DatabaseError.open("Failed to open SQLite source database at \(dbURL.path)")
        }
        defer { sqlite3_close(source) }

        let noteRows = (try? rows(in: source, table: "ZBOOKNOTE")) ?? []
        var noteKeyMap: [String: UUID] = [:]
        var topicToBookMD5s: [String: Set<String>] = [:]
        var noteMaxPages: [String: Int] = [:]
        for row in noteRows {
            let key = first(row, ["ZNOTEID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            noteKeyMap[key] = stableUUID(key)
            if let topicKey = first(row, ["ZTOPICID", "ZTOPIC", "ZTOPIC_PK"]),
               let bookMD5 = first(row, ["ZBOOKMD5", "ZMD5"]) {
                topicToBookMD5s[topicKey, default: []].insert(bookMD5)
            }
            if let bookMD5 = first(row, ["ZBOOKMD5", "ZMD5"]) {
                let endPage = zeroBasedPage(first(row, ["ZENDPAGE"])) ?? 0
                if endPage > (noteMaxPages[bookMD5] ?? 0) {
                    noteMaxPages[bookMD5] = endPage
                }
            }
        }

        let dbDir = dbURL.deletingLastPathComponent()
        let documentSearchPaths: [URL] = [
            dbDir,
            documentsDestinationDirectory,
            dbDir.deletingLastPathComponent().appendingPathComponent("Documents"),
            dbDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QReader.MarginStudyMac/Documents")
        ]

        var rawBookRows = (try? rows(in: source, table: "ZBOOK")) ?? []
        if rawBookRows.isEmpty {
            rawBookRows = (try? rows(in: source, table: "ZBOOKCONFIG")) ?? []
        }

        var documents: [Document] = []
        var folders: [DocumentFolder] = []
        var folderMap: [String: DocumentFolder] = [:]
        for row in rawBookRows {
            let rawKey = first(row, ["ZBOOKID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let rawTitle = first(row, ["ZTITLE", "ZNAME", "ZFILE"]) ?? "Untitled Document"
            let cleanTitle = rawTitle.hasSuffix(".pdf") ? String(rawTitle.dropLast(4)) : rawTitle
            var filePath = first(row, ["ZFILEPATH", "ZPATH", "ZLOCALPATH"]) ?? ""
            let rawOriginalPath = filePath
            let subPath = first(row, ["ZPATH", "ZLOCALPATH"]) ?? ""

            if filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath) {
                var resolvedPath = ""
                let fileName = first(row, ["ZFILE", "ZPATH"]) ?? ""
                if let match = extractedDocuments.first(where: {
                    let name = $0.lastPathComponent
                    let titleWithoutExt = $0.deletingPathExtension().lastPathComponent
                    return (!fileName.isEmpty && name == fileName) ||
                           name == rawTitle ||
                           name == (cleanTitle + ".pdf") ||
                           titleWithoutExt.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame
                }) {
                    resolvedPath = match.path
                } else if extractedDocuments.count == 1 {
                    resolvedPath = extractedDocuments[0].path
                } else if !fileName.isEmpty {
                    for dir in documentSearchPaths {
                        let candidate1 = dir.appendingPathComponent(fileName).path
                        if FileManager.default.fileExists(atPath: candidate1) {
                            resolvedPath = candidate1
                            break
                        }
                        if !subPath.isEmpty {
                            let candidate2 = dir.appendingPathComponent(subPath).appendingPathComponent(fileName).path
                            if FileManager.default.fileExists(atPath: candidate2) {
                                resolvedPath = candidate2
                                break
                            }
                        }
                    }
                }

                if resolvedPath.isEmpty {
                    for candidateName in [rawTitle, cleanTitle + ".pdf", cleanTitle + ".epub"] {
                        for dir in documentSearchPaths {
                            let candidate1 = dir.appendingPathComponent(candidateName).path
                            if FileManager.default.fileExists(atPath: candidate1) {
                                resolvedPath = candidate1
                                break
                            }
                            if !subPath.isEmpty {
                                let candidate2 = dir.appendingPathComponent(subPath).appendingPathComponent(candidateName).path
                                if FileManager.default.fileExists(atPath: candidate2) {
                                resolvedPath = candidate2
                                break
                            }
                        }
                    }
                    if !resolvedPath.isEmpty { break }
                }
            }

                if !resolvedPath.isEmpty {
                    filePath = resolvedPath
                } else if rawOriginalPath.hasPrefix("/") {
                    filePath = rawOriginalPath
                } else {
                    filePath = ""
                }
            }

            // Only add documents that have a file path
            guard !filePath.isEmpty else {
                continue
            }

            let md5 = first(row, ["ZMD5LONG", "ZMD5", "ZBOOKMD5", "ZMD5STRING"]) ?? rawKey
            var totalPages = Int(first(row, ["ZTOTALPAGES", "ZPAGECOUNT"]) ?? "0") ?? 0
            if totalPages <= 0 {
                if let maxPage = noteMaxPages[md5], maxPage > 0 {
                    totalPages = maxPage + 1
                } else if copyDocuments && FileManager.default.fileExists(atPath: filePath), let doc = PDFKit.PDFDocument(url: URL(fileURLWithPath: filePath)) {
                    totalPages = doc.pageCount
                } else {
                    totalPages = 1
                }
            }

            if copyDocuments && FileManager.default.fileExists(atPath: filePath) {
                let sidecar = URL(fileURLWithPath: filePath).appendingPathExtension("md5")
                try? md5.write(to: sidecar, atomically: true, encoding: .utf8)
            }

            let lowerExt = (filePath as NSString).pathExtension.lowercased()
            let docType: String
            if ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(lowerExt) {
                docType = "video"
            } else if lowerExt == "epub" {
                docType = "epub"
            } else {
                docType = "pdf"
            }

            var folderName = first(row, ["ZPATH"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            if folderName == nil || folderName?.isEmpty == true {
                let docParent = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
                let destPath = documentsDestinationDirectory.path
                if docParent.hasPrefix(destPath) && docParent != destPath {
                    let relative = String(docParent.dropFirst(destPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !relative.isEmpty && relative != "MarginNotes.sqlite.files" && relative != "files" && relative != "Documents" {
                        folderName = relative
                    }
                }
            }

            var assignedFolderId: UUID? = nil
            if let folderName, !folderName.isEmpty {
                let segments = folderName.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var currentParentID: UUID? = nil
                for segment in segments {
                    let key = "\(currentParentID?.uuidString ?? "root"):\(segment.lowercased())"
                    let folder: DocumentFolder
                    if let existing = folderMap[key] {
                        folder = existing
                    } else {
                        let folderID = Document.stableUUID("folder_\(currentParentID?.uuidString ?? "")_\(segment)")
                        let newFolder = DocumentFolder(id: folderID, parentId: currentParentID, name: segment)
                        folderMap[key] = newFolder
                        folders.append(newFolder)
                        folder = newFolder
                    }
                    currentParentID = folder.id
                }
                assignedFolderId = currentParentID
            }

            documents.append(Document(
                id: Document.stableUUID(md5),
                title: cleanTitle,
                filePath: filePath,
                md5: md5,
                totalPages: totalPages,
                lastVisited: parseDate(first(row, ["ZLASTVISITED", "ZLASTOPENDATE"])),
                documentType: docType,
                folderId: assignedFolderId
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
                let lowerExt = docURL.pathExtension.lowercased()
                let docType: String
                if ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(lowerExt) {
                    docType = "video"
                } else if lowerExt == "epub" {
                    docType = "epub"
                } else {
                    docType = "pdf"
                }
                documents.append(Document(
                    id: Document.stableUUID(md5),
                    title: cleanTitle,
                    filePath: docURL.path,
                    md5: md5,
                    totalPages: totalPages,
                    lastVisited: Date(),
                    documentType: docType
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

        let mediaSearchDirs: [URL] = [
            dbURL.deletingPathExtension().appendingPathExtension("sqlite.files"),
            dbURL.deletingPathExtension().appendingPathExtension("files"),
            dbURL.deletingLastPathComponent().appendingPathComponent("files"),
            documentsDestinationDirectory
        ]

        var mediaHashCache: [String: String] = [:]
        func convertMediaToHEIC(_ md5: String) -> String? {
            guard copyMedia else { return md5 }
            if let cached = mediaHashCache[md5] {
                return cached
            }
            if let storage = self.mediaStorage {
                if let data = self.fetchMediaBlob(from: source, md5: md5) ?? self.findMediaInFiles(md5: md5, candidateDirs: mediaSearchDirs) {
                    if let newHash = try? storage.saveImage(data, format: "heic", quality: 0.85) {
                        mediaHashCache[md5] = newHash
                        return newHash
                    }
                }
            }
            return md5
        }

        var cards: [NoteCard] = []
        var links: [CardLink] = []

        for row in noteRows {
            let key = first(row, ["ZNOTEID", "ZUUID", "ZIDENTIFIER", "Z_PK"]) ?? UUID().uuidString
            let cardId = noteKeyMap[key] ?? stableUUID(key)
            let topicKey = first(row, ["ZTOPICID", "ZTOPIC", "ZTOPIC_PK"])
            let topicId = topicKey.flatMap { topicKeyMap[$0] } ?? fallbackTopic
            let parentKey = first(row, ["ZGROUPNOTEID", "ZGROUPNOTE", "ZPARENTNOTEID"])
            let parentId = parentKey.flatMap { noteKeyMap[$0] ?? UUID(uuidString: $0) }
            let mindLinks = parseStringList(first(row, ["ZMINDLINKS"])).map { noteKeyMap[$0] ?? stableUUID($0) }
            let created = parseDate(first(row, ["ZCREATEDAT", "ZCREATEDATE", "ZCREATED"])) ?? Date()
            let updated = parseDate(first(row, ["ZUPDATEDAT", "ZMODIFIEDDATE", "ZUPDATED"])) ?? created

            for target in mindLinks {
                links.append(CardLink(
                    id: UUID(),
                    topicId: topicId,
                    sourceCardId: cardId,
                    targetCardId: target,
                    label: nil,
                    isBidirectional: false
                ))
            }

            var colorIndex = Int(first(row, ["ZCOLORINDEX", "ZCOLOR"]) ?? "") ?? -1
            if colorIndex < 0 || colorIndex == 0 {
                if let style = first(row, ["ZHIGHLIGHT_STYLE", "ZHIGHLIGHTSTYLE", "ZSTYLE"]),
                   let last = style.last,
                   let hex = Int(String(last), radix: 16) {
                    colorIndex = hex
                }
            }
            if colorIndex < 0 { colorIndex = 0 }

            let highlightPicRaw = first(row, ["ZHIGHLIGHT_PIC", "ZHIGHLIGHTPIC", "ZHIGHLIGHT_PHOTO", "ZPIC"])
            let picInfo = parseHighlightPic(highlightPicRaw)

            var picHash = first(row, ["ZHIGHLIGHTPICHASH"])
            if picHash == nil, let paintMD5 = picInfo.paintMD5 {
                picHash = convertMediaToHEIC(paintMD5)
            }

            var highlightRects = parseHighlightRects(first(row, ["ZHIGHLIGHTS"]))
            if highlightRects.isEmpty && !picInfo.rects.isEmpty {
                highlightRects = picInfo.rects
            } else if !picInfo.rects.isEmpty {
                for r in picInfo.rects {
                    if !highlightRects.contains(r) {
                        highlightRects.append(r)
                    }
                }
            }

            var mediaType = "pdf"
            var videoStartTime: Double?
            var videoEndTime: Double?

            let startPosRaw = first(row, ["ZSTARTPOS"])
            let endPosRaw = first(row, ["ZENDPOS"])

            if let startTime = parseVideoTimestamp(startPosRaw) {
                mediaType = "video"
                videoStartTime = startTime
                if let endTime = parseVideoTimestamp(endPosRaw) {
                    videoEndTime = endTime
                }
            } else if let bookMD5 = first(row, ["ZBOOKMD5", "ZMD5"]),
                      let doc = documents.first(where: { $0.md5 == bookMD5 }),
                      doc.documentType == "video" {
                mediaType = "video"
            }

            if copyMedia, (mediaType == "video" || videoStartTime != nil),
               picHash == nil,
               let startTime = videoStartTime,
               let bookMD5 = first(row, ["ZBOOKMD5", "ZMD5"]),
               let doc = documents.first(where: { $0.md5 == bookMD5 }),
               FileManager.default.fileExists(atPath: doc.filePath),
               let storage = self.mediaStorage {
                let videoURL = URL(fileURLWithPath: doc.filePath)
                if let posterHash = try? storage.generateVideoPosterFrame(url: videoURL, timestampSeconds: startTime) {
                    picHash = posterHash
                }
            }

            cards.append(NoteCard(
                id: cardId,
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
                startPos: parsePoint(startPosRaw),
                endPos: parsePoint(endPosRaw),
                colorIndex: colorIndex,
                tags: parseStringList(first(row, ["ZTAGS"])),
                highlightPicHash: picHash,
                highlightRects: highlightRects,
                mediaType: mediaType,
                videoStartTime: videoStartTime,
                videoEndTime: videoEndTime,
                createdAt: created,
                updatedAt: updated
            ))
        }

        var reviewItems: [ReviewItem] = []
        if let activityRows = try? rows(in: source, table: "ZACTIVITY") {
            for row in activityRows {
                let action = first(row, ["ZACTION", "ZTYPE", "ZNAME"])
                guard action == "SpacedRepetition" || action == "Review",
                      let rawNoteId = first(row, ["ZNOTEID", "ZBOOKNOTEID", "ZIDENTIFIER"]),
                      let cardId = noteKeyMap[rawNoteId] ?? UUID(uuidString: rawNoteId) else {
                    continue
                }
                let infoStr = first(row, ["ZINFO", "ZDATA", "ZEXTRA"]) ?? ""
                var easeFactor: Double = 2.5
                var intervalDays: Int = 0
                var reps: Int = 0
                if let data = infoStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let factor = (json["factor"] as? NSNumber)?.doubleValue ?? json["factor"] as? Double {
                        easeFactor = factor
                    }
                    if let ivl = (json["ivl"] as? NSNumber)?.intValue ?? json["ivl"] as? Int {
                        intervalDays = ivl
                    }
                    if let r = (json["reps"] as? NSNumber)?.intValue ?? json["reps"] as? Int {
                        reps = r
                    }
                }
                let lastReviewed = parseDate(first(row, ["ZTIME", "ZDATE", "ZTIMESTAMP"]))
                let dueDate = (lastReviewed ?? Date()).addingTimeInterval(Double(max(1, intervalDays)) * 86400)
                reviewItems.append(ReviewItem(
                    cardId: cardId,
                    easeFactor: easeFactor,
                    intervalDays: intervalDays,
                    repetitions: reps,
                    dueDate: dueDate,
                    lastReviewed: lastReviewed
                ))
            }
        }

        return MarginNoteImportResult(
            topics: topics,
            documents: documents,
            cards: cards,
            links: links,
            reviewItems: reviewItems,
            folders: folders
        )
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

        try database.execute("BEGIN TRANSACTION;")
        do {
            for folder in result.folders {
                try? database.insertFolder(folder)
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
            for link in result.links {
                var linkToInsert = link
                if let targetTopicId = topicIdMapping[link.topicId] {
                    linkToInsert.topicId = targetTopicId
                }
                try? database.insertLink(linkToInsert)
            }
            for item in result.reviewItems {
                try? database.upsertReviewItem(item)
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
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

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func fetchMediaBlob(from db: OpaquePointer, md5: String) -> Data? {
        var stmt: OpaquePointer?
        let query = "SELECT ZDATA FROM ZMEDIA WHERE ZMD5=? LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, md5, -1, transient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                if count > 0 {
                    return Data(bytes: bytes, count: count)
                }
            }
        }
        return nil
    }

    private func findMediaInFiles(md5: String, candidateDirs: [URL]) -> Data? {
        let fileManager = FileManager.default
        for dir in candidateDirs {
            let direct = dir.appendingPathComponent(md5)
            if fileManager.fileExists(atPath: direct.path), let data = try? Data(contentsOf: direct), !data.isEmpty {
                return data
            }
            for ext in ["png", "jpg", "jpeg", "heic"] {
                let withExt = dir.appendingPathComponent("\(md5).\(ext)")
                if fileManager.fileExists(atPath: withExt.path), let data = try? Data(contentsOf: withExt), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    private func parseVideoTimestamp(_ raw: String?) -> Double? {
        guard let raw, raw.contains("MN3VIDEO") else { return nil }
        let parts = raw.components(separatedBy: "|")
        if parts.count >= 3 {
            if let duration = Double(parts[1]), let fraction = Double(parts[2]) {
                return duration * fraction
            }
        } else if parts.count == 2 {
            if let sec = Double(parts[1]) {
                return sec
            }
        }
        return nil
    }

    private struct HighlightPicInfo {
        var paintMD5: String?
        var rects: [HighlightRect]
    }

    private func parseHighlightPic(_ raw: String?) -> HighlightPicInfo {
        guard let raw else { return HighlightPicInfo(paintMD5: nil, rects: []) }
        if raw.hasPrefix("paint:") {
            let hash = String(raw.dropFirst("paint:".count))
            return HighlightPicInfo(paintMD5: hash, rects: [])
        }
        if !raw.hasPrefix("base64:") && !raw.contains(" ") && !raw.contains("\n") && raw.count >= 8 && raw.count <= 64 {
            return HighlightPicInfo(paintMD5: raw, rects: [])
        }
        guard raw.hasPrefix("base64:"),
              let data = Data(base64Encoded: String(raw.dropFirst("base64:".count)))
        else { return HighlightPicInfo(paintMD5: nil, rects: []) }

        var paintMD5: String?
        var rects: [HighlightRect] = []

        func inspect(_ root: Any) {
            if let dict = root as? [String: Any] {
                if let paint = dict["paint"] as? String, !paint.isEmpty {
                    paintMD5 = paint
                }
                if let selLst = dict["selLst"] as? [Any] {
                    for item in selLst {
                        if let selDict = item as? [String: Any] {
                            let pageVal = selDict["pageNo"]
                            let page: Int?
                            if let num = pageVal as? NSNumber {
                                page = num.intValue
                            } else if let str = pageVal as? String {
                                page = Int(str)
                            } else {
                                page = nil
                            }
                            if let page, let rObj = selDict["rect"], let r = parseRect(rObj) {
                                rects.append(HighlightRect(
                                    page: max(0, page - 1),
                                    x: r.origin.x,
                                    y: r.origin.y,
                                    width: r.size.width,
                                    height: r.size.height
                                ))
                            }
                        }
                    }
                }
                for v in dict.values {
                    if !(v is String) && !(v is NSNumber) {
                        inspect(v)
                    }
                }
            } else if let arr = root as? [Any] {
                for v in arr {
                    inspect(v)
                }
            }
        }

        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            if let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                inspect(root)
            }
        } else if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            inspect(plist)
        }

        return HighlightPicInfo(paintMD5: paintMD5, rects: rects)
    }
}
