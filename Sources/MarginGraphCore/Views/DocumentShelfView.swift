import SwiftUI
import AppKit
import PDFKit

private nonisolated(unsafe) let coverThumbnailCache = NSCache<NSString, NSImage>()

public struct DocumentShelfView: View {
    public var documents: [Document]
    public var folders: [DocumentFolder]
    public var topics: [Topic]
    public var documentCardCounts: [UUID: Int]
    public var onOpenDocument: (Document) -> Void
    public var onImportDocument: () -> Void
    public var onImportURLs: (([URL]) -> Void)?
    public var onDeleteDocument: (Document) -> Void
    public var onRenameDocument: ((Document, String) -> Void)?
    public var onCreateFolder: ((String, UUID?) -> Void)?
    public var onRenameFolder: ((UUID, String) -> Void)?
    public var onDeleteFolder: ((UUID) -> Void)?
    public var onMoveDocument: ((Document, UUID?) -> Void)?
    public var onMoveFolder: ((DocumentFolder, UUID?) -> Void)?
    public var onAddToStudy: (([Document], UUID?, String?) -> Void)?
    public var onExportDocumentMarginPkg: ((Document) -> Void)?
    public var onExportFolderMarginPkg: ((DocumentFolder) -> Void)?
    public var onManageLibraries: (() -> Void)?
    public var onImportHighlights: ((Document) -> Void)?
    @Binding public var isSearchPresented: Bool
    @Binding public var searchQuery: String

    @State private var currentFolderID: UUID? = nil
    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var isDropTargeted: Bool = false

    // Selection Mode
    @State private var isSelectionMode: Bool = false
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var isShowingAddToStudySheet: Bool = false
    @State private var isShowingBatchDeleteAlert: Bool = false
    @State private var isShowingBatchMovePopover: Bool = false
    @State private var hoveredBatchMoveItem: String? = nil

    // Folder & Document Sheets & Dialogs
    @State private var isShowingCreateFolderSheet: Bool = false
    @State private var newFolderName: String = ""
    @State private var folderToRename: DocumentFolder? = nil
    @State private var renameFolderName: String = ""
    @State private var folderToDelete: DocumentFolder? = nil
    @State private var documentToDelete: Document? = nil
    @State private var documentToRename: Document? = nil
    @State private var renameDocumentTitle: String = ""
    @FocusState private var isSearchFieldFocused: Bool

    public init(
        documents: [Document],
        folders: [DocumentFolder] = [],
        topics: [Topic] = [],
        documentCardCounts: [UUID: Int] = [:],
        isSearchPresented: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        onOpenDocument: @escaping (Document) -> Void,
        onImportDocument: @escaping () -> Void,
        onImportURLs: (([URL]) -> Void)? = nil,
        onDeleteDocument: @escaping (Document) -> Void,
        onRenameDocument: ((Document, String) -> Void)? = nil,
        onCreateFolder: ((String, UUID?) -> Void)? = nil,
        onRenameFolder: ((UUID, String) -> Void)? = nil,
        onDeleteFolder: ((UUID) -> Void)? = nil,
        onMoveDocument: ((Document, UUID?) -> Void)? = nil,
        onMoveFolder: ((DocumentFolder, UUID?) -> Void)? = nil,
        onAddToStudy: (([Document], UUID?, String?) -> Void)? = nil,
        onExportDocumentMarginPkg: ((Document) -> Void)? = nil,
        onExportFolderMarginPkg: ((DocumentFolder) -> Void)? = nil,
        onManageLibraries: (() -> Void)? = nil,
        onImportHighlights: ((Document) -> Void)? = nil
    ) {
        self.documents = documents
        self.folders = folders
        self.topics = topics
        self.documentCardCounts = documentCardCounts
        self._isSearchPresented = isSearchPresented
        self._searchQuery = searchQuery
        self.onOpenDocument = onOpenDocument
        self.onImportDocument = onImportDocument
        self.onImportURLs = onImportURLs
        self.onDeleteDocument = onDeleteDocument
        self.onRenameDocument = onRenameDocument
        self.onCreateFolder = onCreateFolder
        self.onRenameFolder = onRenameFolder
        self.onDeleteFolder = onDeleteFolder
        self.onMoveDocument = onMoveDocument
        self.onMoveFolder = onMoveFolder
        self.onAddToStudy = onAddToStudy
        self.onExportDocumentMarginPkg = onExportDocumentMarginPkg
        self.onExportFolderMarginPkg = onExportFolderMarginPkg
        self.onManageLibraries = onManageLibraries
        self.onImportHighlights = onImportHighlights
    }

    public init(
        documents: [Document],
        folders: [DocumentFolder] = [],
        topics: [Topic] = [],
        documentCardCounts: [UUID: Int] = [:],
        isSearchPresented: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        onOpenDocument: @escaping (Document) -> Void,
        onImportDocument: @escaping () -> Void,
        onImportURLs: (([URL]) -> Void)? = nil,
        onDeleteDocument: @escaping (Document) -> Void,
        onRenameDocument: ((Document, String) -> Void)? = nil,
        onCreateFolder: ((String) -> Void)?,
        onRenameFolder: ((UUID, String) -> Void)? = nil,
        onDeleteFolder: ((UUID) -> Void)? = nil,
        onMoveDocument: ((Document, UUID?) -> Void)? = nil,
        onMoveFolder: ((DocumentFolder, UUID?) -> Void)? = nil,
        onAddToStudy: (([Document], UUID?, String?) -> Void)? = nil,
        onExportDocumentMarginPkg: ((Document) -> Void)? = nil,
        onExportFolderMarginPkg: ((DocumentFolder) -> Void)? = nil,
        onManageLibraries: (() -> Void)? = nil,
        onImportHighlights: ((Document) -> Void)? = nil
    ) {
        self.init(
            documents: documents,
            folders: folders,
            topics: topics,
            documentCardCounts: documentCardCounts,
            isSearchPresented: isSearchPresented,
            searchQuery: searchQuery,
            onOpenDocument: onOpenDocument,
            onImportDocument: onImportDocument,
            onImportURLs: onImportURLs,
            onDeleteDocument: onDeleteDocument,
            onRenameDocument: onRenameDocument,
            onCreateFolder: onCreateFolder.map { fn in { name, _ in fn(name) } },
            onRenameFolder: onRenameFolder,
            onDeleteFolder: onDeleteFolder,
            onMoveDocument: onMoveDocument,
            onMoveFolder: onMoveFolder,
            onAddToStudy: onAddToStudy,
            onExportDocumentMarginPkg: onExportDocumentMarginPkg,
            onExportFolderMarginPkg: onExportFolderMarginPkg,
            onManageLibraries: onManageLibraries,
            onImportHighlights: onImportHighlights
        )
    }

    private var currentFolder: DocumentFolder? {
        guard let currentFolderID else { return nil }
        return folders.first { $0.id == currentFolderID }
    }

    private var foldersInCurrentView: [DocumentFolder] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if let currentFolderID {
            return folders.filter { $0.parentId == currentFolderID }
        } else {
            return folders.filter { $0.parentId == nil }
        }
    }

    private var sortedFolders: [DocumentFolder] {
        foldersInCurrentView.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var documentsInCurrentView: [Document] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return documents.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                URL(fileURLWithPath: $0.filePath).lastPathComponent.localizedCaseInsensitiveContains(query)
            }
        }
        if let currentFolderID {
            return documents.filter { $0.folderId == currentFolderID }
        } else {
            return documents.filter { $0.folderId == nil }
        }
    }

    private var sortedDocuments: [Document] {
        let docs = documentsInCurrentView
        if sortMode == 0 {
            return docs.sorted {
                let d0 = $0.lastVisited ?? .distantPast
                let d1 = $1.lastVisited ?? .distantPast
                if d0 != d1 {
                    return d0 > d1
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } else {
            return docs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private func itemCount(for folder: DocumentFolder) -> Int {
        let docCount = documents.filter { $0.folderId == folder.id }.count
        let subfolderCount = folders.filter { $0.parentId == folder.id }.count
        return docCount + subfolderCount
    }

    private func folderBreadcrumbs(for folderID: UUID?) -> [DocumentFolder] {
        var crumbs: [DocumentFolder] = []
        var cur = folderID
        var visited = Set<UUID>()
        while let fid = cur, !visited.contains(fid), let f = folders.first(where: { $0.id == fid }) {
            visited.insert(fid)
            crumbs.append(f)
            cur = f.parentId
        }
        return crumbs.reversed()
    }

    private func isDescendant(candidateChildID: UUID, of ancestorID: UUID) -> Bool {
        var nextParentID: UUID? = candidateChildID
        var visited = Set<UUID>()
        while let pid = nextParentID, !visited.contains(pid) {
            if pid == ancestorID { return true }
            visited.insert(pid)
            nextParentID = folders.first(where: { $0.id == pid })?.parentId
        }
        return false
    }

    private var hierarchicallySortedFolders: [DocumentFolder] {
        var result: [DocumentFolder] = []
        func appendChildren(of parentID: UUID?) {
            let children = folders
                .filter { $0.parentId == parentID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for child in children {
                result.append(child)
                appendChildren(of: child.id)
            }
        }
        appendChildren(of: nil)
        return result
    }

    private func folderDepth(_ folder: DocumentFolder) -> Int {
        var depth = 0
        var currentParent = folder.parentId
        var visited = Set<UUID>()
        while let pid = currentParent, !visited.contains(pid), let parent = folders.first(where: { $0.id == pid }) {
            visited.insert(pid)
            depth += 1
            currentParent = parent.parentId
        }
        return depth
    }

    private func collectDocuments(in folderID: UUID) -> [Document] {
        var result = documents.filter { $0.folderId == folderID }
        let subfolders = folders.filter { $0.parentId == folderID }
        for sub in subfolders {
            result.append(contentsOf: collectDocuments(in: sub.id))
        }
        return result
    }

    private var totalSelectedCount: Int {
        selectedDocumentIDs.count + selectedFolderIDs.count
    }

    private var isAllSelected: Bool {
        let totalPossible = sortedDocuments.count + sortedFolders.count
        return totalPossible > 0 && selectedDocumentIDs.count == sortedDocuments.count && selectedFolderIDs.count == sortedFolders.count
    }

    private var documentsForStudySelection: [Document] {
        var result: [Document] = []
        var seenIDs = Set<UUID>()

        for doc in documents where selectedDocumentIDs.contains(doc.id) {
            if seenIDs.insert(doc.id).inserted {
                result.append(doc)
            }
        }

        for folderID in selectedFolderIDs {
            for doc in collectDocuments(in: folderID) {
                if seenIDs.insert(doc.id).inserted {
                    result.append(doc)
                }
            }
        }

        return result
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search documents…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchQuery = ""
                    isSearchPresented = false
                    isSearchFieldFocused = false
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: isSearchPresented) { presented in
            if presented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
            }
        }
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.15)) {
                searchQuery = ""
                isSearchPresented = false
                isSearchFieldFocused = false
            }
        }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Top Bar
                headerBar

                if isSearchPresented {
                    searchBar
                }

                Divider()
                    .background(MarginNoteTheme.separatorColor)

                // Main Content Area
                ScrollView {
                    if sortedFolders.isEmpty && sortedDocuments.isEmpty {
                        if !searchQuery.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No Documents Found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        } else if currentFolderID == nil {
                            emptyShelfView
                        } else {
                            emptyFolderView
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                            // Display folders in current scope (both at root and inside nested folders)
                            ForEach(sortedFolders) { folder in
                                let isFolderSelected = selectedFolderIDs.contains(folder.id)
                                FolderCardView(
                                    folder: folder,
                                    itemCount: itemCount(for: folder),
                                    allFolders: folders,
                                    isSelectionMode: isSelectionMode,
                                    isSelected: isFolderSelected,
                                    onOpen: {
                                        if isSelectionMode {
                                            if isFolderSelected {
                                                selectedFolderIDs.remove(folder.id)
                                            } else {
                                                selectedFolderIDs.insert(folder.id)
                                            }
                                        } else {
                                            currentFolderID = folder.id
                                        }
                                    },
                                    onToggleSelect: {
                                        if isFolderSelected {
                                            selectedFolderIDs.remove(folder.id)
                                        } else {
                                            selectedFolderIDs.insert(folder.id)
                                        }
                                    },
                                    onRename: {
                                        renameFolderName = folder.name
                                        folderToRename = folder
                                    },
                                    onDelete: {
                                        folderToDelete = folder
                                    },
                                    onMoveToFolder: { targetFolderID in
                                        if let onMoveFolder {
                                            onMoveFolder(folder, targetFolderID)
                                        } else {
                                            let folderDocs = documents.filter { $0.folderId == folder.id }
                                            for doc in folderDocs {
                                                onMoveDocument?(doc, targetFolderID)
                                            }
                                        }
                                    },
                                    onAddToStudy: {
                                        let folderDocs = collectDocuments(in: folder.id)
                                        guard !folderDocs.isEmpty else { return }
                                        selectedFolderIDs = [folder.id]
                                        selectedDocumentIDs = []
                                        isShowingAddToStudySheet = true
                                    },
                                    onExportMarginPkg: onExportFolderMarginPkg.map { fn in { fn(folder) } }
                                )
                            }

                            // Display documents in the current scope
                            ForEach(sortedDocuments, id: \.id) { doc in
                                let isSelected = selectedDocumentIDs.contains(doc.id)
                                DocumentCardView(
                                    document: doc,
                                    folders: folders,
                                    cardCount: documentCardCounts[doc.id] ?? 0,
                                    isSelectionMode: isSelectionMode,
                                    isSelected: isSelected,
                                    onOpen: { onOpenDocument(doc) },
                                    onToggleSelect: {
                                        if isSelected {
                                            selectedDocumentIDs.remove(doc.id)
                                        } else {
                                            selectedDocumentIDs.insert(doc.id)
                                        }
                                    },
                                    onMoveToFolder: { targetFolderID in
                                        onMoveDocument?(doc, targetFolderID)
                                    },
                                    onDelete: { documentToDelete = doc },
                                    onRename: {
                                        renameDocumentTitle = doc.title
                                        documentToRename = doc
                                    },
                                    onAddToStudy: {
                                        selectedDocumentIDs = [doc.id]
                                        selectedFolderIDs = []
                                        isShowingAddToStudySheet = true
                                    },
                                    onExportMarginPkg: onExportDocumentMarginPkg.map { fn in { fn(doc) } },
                                    onImportHighlights: onImportHighlights.map { fn in { fn(doc) } }
                                )
                            }
                        }
                        .padding(28)
                        .padding(.bottom, (isSelectionMode && totalSelectedCount > 0) ? 60 : 0)
                    }
                }
            }

            // Floating Selection Toolbar
            if isSelectionMode && totalSelectedCount > 0 {
                selectionFloatingToolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(MarginNoteTheme.shelfBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0)
                .padding(4)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let collector = URLCollector()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        collector.add(url)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !collector.urls.isEmpty {
                    onImportURLs?(collector.urls)
                }
            }
            return true
        }
        .sheet(isPresented: $isShowingCreateFolderSheet) {
            createFolderSheet
        }
        .sheet(item: $folderToRename) { folder in
            renameFolderSheet(folder: folder)
        }
        .sheet(item: $documentToRename) { doc in
            renameDocumentSheet(document: doc)
        }
        .sheet(isPresented: $isShowingAddToStudySheet) {
            let selectedDocs = documentsForStudySelection
            AddToStudyNotebookSheet(
                topics: topics,
                selectedDocuments: selectedDocs,
                onConfirm: { targetTopicID, newTopicTitle in
                    onAddToStudy?(selectedDocs, targetTopicID, newTopicTitle)
                    selectedDocumentIDs.removeAll()
                    selectedFolderIDs.removeAll()
                    isSelectionMode = false
                    isShowingAddToStudySheet = false
                },
                onCancel: {
                    isShowingAddToStudySheet = false
                }
            )
        }
        .alert("Delete Document?", isPresented: Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { documentToDelete = nil }
                .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                if let document = documentToDelete { onDeleteDocument(document) }
                documentToDelete = nil
            }
        } message: {
            Text("Remove \"\(documentToDelete?.title ?? "")\" from this library? Its notebook notes will also be removed. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete folder \"\(folderToDelete?.name ?? "")\"? Items inside will be moved to \(folderToDelete?.parentId == nil ? "Root" : "parent folder").",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let id = folderToDelete?.id {
                    let parentID = folderToDelete?.parentId
                    onDeleteFolder?(id)
                    if currentFolderID == id {
                        currentFolderID = parentID
                    }
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
        }
        .confirmationDialog(
            "Delete \(totalSelectedCount) Item\(totalSelectedCount == 1 ? "" : "s")? This action cannot be undone.",
            isPresented: $isShowingBatchDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete \(totalSelectedCount) Item\(totalSelectedCount == 1 ? "" : "s")", role: .destructive) {
                deleteSelectedItems()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Import Button
            Button(action: onImportDocument) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                    Text("Import")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            // New Folder Button
            Button {
                newFolderName = "Folder \(folders.count + 1)"
                isShowingCreateFolderSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                    Text(currentFolderID == nil ? "New Folder" : "New Subfolder")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            // Manage Libraries Button (Always available in document view)
            if let onManageLibraries {
                Button(action: onManageLibraries) {
                    HStack(spacing: 5) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 13))
                        Text("Manage Libraries…")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Manage libraries, set startup default library, and aliases")
            }

            Spacer()

            // Breadcrumb or Folder Selector
            if let current = currentFolder {
                let crumbs = folderBreadcrumbs(for: currentFolderID)
                HStack(spacing: 8) {
                    Button {
                        currentFolderID = current.parentId
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(current.parentId == nil ? "All Documents" : (folders.first(where: { $0.id == current.parentId })?.name ?? "Back"))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    Button {
                        currentFolderID = nil
                    } label: {
                        Text("All Documents")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    ForEach(crumbs) { crumb in
                        Text("/")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if crumb.id == current.id {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                Text(crumb.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            Button {
                                currentFolderID = crumb.id
                            } label: {
                                Text(crumb.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Menu {
                        if let onExportFolderMarginPkg {
                            Button("Export Folder to MarginNote Package (.marginpkg)…") {
                                onExportFolderMarginPkg(current)
                            }
                            Divider()
                        }
                        Button("Rename Folder…") {
                            renameFolderName = current.name
                            folderToRename = current
                        }
                        Divider()
                        Button("Delete Folder", role: .destructive) {
                            folderToDelete = current
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Menu {
                    Button {
                        currentFolderID = nil
                    } label: {
                        HStack {
                            if currentFolderID == nil {
                                Image(systemName: "checkmark")
                            }
                            Text("All Documents (Root)")
                        }
                    }
                    if !folders.isEmpty {
                        Divider()
                        ForEach(hierarchicallySortedFolders) { f in
                            let depth = folderDepth(f)
                            let indent = String(repeating: "    ", count: depth)
                            Button {
                                currentFolderID = f.id
                            } label: {
                                HStack {
                                    if currentFolderID == f.id {
                                        Image(systemName: "checkmark")
                                    }
                                    Text("\(indent)\(depth > 0 ? "↳ " : "")\(f.name)")
                                    Spacer()
                                    Text("(\(itemCount(for: f)))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("+ New Folder…") {
                        newFolderName = "Folder \(folders.count + 1)"
                        isShowingCreateFolderSheet = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("Folder: All Documents")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            // Subheader with Recent / Name segmented control
            Picker("", selection: $sortMode) {
                Text("Recent").tag(0)
                Text("Name").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)

            // Select Mode Toggle Button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedDocumentIDs.removeAll()
                        selectedFolderIDs.removeAll()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 12))
                    Text(isSelectionMode ? "Done" : "Select")
                        .font(.system(size: 13, weight: isSelectionMode ? .semibold : .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelectionMode ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isSelectionMode ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)

            // Select All Button (in selection mode)
            if isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if isAllSelected {
                            selectedDocumentIDs.removeAll()
                            selectedFolderIDs.removeAll()
                        } else {
                            selectedDocumentIDs = Set(sortedDocuments.map(\.id))
                            if currentFolderID == nil {
                                selectedFolderIDs = Set(sortedFolders.map(\.id))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isAllSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                        Text(isAllSelected ? "Deselect All" : "Select All")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Floating Selection Toolbar

    private var selectionFloatingToolbar: some View {
        HStack(spacing: 16) {
            Text("\(totalSelectedCount) Selected")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)

            Divider()
                .frame(height: 18)

            // 1. Add to Study Button
            Button {
                isShowingAddToStudySheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 12))
                    Text("Add to Study…")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(documentsForStudySelection.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(documentsForStudySelection.isEmpty)

            Divider()
                .frame(height: 18)

            // 2. Move to Folder Popover (opens upward to stay within window bounds)
            Button {
                isShowingBatchMovePopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Move to…")
                        .font(.system(size: 12.5, weight: .medium))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isShowingBatchMovePopover ? Color.secondary.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingBatchMovePopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(totalSelectedCount) item\(totalSelectedCount > 1 ? "s" : "") to:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    Divider()

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                moveSelectedItems(to: nil)
                                isShowingBatchMovePopover = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "tray")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 16)
                                    Text("All Documents (Root)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(hoveredBatchMoveItem == "root" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredBatchMoveItem = $0 ? "root" : nil }

                            let availableFolders = hierarchicallySortedFolders.filter { f in
                                !selectedFolderIDs.contains(f.id) &&
                                !selectedFolderIDs.contains(where: { selID in isDescendant(candidateChildID: f.id, of: selID) })
                            }

                            if !availableFolders.isEmpty {
                                Divider()
                                    .padding(.vertical, 2)

                                ForEach(availableFolders) { f in
                                    let depth = folderDepth(f)
                                    let indent = String(repeating: "    ", count: depth)
                                    Button {
                                        moveSelectedItems(to: f.id)
                                        isShowingBatchMovePopover = false
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 12))
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 16)
                                            Text("\(indent)\(depth > 0 ? "↳ " : "")\(f.name)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(hoveredBatchMoveItem == f.id.uuidString ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredBatchMoveItem = $0 ? f.id.uuidString : nil }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .padding(6)
                .frame(width: 220)
            }

            Divider()
                .frame(height: 18)

            // 3. Delete Selected Documents & Folders
            Button(role: .destructive) {
                isShowingBatchDeleteAlert = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Delete")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 18)

            // 4. Cancel Button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isShowingBatchMovePopover = false
                    selectedDocumentIDs.removeAll()
                    selectedFolderIDs.removeAll()
                    isSelectionMode = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Cancel")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.98).opacity(0.96))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.1), lineWidth: 0.75)
                )
        )
        .padding(.bottom, 20)
    }

    private func moveSelectedItems(to targetFolderID: UUID?) {
        let selectedDocs = documents.filter { selectedDocumentIDs.contains($0.id) }
        for doc in selectedDocs {
            onMoveDocument?(doc, targetFolderID)
        }
        for folderID in selectedFolderIDs {
            if let folder = folders.first(where: { $0.id == folderID }) {
                if targetFolderID != folder.id && (targetFolderID == nil || !isDescendant(candidateChildID: targetFolderID!, of: folder.id)) {
                    if let onMoveFolder {
                        onMoveFolder(folder, targetFolderID)
                    } else {
                        let folderDocs = documents.filter { $0.folderId == folderID }
                        for doc in folderDocs {
                            onMoveDocument?(doc, targetFolderID)
                        }
                    }
                }
            }
        }
        selectedDocumentIDs.removeAll()
        selectedFolderIDs.removeAll()
        isSelectionMode = false
    }

    private func deleteSelectedItems() {
        let selectedDocs = documents.filter { selectedDocumentIDs.contains($0.id) }
        for doc in selectedDocs {
            onDeleteDocument(doc)
        }
        for folderID in selectedFolderIDs {
            let parentID = folders.first(where: { $0.id == folderID })?.parentId
            onDeleteFolder?(folderID)
            if currentFolderID == folderID {
                currentFolderID = parentID
            }
        }
        selectedDocumentIDs.removeAll()
        selectedFolderIDs.removeAll()
        isSelectionMode = false
    }

    // MARK: - Empty Views

    private var emptyShelfView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Documents")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Import Document / Media…", action: onImportDocument)
                    .buttonStyle(.borderedProminent)
                Button("Create Folder") {
                    newFolderName = "Folder \(folders.count + 1)"
                    isShowingCreateFolderSheet = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(currentFolder?.name ?? "Folder is Empty")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("This folder is empty. Create a subfolder, right-click any document to move it here, or import a new file.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("New Subfolder") {
                    newFolderName = "Folder \(folders.count + 1)"
                    isShowingCreateFolderSheet = true
                }
                .buttonStyle(.borderedProminent)
                Button("Import to Folder…", action: onImportDocument)
                    .buttonStyle(.bordered)
                Button(currentFolder?.parentId == nil ? "Back to All Documents" : "Back to Parent Folder") {
                    currentFolderID = currentFolder?.parentId
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Sheets

    private var createFolderSheet: some View {
        VStack(spacing: 18) {
            Text(currentFolderID == nil ? "New Folder" : "New Subfolder in \"\(currentFolder?.name ?? "")\"")
                .font(.headline)

            TextField("Folder Name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isShowingCreateFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onCreateFolder?(trimmed, currentFolderID)
                    }
                    isShowingCreateFolderSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 260)
        }
        .padding(24)
    }

    private func renameFolderSheet(folder: DocumentFolder) -> some View {
        VStack(spacing: 18) {
            Text("Rename Folder")
                .font(.headline)

            TextField("Folder Name", text: $renameFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack(spacing: 12) {
                Button("Cancel") {
                    folderToRename = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRenameFolder?(folder.id, trimmed)
                    }
                    folderToRename = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 260)
        }
        .padding(24)
    }

    private func renameDocumentSheet(document: Document) -> some View {
        VStack(spacing: 18) {
            Text("Rename Document")
                .font(.headline)

            TextField("Document Title", text: $renameDocumentTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack(spacing: 12) {
                Button("Cancel") {
                    documentToRename = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    let trimmed = renameDocumentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRenameDocument?(document, trimmed)
                    }
                    documentToRename = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(renameDocumentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 320)
        }
        .padding(24)
    }
}

// MARK: - Add To Study Notebook Sheet

public struct AddToStudyNotebookSheet: View {
    public var topics: [Topic]
    public var selectedDocuments: [Document]
    public var onConfirm: (UUID?, String?) -> Void
    public var onCancel: () -> Void

    @State private var mode: Int = 0 // 0: Existing, 1: New
    @State private var selectedTopicID: UUID? = nil
    @State private var newTopicTitle: String = ""
    @State private var searchText: String = ""

    public init(
        topics: [Topic],
        selectedDocuments: [Document],
        onConfirm: @escaping (UUID?, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.topics = topics
        self.selectedDocuments = selectedDocuments
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let defaultTitle = selectedDocuments.count == 1 ? selectedDocuments[0].title : "Study Notebook"
        _newTopicTitle = State(initialValue: defaultTitle)
        _selectedTopicID = State(initialValue: topics.first?.id)
        _mode = State(initialValue: topics.isEmpty ? 1 : 0)
    }

    private var filteredTopics: [Topic] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return topics
        }
        return topics.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add to Study Notebook")
                        .font(.headline)
                    Text("\(selectedDocuments.count) document\(selectedDocuments.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            // Mode Picker
            Picker("", selection: $mode) {
                Text("Existing Notebook").tag(0)
                Text("New Notebook").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .disabled(topics.isEmpty)

            if mode == 0 && !topics.isEmpty {
                // Existing notebook selection
                VStack(spacing: 8) {
                    if topics.count > 5 {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            TextField("Search notebooks…", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 20)
                    }

                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(filteredTopics, id: \.id) { topic in
                                let isSelected = (selectedTopicID == topic.id)
                                Button {
                                    selectedTopicID = topic.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "book.closed.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(topic.title)
                                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Text("\(topic.bookMD5List.count) document\(topic.bookMD5List.count == 1 ? "" : "s")")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 15))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(height: 170)
                }
            } else {
                // New notebook creation
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notebook Name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Enter notebook name", text: $newTopicTitle)
                        .textFieldStyle(.roundedBorder)

                    Text("Selected documents will be opened in tabs within this new study notebook.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .frame(height: 170)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Open in Study") {
                    if mode == 0 {
                        onConfirm(selectedTopicID, nil)
                    } else {
                        onConfirm(nil, newTopicTitle)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(mode == 1 && newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .disabled(mode == 0 && selectedTopicID == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380, height: 340)
    }
}

// MARK: - URL Collector

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }
}

// MARK: - Action Popover Cards

public struct DocumentActionCardView: View {
    public var document: Document
    public var folders: [DocumentFolder]
    public var onAddToStudy: () -> Void
    public var onMoveToFolder: (UUID?) -> Void
    public var onRename: (() -> Void)?
    public var onDelete: () -> Void
    public var onExportMarginPkg: (() -> Void)?
    public var onImportHighlights: (() -> Void)?

    @State private var hoveredItem: String? = nil
    @State private var showingMoveDestinations: Bool = false

    private var hierarchicallySortedFolders: [DocumentFolder] {
        var result: [DocumentFolder] = []
        func appendChildren(of parentID: UUID?) {
            let direct = folders.filter { $0.parentId == parentID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for f in direct {
                result.append(f)
                appendChildren(of: f.id)
            }
        }
        appendChildren(of: nil)
        return result
    }

    private func folderDepth(_ folder: DocumentFolder) -> Int {
        var depth = 0
        var cur = folder.parentId
        var visited = Set<UUID>()
        while let pid = cur, !visited.contains(pid) {
            visited.insert(pid)
            depth += 1
            cur = folders.first(where: { $0.id == pid })?.parentId
        }
        return depth
    }

    public init(
        document: Document,
        folders: [DocumentFolder],
        onAddToStudy: @escaping () -> Void,
        onMoveToFolder: @escaping (UUID?) -> Void,
        onRename: (() -> Void)? = nil,
        onDelete: @escaping () -> Void,
        onExportMarginPkg: (() -> Void)? = nil,
        onImportHighlights: (() -> Void)? = nil
    ) {
        self.document = document
        self.folders = folders
        self.onAddToStudy = onAddToStudy
        self.onMoveToFolder = onMoveToFolder
        self.onRename = onRename
        self.onDelete = onDelete
        self.onExportMarginPkg = onExportMarginPkg
        self.onImportHighlights = onImportHighlights
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showingMoveDestinations {
                // Back button
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingMoveDestinations = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                        Text("Move to")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "back" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "back" : nil }

                Divider()
                    .padding(.vertical, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        // All Documents (Root)
                        let isAtRoot = (document.folderId == nil)
                        Button {
                            if !isAtRoot {
                                onMoveToFolder(nil)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.system(size: 12))
                                    .foregroundStyle(isAtRoot ? .secondary : Color.accentColor)
                                    .frame(width: 16)
                                Text("All Documents (Root)")
                                    .font(.system(size: 12, weight: isAtRoot ? .regular : .medium))
                                    .foregroundStyle(isAtRoot ? .secondary : .primary)
                                Spacer()
                                if isAtRoot {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(hoveredItem == "dest_root" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAtRoot)
                        .onHover { hoveredItem = $0 ? "dest_root" : nil }

                        // Target Folders
                        ForEach(hierarchicallySortedFolders) { f in
                            let isCurrent = (f.id == document.folderId)
                            let depth = folderDepth(f)
                            let indent = String(repeating: "    ", count: depth)
                            Button {
                                if !isCurrent {
                                    onMoveToFolder(f.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(isCurrent ? .secondary : Color.accentColor)
                                        .frame(width: 16)
                                    Text("\(indent)\(depth > 0 ? "↳ " : "")\(f.name)")
                                        .font(.system(size: 12, weight: isCurrent ? .regular : .medium))
                                        .foregroundStyle(isCurrent ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(hoveredItem == "dest_\(f.id)" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCurrent)
                            .onHover { hoveredItem = $0 ? "dest_\(f.id)" : nil }
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else {
                // Add to Study
                Button(action: onAddToStudy) {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                        Text("Add to Study…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "study" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "study" : nil }

                Divider()
                    .padding(.vertical, 2)

                // Move to...
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingMoveDestinations = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(width: 16)
                        Text("Move to…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "move" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "move" : nil }

                // Rename
                Button {
                    onRename?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(width: 16)
                        Text("Rename…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "rename" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "rename" : nil }

                Divider()
                    .padding(.vertical, 2)

                if let onImportHighlights {
                    Button(action: onImportHighlights) {
                        HStack(spacing: 8) {
                            Image(systemName: "highlighter")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Import PDF Highlights…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "import_highlights" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "import_highlights" : nil }

                    Divider()
                        .padding(.vertical, 2)
                }

                if let onExportMarginPkg {
                    Button(action: onExportMarginPkg) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Export to MarginNote Package (.marginpkg)…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "export_marginpkg" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "export_marginpkg" : nil }

                    Divider()
                        .padding(.vertical, 2)
                }

                // Delete
                Button(role: .destructive, action: onDelete) {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(width: 16)
                        Text("Delete")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "delete" ? Color.red.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "delete" : nil }
            }
        }
        .padding(6)
        .frame(width: 210)
    }
}

public struct FolderActionCardView: View {
    public var folder: DocumentFolder
    public var allFolders: [DocumentFolder]
    public var itemCount: Int
    public var onAddToStudy: () -> Void
    public var onMoveToFolder: (UUID?) -> Void
    public var onRename: () -> Void
    public var onDelete: () -> Void
    public var onExportMarginPkg: (() -> Void)?

    @State private var hoveredItem: String? = nil
    @State private var showingMoveDestinations: Bool = false

    public init(
        folder: DocumentFolder,
        allFolders: [DocumentFolder],
        itemCount: Int,
        onAddToStudy: @escaping () -> Void,
        onMoveToFolder: @escaping (UUID?) -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onExportMarginPkg: (() -> Void)? = nil
    ) {
        self.folder = folder
        self.allFolders = allFolders
        self.itemCount = itemCount
        self.onAddToStudy = onAddToStudy
        self.onMoveToFolder = onMoveToFolder
        self.onRename = onRename
        self.onDelete = onDelete
        self.onExportMarginPkg = onExportMarginPkg
    }

    private func isDescendant(candidateChildID: UUID, of ancestorID: UUID) -> Bool {
        var nextParentID: UUID? = candidateChildID
        var visited = Set<UUID>()
        while let pid = nextParentID, !visited.contains(pid) {
            if pid == ancestorID { return true }
            visited.insert(pid)
            nextParentID = allFolders.first(where: { $0.id == pid })?.parentId
        }
        return false
    }

    private var hierarchicallySortedFolders: [DocumentFolder] {
        var result: [DocumentFolder] = []
        func appendChildren(of parentID: UUID?) {
            let direct = allFolders.filter { $0.parentId == parentID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for f in direct {
                result.append(f)
                appendChildren(of: f.id)
            }
        }
        appendChildren(of: nil)
        return result
    }

    private func folderDepth(_ folder: DocumentFolder) -> Int {
        var depth = 0
        var cur = folder.parentId
        var visited = Set<UUID>()
        while let pid = cur, !visited.contains(pid) {
            visited.insert(pid)
            depth += 1
            cur = allFolders.first(where: { $0.id == pid })?.parentId
        }
        return depth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showingMoveDestinations {
                // Back button
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingMoveDestinations = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                        Text("Move to")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "back" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "back" : nil }

                Divider()
                    .padding(.vertical, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        // All Documents (Root)
                        let isAtRoot = (folder.parentId == nil)
                        Button {
                            if !isAtRoot {
                                onMoveToFolder(nil)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.system(size: 12))
                                    .foregroundStyle(isAtRoot ? .secondary : Color.accentColor)
                                    .frame(width: 16)
                                Text("All Documents (Root)")
                                    .font(.system(size: 12, weight: isAtRoot ? .regular : .medium))
                                    .foregroundStyle(isAtRoot ? .secondary : .primary)
                                Spacer()
                                if isAtRoot {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(hoveredItem == "dest_root" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAtRoot)
                        .onHover { hoveredItem = $0 ? "dest_root" : nil }

                        let validFolders = hierarchicallySortedFolders.filter { candidate in
                            candidate.id != folder.id && !isDescendant(candidateChildID: candidate.id, of: folder.id)
                        }
                        ForEach(validFolders) { f in
                            let isCurrentParent = (f.id == folder.parentId)
                            let depth = folderDepth(f)
                            let indent = String(repeating: "    ", count: depth)
                            Button {
                                if !isCurrentParent {
                                    onMoveToFolder(f.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(isCurrentParent ? .secondary : Color.accentColor)
                                        .frame(width: 16)
                                    Text("\(indent)\(depth > 0 ? "↳ " : "")\(f.name)")
                                        .font(.system(size: 12, weight: isCurrentParent ? .regular : .medium))
                                        .foregroundStyle(isCurrentParent ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if isCurrentParent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(hoveredItem == "dest_\(f.id)" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCurrentParent)
                            .onHover { hoveredItem = $0 ? "dest_\(f.id)" : nil }
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else {
                // Add to Study
                Button(action: onAddToStudy) {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(itemCount > 0 ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text("Add to Study…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(itemCount > 0 ? Color.primary : Color.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "study" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(itemCount == 0)
                .onHover { hoveredItem = $0 ? "study" : nil }

                Divider()
                    .padding(.vertical, 2)

                // Move to... (move all contents inside this folder to another folder or root)
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingMoveDestinations = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(width: 16)
                        Text("Move to…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "move" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "move" : nil }

                Divider()
                    .padding(.vertical, 2)

                // Rename Folder
                Button(action: onRename) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .frame(width: 16)
                        Text("Rename Folder…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "rename" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "rename" : nil }

                Divider()
                    .padding(.vertical, 2)

                if let onExportMarginPkg {
                    Button(action: onExportMarginPkg) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Export to MarginNote Package (.marginpkg)…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "export_marginpkg" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "export_marginpkg" : nil }

                    Divider()
                        .padding(.vertical, 2)
                }

                // Delete Folder
                Button(role: .destructive, action: onDelete) {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(width: 16)
                        Text("Delete Folder")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "delete" ? Color.red.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "delete" : nil }
            }
        }
        .padding(6)
        .frame(width: 210)
    }
}

// MARK: - Folder Card View

public struct FolderCardView: View {
    public var folder: DocumentFolder
    public var itemCount: Int
    public var allFolders: [DocumentFolder]
    public var isSelectionMode: Bool
    public var isSelected: Bool
    public var onOpen: () -> Void
    public var onToggleSelect: (() -> Void)?
    public var onRename: () -> Void
    public var onDelete: () -> Void
    public var onMoveToFolder: ((UUID?) -> Void)?
    public var onAddToStudy: (() -> Void)?
    public var onExportMarginPkg: (() -> Void)?

    @State private var isShowingActionPopover: Bool = false

    public init(
        folder: DocumentFolder,
        itemCount: Int,
        allFolders: [DocumentFolder] = [],
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelect: (() -> Void)? = nil,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onMoveToFolder: ((UUID?) -> Void)? = nil,
        onAddToStudy: (() -> Void)? = nil,
        onExportMarginPkg: (() -> Void)? = nil
    ) {
        self.folder = folder
        self.itemCount = itemCount
        self.allFolders = allFolders
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onOpen = onOpen
        self.onToggleSelect = onToggleSelect
        self.onRename = onRename
        self.onDelete = onDelete
        self.onMoveToFolder = onMoveToFolder
        self.onAddToStudy = onAddToStudy
        self.onExportMarginPkg = onExportMarginPkg
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main clickable folder card (toggles select or opens folder)
            Button {
                if isSelectionMode {
                    onToggleSelect?()
                } else {
                    onOpen()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // Folder Cover Container
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.94, green: 0.94, blue: 0.96),
                                        Color(red: 0.88, green: 0.89, blue: 0.92)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 180)
                            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

                        VStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.28, green: 0.58, blue: 0.96),
                                            Color(red: 0.16, green: 0.44, blue: 0.86)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .shadow(color: Color.blue.opacity(0.2), radius: 3, x: 0, y: 2)

                            Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.8), in: Capsule())
                        }

                        // Selection Mode Checkbox (bottom-right circle indicator)
                        if isSelectionMode {
                            HStack {
                                Spacer()
                                VStack {
                                    Spacer()
                                    ZStack {
                                        Circle()
                                            .fill(isSelected ? Color.accentColor : Color.white.opacity(0.85))
                                            .frame(width: 22, height: 22)
                                            .shadow(color: .black.opacity(0.25), radius: 2)

                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        } else {
                                            Circle()
                                                .stroke(Color.gray.opacity(0.6), lineWidth: 1.5)
                                                .frame(width: 20, height: 20)
                                        }
                                    }
                                    .padding(6)
                                }
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )

                    // Folder Name Below Card
                    Text(folder.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Subtitle / Indicator Row with "..." Action Popover Button
            HStack {
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary.opacity(0.75))

                Spacer()

                Button {
                    isShowingActionPopover.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .frame(width: 22, height: 16)
                        .background(isShowingActionPopover ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingActionPopover, arrowEdge: .trailing) {
                    FolderActionCardView(
                        folder: folder,
                        allFolders: allFolders,
                        itemCount: itemCount,
                        onAddToStudy: {
                            isShowingActionPopover = false
                            onAddToStudy?()
                        },
                        onMoveToFolder: { targetFolderID in
                            isShowingActionPopover = false
                            onMoveToFolder?(targetFolderID)
                        },
                        onRename: {
                            isShowingActionPopover = false
                            onRename()
                        },
                        onDelete: {
                            isShowingActionPopover = false
                            onDelete()
                        },
                        onExportMarginPkg: onExportMarginPkg.map { fn in
                            {
                                isShowingActionPopover = false
                                fn()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 148)
        .contextMenu {
            Button("Open Folder") { onOpen() }
            Divider()
            if let onExportMarginPkg {
                Button("Export to MarginNote Package (.marginpkg)…") { onExportMarginPkg() }
                Divider()
            }
            if let onAddToStudy {
                Button("Add to Study…") { onAddToStudy() }
            }
            Button("Rename Folder…") { onRename() }
            Divider()
            Button("Delete Folder", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Document Card View

public struct DocumentCardView: View {
    public var document: Document
    public var folders: [DocumentFolder]
    public var cardCount: Int
    public var isSelectionMode: Bool
    public var isSelected: Bool
    public var onOpen: () -> Void
    public var onToggleSelect: (() -> Void)?
    public var onMoveToFolder: ((UUID?) -> Void)?
    public var onDelete: (() -> Void)?
    public var onRename: (() -> Void)?
    public var onAddToStudy: (() -> Void)?
    public var onExportMarginPkg: (() -> Void)?
    public var onImportHighlights: (() -> Void)?

    @State private var isShowingActionPopover: Bool = false

    public init(
        document: Document,
        folders: [DocumentFolder] = [],
        cardCount: Int = 0,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelect: (() -> Void)? = nil,
        onMoveToFolder: ((UUID?) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onRename: (() -> Void)? = nil,
        onAddToStudy: (() -> Void)? = nil,
        onExportMarginPkg: (() -> Void)? = nil,
        onImportHighlights: (() -> Void)? = nil
    ) {
        self.document = document
        self.folders = folders
        self.cardCount = cardCount
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onOpen = onOpen
        self.onToggleSelect = onToggleSelect
        self.onMoveToFolder = onMoveToFolder
        self.onDelete = onDelete
        self.onRename = onRename
        self.onAddToStudy = onAddToStudy
        self.onExportMarginPkg = onExportMarginPkg
        self.onImportHighlights = onImportHighlights
    }

    @State private var loadedThumbnail: NSImage? = nil

    private var docType: String {
        if !document.documentType.isEmpty && document.documentType != "pdf" {
            return document.documentType
        }
        let url = URL(fileURLWithPath: document.filePath)
        if DocumentFileAccess.requiresExplicitOpen(document.filePath) {
            return MediaDocumentHelper.documentType(for: url)
        }
        let sidecarFormat = url.deletingPathExtension().appendingPathExtension("format")
        if FileManager.default.fileExists(atPath: sidecarFormat.path),
           let fmt = try? String(contentsOf: sidecarFormat, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fmt.isEmpty {
            return MediaDocumentHelper.documentType(for: URL(fileURLWithPath: "doc." + fmt))
        }
        return MediaDocumentHelper.documentType(for: url)
    }

    private var badgeColor: Color {
        switch docType {
        case "video":
            return Color(red: 0.15, green: 0.45, blue: 0.85) // Blue
        case "audio":
            return Color(red: 0.12, green: 0.60, blue: 0.42) // Emerald
        case "epub":
            return Color.orange
        case "comic":
            return Color(red: 0.88, green: 0.28, blue: 0.55) // Magenta/Pink for Comics
        case "mobi":
            return Color(red: 0.35, green: 0.55, blue: 0.85) // Steel Blue
        case "azw3":
            return Color(red: 0.85, green: 0.48, blue: 0.12) // Amazon Amber
        case "pdb":
            return Color(red: 0.40, green: 0.55, blue: 0.30) // Palm Olive
        case "docx":
            return Color(red: 0.16, green: 0.42, blue: 0.82) // Word Blue
        case "odt":
            return Color(red: 0.28, green: 0.35, blue: 0.78) // OpenDocument Indigo
        case "chm":
            return Color(red: 0.10, green: 0.55, blue: 0.70) // CHM Cyan
        case "djvu":
            return Color(red: 0.65, green: 0.35, blue: 0.15) // DjVu Amber
        case "latex":
            return Color(red: 0.15, green: 0.55, blue: 0.45) // TeX Emerald
        case "asciidoc":
            return Color(red: 0.85, green: 0.35, blue: 0.25) // AsciiDoc Coral
        case "org":
            return Color(red: 0.45, green: 0.35, blue: 0.65) // Org Purple
        case "rst":
            return Color(red: 0.25, green: 0.50, blue: 0.65) // RST Steel Blue
        case "fb2":
            return Color(red: 0.75, green: 0.45, blue: 0.15) // Amber/Bronze
        case "text":
            return Color(red: 0.45, green: 0.45, blue: 0.50) // Slate
        case "markdown":
            return Color(red: 0.20, green: 0.65, blue: 0.70) // Cyan/Teal
        case "rtf":
            return Color(red: 0.50, green: 0.35, blue: 0.75) // Purple
        case "html":
            return Color(red: 0.20, green: 0.60, blue: 0.35) // Forest Green
        default:
            return MarginNoteTheme.badgePDFRed
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main clickable book cover + title button
            Button {
                if isSelectionMode {
                    onToggleSelect?()
                } else {
                    onOpen()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // Book Cover Container
                    ZStack(alignment: .topLeading) {
                        // Same natural paper fill color for both PDF and Video
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0.93, green: 0.91, blue: 0.86))
                            .frame(height: 180)
                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                        // Cover thumbnail or preview preserving original ratio
                        if let image = loadedThumbnail ?? coverThumbnailCache.object(forKey: document.filePath as NSString) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            VStack(spacing: 8) {
                                if docType == "video" {
                                    Image(systemName: "film.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "audio" {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "comic" {
                                    Image(systemName: "photo.stack.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "markdown" {
                                    Image(systemName: "arrow.down.doc.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "text" {
                                    Image(systemName: "doc.plaintext.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "docx" || docType == "odt" {
                                    Image(systemName: "doc.text.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "latex" {
                                    Image(systemName: "function")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "org" {
                                    Image(systemName: "checklist")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "asciidoc" {
                                    Image(systemName: "text.alignleft")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "rst" {
                                    Image(systemName: "doc.plaintext.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "chm" {
                                    Image(systemName: "questionmark.folder.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "djvu" {
                                    Image(systemName: "doc.richtext.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "rtf" {
                                    Image(systemName: "doc.richtext.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else if docType == "html" {
                                    Image(systemName: "safari.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                } else {
                                    Image(systemName: "book.closed.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }

                                Text(document.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                                    .padding(.horizontal, 10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: 180)
                        }

                        // Top Left Type Badge
                        HStack(spacing: 3) {
                            if docType == "video" {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 7.5))
                                Text("VIDEO")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "audio" {
                                Image(systemName: "waveform")
                                    .font(.system(size: 7.5))
                                Text("AUDIO")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "comic" {
                                Text("COMIC")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "mobi" {
                                Text("MOBI")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "azw3" {
                                Text("AZW3")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "pdb" {
                                Text("PDB")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "docx" {
                                Text("DOCX")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "odt" {
                                Text("ODT")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "chm" {
                                Text("CHM")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "djvu" {
                                Text("DJVU")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "latex" {
                                Text("TEX")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "asciidoc" {
                                Text("ADOC")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "org" {
                                Text("ORG")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "rst" {
                                Text("RST")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "fb2" {
                                Text("FB2")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "text" {
                                Text("TXT")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "markdown" {
                                Text("MD")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "rtf" {
                                Text("RTF")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "html" {
                                Text("HTML")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else if docType == "epub" {
                                Text("EPUB")
                                    .font(.system(size: 8.5, weight: .bold))
                            } else {
                                Text("PDF")
                                    .font(.system(size: 8.5, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(badgeColor, in: RoundedRectangle(cornerRadius: 2))
                        .padding(5)

                        // Top Right Note Card Count Badge: ONLY show if cardCount > 0
                        if cardCount > 0 {
                            HStack {
                                Spacer()
                                Text("\(cardCount)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(MarginNoteTheme.badgeGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                                    .padding(5)
                            }
                        }

                        // Selection Mode Checkbox (bottom-right circle indicator)
                        if isSelectionMode {
                            HStack {
                                Spacer()
                                VStack {
                                    Spacer()
                                    ZStack {
                                        Circle()
                                            .fill(isSelected ? Color.accentColor : Color.white.opacity(0.85))
                                            .frame(width: 22, height: 22)
                                            .shadow(color: .black.opacity(0.25), radius: 2)

                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        } else {
                                            Circle()
                                                .stroke(Color.gray.opacity(0.6), lineWidth: 1.5)
                                                .frame(width: 20, height: 20)
                                        }
                                    }
                                    .padding(6)
                                }
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )

                    // Title Below Card
                    Text(document.title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Bottom Row: Cloud icon & "..." Action Popover Button
            HStack {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.6))

                Spacer()

                Button {
                    isShowingActionPopover.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .frame(width: 22, height: 16)
                        .background(isShowingActionPopover ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingActionPopover, arrowEdge: .trailing) {
                    DocumentActionCardView(
                        document: document,
                        folders: folders,
                        onAddToStudy: {
                            isShowingActionPopover = false
                            onAddToStudy?()
                        },
                        onMoveToFolder: { targetFolderID in
                            isShowingActionPopover = false
                            onMoveToFolder?(targetFolderID)
                        },
                        onRename: {
                            isShowingActionPopover = false
                            onRename?()
                        },
                        onDelete: {
                            isShowingActionPopover = false
                            onDelete?()
                        },
                        onExportMarginPkg: onExportMarginPkg.map { fn in
                            {
                                isShowingActionPopover = false
                                fn()
                            }
                        },
                        onImportHighlights: onImportHighlights.map { fn in
                            {
                                isShowingActionPopover = false
                                fn()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 148)
        .contextMenu {
            if !isSelectionMode {
                Button("Open") { onOpen() }
                Divider()
                if let onImportHighlights {
                    Button("Import PDF Highlights…") { onImportHighlights() }
                    Divider()
                }
                if let onExportMarginPkg {
                    Button("Export to MarginNote Package (.marginpkg)…") { onExportMarginPkg() }
                    Divider()
                }
                Button("Rename…") { onRename?() }
                if let onAddToStudy {
                    Button("Add to Study…") { onAddToStudy() }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(document.filePath, inFileViewerRootedAtPath: "")
                }
                Divider()
                Menu("Move to…") {
                    if document.folderId != nil {
                        Button("All Documents (Root)") {
                            onMoveToFolder?(nil)
                        }
                        Divider()
                    }
                    ForEach(folders) { f in
                        Button {
                            onMoveToFolder?(f.id)
                        } label: {
                            HStack {
                                if document.folderId == f.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(f.name)
                            }
                        }
                        .disabled(document.folderId == f.id)
                    }
                }
                Divider()
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
            }
        }
        .onAppear {
            loadThumbnailAsync()
        }
        .onChange(of: document.filePath) { _, _ in
            loadThumbnailAsync()
        }
    }

    private func loadThumbnailAsync() {
        let path = document.filePath
        let type = docType
        guard !path.isEmpty else { return }
        if let cached = coverThumbnailCache.object(forKey: path as NSString) {
            loadedThumbnail = cached
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let img = Self.generateCoverThumbnail(path: path, docType: type)
            if let img {
                DispatchQueue.main.async {
                    self.loadedThumbnail = img
                }
            }
        }
    }

    private nonisolated static func generateCoverThumbnail(path: String, docType: String) -> NSImage? {
        let key = path as NSString
        if let cached = coverThumbnailCache.object(forKey: key) {
            return cached
        }
        if let saved = DocumentCoverStore.load(path: path, variant: "shelf-v1") {
            coverThumbnailCache.setObject(saved, forKey: key)
            return saved
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if docType == "video" {
            if let img = MediaDocumentHelper.generatePosterFrame(url: url) {
                DocumentCoverStore.save(img, path: path, variant: "shelf-v1")
                coverThumbnailCache.setObject(img, forKey: key)
                return img
            }
        } else if docType != "audio" {
            // For EPUB, extract native high-resolution cover image directly if available
            if url.pathExtension.lowercased() == "epub" {
                if let coverImg = MediaDocumentHelper.extractEPUBCoverImage(url: url) {
                    DocumentCoverStore.save(coverImg, path: path, variant: "shelf-v1")
                    coverThumbnailCache.setObject(coverImg, forKey: key)
                    return coverImg
                }
            }

            let pdfURL: URL?
            if url.pathExtension.lowercased() == "pdf" {
                pdfURL = url
            } else if MediaDocumentHelper.isEBook(url: url) {
                pdfURL = EBookConverter.existingConvertedPDFURL(for: url)
            } else {
                pdfURL = nil
            }
            if let validPDFURL = pdfURL,
               let pdfDoc = PDFDocument(url: validPDFURL),
               let page = pdfDoc.page(at: 0) {
                let thumbSize = NSSize(width: 148, height: 180)
                let cropBox = page.bounds(for: .cropBox)
                let box: PDFDisplayBox = (cropBox.width > 0 && cropBox.height > 0) ? .cropBox : .mediaBox
                let img = page.thumbnail(of: thumbSize, for: box)
                DocumentCoverStore.save(img, path: path, variant: "shelf-v1")
                coverThumbnailCache.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }
}

