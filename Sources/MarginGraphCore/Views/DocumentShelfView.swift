import SwiftUI
import AppKit
import PDFKit

@MainActor private let coverThumbnailCache = NSCache<NSString, NSImage>()

public struct DocumentShelfView: View {
    public var documents: [Document]
    public var folders: [DocumentFolder]
    public var topics: [Topic]
    public var documentCardCounts: [UUID: Int]
    public var onOpenDocument: (Document) -> Void
    public var onImportDocument: () -> Void
    public var onImportURLs: (([URL]) -> Void)?
    public var onDeleteDocument: (Document) -> Void
    public var onCreateFolder: ((String) -> Void)?
    public var onRenameFolder: ((UUID, String) -> Void)?
    public var onDeleteFolder: ((UUID) -> Void)?
    public var onMoveDocument: ((Document, UUID?) -> Void)?
    public var onAddToStudy: (([Document], UUID?, String?) -> Void)?

    @State private var currentFolderID: UUID? = nil
    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var isDropTargeted: Bool = false

    // Selection Mode
    @State private var isSelectionMode: Bool = false
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isShowingAddToStudySheet: Bool = false
    @State private var isShowingBatchDeleteAlert: Bool = false

    // Folder Sheets & Dialogs
    @State private var isShowingCreateFolderSheet: Bool = false
    @State private var newFolderName: String = ""
    @State private var folderToRename: DocumentFolder? = nil
    @State private var renameFolderName: String = ""
    @State private var folderToDelete: DocumentFolder? = nil

    public init(
        documents: [Document],
        folders: [DocumentFolder] = [],
        topics: [Topic] = [],
        documentCardCounts: [UUID: Int] = [:],
        onOpenDocument: @escaping (Document) -> Void,
        onImportDocument: @escaping () -> Void,
        onImportURLs: (([URL]) -> Void)? = nil,
        onDeleteDocument: @escaping (Document) -> Void,
        onCreateFolder: ((String) -> Void)? = nil,
        onRenameFolder: ((UUID, String) -> Void)? = nil,
        onDeleteFolder: ((UUID) -> Void)? = nil,
        onMoveDocument: ((Document, UUID?) -> Void)? = nil,
        onAddToStudy: (([Document], UUID?, String?) -> Void)? = nil
    ) {
        self.documents = documents
        self.folders = folders
        self.topics = topics
        self.documentCardCounts = documentCardCounts
        self.onOpenDocument = onOpenDocument
        self.onImportDocument = onImportDocument
        self.onImportURLs = onImportURLs
        self.onDeleteDocument = onDeleteDocument
        self.onCreateFolder = onCreateFolder
        self.onRenameFolder = onRenameFolder
        self.onDeleteFolder = onDeleteFolder
        self.onMoveDocument = onMoveDocument
        self.onAddToStudy = onAddToStudy
    }

    private var currentFolder: DocumentFolder? {
        guard let currentFolderID else { return nil }
        return folders.first { $0.id == currentFolderID }
    }

    private var documentsInCurrentView: [Document] {
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

    private var sortedFolders: [DocumentFolder] {
        folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func documentCount(for folder: DocumentFolder) -> Int {
        documents.filter { $0.folderId == folder.id }.count
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Top Bar
                headerBar

                Divider()
                    .background(MarginNoteTheme.separatorColor)

                // Main Content Area
                ScrollView {
                    if currentFolderID == nil && sortedFolders.isEmpty && sortedDocuments.isEmpty {
                        emptyShelfView
                    } else if currentFolderID != nil && sortedDocuments.isEmpty {
                        emptyFolderView
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                            // When at root and not in selection mode, display folders first
                            if currentFolderID == nil && !isSelectionMode {
                                ForEach(sortedFolders) { folder in
                                    FolderCardView(
                                        folder: folder,
                                        itemCount: documentCount(for: folder),
                                        onOpen: {
                                            currentFolderID = folder.id
                                        },
                                        onRename: {
                                            renameFolderName = folder.name
                                            folderToRename = folder
                                        },
                                        onDelete: {
                                            folderToDelete = folder
                                        }
                                    )
                                }
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
                                    onDelete: { onDeleteDocument(doc) }
                                )
                            }
                        }
                        .padding(28)
                        .padding(.bottom, (isSelectionMode && !selectedDocumentIDs.isEmpty) ? 60 : 0)
                    }
                }
            }

            // Floating Selection Toolbar
            if isSelectionMode && !selectedDocumentIDs.isEmpty {
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
        .sheet(isPresented: $isShowingAddToStudySheet) {
            let selectedDocs = documents.filter { selectedDocumentIDs.contains($0.id) }
            AddToStudyNotebookSheet(
                topics: topics,
                selectedDocuments: selectedDocs,
                onConfirm: { targetTopicID, newTopicTitle in
                    onAddToStudy?(selectedDocs, targetTopicID, newTopicTitle)
                    selectedDocumentIDs.removeAll()
                    isSelectionMode = false
                    isShowingAddToStudySheet = false
                },
                onCancel: {
                    isShowingAddToStudySheet = false
                }
            )
        }
        .confirmationDialog(
            "Delete folder \"\(folderToDelete?.name ?? "")\"? Documents inside will be moved to Root.",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let id = folderToDelete?.id {
                    onDeleteFolder?(id)
                    if currentFolderID == id {
                        currentFolderID = nil
                    }
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
        }
        .confirmationDialog(
            "Delete \(selectedDocumentIDs.count) Document\(selectedDocumentIDs.count == 1 ? "" : "s")? This action cannot be undone.",
            isPresented: $isShowingBatchDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedDocumentIDs.count) Document\(selectedDocumentIDs.count == 1 ? "" : "s")", role: .destructive) {
                deleteSelectedDocuments()
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
                    Text("New Folder")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Breadcrumb or Folder Selector
            if let current = currentFolder {
                HStack(spacing: 8) {
                    Button {
                        currentFolderID = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text("All Documents")
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    Text("/")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Text(current.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    Menu {
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
                        ForEach(sortedFolders) { f in
                            Button {
                                currentFolderID = f.id
                            } label: {
                                HStack {
                                    if currentFolderID == f.id {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(f.name)
                                    Spacer()
                                    Text("(\(documentCount(for: f)))")
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
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("Folder: All Documents")
                            .font(.system(size: 13, weight: .regular))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
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
            Button(isSelectionMode ? "Done" : "Select") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedDocumentIDs.removeAll()
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: isSelectionMode ? .semibold : .regular))
            .foregroundStyle(isSelectionMode ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelectionMode ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))

            // Select All Button (in selection mode)
            if isSelectionMode {
                Button(selectedDocumentIDs.count == sortedDocuments.count && !sortedDocuments.isEmpty ? "Deselect All" : "Select All") {
                    if selectedDocumentIDs.count == sortedDocuments.count {
                        selectedDocumentIDs.removeAll()
                    } else {
                        selectedDocumentIDs = Set(sortedDocuments.map(\.id))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Floating Selection Toolbar

    private var selectionFloatingToolbar: some View {
        HStack(spacing: 16) {
            Text("\(selectedDocumentIDs.count) Selected")
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
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 18)

            // 2. Move to Folder Menu
            Menu {
                Button("All Documents (Root)") {
                    moveSelectedDocuments(to: nil)
                }
                if !folders.isEmpty {
                    Divider()
                    ForEach(folders) { f in
                        Button(f.name) {
                            moveSelectedDocuments(to: f.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Move to…")
                        .font(.system(size: 12.5, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton)

            Divider()
                .frame(height: 18)

            // 3. Delete Selected Documents
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

    private func moveSelectedDocuments(to targetFolderID: UUID?) {
        let selectedDocs = documents.filter { selectedDocumentIDs.contains($0.id) }
        for doc in selectedDocs {
            onMoveDocument?(doc, targetFolderID)
        }
        selectedDocumentIDs.removeAll()
        isSelectionMode = false
    }

    private func deleteSelectedDocuments() {
        let selectedDocs = documents.filter { selectedDocumentIDs.contains($0.id) }
        for doc in selectedDocs {
            onDeleteDocument(doc)
        }
        selectedDocumentIDs.removeAll()
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
            Text("This folder is empty. Right-click any document to move it here, or import a new file.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("Import to Folder…", action: onImportDocument)
                    .buttonStyle(.borderedProminent)
                Button("Back to All Documents") {
                    currentFolderID = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Sheets

    private var createFolderSheet: some View {
        VStack(spacing: 18) {
            Text("New Folder")
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
                        onCreateFolder?(trimmed)
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

// MARK: - Folder Card View

public struct FolderCardView: View {
    public var folder: DocumentFolder
    public var itemCount: Int
    public var onOpen: () -> Void
    public var onRename: () -> Void
    public var onDelete: () -> Void

    public init(
        folder: DocumentFolder,
        itemCount: Int,
        onOpen: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.folder = folder
        self.itemCount = itemCount
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        Button(action: onOpen) {
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

                        Text("\(itemCount) \(itemCount == 1 ? "document" : "documents")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.8), in: Capsule())
                    }
                }

                // Folder Name Below Card
                Text(folder.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)

                // Subtitle / Indicator
                HStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Folder") { onOpen() }
            Divider()
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

    public init(
        document: Document,
        folders: [DocumentFolder] = [],
        cardCount: Int = 0,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onOpen: @escaping () -> Void,
        onToggleSelect: (() -> Void)? = nil,
        onMoveToFolder: ((UUID?) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
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
    }

    private var docType: String {
        if !document.documentType.isEmpty {
            return document.documentType
        }
        return MediaDocumentHelper.documentType(for: URL(fileURLWithPath: document.filePath))
    }

    private var badgeColor: Color {
        switch docType {
        case "video":
            return Color(red: 0.15, green: 0.45, blue: 0.85) // Blue
        case "audio":
            return Color(red: 0.12, green: 0.60, blue: 0.42) // Emerald
        case "epub":
            return Color.orange
        default:
            return MarginNoteTheme.badgePDFRed
        }
    }

    public var body: some View {
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
                    if let image = loadCoverThumbnail(path: document.filePath, docType: docType) {
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

                // Cloud & More dots
                HStack {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isSelectionMode {
                Button("Open") { onOpen() }
                Divider()
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
    }

    private func loadCoverThumbnail(path: String, docType: String) -> NSImage? {
        let key = path as NSString
        if let cached = coverThumbnailCache.object(forKey: key) {
            return cached
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if docType == "video" {
            if let img = MediaDocumentHelper.generatePosterFrame(url: url) {
                coverThumbnailCache.setObject(img, forKey: key)
                return img
            }
        } else if docType == "pdf" {
            guard let pdfDoc = PDFDocument(url: url),
                  let page = pdfDoc.page(at: 0) else {
                return nil
            }
            let thumbSize = NSSize(width: 148, height: 180)
            let img = page.thumbnail(of: thumbSize, for: .mediaBox)
            coverThumbnailCache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
}
