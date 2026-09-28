import Foundation
import CryptoKit
import PDFKit
#if canImport(SQLite3)
import SQLite3
#endif

public extension Database {
    func deleteDocument(id: UUID) throws {
        try execute("DELETE FROM documents WHERE id = '\(id.uuidString)';")
    }

    func deleteDocument(md5: String) throws {
        try execute("DELETE FROM documents WHERE md5 = '\(md5)';")
    }

    func syncAvailableDocuments(additionalSearchPaths: [URL] = [], libraryRoot: URL? = nil) throws {
        try repairDocumentIDs()

        // 1. Remove phantom documents with empty or non-existent file paths
        try execute("DELETE FROM documents WHERE file_path = '' OR file_path IS NULL;")
        if !isInMemory {
            let currentDocs = try allDocuments()
            for doc in currentDocs {
                if !FileManager.default.fileExists(atPath: doc.filePath) {
                    try deleteDocument(id: doc.id)
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
        let groupedByPath = Dictionary(grouping: currentDocs, by: { $0.filePath })
        for (path, docs) in groupedByPath where docs.count > 1 && !path.isEmpty {
            let bestDoc = docs.max { a, b in
                let aCards = (try? cardCountForDocument(md5: a.md5)) ?? 0
                let bCards = (try? cardCountForDocument(md5: b.md5)) ?? 0
                if aCards != bCards { return aCards < bCards }
                let aTopics = (try? allTopics().filter { $0.bookMD5List.contains(a.md5) }.count) ?? 0
                let bTopics = (try? allTopics().filter { $0.bookMD5List.contains(b.md5) }.count) ?? 0
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
                let aTopics = (try? allTopics().filter { $0.bookMD5List.contains(a.md5) }.count) ?? 0
                let bTopics = (try? allTopics().filter { $0.bookMD5List.contains(b.md5) }.count) ?? 0
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
        let allTopicsList = try allTopics()
        let cardCounts = (try? cardCountsByTopic()) ?? [:]
        let topicsWithCards = allTopicsList.filter { (cardCounts[$0.id] ?? 0) > 0 }

        for topic in allTopicsList where (cardCounts[topic.id] ?? 0) == 0 {
            let cleanTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSisterTopicWithCards = topicsWithCards.contains { other in
                let cleanOtherTitle = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let titleMatch = cleanOtherTitle.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame ||
                                 cleanOtherTitle.localizedCaseInsensitiveContains(cleanTitle) ||
                                 cleanTitle.localizedCaseInsensitiveContains(cleanOtherTitle)
                let bookMatch = !Set(topic.bookMD5List).isDisjoint(with: Set(other.bookMD5List)) ||
                    topic.bookMD5List.contains(where: { tmd5 in
                        other.bookMD5List.contains(where: { omd5 in
                            tmd5 == omd5 || tmd5.hasPrefix(omd5) || omd5.hasPrefix(tmd5)
                        })
                    })
                return titleMatch || bookMatch
            }
            if hasSisterTopicWithCards {
                try? deleteTopic(id: topic.id)
            }
        }

        // 2. Discover physical PDF files in search directories
        var searchDirectories: [URL] = []
        if let libraryRoot {
            searchDirectories = [libraryRoot]
        } else if !isInMemory {
            if let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MarginGraph/Documents", isDirectory: true) {
                searchDirectories.append(defaultDir)
            }
        }
        searchDirectories.append(contentsOf: additionalSearchPaths)
        var seenDirs = Set<String>()
        searchDirectories = searchDirectories.filter { seenDirs.insert($0.standardizedFileURL.path).inserted }

        for dir in searchDirectories where FileManager.default.fileExists(atPath: dir.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
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

                // If already registered and points to an existing file, skip heavy loading!
                if let md5, let existing = try? getDocumentByMD5(md5: md5),
                   !existing.filePath.isEmpty, FileManager.default.fileExists(atPath: existing.filePath) {
                    continue
                }

                // If document is already registered for this physical file path, skip re-adding!
                if let existingByPath = try? getDocumentByPath(filePath: fileURL.path),
                   !existingByPath.filePath.isEmpty, FileManager.default.fileExists(atPath: existingByPath.filePath) {
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

    func repairTopicBookMD5Lists() throws {
        let validDocs: [Document] = try allDocuments().filter {
            !$0.filePath.isEmpty && (isInMemory || FileManager.default.fileExists(atPath: $0.filePath))
        }
        let validMD5s = Set(validDocs.map(\.md5))
        let topics = try allTopics()

        for var topic in topics {
            let cards = try cardsForTopic(id: topic.id)
            let cardMD5s = Set(cards.compactMap { $0.bookMD5 }.filter { !$0.isEmpty })

            var newBookList: [String] = []

            // 1. If topic has cards with book_md5, use those book_md5s that exist in validMD5s
            for cmd5 in cardMD5s {
                if let exact = validDocs.first(where: { $0.md5 == cmd5 || $0.md5.hasPrefix(cmd5) || cmd5.hasPrefix($0.md5) }) {
                    if !newBookList.contains(exact.md5) {
                        newBookList.append(exact.md5)
                    }
                } else if !newBookList.contains(cmd5) {
                    newBookList.append(cmd5)
                }
            }

            // 2. If topic has no cards or card MD5s didn't match a document, match by topic title
            if newBookList.isEmpty {
                let cleanTopicTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = validDocs.first(where: { doc in
                    let dTitle = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let dFileName = URL(fileURLWithPath: doc.filePath).deletingPathExtension().lastPathComponent
                    return dTitle.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame ||
                           dFileName.localizedCaseInsensitiveCompare(cleanTopicTitle) == .orderedSame ||
                           cleanTopicTitle.localizedCaseInsensitiveContains(dFileName) ||
                           dFileName.localizedCaseInsensitiveContains(cleanTopicTitle) ||
                           cleanTopicTitle.localizedCaseInsensitiveContains(dTitle) ||
                           dTitle.localizedCaseInsensitiveContains(cleanTopicTitle)
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
                try updateTopic(topic)
            }
        }
    }

    func repairDocumentFolders(libraryRoot: URL? = nil) throws {
        let allDocs = try allDocuments()
        let existingFolders = try allFolders()
        var folderMap: [String: DocumentFolder] = [:]
        for folder in existingFolders {
            let key = "\(folder.parentId?.uuidString ?? "root"):\(folder.name.lowercased())"
            folderMap[key] = folder
        }

        for doc in allDocs {
            guard !doc.filePath.isEmpty else { continue }
            let docURL = URL(fileURLWithPath: doc.filePath)
            let parentDirURL = docURL.deletingLastPathComponent()
            let parentDir = parentDirURL.standardizedFileURL.path
            let parentName = parentDirURL.lastPathComponent

            var folderPath: String? = nil

            if let libraryRoot {
                let libPath = libraryRoot.standardizedFileURL.path
                if parentDir != libPath && parentDir.hasPrefix(libPath) {
                    let relative = String(parentDir.dropFirst(libPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !relative.isEmpty && relative != "MarginNotes.sqlite.files" && relative != "files" && relative != "Documents" {
                        folderPath = relative
                    }
                }
            }

            if folderPath == nil {
                if doc.documentType == "video" || doc.documentType == "audio" {
                    if !parentName.isEmpty && parentName != "Documents" && parentName != "MarginGraph" && !parentName.hasSuffix(".marginbackupall") && !parentName.hasSuffix(".marginpkg") {
                        folderPath = parentName
                    }
                }
            }

            guard let folderPath, !folderPath.isEmpty else { continue }

            let segments = folderPath.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var currentParentID: UUID? = nil

            for segment in segments {
                let key = "\(currentParentID?.uuidString ?? "root"):\(segment.lowercased())"
                let folder: DocumentFolder
                if let existing = folderMap[key] {
                    folder = existing
                } else if let matchInDb = existingFolders.first(where: { $0.parentId == currentParentID && $0.name.localizedCaseInsensitiveCompare(segment) == .orderedSame }) {
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
}
