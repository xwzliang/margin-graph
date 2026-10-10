import Foundation
import CryptoKit
import PDFKit
#if canImport(SQLite3)
import SQLite3
#endif

public extension Database {
    func deleteDocument(id: UUID) throws {
        // First find the document's md5 to clean up associated cards
        if let doc = try allDocuments().first(where: { $0.id == id }) {
            try deleteCardsForDocument(md5: doc.md5)
            let topics = try allTopics()
            for var topic in topics where topic.bookMD5List.contains(doc.md5) {
                topic.bookMD5List.removeAll { $0 == doc.md5 }
                if topic.bookMD5List.isEmpty {
                    let remaining = (try? cardsForTopic(id: topic.id))?.count ?? 0
                    if remaining == 0 {
                        try? deleteTopic(id: topic.id)
                        continue
                    }
                }
                try? updateTopic(topic)
            }
        }
        try execute("DELETE FROM documents WHERE id = '\(id.uuidString)';")
    }

    func deleteDocument(md5: String) throws {
        try deleteCardsForDocument(md5: md5)
        let topics = try allTopics()
        for var topic in topics where topic.bookMD5List.contains(md5) {
            topic.bookMD5List.removeAll { $0 == md5 }
            if topic.bookMD5List.isEmpty {
                let remaining = (try? cardsForTopic(id: topic.id))?.count ?? 0
                if remaining == 0 {
                    try? deleteTopic(id: topic.id)
                    continue
                }
            }
            try? updateTopic(topic)
        }
        try execute("DELETE FROM documents WHERE md5 = '\(md5)';")
    }

    func syncAvailableDocuments(additionalSearchPaths: [URL] = [], libraryRoot: URL? = nil) throws {
        try repairDocumentIDs()

        // 1. Remove phantom documents with empty or non-existent file paths
        try execute("DELETE FROM documents WHERE file_path = '' OR file_path IS NULL;")
        if !isInMemory {
            let isNetwork = (libraryRoot != nil && Database.isNetworkVolume(url: libraryRoot!))
            if !isNetwork {
                let currentDocs = try allDocuments()
                for doc in currentDocs {
                    if !FileManager.default.fileExists(atPath: doc.filePath) {
                        try deleteDocument(id: doc.id)
                    }
                }
            }
        }

        // When syncing an external library, purge any documents originating from the default Application Support directory
        if libraryRoot != nil {
            let defaultDocsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MarginGraph/Documents", isDirectory: true).standardizedFileURL.path
            if let defaultDocsDir {
                let currentDocs = try allDocuments()
                for doc in currentDocs {
                    let standardPath = URL(fileURLWithPath: doc.filePath).standardizedFileURL.path
                    if standardPath.hasPrefix(defaultDocsDir) {
                        try deleteDocument(id: doc.id)
                    }
                }
            }
        }

        // Deduplicate any documents sharing the same file_path
        let currentDocs = try allDocuments()
        let allTopicsCached = try allTopics()
        var topicCountByBookMD5: [String: Int] = [:]
        for t in allTopicsCached {
            for b in t.bookMD5List {
                topicCountByBookMD5[b, default: 0] += 1
            }
        }

        let groupedByPath = Dictionary(grouping: currentDocs, by: { $0.filePath })
        for (path, docs) in groupedByPath where docs.count > 1 && !path.isEmpty {
            let bestDoc = docs.max { a, b in
                let aCards = (try? cardCountForDocument(md5: a.md5)) ?? 0
                let bCards = (try? cardCountForDocument(md5: b.md5)) ?? 0
                if aCards != bCards { return aCards < bCards }
                let aTopics = topicCountByBookMD5[a.md5] ?? 0
                let bTopics = topicCountByBookMD5[b.md5] ?? 0
                if aTopics != bTopics { return aTopics < bTopics }
                return a.md5.count < b.md5.count
            } ?? docs[0]

            for doc in docs where doc.id != bestDoc.id {
                try migrateDocumentMD5(from: doc.md5, to: bestDoc.md5)
                try deleteDocument(id: doc.id)
            }

            let sidecar = URL(fileURLWithPath: path).appendingPathExtension("md5")
            try? bestDoc.md5.write(to: sidecar, atomically: true, encoding: .utf8)
        }

        // Deduplicate documents sharing the same title in the same folder
        let docsAfterFilePath = try allDocuments()
        struct FolderTitleKey: Hashable {
            let folderId: UUID?
            let title: String
        }
        let groupedByFolderTitle = Dictionary(grouping: docsAfterFilePath) { doc in
            FolderTitleKey(
                folderId: doc.folderId,
                title: doc.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }

        for (key, docs) in groupedByFolderTitle where docs.count > 1 && !key.title.isEmpty {
            let bestDoc = docs.max { a, b in
                let aCards = (try? cardCountForDocument(md5: a.md5)) ?? 0
                let bCards = (try? cardCountForDocument(md5: b.md5)) ?? 0
                if aCards != bCards { return aCards < bCards }
                let aTopics = topicCountByBookMD5[a.md5] ?? 0
                let bTopics = topicCountByBookMD5[b.md5] ?? 0
                if aTopics != bTopics { return aTopics < bTopics }
                let aExists = FileManager.default.fileExists(atPath: a.filePath)
                let bExists = FileManager.default.fileExists(atPath: b.filePath)
                if aExists != bExists { return !aExists && bExists }
                if a.totalPages != b.totalPages { return a.totalPages < b.totalPages }
                return a.id.uuidString < b.id.uuidString
            } ?? docs[0]

            for doc in docs where doc.id != bestDoc.id {
                try migrateDocumentMD5(from: doc.md5, to: bestDoc.md5)
                try deleteDocument(id: doc.id)

                // If the redundant file is an auto-converted file inside MarginGraph/Documents, clean it from disk
                if !doc.filePath.isEmpty && doc.filePath != bestDoc.filePath {
                    let docURL = URL(fileURLWithPath: doc.filePath)
                    if docURL.path.contains("/MarginGraph/Documents/") {
                        try? FileManager.default.removeItem(at: docURL)
                        let sidecar1 = docURL.appendingPathExtension("md5")
                        try? FileManager.default.removeItem(at: sidecar1)
                        let sidecar2 = docURL.deletingPathExtension().appendingPathExtension("format")
                        try? FileManager.default.removeItem(at: sidecar2)
                        let sidecar3 = docURL.deletingPathExtension().appendingPathExtension("md5")
                        try? FileManager.default.removeItem(at: sidecar3)
                    }
                }
            }
        }

        // Clean up dummy topics with 0 cards when a real topic with cards already exists for the same book or title
        let cardCounts = (try? cardCountsByTopic()) ?? [:]
        let topicsWithCards = allTopicsCached.filter { (cardCounts[$0.id] ?? 0) > 0 }
        var booksWithCards = Set<String>()
        var titlesWithCards = Set<String>()
        for t in topicsWithCards {
            for b in t.bookMD5List { booksWithCards.insert(b.lowercased()) }
            let clean = t.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty { titlesWithCards.insert(clean) }
        }

        for topic in allTopicsCached where (cardCounts[topic.id] ?? 0) == 0 {
            let cleanTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasSisterTitle = !cleanTitle.isEmpty && titlesWithCards.contains(cleanTitle)
            let hasSisterBook = topic.bookMD5List.contains { booksWithCards.contains($0.lowercased()) }
            if hasSisterTitle || hasSisterBook {
                try? deleteTopic(id: topic.id)
            }
        }

        // 2. Discover physical PDF files in search directories
        var searchDirectories: [URL] = []
        if let libraryRoot {
            let ext = libraryRoot.pathExtension.lowercased()
            let isPackage = ext == "marginbackupall" || ext == "marginpkg" || ext == "marginnotes"
            let isNetwork = Database.isNetworkVolume(url: libraryRoot)
            if !isPackage && !isNetwork {
                searchDirectories = [libraryRoot]
            }
        } else if !isInMemory {
            if let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MarginGraph/Documents", isDirectory: true) {
                searchDirectories.append(defaultDir)
            }
        }

        searchDirectories.append(contentsOf: additionalSearchPaths)
        var seenDirs = Set<String>()
        searchDirectories = searchDirectories.filter { seenDirs.insert($0.standardizedFileURL.path).inserted }

        let existingDocsForScan = (try? allDocuments()) ?? []
        var existingPaths = Set(existingDocsForScan.map(\.filePath))
        let existingMD5s = Set(existingDocsForScan.map(\.md5))

        for dir in searchDirectories where FileManager.default.fileExists(atPath: dir.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if let res = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), res.isDirectory == true {
                    let dirName = fileURL.lastPathComponent
                    if dirName == "MarginNotes.sqlite.files" || dirName == "files" || dirName.hasPrefix(".") || dirName.hasSuffix(".marginnotes") || dirName.hasSuffix(".marginpkg") {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // If document is already registered for this physical file path, skip all heavy checks immediately!
                if existingPaths.contains(fileURL.path) {
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                guard MediaDocumentHelper.isSupportedFile(url: fileURL) && ext != "marginpkg" && ext != "marginnotes" && ext != "sqlite" else { continue }

                // Check sidecar .md5 first
                var md5: String? = nil
                let sidecar1 = fileURL.appendingPathExtension("md5")
                let sidecar2 = fileURL.deletingPathExtension().appendingPathExtension("md5")
                if FileManager.default.fileExists(atPath: sidecar1.path),
                   let content = try? String(contentsOf: sidecar1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    md5 = content
                } else if FileManager.default.fileExists(atPath: sidecar2.path),
                          let content = try? String(contentsOf: sidecar2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                          !content.isEmpty {
                    md5 = content
                }

                // If already registered by MD5, update our cached set and skip
                if let md5, existingMD5s.contains(md5) {
                    existingPaths.insert(fileURL.path)
                    continue
                }

                var docType = MediaDocumentHelper.documentType(for: fileURL)
                let sidecarFormat = fileURL.deletingPathExtension().appendingPathExtension("format")
                if docType == "pdf", FileManager.default.fileExists(atPath: sidecarFormat.path),
                   let fmt = try? String(contentsOf: sidecarFormat, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fmt.isEmpty {
                    docType = MediaDocumentHelper.documentType(for: URL(fileURLWithPath: "doc." + fmt))
                }

                if docType == "video" || docType == "audio" {
                    let title = fileURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, let existingByTitle = try? allDocuments().first(where: {
                        $0.folderId == nil &&
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(title) == .orderedSame
                    }) {
                        if !FileManager.default.fileExists(atPath: existingByTitle.filePath) {
                            try? deleteDocument(id: existingByTitle.id)
                        } else {
                            continue
                        }
                    }
                    let docMD5 = md5 ?? MediaDocumentHelper.computeFileMD5(url: fileURL)
                    let duration = MediaDocumentHelper.mediaDuration(url: fileURL)
                    let newDoc = Document(
                        id: Document.stableUUID(docMD5),
                        title: title,
                        filePath: fileURL.path,
                        md5: docMD5,
                        totalPages: Int(duration.rounded()),
                        lastVisited: nil,
                        documentType: docType
                    )
                    try? insertDocument(newDoc)
                } else if let mgr = try? PDFDocumentManager(url: fileURL, md5: md5) {
                    let title = mgr.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, let existingByTitle = try? allDocuments().first(where: {
                        $0.folderId == nil &&
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(title) == .orderedSame
                    }) {
                        if !FileManager.default.fileExists(atPath: existingByTitle.filePath) {
                            try? deleteDocument(id: existingByTitle.id)
                        } else {
                            continue
                        }
                    }
                    let docMD5 = mgr.md5
                    let newDoc = Document(
                        id: Document.stableUUID(docMD5),
                        title: mgr.title,
                        filePath: fileURL.path,
                        md5: docMD5,
                        totalPages: mgr.pageCount,
                        lastVisited: nil,
                        documentType: docType
                    )
                    try? insertDocument(newDoc)

                    // Write sidecar .md5 if missing
                    let sidecar = fileURL.appendingPathExtension("md5")
                    if !FileManager.default.fileExists(atPath: sidecar.path) {
                        try? docMD5.write(to: sidecar, atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        // 3. Repair topic bookMD5List to remove bloated 500+ phantom MD5s
        try repairTopicBookMD5Lists()
        try repairDocumentFolders(libraryRoot: libraryRoot)
    }

    func topicCardBookMD5s() throws -> [UUID: Set<String>] {
        try withStatement("SELECT topic_id, book_md5 FROM cards WHERE book_md5 IS NOT NULL AND book_md5 != '' GROUP BY topic_id, book_md5") { stmt in
            var map: [UUID: Set<String>] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let tStr = text(stmt, 0), let tid = UUID(uuidString: tStr), let bMD5 = text(stmt, 1), !bMD5.isEmpty {
                    map[tid, default: []].insert(bMD5)
                }
            }
            return map
        }
    }

    func repairTopicBookMD5Lists() throws {
        let validDocs: [Document] = try allDocuments().filter { !$0.filePath.isEmpty }
        let validMD5s = Set(validDocs.map(\.md5))
        let topics = try allTopics()
        let topicMD5Map = try topicCardBookMD5s()

        struct PreparedDoc {
            let md5: String
            let lowerTitle: String
            let lowerFileName: String
        }
        let preparedDocs = validDocs.map { doc -> PreparedDoc in
            let fn = (doc.filePath as NSString).lastPathComponent
            let fnNoExt = (fn as NSString).deletingPathExtension.lowercased()
            return PreparedDoc(
                md5: doc.md5,
                lowerTitle: doc.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                lowerFileName: fnNoExt
            )
        }

        let docByMD5 = Dictionary(validDocs.map { ($0.md5, $0) }, uniquingKeysWith: { first, _ in first })
        var topicsToUpdate: [Topic] = []

        for var topic in topics {
            let cardMD5s = topicMD5Map[topic.id] ?? []

            var newBookList: [String] = []

            // 1. If topic has cards with book_md5, use those book_md5s that exist in validMD5s
            for cmd5 in cardMD5s {
                if let exact = docByMD5[cmd5] {
                    if !newBookList.contains(exact.md5) {
                        newBookList.append(exact.md5)
                    }
                } else if let exact = validDocs.first(where: { $0.md5.hasPrefix(cmd5) || cmd5.hasPrefix($0.md5) }) {
                    if !newBookList.contains(exact.md5) {
                        newBookList.append(exact.md5)
                    }
                } else if !newBookList.contains(cmd5) {
                    newBookList.append(cmd5)
                }
            }

            // 2. If topic has no cards or card MD5s didn't match a document, match by topic title
            if newBookList.isEmpty {
                let cleanLowerTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !cleanLowerTitle.isEmpty, let match = preparedDocs.first(where: { doc in
                    doc.lowerTitle == cleanLowerTitle ||
                    doc.lowerFileName == cleanLowerTitle ||
                    cleanLowerTitle.contains(doc.lowerFileName) ||
                    doc.lowerFileName.contains(cleanLowerTitle) ||
                    cleanLowerTitle.contains(doc.lowerTitle) ||
                    doc.lowerTitle.contains(cleanLowerTitle)
                }) {
                    newBookList.append(match.md5)
                }
            }

            // 3. If still empty, only keep bookMD5s from the original list that match a valid document
            if newBookList.isEmpty && topic.bookMD5List.count <= 2 {
                for m in topic.bookMD5List where validMD5s.contains(m) && !newBookList.contains(m) {
                    newBookList.append(m)
                }
            }

            if newBookList != topic.bookMD5List {
                topic.bookMD5List = newBookList
                topicsToUpdate.append(topic)
            }
        }

        if !topicsToUpdate.isEmpty {
            try transaction {
                for t in topicsToUpdate {
                    try updateTopic(t)
                }
            }
        }
    }

    func repairDocumentFolders(libraryRoot: URL? = nil) throws {
        // 0. Cleanup bogus package folders (e.g. named ".marginbackupall", ending with ".marginbackupall" / ".marginpkg")
        let foldersBefore = try allFolders()
        let bogusFolders = foldersBefore.filter { f in
            let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name == ".marginbackupall" || name == ".marginpkg" || name.hasSuffix(".marginbackupall") || name.hasSuffix(".marginpkg")
        }
        for bogus in bogusFolders {
            let children = foldersBefore.filter { $0.parentId == bogus.id }
            for child in children {
                // If a matching root folder already exists, merge documents into it and remove the child
                if let existingRoot = foldersBefore.first(where: {
                    $0.parentId == nil && $0.id != bogus.id && $0.id != child.id &&
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(child.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) {
                    try execute("UPDATE documents SET folder_id = '\(existingRoot.id.uuidString)' WHERE folder_id = '\(child.id.uuidString)';")
                    try execute("DELETE FROM document_folders WHERE id = '\(child.id.uuidString)';")
                } else {
                    // Otherwise promote to root
                    try execute("UPDATE document_folders SET parent_id = NULL WHERE id = '\(child.id.uuidString)';")
                }
            }
            // Move documents directly under the bogus folder back to root
            try execute("UPDATE documents SET folder_id = NULL WHERE folder_id = '\(bogus.id.uuidString)';")
            try execute("DELETE FROM document_folders WHERE id = '\(bogus.id.uuidString)';")
        }

        // Deduplicate any root folders with identical names
        let foldersAfterBogus = try allFolders()
        let groupedRootFolders = Dictionary(grouping: foldersAfterBogus.filter { $0.parentId == nil }) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for (_, group) in groupedRootFolders where group.count > 1 {
            let keeper = group.max { a, b in
                let aCount = (try? allDocuments().filter { $0.folderId == a.id }.count) ?? 0
                let bCount = (try? allDocuments().filter { $0.folderId == b.id }.count) ?? 0
                return aCount < bCount
            } ?? group[0]
            for dup in group where dup.id != keeper.id {
                try execute("UPDATE documents SET folder_id = '\(keeper.id.uuidString)' WHERE folder_id = '\(dup.id.uuidString)';")
                try execute("DELETE FROM document_folders WHERE id = '\(dup.id.uuidString)';")
            }
        }

        let currentFolders = try allFolders()
        var folderMap: [String: DocumentFolder] = [:]
        for folder in currentFolders {
            let key = "\(folder.parentId?.uuidString ?? "root"):\(folder.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            folderMap[key] = folder
        }

        let allDocs = try allDocuments()
        for doc in allDocs {
            guard !doc.filePath.isEmpty else { continue }
            let docPath = doc.filePath
            let pathComponents = (docPath as NSString).pathComponents
            var folderPath: String? = nil

            // 1. Check if the document path is within a package bundle (*.marginbackupall or *.marginpkg)
            if let pkgIndex = pathComponents.firstIndex(where: {
                let lower = $0.lowercased()
                return lower.hasSuffix(".marginbackupall") || lower.hasSuffix(".marginpkg")
            }) {
                // Any subdirectories between the package bundle and the filename are user folders
                if pkgIndex + 1 < pathComponents.count - 1 {
                    let folderSegments = pathComponents[(pkgIndex + 1)..<(pathComponents.count - 1)]
                    let valid = folderSegments.filter { seg in
                        let lower = seg.lowercased()
                        return !lower.isEmpty &&
                            lower != "marginnotes.sqlite.files" &&
                            lower != "files" &&
                            lower != "documents" &&
                            !lower.hasPrefix(".") &&
                            !lower.hasSuffix(".marginbackupall") &&
                            !lower.hasSuffix(".marginpkg")
                    }
                    if !valid.isEmpty {
                        folderPath = valid.joined(separator: "/")
                    }
                }
            } else if let libraryRoot {
                let libPath = libraryRoot.standardizedFileURL.path
                let docURL = URL(fileURLWithPath: docPath)
                let parentDirURL = docURL.deletingLastPathComponent()
                let parentDir = parentDirURL.standardizedFileURL.path
                if parentDir == libPath {
                    folderPath = nil
                } else if parentDir.hasPrefix(libPath + "/") {
                    let relative = String(parentDir.dropFirst(libPath.count + 1))
                    let segments = relative.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { seg in
                        let lower = seg.lowercased()
                        return !lower.isEmpty &&
                            lower != "marginnotes.sqlite.files" &&
                            lower != "files" &&
                            lower != "documents" &&
                            !lower.hasPrefix(".") &&
                            !lower.hasSuffix(".marginbackupall") &&
                            !lower.hasSuffix(".marginpkg")
                    }
                    if !segments.isEmpty {
                        folderPath = segments.joined(separator: "/")
                    }
                }
            } else if doc.documentType == "video" || doc.documentType == "audio" {
                let docURL = URL(fileURLWithPath: docPath)
                let parentName = docURL.deletingLastPathComponent().lastPathComponent
                if !parentName.isEmpty && parentName != "Documents" && parentName != "MarginGraph" && !parentName.hasSuffix(".marginbackupall") && !parentName.hasSuffix(".marginpkg") && !parentName.hasPrefix(".") {
                    folderPath = parentName
                }
            }

            guard let folderPath, !folderPath.isEmpty else {
                // Document belongs at root: if it currently has a folderId, clear it!
                if doc.folderId != nil {
                    try updateDocumentFolder(documentID: doc.id, folderID: nil)
                }
                continue
            }

            let segments = folderPath.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var currentParentID: UUID? = nil

            for segment in segments {
                let key = "\(currentParentID?.uuidString ?? "root"):\(segment.lowercased())"
                let folder: DocumentFolder
                if let existing = folderMap[key] {
                    folder = existing
                } else if let matchInDb = (try allFolders()).first(where: {
                    $0.parentId == currentParentID &&
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(segment) == .orderedSame
                }) {
                    folder = matchInDb
                    folderMap[key] = folder
                } else {
                    let newFolderID = Document.stableUUID("folder_\(currentParentID?.uuidString ?? "")_\(segment)")
                    let newFolder = DocumentFolder(id: newFolderID, parentId: currentParentID, name: segment)
                    try insertFolder(newFolder)
                    folder = newFolder
                    folderMap[key] = folder
                }
                currentParentID = folder.id
            }

            if let targetFolderID = currentParentID, doc.folderId != targetFolderID {
                try updateDocumentFolder(documentID: doc.id, folderID: targetFolderID)
            }
        }
    }

    func updateDocumentLastVisited(id: UUID, date: Date = Date()) throws {
        try withStatement("UPDATE documents SET last_visited = ? WHERE id = ?") { stmt in
            bind(date.timeIntervalSince1970, to: 1, in: stmt)
            bind(id.uuidString, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }

    func updateDocumentLastVisited(md5: String, date: Date = Date()) throws {
        try withStatement("UPDATE documents SET last_visited = ? WHERE md5 = ?") { stmt in
            bind(date.timeIntervalSince1970, to: 1, in: stmt)
            bind(md5, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }

    func updateDocumentPages(id: UUID, pages: Int) throws {
        try withStatement("UPDATE documents SET total_pages = ? WHERE id = ?") { stmt in
            bind(pages, to: 1, in: stmt)
            bind(id.uuidString, to: 2, in: stmt)
            try requireDone(stmt)
        }
    }

    func updateDocumentPosition(id: UUID, pageIndex: Int, pageOffsetY: Double) throws {
        try withStatement("UPDATE documents SET last_page_index = ?, last_page_offset_y = ? WHERE id = ?") { stmt in
            bind(pageIndex, to: 1, in: stmt)
            bind(pageOffsetY, to: 2, in: stmt)
            bind(id.uuidString, to: 3, in: stmt)
            try requireDone(stmt)
        }
    }
}
