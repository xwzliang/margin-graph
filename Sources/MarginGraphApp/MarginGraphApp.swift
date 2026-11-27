import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import SQLite3
import MarginGraphCore

public enum WorkspaceViewMode: String, CaseIterable, Identifiable {
    case readerOnly = "1-View"
    case splitView = "2-View"
    case threeView = "3-View"
    case mindMapOnly = "MindMap"

    public var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedMainTab: MainNavigationTab = .document
    let referenceWorkspace = ReferenceWorkspace()
    @Published var isExportingOrg = false
    @Published var isReplacingPDF = false
    @Published var isInStudyWorkspace: Bool = false
    @Published var isOutlineVisible: Bool = false
    @Published var workspaceMode: WorkspaceViewMode = .splitView
    @Published var isShelfSearchPresented: Bool = false
    @Published var shelfSearchQuery: String = ""

    // MindMap Search State
    @Published var isMindMapSearchPresented: Bool = false
    @Published var mindMapSearchQuery: String = "" {
        didSet {
            guard mindMapSearchQuery != oldValue else { return }
            scheduleMindMapSearchJump()
        }
    }
    @Published var mindMapSearchScope: MindMapSearchScope = .all {
        didSet {
            guard mindMapSearchScope != oldValue else { return }
            scheduleMindMapSearchJump()
        }
    }
    @Published var currentMindMapMatchIndex: Int = 0
    private var mindMapSearchDebounceTask: Task<Void, Never>? = nil

    var matchingMindMapCards: [NoteCard] {
        let q = mindMapSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return mindMapCards.filter { MindMapSearchMatcher.matches(card: $0, query: q, scope: mindMapSearchScope) }
    }

    private func scheduleMindMapSearchJump() {
        mindMapSearchDebounceTask?.cancel()
        currentMindMapMatchIndex = 0
        let q = mindMapSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        mindMapSearchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.jumpToCurrentMindMapMatch()
        }
    }

    func nextMindMapSearchResult() {
        let matches = matchingMindMapCards
        guard !matches.isEmpty else { return }
        currentMindMapMatchIndex = (currentMindMapMatchIndex + 1) % matches.count
        jumpToCurrentMindMapMatch()
    }

    func previousMindMapSearchResult() {
        let matches = matchingMindMapCards
        guard !matches.isEmpty else { return }
        currentMindMapMatchIndex = (currentMindMapMatchIndex - 1 + matches.count) % matches.count
        jumpToCurrentMindMapMatch()
    }

    func jumpToCurrentMindMapMatch() {
        let matches = matchingMindMapCards
        guard !matches.isEmpty else { return }
        if currentMindMapMatchIndex < 0 || currentMindMapMatchIndex >= matches.count {
            currentMindMapMatchIndex = 0
        }
        let target = matches[currentMindMapMatchIndex]
        select(card: target)
        cardIDToCenter = target.id
    }

    func toggleMindMapSearch() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isMindMapSearchPresented.toggle()
            if isMindMapSearchPresented {
                if !mindMapSearchQuery.isEmpty {
                    jumpToCurrentMindMapMatch()
                }
            } else {
                closeMindMapSearch()
            }
        }
    }

    func closeMindMapSearch() {
        mindMapSearchDebounceTask?.cancel()
        isMindMapSearchPresented = false
        mindMapSearchQuery = ""
        currentMindMapMatchIndex = 0
    }

    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    @Published var documentFolders: [DocumentFolder] = []
    @Published var documentCardCounts: [UUID: Int] = [:]
    @Published var selectedTopicID: UUID?
    @Published var studyDocuments: [Document] = []
    @Published var activeDocument: Document?
    @Published var manager: PDFDocumentManager?
    @Published var documentCards: [NoteCard] = []
    @Published var mindMapCards: [NoteCard] = []
    @Published var links: [CardLink] = []
    @Published var selectedCardID: UUID?
    @Published var cardIDToCenter: UUID? = nil
    @Published var activeToolbarOwner: ToolbarOwner = .none
    @Published var jumpTarget: PDFJumpTarget?
    @Published var dueFlashcards: [NoteCard] = []
    @Published var cardCounts: [UUID: Int] = [:]
    @Published var reviewDecks: [ReviewDeckItem] = []
    @Published var customDecks: [CardDeck] = []
    @Published var deckCardCounts: [UUID: Int] = [:]
    @Published var dueDeckCounts: [UUID: Int] = [:]
    @Published var cardForAddToDeck: NoteCard? = nil
    @Published var activeReviewCards: [NoteCard] = []
    @Published var activeReviewDocuments: [Document] = []
    @Published var isReviewPresented = false
    @Published var linkedMindMapCard: NoteCard? = nil
    @Published var editingCard: NoteCard? = nil
    @Published var freeNoteDraft: NoteCard? = nil
    @Published var editingCardTitleID: UUID? = nil
    @Published var documentBookmarks: Set<Int> = []
    @Published var isManagingDocuments = false
    @Published var studyDocumentSheetMode: StudyDocumentSheetMode = .manage
    @Published var handledHighlightImportMD5s: Set<String> = []
    var documentCurrentPage: [String: Int] = [:]
    var documentPageOffsets: [String: Double] = [:]
    var documentMindPan: [String: CGPoint] = [:]
    var documentMindZoom: [String: CGFloat] = [:]
    var topicMindPan: [UUID: CGPoint] = [:]
    var topicMindZoom: [UUID: CGFloat] = [:]

    private var positionSaveWorkItem: DispatchWorkItem? = nil
    private var pendingDocPositions: [String: (page: Int, offset: Double)] = [:]
    private var pendingDocMindMaps: [String: (pan: CGPoint, zoom: CGFloat)] = [:]
    private var pendingTopicMindMaps: [UUID: (pan: CGPoint, zoom: CGFloat)] = [:]

    var currentMindPan: CGPoint? {
        if let md5 = activeDocument?.md5, let pan = documentMindPan[md5] {
            return pan
        }
        if let topicID = selectedTopicID, let pan = topicMindPan[topicID] {
            return pan
        }
        return nil
    }

    var currentMindZoom: CGFloat? {
        if let md5 = activeDocument?.md5, let zoom = documentMindZoom[md5] {
            return zoom
        }
        if let topicID = selectedTopicID, let zoom = topicMindZoom[topicID] {
            return zoom
        }
        return nil
    }

    func updatePDFPosition(md5: String, pageIndex: Int, pageOffsetY: Double) {
        documentCurrentPage[md5] = pageIndex
        documentPageOffsets[md5] = pageOffsetY
        pendingDocPositions[md5] = (pageIndex, pageOffsetY)
        schedulePositionSave()
    }

    func updateMindMapPosition(pan: CGPoint, zoom: CGFloat) {
        if let md5 = activeDocument?.md5 {
            documentMindPan[md5] = pan
            documentMindZoom[md5] = zoom
            pendingDocMindMaps[md5] = (pan, zoom)
        }
        if let topicID = selectedTopicID {
            topicMindPan[topicID] = pan
            topicMindZoom[topicID] = zoom
            pendingTopicMindMaps[topicID] = (pan, zoom)
        }
        schedulePositionSave()
    }

    private func schedulePositionSave() {
        positionSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingPositions()
        }
        positionSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func flushPendingPositions() {
        positionSaveWorkItem?.cancel()
        positionSaveWorkItem = nil

        for (md5, pos) in pendingDocPositions {
            try? database.updateDocumentPosition(md5: md5, pageIndex: pos.page, pageOffsetY: pos.offset)
        }
        pendingDocPositions.removeAll()

        for (md5, mm) in pendingDocMindMaps {
            try? database.updateDocumentMindMapPosition(md5: md5, panX: Double(mm.pan.x), panY: Double(mm.pan.y), zoomScale: Double(mm.zoom))
        }
        pendingDocMindMaps.removeAll()

        for (topicID, mm) in pendingTopicMindMaps {
            try? database.updateTopicMindMapPosition(id: topicID, panX: Double(mm.pan.x), panY: Double(mm.pan.y), zoomScale: Double(mm.zoom))
        }
        pendingTopicMindMaps.removeAll()
    }

    var database: Database
    var mediaStorage: MediaStorage
    let undoManager = UndoManager()

    @Published var activeDatabaseName: String = "Default Library"
    @Published var activeDatabaseURL: URL? = nil
    private var externalLibraryDirectory: URL?
    @Published var isExternalDatabase: Bool = false
    @Published var isOpeningDatabase: Bool = false
    @Published private(set) var isImportingMarginNote = false
    @Published var isExportingDocument: Bool = false
    @Published var databaseOpeningStatus: String = ""
    @Published var databaseErrorMessage: String? = nil
    @Published var recentDatabasePaths: [String] = []
    @Published var isShowingManageLibraries: Bool = false

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        objectWillChange.send()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        objectWillChange.send()
    }

    init() {
        database = try! Database()
        mediaStorage = try! MediaStorage()
        recentDatabasePaths = UserDefaults.standard.stringArray(forKey: "MarginGraph.RecentDatabases") ?? []
        reloadLibrary()
        // Launch should load catalog metadata, not probe every stored file path.
        // Inaccessible files are not missing files; sync can also delete them.

        if let backupArgIndex = CommandLine.arguments.firstIndex(of: "--open-backup"),
           backupArgIndex + 1 < CommandLine.arguments.count {
            let backupPath = CommandLine.arguments[backupArgIndex + 1]
            Task { @MainActor in
                await self.openMarginNoteBackup(at: URL(fileURLWithPath: backupPath))
            }
        } else if let importDocIndex = CommandLine.arguments.firstIndex(of: "--import-document"),
                  importDocIndex + 1 < CommandLine.arguments.count {
            let docPath = CommandLine.arguments[importDocIndex + 1]
            Task { @MainActor in
                await self.openOrImportFile(url: URL(fileURLWithPath: docPath), attachToTopic: false)
            }
        } else if let defaultLib = LibraryManager.shared.defaultLibrary, !defaultLib.isBuiltIn {
            let targetPath = FileManager.default.fileExists(atPath: defaultLib.path) ? defaultLib.path : (defaultLib.workingFolderPath ?? "")
            if !targetPath.isEmpty && FileManager.default.fileExists(atPath: targetPath) {
                Task { @MainActor in
                    await self.openMarginNoteBackup(at: URL(fileURLWithPath: targetPath))
                }
            }
        }

        let center = NotificationCenter.default
        let undoNotifications: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        for name in undoNotifications {
            center.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingPositions()
            }
        }
    }

    var selectedTopic: Topic? {
        topics.first(where: { $0.id == selectedTopicID })
    }

    var activePDFCards: [NoteCard] {
        if selectedTopicID != nil {
            // When inside a notebook / study workspace, cards shown on documents MUST strictly
            // belong to the active topic. Notes from other notebooks are isolated.
            return mindMapCards.filter { card in
                guard let bmd5 = card.bookMD5, let activeDoc = activeDocument else { return true }
                let b1 = bmd5.lowercased()
                let b2 = activeDoc.md5.lowercased()
                return b1 == b2 || b1.hasPrefix(b2) || b2.hasPrefix(b1)
            }
        }
        var cardMap = [UUID: NoteCard]()
        for card in mindMapCards {
            cardMap[card.id] = card
        }
        for card in documentCards {
            cardMap[card.id] = card
        }
        if let selID = selectedCardID, cardMap[selID] == nil,
           let card = (try? database.getCard(id: selID)) {
            cardMap[selID] = card
        }
        return Array(cardMap.values)
    }

    func autoImportLiveMarginNoteIfEmpty() {
        let existingTopics = (try? database.allTopics()) ?? []
        let totalCards = (try? database.totalCardCount()) ?? 0
        let needsImport = existingTopics.isEmpty || totalCards == 0
        guard needsImport else { return }

        let liveCandidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Library/Application Support/QReader.MarginNoteMac/MarginNotes.sqlite"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QReader.MarginStudyMac/MarginNotes.sqlite")
        ]

        for url in liveCandidates where FileManager.default.fileExists(atPath: url.path) {
            if let result = try? MarginNoteImporter(url: url).importInto(database) {
                print("Auto-imported live MarginNote 3 database: \(result.topics.count) topics, \(result.documents.count) docs, \(result.cards.count) cards")
                break
            }
        }
    }

    private struct LibraryCatalog: Sendable {
        let topics: [Topic]
        let documents: [Document]
        let folders: [DocumentFolder]
        let decks: [CardDeck]
        let deckCounts: [UUID: Int]
        let dueDeckCounts: [UUID: Int]
        let topicCounts: [UUID: Int]
        let dueTopicCounts: [UUID: Int]
        let deckReviews: [UUID: Date]
        let documentCounts: [String: Int]

        init(database: Database) {
            topics = (try? database.allTopics()) ?? []
            documents = (try? database.allDocuments()) ?? []
            folders = (try? database.allFolders()) ?? []
            decks = (try? database.allDecks()) ?? []
            deckCounts = (try? database.deckCardCounts()) ?? [:]
            dueDeckCounts = (try? database.dueDeckCardCounts()) ?? [:]
            let counts = try? database.cardCountsAndDueCountsByTopic()
            topicCounts = counts?.total ?? [:]
            dueTopicCounts = counts?.due ?? [:]
            deckReviews = (try? database.allDeckReviews()) ?? [:]
            documentCounts = (try? database.cardCountsByDocument()) ?? [:]
        }
    }

    func reloadLibrary() {
        updateLibrary(from: LibraryCatalog(database: database))
    }

    private func updateLibrary(from catalog: LibraryCatalog) {
        topics = catalog.topics
        documents = catalog.documents
        documentFolders = catalog.folders
        customDecks = catalog.decks
        deckCardCounts = catalog.deckCounts
        dueDeckCounts = catalog.dueDeckCounts
        let counts = catalog.topicCounts
        let dueCounts = catalog.dueTopicCounts
        let deckReviews = catalog.deckReviews
        let rawDocCounts = catalog.documentCounts
        var docCounts: [UUID: Int] = [:]
        for doc in documents {
            if let direct = rawDocCounts[doc.md5] {
                docCounts[doc.id] = direct
            } else {
                var found = 0
                for (k, v) in rawDocCounts {
                    if k.hasPrefix(doc.md5) || doc.md5.hasPrefix(k) {
                        found += v
                    }
                }
                docCounts[doc.id] = found
            }
        }
        documentCardCounts = docCounts

        var decks: [ReviewDeckItem] = []
        decks.reserveCapacity(customDecks.count + topics.count)

        // 1. Custom Card Decks (only show decks with at least 1 card)
        for deck in customDecks {
            let total = deckCardCounts[deck.id] ?? 0
            guard total > 0 else { continue }
            let due = dueDeckCounts[deck.id] ?? 0
            let lastReviewed = deckReviews[deck.id]
            decks.append(ReviewDeckItem(
                id: deck.id,
                title: deck.title,
                dueCount: due,
                totalCount: total,
                topicId: nil,
                deckId: deck.id,
                lastReviewed: lastReviewed
            ))
        }

        // 2. Topic Study Sets (only show decks with at least 1 card)
        let customDeckIDs = Set(customDecks.map(\.id))
        for topic in topics {
            guard !customDeckIDs.contains(topic.id) else { continue }
            let total = counts[topic.id] ?? 0
            guard total > 0 else { continue }
            let due = dueCounts[topic.id] ?? 0
            let lastReviewed = deckReviews[topic.id]
            decks.append(ReviewDeckItem(
                id: topic.id,
                title: topic.title,
                dueCount: due,
                totalCount: total,
                topicId: topic.id,
                lastReviewed: lastReviewed
            ))
        }

        cardCounts = counts
        reviewDecks = decks

        for doc in documents {
            if documentCurrentPage[doc.md5] == nil {
                documentCurrentPage[doc.md5] = doc.lastPageIndex
            }
            if documentPageOffsets[doc.md5] == nil {
                documentPageOffsets[doc.md5] = doc.lastPageOffsetY
            }
            if documentMindPan[doc.md5] == nil, let px = doc.mindPanX, let py = doc.mindPanY {
                documentMindPan[doc.md5] = CGPoint(x: px, y: py)
            }
            if documentMindZoom[doc.md5] == nil, let z = doc.mindZoomScale {
                documentMindZoom[doc.md5] = CGFloat(z)
            }
        }

        for topic in topics {
            if topicMindPan[topic.id] == nil, let px = topic.mindPanX, let py = topic.mindPanY {
                topicMindPan[topic.id] = CGPoint(x: px, y: py)
            }
            if topicMindZoom[topic.id] == nil, let z = topic.mindZoomScale {
                topicMindZoom[topic.id] = CGFloat(z)
            }
        }

        if isInStudyWorkspace {
            if selectedTopicID == nil || !topics.contains(where: { $0.id == selectedTopicID }) {
                selectedTopicID = topics.first?.id
            }
        }
    }

    func selectTopic(_ topic: Topic) {
        selectedTopicID = topic.id
        selectedCardID = nil
        activeToolbarOwner = .none
        jumpTarget = nil
        closeMindMapSearch()
        reloadStudySet()
    }

    func enterStudyWorkspace(topic: Topic) {
        flushPendingPositions()
        let now = Date()
        try? database.updateTopicUpdatedAt(id: topic.id, date: now)
        let associatedDocs = (try? database.documentsForTopic(id: topic.id)) ?? []
        for doc in associatedDocs {
            try? database.updateDocumentLastVisited(id: doc.id, date: now)
        }
        if associatedDocs.isEmpty {
            for bmd5 in topic.bookMD5List {
                try? database.updateDocumentLastVisited(md5: bmd5, date: now)
            }
        }
        reloadLibrary()

        selectTopic(topic)
        workspaceMode = .splitView
        isInStudyWorkspace = true
    }

    func exitStudyWorkspace() {
        flushPendingPositions()
        closeMindMapSearch()
        isInStudyWorkspace = false
    }

    func openDocumentInReader(document: Document) {
        flushPendingPositions()
        let now = Date()

        // Card ownership outranks title/attachment guesses; explicit removals persist.
        let matchingTopic = try? database.preferredTopic(for: document, topics: topics)
        if var matchingTopic {
            if !matchingTopic.bookMD5List.contains(document.md5) {
                try? database.addDocument(to: matchingTopic.id, md5: document.md5)
                matchingTopic.bookMD5List.append(document.md5)
            }
            if let index = topics.firstIndex(where: { $0.id == matchingTopic.id }) {
                topics[index] = matchingTopic
            }
            selectedTopicID = matchingTopic.id
            switchToDocument(document, clearSelection: false)
            reloadStudySet()
        } else {
            let newTopic = Topic(title: document.title, bookMD5List: [document.md5], createdAt: now, updatedAt: now)
            try? database.insertTopic(newTopic)
            topics.append(newTopic)
            selectedTopicID = newTopic.id
            switchToDocument(document, clearSelection: false)
            reloadStudySet()
        }
        workspaceMode = .splitView
        isInStudyWorkspace = true
    }

    func createTopic() {
        let newTopic = Topic(title: "New Notebook \(topics.count + 1)")
        try? database.insertTopic(newTopic)
        reloadLibrary()
        enterStudyWorkspace(topic: newTopic)
    }

    func deleteTopic(_ topic: Topic) {
        try? database.deleteTopic(id: topic.id)
        if selectedTopicID == topic.id {
            selectedTopicID = nil
        }
        reloadLibrary()
    }

    func renameTopic(_ topic: Topic, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? database.renameTopic(id: topic.id, newTitle: trimmed)
        reloadLibrary()
    }

    func renameDocument(_ document: Document, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? database.renameDocument(id: document.id, newTitle: trimmed)
        reloadLibrary()
    }

    func deleteDocument(_ document: Document) {
        handledHighlightImportMD5s.remove(document.md5)
        try? database.deleteDocument(id: document.id)
        reloadLibrary()
        reloadStudySet()
    }

    func createFolder(name: String, parentId: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = DocumentFolder(parentId: parentId, name: trimmed)
        try? database.insertFolder(folder)
        reloadLibrary()
    }

    func renameFolder(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? database.renameFolder(id: id, newName: trimmed)
        reloadLibrary()
    }

    func deleteFolder(id: UUID) {
        try? database.deleteFolder(id: id)
        reloadLibrary()
    }

    func moveFolder(_ folder: DocumentFolder, to parentID: UUID?) {
        guard folder.id != parentID else { return }
        try? database.updateFolderParent(folderID: folder.id, parentID: parentID)
        reloadLibrary()
    }

    func moveDocument(_ document: Document, to folderID: UUID?) {
        try? database.updateDocumentFolder(documentID: document.id, folderID: folderID)
        reloadLibrary()
    }

    func addDocumentsToStudy(documents selectedDocs: [Document], targetTopicID: UUID?, newTopicTitle: String?) {
        guard !selectedDocs.isEmpty else { return }

        let targetTopic: Topic
        if let targetTopicID, let existing = topics.first(where: { $0.id == targetTopicID }) {
            var updated = existing
            for doc in selectedDocs {
                if !updated.bookMD5List.contains(doc.md5) {
                    updated.bookMD5List.append(doc.md5)
                }
            }
            try? database.updateTopic(updated)
            targetTopic = updated
        } else {
            let title = (newTopicTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? newTopicTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
                : (selectedDocs.count == 1 ? selectedDocs[0].title : "Study Notebook \(topics.count + 1)")
            let newTopic = Topic(title: title, bookMD5List: selectedDocs.map(\.md5))
            try? database.insertTopic(newTopic)
            targetTopic = newTopic
        }

        reloadLibrary()
        enterStudyWorkspace(topic: targetTopic)

        if let firstDoc = selectedDocs.first {
            switchToDocument(firstDoc)
        }
    }

    private struct StudySetData: Sendable {
        var documents: [Document]
        let cards: [NoteCard]
        let links: [CardLink]
        let dueCardIDs: Set<UUID>

        init(database: Database, topicID: UUID, graph: (cards: [NoteCard], links: [CardLink])? = nil) {
            documents = (try? database.documentsForTopic(id: topicID)) ?? []
            cards = graph?.cards ?? (try? database.cardsForTopic(id: topicID)) ?? []
            links = graph?.links ?? (try? database.linksForTopic(id: topicID)) ?? []
            dueCardIDs = (try? database.dueCardIDsForTopic(id: topicID)) ?? []
        }
    }

    private func updateStudySet(from data: StudySetData) {
        var cards = NoteCard.filterMarginNoteDocumentRootCard(from: data.cards)
        var topicLinks = data.links
        if cards.count < data.cards.count {
            let removed = Set(data.cards.map(\.id)).subtracting(cards.map(\.id))
            topicLinks.removeAll { removed.contains($0.sourceCardId) || removed.contains($0.targetCardId) }
        }
        studyDocuments = data.documents
        if !cards.isEmpty {
            backfillHighlightTextsFromDocuments(cards: &cards, documents: studyDocuments.isEmpty ? documents : studyDocuments)
        }
        mindMapCards = cards
        links = topicLinks
        dueFlashcards = cards.filter { data.dueCardIDs.contains($0.id) }
    }

    func reloadStudySet() {
        guard let topicID = selectedTopicID else {
            studyDocuments = []
            mindMapCards = []
            links = []
            dueFlashcards = []
            return
        }
        let graph = try? database.notebookGraph(id: topicID)
        updateStudySet(from: StudySetData(database: database, topicID: topicID, graph: graph))

        if let activeDocument, studyDocuments.contains(where: { $0.md5 == activeDocument.md5 }) {
            reloadDocumentCards()
        } else if let lastMD5 = selectedTopic?.lastDocumentMD5, let lastDoc = studyDocuments.first(where: { $0.md5 == lastMD5 }) {
            switchToDocument(lastDoc)
        } else if let first = studyDocuments.first {
            switchToDocument(first)
        } else {
            activeDocument = nil
            manager = nil
            documentCards = []
        }
    }

    private func backfillHighlightTextsFromDocuments(cards: inout [NoteCard], documents: [Document]) {
        guard !documents.isEmpty else { return }
        var docCache: [String: PDFDocument] = [:]
        var updatedCards: [NoteCard] = []

        for i in 0..<cards.count {
            guard cards[i].highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cards[i].highlightRects.isEmpty else { continue }

            let cardMD5 = cards[i].bookMD5
            let matchingDoc = documents.first(where: {
                if let cardMD5 {
                    return $0.md5 == cardMD5 || cardMD5.hasPrefix($0.md5) || $0.md5.hasPrefix(cardMD5)
                }
                return true
            })
            guard let matchingDoc, FileManager.default.fileExists(atPath: matchingDoc.filePath) else { continue }

            let pdfDoc: PDFDocument
            if let cached = docCache[matchingDoc.md5] {
                pdfDoc = cached
            } else if let loaded = PDFDocument(url: URL(fileURLWithPath: matchingDoc.filePath)) {
                docCache[matchingDoc.md5] = loaded
                pdfDoc = loaded
            } else {
                continue
            }

            var pieces: [String] = []
            for r in cards[i].highlightRects {
                guard let page = pdfDoc.page(at: r.page) else { continue }
                let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                if let sel = page.selection(for: rect),
                   let str = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    pieces.append(str)
                }
            }
            let extracted = pieces.joined(separator: "\n")
            if !extracted.isEmpty {
                cards[i].highlightText = extracted
                updatedCards.append(cards[i])
            }
        }

        if !updatedCards.isEmpty {
            try? database.transaction {
                for card in updatedCards {
                    try? database.updateCard(card)
                }
            }
        }
    }

    func promptNotebookConflict(existing: Topic, imported: Topic) -> NotebookConflictResolution {
        let alert = NSAlert()
        alert.messageText = "Notebook Already Exists"
        alert.informativeText = "A notebook named \"\(existing.title)\" already exists. Would you like to merge the imported notes with the existing notebook, replace it completely, or cancel the import?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return .cancel
        }
    }

    func openDocumentPicker(attachToTopic: Bool = false) {
        guard !isImportingMarginNote else { return }
        let panel = NSOpenPanel()
        let extensions = [
            "mp4", "mov", "m4v", "mkv", "avi", "webm",
            "mp3", "m4a", "wav", "aac", "flac", "aiff", "caf",
            "pdf", "epub", "cbz", "cbr", "cbt", "fb2", "zfb2", "txt", "text", "md", "markdown", "rtf", "rtfd", "html", "htm", "xhtml", "webarchive",
            "mobi", "prc", "azw", "azw3", "kf8", "pdb",
            "docx", "doc", "odt",
            "chm", "djvu", "djv",
            "tex", "latex", "adoc", "asciidoc", "org", "rst",
            "marginpkg", "marginnotes", "sqlite"
        ]
        var types: [UTType] = [.pdf, .movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .epub, .plainText, .rtf, .rtfd, .html]
        for ext in extensions {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        openOrImportFiles(urls: panel.urls, attachToTopic: attachToTopic)
    }

    func openOrImportFiles(urls: [URL], attachToTopic: Bool = false) {
        Task {
            for url in urls {
                await openOrImportFile(url: url, attachToTopic: attachToTopic)
            }
        }
    }

    func openOrImportFile(url: URL, attachToTopic: Bool = false) async {
        guard !isImportingMarginNote else { return }
        var isDir: ObjCBool = false
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()

        if exists && isDir.boolValue {
            let sqliteCand = url.appendingPathComponent("MarginNotes.sqlite")
            if fileManager.fileExists(atPath: sqliteCand.path) || ext == "marginbackupall" || ext == "marginbackup" {
                await openMarginNoteBackup(at: url)
                return
            }
        }

        if ext == "marginbackupall" || ext == "marginbackup" {
            await openMarginNoteBackup(at: url)
        } else if ext == "marginpkg" || ext == "marginnotes" || ext == "sqlite" {
            let filename = url.lastPathComponent.lowercased()
            if filename == "marginnotes.sqlite" || filename.contains("backup") {
                await openMarginNoteBackup(at: url)
            } else {
                await importMarginNoteOrPackage(url: url)
            }
        } else {
            openDocument(url: url, attachToTopic: attachToTopic)
        }
    }

    func openMarginNoteBackupPicker(completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Open MarginNote Database or Backup"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true

        var types: [UTType] = [.folder, .package, .database]
        if let mnBackupAll = UTType("com.qreader.marginnote.marginbackupall") {
            types.append(mnBackupAll)
        }
        if let mnBackup = UTType("com.qreader.marginnote.marginbackup") {
            types.append(mnBackup)
        }
        if let mnPkg = UTType("com.qreader.marginnote.marginpkg") {
            types.append(mnPkg)
        }
        for ext in ["marginbackupall", "marginbackup", "marginpkg", "sqlite", "marginnotes"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, let selectedURL = panel.url {
            if let completion {
                completion(selectedURL)
            } else {
                Task { @MainActor in
                    await self.openMarginNoteBackup(at: selectedURL)
                }
            }
        }
    }

    func saveRecentDatabase(path: String) {
        var recents = UserDefaults.standard.stringArray(forKey: "MarginGraph.RecentDatabases") ?? []
        recents.removeAll(where: { $0 == path })
        recents.insert(path, at: 0)
        if recents.count > 10 {
            recents = Array(recents.prefix(10))
        }
        UserDefaults.standard.set(recents, forKey: "MarginGraph.RecentDatabases")
        recentDatabasePaths = recents
    }

    func openMarginNoteBackup(at url: URL) async {
        guard !isImportingMarginNote else { return }
        isOpeningDatabase = true
        databaseOpeningStatus = "Inspecting backup..."
        defer { isOpeningDatabase = false }

        flushPendingPositions()

        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else {
            databaseErrorMessage = "File or folder not found at \(url.path)"
            return
        }

        let backupDir: URL
        let sqliteURL: URL

        let companionURL: URL?
        if isDir.boolValue {
            // Check if this directory is actually a sidecar working folder with a companion .marginbackupall
            let companion1 = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".marginbackupall")
            let companion2 = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".marginpkg")
            let comp = fileManager.fileExists(atPath: companion1.path) ? companion1 : (fileManager.fileExists(atPath: companion2.path) ? companion2 : nil)
            companionURL = comp

            if let companion = comp {
                backupDir = companion
                let cand1 = companion.appendingPathComponent("MarginNotes.sqlite")
                let cand2 = companion.appendingPathComponent("MarginNotes.marginnotes")
                if fileManager.fileExists(atPath: cand1.path) {
                    sqliteURL = cand1
                } else if fileManager.fileExists(atPath: cand2.path) {
                    sqliteURL = cand2
                } else if let items = try? fileManager.contentsOfDirectory(at: companion, includingPropertiesForKeys: nil),
                          let found = items.first(where: {
                              let name = $0.lastPathComponent
                              return !name.hasPrefix(".") && ["sqlite", "marginnotes"].contains($0.pathExtension.lowercased())
                          }) {
                    sqliteURL = found
                } else {
                    sqliteURL = companion.appendingPathComponent("MarginNotes.sqlite")
                }
            } else {
                backupDir = url
                let cand1 = url.appendingPathComponent("MarginNotes.sqlite")
                let cand2 = url.appendingPathComponent("MarginNotes.marginnotes")
                if fileManager.fileExists(atPath: cand1.path) {
                    sqliteURL = cand1
                } else if fileManager.fileExists(atPath: cand2.path) {
                    sqliteURL = cand2
                } else if let items = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
                          let found = items.first(where: {
                              let name = $0.lastPathComponent
                              return !name.hasPrefix(".") && ["sqlite", "marginnotes"].contains($0.pathExtension.lowercased())
                          }) {
                    sqliteURL = found
                } else {
                    databaseErrorMessage = "No SQLite database found inside \(url.lastPathComponent)"
                    return
                }
            }
        } else {
            companionURL = nil
            if url.lastPathComponent.lowercased().contains("marginnotes") {
                backupDir = url.deletingLastPathComponent()
                sqliteURL = url
            } else if url.pathExtension.lowercased() == "sqlite" {
                var testDb: OpaquePointer?
                let uri = "file:\(url.path)?immutable=1"
                var isMN = false
                if sqlite3_open_v2(uri, &testDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let testDb {
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(testDb, "SELECT 1 FROM ZTOPIC LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
                        isMN = true
                    }
                    sqlite3_finalize(stmt)
                    sqlite3_close(testDb)
                }
                if !isMN {
                    do {
                        let newDb = try Database(url: url)
                        self.database = newDb
                        self.mediaStorage.clearFallbackDatabase()
                        // Working databases retain document paths into their source backup.
                        // Restore attachment lookup from those roots when opened directly.
                        let roots = Set(((try? newDb.allDocuments()) ?? []).compactMap { document -> URL? in
                            let source = URL(fileURLWithPath: document.filePath)
                            return source.pathComponents.indices.reversed().compactMap { index -> URL? in
                                let component = source.pathComponents[index]
                                guard ["marginbackupall", "marginbackup", "marginpkg"].contains((component as NSString).pathExtension.lowercased()) else { return nil }
                                return URL(fileURLWithPath: NSString.path(withComponents: Array(source.pathComponents[...index])))
                            }.first
                        })
                        self.mediaStorage.fallbackDirectories = roots.sorted { $0.path < $1.path }.map {
                            $0.appendingPathComponent("MarginNotes.sqlite.files")
                        }
                        self.mediaStorage.fallbackDatabaseURL = roots.sorted { $0.path < $1.path }.first?
                            .appendingPathComponent("MarginNotes.sqlite")
                        self.activeDatabaseName = url.lastPathComponent
                        self.activeDatabaseURL = url
                        self.externalLibraryDirectory = url.deletingLastPathComponent()
                        self.isExternalDatabase = true
                        saveRecentDatabase(path: url.path)
                        resetWorkspaceForNewDatabase()
                        reloadLibrary()
                        return
                    } catch {
                        databaseErrorMessage = "Failed to open SQLite database: \(error.localizedDescription)"
                        return
                    }
                }
                backupDir = url.deletingLastPathComponent()
                sqliteURL = url
            } else {
                backupDir = url.deletingLastPathComponent()
                sqliteURL = url
            }
        }

        let libManager = LibraryManager.shared
        let entry = libManager.addOrUpdateLibrary(path: backupDir.path)
        let alias = entry.alias

        // Resolve sidecar working folder next to backup file (named after alias or backup bundle)
        let sidecarFolderURL: URL
        if isDir.boolValue && url.pathExtension.isEmpty && companionURL != nil {
            sidecarFolderURL = url
        } else {
            sidecarFolderURL = LibraryManager.resolveSidecarFolderURL(for: backupDir, alias: alias)
        }
        try? fileManager.createDirectory(at: sidecarFolderURL, withIntermediateDirectories: true)

        let workingDbURL = sidecarFolderURL.appendingPathComponent("MarginGraph.sqlite")

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let extDatabasesDir = appSupport.appendingPathComponent("MarginGraph/ExternalDatabases", isDirectory: true)
        try? fileManager.createDirectory(at: extDatabasesDir, withIntermediateDirectories: true)

        let safeBaseName = backupDir.lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let cacheName = safeBaseName.isEmpty ? "backup_\(UUID().uuidString.prefix(8))" : safeBaseName
        let legacyCacheDbURL = extDatabasesDir.appendingPathComponent("\(cacheName).sqlite")

        let targetDbURL: URL
        if fileManager.fileExists(atPath: workingDbURL.path) || fileManager.isWritableFile(atPath: sidecarFolderURL.path) {
            targetDbURL = workingDbURL
            // If legacy cache exists but workingDbURL does not, migrate into sidecar folder
            if !fileManager.fileExists(atPath: workingDbURL.path) && fileManager.fileExists(atPath: legacyCacheDbURL.path) {
                if Database.isNetworkVolume(url: sidecarFolderURL) {
                    if let localDb = try? Database(url: legacyCacheDbURL) {
                        try? localDb.execute("PRAGMA wal_checkpoint(TRUNCATE);")
                        try? localDb.execute("PRAGMA journal_mode = DELETE;")
                    }
                }
                try? fileManager.copyItem(at: legacyCacheDbURL, to: workingDbURL)
            }
        } else {
            // Fallback to Application Support cache if sidecar parent is not writable
            targetDbURL = legacyCacheDbURL
        }

        let mediaDir = backupDir.appendingPathComponent("MarginNotes.sqlite.files")

        do {
            let newDb: Database
            var actualDbURL = targetDbURL
            if fileManager.fileExists(atPath: targetDbURL.path) {
                databaseOpeningStatus = "Opening cached database..."
                do {
                    newDb = try Database(url: targetDbURL)
                } catch {
                    // Fallback to local cache if opening sidecar on external/network volume fails
                    if targetDbURL != legacyCacheDbURL && fileManager.fileExists(atPath: legacyCacheDbURL.path) {
                        print("Warning: failed to open sidecar database at \(targetDbURL.path): \(error). Falling back to local cache.")
                        actualDbURL = legacyCacheDbURL
                        newDb = try Database(url: legacyCacheDbURL)
                    } else {
                        throw error
                    }
                }

                if fileManager.fileExists(atPath: mediaDir.path) {
                    self.mediaStorage.fallbackDirectories = [mediaDir]
                } else {
                    self.mediaStorage.fallbackDirectories.removeAll()
                }
                self.mediaStorage.fallbackDatabaseURL = sqliteURL

                self.database = newDb
                self.activeDatabaseName = entry.displayName
                self.activeDatabaseURL = backupDir
                self.externalLibraryDirectory = sidecarFolderURL
                self.isExternalDatabase = true
                libManager.updateWorkingFolderPath(id: entry.id, workingFolderPath: actualDbURL.deletingLastPathComponent().path)
                libManager.touchLastOpened(path: backupDir.path)
                saveRecentDatabase(path: backupDir.path)

                resetWorkspaceForNewDatabase()
                reloadLibrary()

                // Dismiss opening modal immediately so the UI is active and responsive without delay
                isOpeningDatabase = false

                // Asynchronously sync any new documents in the background without blocking the UI
                Task.detached(priority: .utility) { [weak self] in
                    try? newDb.syncAvailableDocuments(libraryRoot: backupDir)
                    await MainActor.run { [weak self] in
                        guard let self, self.activeDatabaseURL == backupDir else { return }
                        self.reloadLibrary()
                    }
                }
                return
            } else {
                databaseOpeningStatus = "Reading MarginNote database..."
                var createdDb: Database?
                var initError: Error?
                do {
                    createdDb = try await Task.detached(priority: .userInitiated) {
                        try Database(url: targetDbURL)
                    }.value
                } catch {
                    initError = error
                    if targetDbURL != legacyCacheDbURL && fileManager.fileExists(atPath: legacyCacheDbURL.path) {
                        print("Warning: failed to create sidecar database at \(targetDbURL.path): \(error). Falling back to local cache.")
                        actualDbURL = legacyCacheDbURL
                        createdDb = try? await Task.detached(priority: .userInitiated) {
                            try Database(url: legacyCacheDbURL)
                        }.value
                    }
                }
                guard let validDb = createdDb else {
                    throw initError ?? DatabaseError.open("Failed to initialize database")
                }
                newDb = validDb

                let importer = MarginNoteImporter(
                    url: sqliteURL,
                    documentsDestinationDirectory: backupDir,
                    copyDocuments: false,
                    copyMedia: false
                )
                databaseOpeningStatus = "Importing notebooks and documents in-place..."
                _ = try await Task.detached(priority: .userInitiated) {
                    try importer.importInto(newDb)
                }.value
                _ = try await Task.detached(priority: .userInitiated) {
                    try newDb.syncAvailableDocuments(libraryRoot: backupDir)
                }.value
            }

            if fileManager.fileExists(atPath: mediaDir.path) {
                self.mediaStorage.fallbackDirectories = [mediaDir]
            } else {
                self.mediaStorage.fallbackDirectories.removeAll()
            }
            self.mediaStorage.fallbackDatabaseURL = sqliteURL

            self.database = newDb
            self.activeDatabaseName = entry.displayName
            self.activeDatabaseURL = backupDir
            self.externalLibraryDirectory = sidecarFolderURL
            self.isExternalDatabase = true
            libManager.updateWorkingFolderPath(id: entry.id, workingFolderPath: actualDbURL.deletingLastPathComponent().path)
            libManager.touchLastOpened(path: backupDir.path)
            saveRecentDatabase(path: backupDir.path)

            resetWorkspaceForNewDatabase()
            reloadLibrary()
        } catch {
            databaseErrorMessage = "Failed to load backup: \(error.localizedDescription)"
            print("Error loading MarginNote backup: \(error)")
        }
    }

    func exportDocumentAsMarginPkg(document: Document) {
        let panel = NSSavePanel()
        panel.title = "Export to MarginNote Package"
        panel.prompt = "Export"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = dateFormatter.string(from: Date())
        panel.nameFieldStringValue = "\(MarginPackageExporter.sanitizeFilename(document.title))(\(timestamp)).marginpkg"
        if let type = UTType(filenameExtension: "marginpkg") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let database = self.database, mediaStorage = self.mediaStorage
        let hideNumbers = PDFPageNumberPreferences.isHidden(for: document.md5)
        runPackageExport(to: destinationURL) {
            try MarginPackageExporter.exportDocument(
                document: document, database: database, mediaStorage: mediaStorage,
                destinationURL: destinationURL, hidesPageNumbers: hideNumbers
            )
        }
    }

    func exportFolderAsMarginPkg(folder: DocumentFolder) {
        let panel = NSSavePanel()
        panel.title = "Export Folder to MarginNote Package"
        panel.prompt = "Export"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = dateFormatter.string(from: Date())
        panel.nameFieldStringValue = "\(MarginPackageExporter.sanitizeFilename(folder.name))(\(timestamp)).marginpkg"
        if let type = UTType(filenameExtension: "marginpkg") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let database = self.database, mediaStorage = self.mediaStorage
        let folders = documentFolders, documents = self.documents
        let hidden = Set(documents.filter { PDFPageNumberPreferences.isHidden(for: $0.md5) }.map(\.md5))
        runPackageExport(to: destinationURL) {
            try MarginPackageExporter.exportFolder(
                folder: folder, allFolders: folders, allDocuments: documents,
                database: database, mediaStorage: mediaStorage, destinationURL: destinationURL,
                hiddenPageNumberDocumentMD5s: hidden
            )
        }
    }

    private func runPackageExport(to destination: URL, operation: @escaping @Sendable () throws -> Void) {
        guard !isExportingDocument else { return }
        isExportingDocument = true
        Task {
            defer { isExportingDocument = false }
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func switchToDefaultDatabase() {
        flushPendingPositions()
        guard let defaultLib = LibraryManager.shared.defaultLibrary else {
            switchToBuiltInDatabase()
            return
        }
        if defaultLib.isBuiltIn {
            switchToBuiltInDatabase()
        } else {
            let currentPath = activeDatabaseURL?.path ?? ""
            if isExternalDatabase && LibraryManager.shared.isLibrary(entry: defaultLib, matchesPath: currentPath) {
                return
            }
            Task { @MainActor in
                await self.openMarginNoteBackup(at: URL(fileURLWithPath: defaultLib.path))
            }
        }
    }

    func switchToBuiltInDatabase() {
        guard isExternalDatabase, !isImportingMarginNote else { return }
        flushPendingPositions()
        do {
            let defaultDb = try Database()
            self.database = defaultDb
            self.mediaStorage.fallbackDirectories.removeAll()
            self.mediaStorage.clearFallbackDatabase()
            self.activeDatabaseName = "Default Library"
            self.activeDatabaseURL = nil
            self.externalLibraryDirectory = nil
            self.isExternalDatabase = false
            resetWorkspaceForNewDatabase()
            reloadLibrary()
        } catch {
            databaseErrorMessage = "Failed to switch to built-in database: \(error.localizedDescription)"
        }
    }

    private func resetWorkspaceForNewDatabase() {
        self.selectedTopicID = nil
        self.activeDocument = nil
        self.manager = nil
        self.selectedCardID = nil
        self.cardIDToCenter = nil
        self.mindMapCards.removeAll()
        self.documentCards.removeAll()
        self.links.removeAll()
        self.isInStudyWorkspace = false
        self.selectedMainTab = .document
        self.activeReviewCards.removeAll()
        self.activeReviewDocuments.removeAll()
        self.isReviewPresented = false
        self.documentCurrentPage.removeAll()
        self.documentPageOffsets.removeAll()
        self.documentMindPan.removeAll()
        self.documentMindZoom.removeAll()
        self.topicMindPan.removeAll()
        self.topicMindZoom.removeAll()
    }

    private struct ImportedWorkspace: Sendable {
        let topicID: UUID
        var studySet: StudySetData
        var document: Document?
        let bookmarks: Set<Int>
        let catalog: LibraryCatalog

        init?(result: MarginNoteImportResult, database: Database) throws {
            let importedDocument = result.documents.first { !$0.filePath.isEmpty }
            let matchingTopic = importedDocument.flatMap { document in
                result.topics.first { topic in
                    topic.bookMD5List.contains { Database.bookHashesMatch($0, document.md5) }
                }
            }
            guard let topic = matchingTopic ?? result.topics.first else { return nil }
            topicID = topic.id
            studySet = StudySetData(database: database, topicID: topic.id)
            document = studySet.documents.first { $0.id == importedDocument?.id }
                ?? studySet.documents.first { $0.md5 == topic.lastDocumentMD5 }
                ?? studySet.documents.first

            let visitedAt = Date()
            if var opened = document {
                try AppModel.saveDocumentVisit(opened, topicID: topicID, at: visitedAt, in: database)
                opened.lastVisited = visitedAt
                document = opened
                if let index = studySet.documents.firstIndex(where: { $0.id == opened.id }) {
                    studySet.documents[index] = opened
                }
                bookmarks = (try? database.getBookmarks(for: opened.md5)) ?? []
            } else {
                try database.updateTopicUpdatedAt(id: topicID, date: visitedAt)
                bookmarks = []
            }
            // Capture the catalog and workspace before SQLite releases its write
            // lock and SMB may invalidate the pages the transaction just touched.
            catalog = LibraryCatalog(database: database)
        }
    }

    func importMarginNoteOrPackage(url: URL) async {
        guard !isImportingMarginNote, !isOpeningDatabase else { return }
        flushPendingPositions()
        let database = self.database
        let destination = externalLibraryDirectory.map { _ in importedDocumentsDirectory }
        isImportingMarginNote = true
        defer { isImportingMarginNote = false }
        let prompt: @MainActor @Sendable (Topic, Topic) -> NotebookConflictResolution = { [weak self] existing, imported in
            self?.promptNotebookConflict(existing: existing, imported: imported) ?? .cancel
        }

        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                var workspace: ImportedWorkspace?
                _ = try MarginNoteImporter(url: url, documentsDestinationDirectory: destination)
                    .importInto(database, beforeCommit: { result in
                    workspace = try ImportedWorkspace(result: result, database: database)
                }) { existing, imported in
                    // The importer asks before its write transaction holds the database lock.
                    DispatchQueue.main.sync { prompt(existing, imported) }
                }
                return workspace.map { workspace in
                    (workspace, workspace.document.flatMap(Self.loadPDFManager))
                }
            }.value
            guard let (workspace, loadedPDF) = imported else { return }
            updateLibrary(from: workspace.catalog)
            selectedTopicID = workspace.topicID
            selectedCardID = nil
            jumpTarget = nil
            activeToolbarOwner = .none
            closeMindMapSearch()
            activeDocument = workspace.document
            manager = loadedPDF
            documentBookmarks = workspace.bookmarks
            updateStudySet(from: workspace.studySet)
            reloadDocumentCards()
            workspaceMode = .splitView
            isInStudyWorkspace = true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func openPDFPicker(attachToTopic: Bool = false) {
        openDocumentPicker(attachToTopic: attachToTopic)
    }

    private var importedDocumentsDirectory: URL {
        let libraryDirectory = externalLibraryDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MarginGraph", isDirectory: true)
        return libraryDirectory.appendingPathComponent("ImportedDocuments", isDirectory: true)
    }

    @discardableResult
    func openDocument(url: URL, attachToTopic: Bool = false) -> Document? {
        let importedURL: URL
        do {
            importedURL = try ManagedDocumentImport.copySource(url, into: importedDocumentsDirectory)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
        let url = importedURL
        let docType = MediaDocumentHelper.documentType(for: url)

        var loadedPDFManager: PDFDocumentManager? = nil
        var isNewDocument = false
        var document: Document
        if docType == "video" || docType == "audio" {
            let md5 = MediaDocumentHelper.computeFileMD5(url: url)
            var existing = try? database.getDocumentByMD5(md5: md5)
            existing?.filePath = url.path
            isNewDocument = (existing == nil)
            let duration = MediaDocumentHelper.mediaDuration(url: url)
            let title = url.deletingPathExtension().lastPathComponent
            document = existing ?? Document(
                id: Document.stableUUID(md5),
                title: title,
                filePath: url.path,
                md5: md5,
                totalPages: Int(duration.rounded()),
                lastVisited: Date(),
                documentType: docType
            )
        } else if let manager = try? PDFDocumentManager(url: url) {
            loadedPDFManager = manager
            var existing = try? database.getDocumentByMD5(md5: manager.md5)
            existing?.filePath = manager.url.path
            isNewDocument = (existing == nil)
            document = existing ?? Document(
                id: Document.stableUUID(manager.md5),
                title: manager.title,
                filePath: manager.url.path,
                md5: manager.md5,
                totalPages: manager.pageCount,
                lastVisited: Date(),
                documentType: docType
            )
        } else {
            return nil
        }

        do {
            try database.insertDocument(document)
            document = try database.getDocumentByPath(filePath: document.filePath) ?? document
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }

        if attachToTopic, let topicID = selectedTopicID {
            try? database.addDocument(to: topicID, md5: document.md5)
        }

        reloadLibrary()
        reloadStudySet()
        switchToDocument(document)

        if let pdfDoc = loadedPDFManager?.document {
            if isNewDocument && !handledHighlightImportMD5s.contains(document.md5) {
                handledHighlightImportMD5s.insert(document.md5)
                if PDFHighlightImporter.hasHighlights(in: pdfDoc) {
                    handlePDFHighlightImport(for: document, pdfDocument: pdfDoc, attachToTopic: attachToTopic)
                }
            }
        }
        return document
    }

    /// Handles detecting and importing PDF highlights as notebook cards, presenting the two sequential alerts requested.
    @MainActor
    func handlePDFHighlightImport(
        for document: Document,
        pdfDocument: PDFDocument,
        attachToTopic: Bool
    ) {
        let highlightCount = PDFHighlightImporter.countHighlights(in: pdfDocument)
        guard highlightCount > 0 else { return }

        // Alert 1: Ask whether to turn highlights into notebook cards
        let alert1 = NSAlert()
        alert1.messageText = "Import PDF Highlights as Cards?"
        alert1.informativeText = "Found \(highlightCount) highlighted note\(highlightCount == 1 ? "" : "s") in \"\(document.title)\". Would you like to turn these highlights into study notebook cards?"
        alert1.addButton(withTitle: "Turn into Cards")
        alert1.addButton(withTitle: "Skip")
        alert1.alertStyle = .informational

        let response1 = alert1.runModal()
        guard response1 == .alertFirstButtonReturn else {
            return
        }

        // Alert 2: Ask whether to merge consecutive notes
        let alert2 = NSAlert()
        alert2.messageText = "Merge Consecutive Notes?"
        alert2.informativeText = "Would you like to merge consecutive notes (two adjacent highlights with no text between them and sharing the same color) into one card?"
        alert2.addButton(withTitle: "Merge Consecutive Notes")
        alert2.addButton(withTitle: "Keep Separate Cards")
        alert2.addButton(withTitle: "Cancel")
        alert2.alertStyle = .informational

        let response2 = alert2.runModal()
        guard response2 != .alertThirdButtonReturn else {
            return
        }
        let shouldMerge = (response2 == .alertFirstButtonReturn)

        var singleNativeHighlight = true
        if shouldMerge {
            // Alert 3: Ask whether to merge into one native note (one highlighted area)
            let alert3 = NSAlert()
            alert3.messageText = "Merge into One Native Note?"
            alert3.informativeText = "Would you like to merge consecutive highlights into one native note (one highlighted area for the merged note, not several highlighted areas merged together into one note)?"
            alert3.addButton(withTitle: "One Native Note")
            alert3.addButton(withTitle: "Several Highlighted Areas")
            alert3.addButton(withTitle: "Cancel")
            alert3.alertStyle = .informational

            let response3 = alert3.runModal()
            guard response3 != .alertThirdButtonReturn else {
                return
            }
            singleNativeHighlight = (response3 == .alertFirstButtonReturn)
        }

        // Find or create matching topic
        let targetTopic: Topic
        if attachToTopic, let selectedTopicID, let existing = topics.first(where: { $0.id == selectedTopicID }) {
            targetTopic = existing
            if !targetTopic.bookMD5List.contains(document.md5) {
                try? database.addDocument(to: targetTopic.id, md5: document.md5)
            }
        } else if let matching = topics.first(where: { $0.bookMD5List.contains(document.md5) }) {
            let cleanDocTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTopicTitle = matching.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if matching.bookMD5List.count == 1 && !cleanDocTitle.isEmpty &&
                !cleanTopicTitle.localizedCaseInsensitiveContains(cleanDocTitle) &&
                !cleanDocTitle.localizedCaseInsensitiveContains(cleanTopicTitle) {
                try? database.renameTopic(id: matching.id, newTitle: cleanDocTitle)
                var updated = matching
                updated.title = cleanDocTitle
                targetTopic = updated
            } else {
                targetTopic = matching
            }
        } else if let matchingByTitle = topics.first(where: {
            let cleanTopicTitle = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDocTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let docFileName = URL(fileURLWithPath: document.filePath).deletingPathExtension().lastPathComponent
            return !cleanTopicTitle.isEmpty && (
                cleanTopicTitle.localizedCaseInsensitiveCompare(cleanDocTitle) == .orderedSame ||
                cleanTopicTitle.localizedCaseInsensitiveCompare(docFileName) == .orderedSame
            )
        }) {
            if !matchingByTitle.bookMD5List.contains(document.md5) {
                try? database.addDocument(to: matchingByTitle.id, md5: document.md5)
            }
            targetTopic = matchingByTitle
        } else {
            let now = Date()
            let title = !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? document.title.trimmingCharacters(in: .whitespacesAndNewlines)
                : URL(fileURLWithPath: document.filePath).deletingPathExtension().lastPathComponent
            let newTopic = Topic(title: title, bookMD5List: [document.md5], createdAt: now, updatedAt: now)
            try? database.insertTopic(newTopic)
            targetTopic = newTopic
        }

        do {
            var workingDocument = document
            let copyURL = try ManagedDocumentImport.copySource(URL(fileURLWithPath: document.filePath), into: importedDocumentsDirectory)
            workingDocument.filePath = copyURL.path
            // Reload the copy so annotation removal cannot mutate the source PDF object.
            guard let workingPDF = PDFDocument(url: copyURL) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try database.insertDocument(workingDocument)
            _ = try PDFHighlightImporter.importHighlights(
                from: workingPDF,
                for: workingDocument,
                topicId: targetTopic.id,
                shouldMerge: shouldMerge,
                singleNativeHighlight: singleNativeHighlight,
                database: database
            )
            reloadLibrary()
            reloadStudySet()

            // Open document in reader/study workspace so imported cards are immediately visible
            openDocumentInReader(document: workingDocument)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Manually triggers highlight import for a document from context menus or toolbar options.
    @MainActor
    func importPDFHighlightsManually(for document: Document) {
        guard let pdfDoc = PDFDocument(url: URL(fileURLWithPath: document.filePath)) else {
            let alert = NSAlert()
            alert.messageText = "Unable to Open PDF"
            alert.informativeText = "Could not load the PDF document from: \(document.filePath)"
            alert.runModal()
            return
        }
        let count = PDFHighlightImporter.countHighlights(in: pdfDoc)
        if count == 0 {
            let alert = NSAlert()
            alert.messageText = "No Highlights Found"
            alert.informativeText = "No highlight annotations or notes were found in \"\(document.title)\"."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        handlePDFHighlightImport(for: document, pdfDocument: pdfDoc, attachToTopic: false)
    }

    func openPDF(url: URL, attachToTopic: Bool = false) {
        openDocument(url: url, attachToTopic: attachToTopic)
    }

    func chooseReplacementPDF() {
        guard let document = activeDocument, document.documentType == "pdf",
              !isReplacingPDF, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let sourceDatabase = database
        let panel = NSOpenPanel()
        panel.title = "Replace PDF"
        panel.message = "Choose a PDF with the same pages in the same order so your notes and highlights stay aligned."
        panel.prompt = "Replace PDF"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let source = panel.url, let self,
                  self.database === sourceDatabase, self.activeDocument?.id == document.id else { return }
            Task { await self.replacePDF(document, with: source, in: sourceDatabase, window: window) }
        }
    }

    private func replacePDF(_ document: Document, with source: URL, in database: Database, window: NSWindow) async {
        guard !isReplacingPDF else { return }
        isReplacingPDF = true
        defer { isReplacingPDF = false }
        let destination = importedDocumentsDirectory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PDFDocumentReplacement.replace(document, with: source, in: database, managedDirectory: destination)
            }.value
            guard self.database === database else { return }
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index].filePath = result.document.filePath
                documents[index].totalPages = result.document.totalPages
            }
            if let index = studyDocuments.firstIndex(where: { $0.id == document.id }) {
                studyDocuments[index].filePath = result.document.filePath
                studyDocuments[index].totalPages = result.document.totalPages
            }
            if activeDocument?.id == document.id {
                activeDocument?.filePath = result.document.filePath
                activeDocument?.totalPages = result.document.totalPages
                manager = result.manager
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to Replace PDF"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    func switchToDocument(_ document: Document, clearSelection: Bool = true) {
        flushPendingPositions()
        if clearSelection && activeDocument?.id != document.id {
            selectedCardID = nil
            jumpTarget = nil
        }
        let docType = document.documentType.isEmpty ? MediaDocumentHelper.documentType(for: URL(fileURLWithPath: document.filePath)) : document.documentType
        if docType == "video" || docType == "audio" {
            activeDocument = document
            manager = nil
            recordDocumentVisit(document)
            loadBookmarks()
            reloadDocumentCards()
            return
        }
        guard let loaded = Self.loadPDFManager(for: document) else { return }
        activeDocument = document
        manager = loaded
        recordDocumentVisit(document)
        loadBookmarks()
        reloadDocumentCards()
    }

    private nonisolated static func loadPDFManager(for document: Document) -> PDFDocumentManager? {
        let url = URL(fileURLWithPath: document.filePath)
        let type = document.documentType.isEmpty ? MediaDocumentHelper.documentType(for: url) : document.documentType
        guard type != "video", type != "audio" else { return nil }
        return try? PDFDocumentManager(url: url, md5: document.md5)
    }

    private nonisolated static func saveDocumentVisit(_ document: Document, topicID: UUID?, at date: Date, in database: Database) throws {
        try database.updateDocumentLastVisited(id: document.id, date: date)
        if let topicID {
            try database.updateTopicUpdatedAt(id: topicID, date: date)
            try database.updateTopicLastDocument(id: topicID, md5: document.md5)
        }
    }

    // Opening a document changes recency, not library membership or review counts.
    // Keep the loaded library snapshot current without scanning the network database.
    private func recordDocumentVisit(_ document: Document) {
        let now = Date()
        try? database.transaction {
            try Self.saveDocumentVisit(document, topicID: selectedTopicID, at: now, in: database)
        }
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index].lastVisited = now
        }
        if let index = studyDocuments.firstIndex(where: { $0.id == document.id }) {
            studyDocuments[index].lastVisited = now
        }
        activeDocument?.lastVisited = now
        if let index = topics.firstIndex(where: { $0.id == selectedTopicID }) {
            topics[index].updatedAt = now
            topics[index].lastDocumentMD5 = document.md5
        }
    }

    func updateTypography(options: TypographyOptions) {
        guard let doc = activeDocument else { return }
        TypographyPreferences.shared.setOptions(options, forDocumentMD5: doc.md5)

        var sourceURL: URL? = nil
        let directURL = URL(fileURLWithPath: doc.filePath)
        if MediaDocumentHelper.isEBook(url: directURL) {
            sourceURL = directURL
        } else if let sidecarSource = MediaDocumentHelper.resolveSourceURL(for: directURL) {
            sourceURL = sidecarSource
        } else if let orig = manager?.originalURL {
            sourceURL = orig
        }

        if sourceURL == nil {
            if let match = try? database.allDocuments().first(where: { $0.md5 == doc.md5 && MediaDocumentHelper.isEBook(url: URL(fileURLWithPath: $0.filePath)) }) {
                sourceURL = URL(fileURLWithPath: match.filePath)
            }
        }

        guard let source = sourceURL else { return }

        let currentIdx = documentCurrentPage[doc.md5] ?? doc.lastPageIndex
        let oldTotal = max(1, manager?.pageCount ?? doc.totalPages)
        let progress = Double(currentIdx) / Double(oldTotal)

        do {
            let converted = try EBookConverter.ensureConvertedPDF(for: source, options: options)
            guard let newDoc = PDFDocument(url: converted.pdfURL) else { return }
            let newTotal = newDoc.pageCount
            let newPage = min(max(0, Int(round(progress * Double(newTotal)))), newTotal - 1)

            let newManager = try PDFDocumentManager(url: source, md5: doc.md5, typographyOptions: options)
            self.manager = newManager
            self.documentCurrentPage[doc.md5] = newPage
            self.activeDocument?.totalPages = newTotal
            self.activeDocument?.lastPageIndex = newPage
            try? database.updateDocumentPages(id: doc.id, pages: newTotal)
            try? database.updateDocumentPosition(id: doc.id, pageIndex: newPage, pageOffsetY: 0.0)
            self.reloadDocumentCards()
        } catch {
            print("Failed to re-convert with typography options: \(error)")
        }
    }

    func createVideoExcerptCard(startTime: Double, endTime: Double, title: String) {
        guard let activeDocument, let topicID = selectedTopicID else { return }
        let cardID = UUID()

        // Generate poster frame
        var posterHash: String? = nil
        let videoURL = URL(fileURLWithPath: activeDocument.filePath)
        if let hash = try? mediaStorage.generateVideoPosterFrame(url: videoURL, timestampSeconds: startTime) {
            posterHash = hash
        }

        // Layout position adjacent to existing cards
        let lastPos = mindMapCards.last?.mindPos ?? CGPoint(x: 100, y: 100)
        let lastH = mindMapCards.last.map { TreeLayout.estimatedCardHeight(for: $0, width: 220) } ?? 100.0
        let mindPos = CGPoint(x: lastPos.x, y: lastPos.y + lastH + 56.0)

        // Choose next distinct color index so notes are color-coded on the timeline
        let nextColor = (mindMapCards.count) % 6

        let card = NoteCard(
            id: cardID,
            topicId: topicID,
            bookMD5: activeDocument.md5,
            title: title,
            highlightText: "",
            notesText: "",
            mindPos: mindPos,
            startPage: 0,
            endPage: 0,
            startPos: nil,
            endPos: nil,
            colorIndex: nextColor,
            highlightPicHash: posterHash,
            mediaType: activeDocument.documentType == "audio" ? "audio" : "video",
            videoStartTime: startTime,
            videoEndTime: endTime,
            createdAt: Date(),
            updatedAt: Date()
        )

        try? database.insertCard(card)
        reloadStudySet()
        selectedCardID = cardID
        objectWillChange.send()
    }

    func loadBookmarks() {
        guard let md5 = activeDocument?.md5 else {
            documentBookmarks = []
            return
        }
        documentBookmarks = (try? database.getBookmarks(for: md5)) ?? []
    }

    func toggleBookmark(pageIndex: Int, isBookmarked: Bool) {
        guard let md5 = activeDocument?.md5 else { return }
        try? database.setBookmark(md5: md5, pageIndex: pageIndex, isBookmarked: isBookmarked)
        if isBookmarked {
            documentBookmarks.insert(pageIndex)
        } else {
            documentBookmarks.remove(pageIndex)
        }
        objectWillChange.send()
    }

    func addCardLink(from sourceID: UUID, to targetID: UUID, label: String = "") {
        guard let topicID = selectedTopicID else { return }
        let link = CardLink(topicId: topicID, sourceCardId: sourceID, targetCardId: targetID, label: label)
        try? database.insertLink(link)
        links = (try? database.linksForTopic(id: topicID)) ?? []
        objectWillChange.send()
    }

    func mergeCards(sourceID: UUID, into targetID: UUID) {
        guard let source = try? database.getCard(id: sourceID),
              let target = try? database.getCard(id: targetID) else { return }
        var merged = target
        if !source.highlightText.isEmpty {
            if merged.highlightText.isEmpty {
                merged.highlightText = source.highlightText
            } else {
                merged.highlightText += "\n\n" + source.highlightText
            }
        }
        if !source.notesText.isEmpty {
            if merged.notesText.isEmpty {
                merged.notesText = source.notesText
            } else {
                merged.notesText += "\n" + source.notesText
            }
        }
        for seg in source.effectiveSegments {
            if !merged.excerptSegments.contains(where: { $0.id == seg.id }) {
                merged.excerptSegments.append(seg)
            }
        }
        for emp in source.emphasisList {
            if !merged.emphasisList.contains(emp) {
                merged.emphasisList.append(emp)
            }
        }
        for r in source.emphasisRects {
            merged.emphasisRects.append(r)
        }
        merged.updatedAt = Date()
        registerCardUndo(oldCard: target, newCard: merged, actionName: "Merge Cards")
        try? database.updateCard(merged)
        try? database.deleteCard(id: sourceID)
        reloadStudySet()
        selectedCardID = targetID
        objectWillChange.send()
    }

    func addComment(to cardID: UUID, comment: String) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var card = oldCard
        if card.notesText.isEmpty {
            card.notesText = trimmed
        } else {
            card.notesText += "\n" + trimmed
        }
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Add Comment")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        objectWillChange.send()
    }

    func attachExistingDocument(_ document: Document) {
        guard let topicID = selectedTopicID else { return }
        try? database.addDocument(to: topicID, md5: document.md5)
        reloadLibrary()
        reloadStudySet()
        switchToDocument(document)
    }

    func detachDocument(_ document: Document) {
        guard let topicID = selectedTopicID else { return }
        try? database.removeDocument(from: topicID, md5: document.md5)
        reloadLibrary()
        reloadStudySet()
    }

    func createExcerpt(_ excerpt: PDFExcerpt, colorIndex: Int = 0) {
        let topic = ensureTopic()
        let coordinator = ExcerptCoordinator(database: database, mediaStorage: mediaStorage)
        guard let card = try? coordinator.createCard(from: excerpt, topicId: topic.id, colorIndex: colorIndex) else { return }
        selectedCardID = card.id
        activeToolbarOwner = .pdf
        reloadStudySet()
        navigateToCard(card)
    }

    func select(card: NoteCard) {
        print("[App] select card: id=\(card.id) title='\(card.title)' page=\(card.startPage ?? -1)")
        selectedCardID = card.id
        activeToolbarOwner = .mindMap
        navigateToCard(card)
    }

    func select(cardID: UUID) {
        if let card = mindMapCards.first(where: { $0.id == cardID })
            ?? documentCards.first(where: { $0.id == cardID })
            ?? (try? database.getCard(id: cardID)) {
            select(card: card)
        }
    }

    func selectCardFromPDF(cardID: UUID?) {
        guard let cardID else {
            Swift.print("[App] selectCardFromPDF: deselected")
            selectedCardID = nil
            activeToolbarOwner = .none
            jumpTarget = nil
            return
        }
        if let card = mindMapCards.first(where: { $0.id == cardID })
            ?? documentCards.first(where: { $0.id == cardID })
            ?? (try? database.getCard(id: cardID)) {
            Swift.print("[App] selectCardFromPDF: id=\(card.id) title='\(card.title)' page=\(card.startPage ?? -1)")
            selectedCardID = card.id
            activeToolbarOwner = .pdf
        }
    }

    private var cleaningPageNumberDocuments = Set<String>()

    func cleanExistingNotePageNumbers() {
        guard let manager, cleaningPageNumberDocuments.insert(manager.md5).inserted else { return }
        let md5 = manager.md5, url = manager.url, database = self.database
        Task {
            defer { cleaningPageNumberDocuments.remove(md5) }
            do {
                let changes = try await Task.detached(priority: .userInitiated) {
                    guard let pdf = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
                    let cleaner = PDFNotePageNumberCleaner(document: pdf)
                    return try database.cardsForDocument(md5: md5).compactMap { old -> (NoteCard, NoteCard)? in
                        let new = cleaner.clean(old)
                        return old == new ? nil : (old, new)
                    }
                }.value
                guard self.database === database, PDFPageNumberPreferences.isHidden(for: md5) else { return }
                // Do not overwrite notes edited while the PDF was being scanned.
                let current = try changes.filter { try database.getCard(id: $0.0.id) == $0.0 }
                try applyPageNumberCleanup(current.map { $0.1 }, opposite: current.map { $0.0 })
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Clean Existing Notes"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func applyPageNumberCleanup(_ cards: [NoteCard], opposite: [NoteCard]) throws {
        guard !cards.isEmpty else { return }
        try database.transaction {
            for var card in cards {
                card.updatedAt = Date()
                try database.updateCard(card)
                PDFHighlightResolver.invalidateLineRectsCache(for: card.id)
            }
        }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                do { try target.applyPageNumberCleanup(opposite, opposite: cards) }
                catch {
                    let alert = NSAlert(); alert.messageText = "Could Not Restore Notes"
                    alert.informativeText = error.localizedDescription; alert.runModal()
                }
            }
        }
        undoManager.setActionName("Remove Page Numbers from Notes")
        reloadStudySet()
        objectWillChange.send()
    }

    private func registerCardUndo(oldCard: NoteCard, newCard: NoteCard, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreCard(cardToRestore: oldCard, oppositeCard: newCard, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        objectWillChange.send()
    }

    private func restoreCard(cardToRestore: NoteCard, oppositeCard: NoteCard, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreCard(cardToRestore: oppositeCard, oppositeCard: cardToRestore, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        try? database.updateCard(cardToRestore)
        reloadStudySet()
        selectedCardID = cardToRestore.id
        activeToolbarOwner = .mindMap
        navigateToCard(cardToRestore)
        objectWillChange.send()
    }

    private func restoreDeletedCard(_ card: NoteCard) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.delete(cardID: card.id)
            }
        }
        undoManager.setActionName("Delete Note")
        try? database.insertCard(card)
        reloadStudySet()
        selectedCardID = card.id
        activeToolbarOwner = .mindMap
        navigateToCard(card)
        objectWillChange.send()
    }

    private func registerBatchMoveUndo(oldPositions: [(id: UUID, position: CGPoint)], newPositions: [(id: UUID, position: CGPoint)]) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreBatchMove(positionsToRestore: oldPositions, oppositePositions: newPositions)
            }
        }
        undoManager.setActionName("Move Notes")
        objectWillChange.send()
    }

    private func restoreBatchMove(positionsToRestore: [(id: UUID, position: CGPoint)], oppositePositions: [(id: UUID, position: CGPoint)]) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreBatchMove(positionsToRestore: oppositePositions, oppositePositions: positionsToRestore)
            }
        }
        undoManager.setActionName("Move Notes")
        try? database.updateCardPositions(positionsToRestore)
        reloadStudySet()
        objectWillChange.send()
    }

    func updateHighlight(
        cardID: UUID,
        segmentID: UUID?,
        newText: String,
        rects: [HighlightRect],
        startPos: CGPoint,
        endPos: CGPoint
    ) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        let normalized = PDFHighlightResolver.normalizeExcerptParagraphs(newText)
        if !card.excerptSegments.isEmpty || segmentID != nil {
            var segments = card.effectiveSegments
            if let segmentID, let idx = segments.firstIndex(where: { $0.id == segmentID }) {
                segments[idx].text = normalized
                segments[idx].rects = rects
            } else if let firstIdx = segments.indices.first {
                segments[firstIdx].text = normalized
                segments[firstIdx].rects = rects
            }
            card.excerptSegments = segments
            card.highlightText = segments.map(\.text).joined(separator: "\n\n")
            card.highlightRects = PDFHighlightResolver.deduplicate(segments.flatMap(\.rects))
        } else {
            card.highlightText = normalized
            card.highlightRects = rects
        }
        card.startPage = rects.first?.page ?? card.startPage
        card.endPage = rects.last?.page ?? card.endPage
        card.startPos = startPos
        card.endPos = endPos
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Update Highlight")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] updateHighlight completed cardID=\(cardID) segmentID=\(String(describing: segmentID)) newTitle='\(card.title.prefix(30))...' newTextLength=\(card.highlightText.count) rects=\(rects.count)")
    }

    func setCardTitleFromSelection(cardID: UUID, text: String) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        card.title = text
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Set Card Title")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] setCardTitleFromSelection cardID=\(cardID) newTitle='\(text)'")
    }

    func addCommentFromSelection(cardID: UUID, text: String) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        if card.notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            card.notesText = text
        } else {
            card.notesText = card.notesText + "\n\n" + text
        }
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Add Comment")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] addCommentFromSelection cardID=\(cardID) appendedText='\(text)'")
    }

    func mergeSelectionIntoCard(cardID: UUID, text: String, rects: [HighlightRect]) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        let normalized = PDFHighlightResolver.normalizeExcerptParagraphs(text)
        var segments = card.effectiveSegments
        if segments.isEmpty {
            if !card.highlightText.isEmpty || !card.highlightRects.isEmpty {
                segments.append(ExcerptSegment(id: UUID(), text: card.highlightText, rects: card.highlightRects))
            }
        }
        let newSegment = ExcerptSegment(id: UUID(), text: normalized, rects: rects)
        segments.append(newSegment)
        card.excerptSegments = segments
        card.highlightText = segments.map(\.text).joined(separator: "\n\n")
        let combinedRects = segments.flatMap(\.rects)
        card.highlightRects = PDFHighlightResolver.deduplicate(combinedRects)
        let sortedPages = card.highlightRects.map { $0.page }.sorted()
        if let minP = sortedPages.first { card.startPage = minP }
        if let maxP = sortedPages.last { card.endPage = maxP }
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Merge Highlight")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] mergeSelectionIntoCard cardID=\(cardID) totalSegments=\(card.excerptSegments.count) totalRects=\(card.highlightRects.count)")
    }

    func deleteSegment(cardID: UUID, segmentID: UUID) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        var segments = card.effectiveSegments
        let removedSegment = segments.first(where: { $0.id == segmentID })
        segments.removeAll(where: { $0.id == segmentID })
        if segments.isEmpty {
            delete(cardID: cardID)
            return
        }
        if let removed = removedSegment, let mgr = self.manager {
            let dummyCard = NoteCard(
                id: UUID(),
                topicId: card.topicId,
                highlightText: removed.text,
                startPage: removed.rects.first?.page,
                highlightRects: removed.rects
            )
            removeOriginalAnnotations(for: dummyCard, in: mgr.document, fileURL: mgr.url, bookMD5: mgr.md5)
        }
        card.excerptSegments = segments
        card.highlightText = segments.map(\.text).joined(separator: "\n\n")
        card.highlightRects = PDFHighlightResolver.deduplicate(segments.flatMap(\.rects))
        let sortedPages = card.highlightRects.map { $0.page }.sorted()
        card.startPage = sortedPages.first
        card.endPage = sortedPages.last
        let remainingRects = card.highlightRects
        card.emphasisRects.removeAll { emp in
            !remainingRects.contains { r in
                r.page == emp.page && CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: -4, dy: -4).intersects(CGRect(x: emp.x, y: emp.y, width: emp.width, height: emp.height))
            }
        }
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Delete Excerpt Segment")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] deleteSegment cardID=\(cardID) segmentID=\(segmentID) remainingSegments=\(card.excerptSegments.count)")
    }

    func emphasizeTextInCard(cardID: UUID, text: String, rects: [HighlightRect] = []) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if !card.emphasisList.contains(clean) {
            card.emphasisList.append(clean)
        }
        var resolvedRects = rects
        if resolvedRects.isEmpty, let path = activeDocument?.filePath, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            resolvedRects = PDFHighlightResolver.lineRects(forPhrase: clean, in: card, in: doc)
        }
        for r in resolvedRects {
            if !card.emphasisRects.contains(where: { $0.page == r.page && abs($0.y - r.y) < 1.0 && abs($0.x - r.x) < 2.0 && abs($0.width - r.width) < 2.0 }) {
                card.emphasisRects.append(r)
            }
        }
        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Emphasize Text")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] emphasizeTextInCard cardID=\(cardID) emphasisList=\(card.emphasisList) emphasisRects=\(card.emphasisRects.count)")
    }

    func deleteEmphasisInCard(cardID: UUID, text: String, rects: [HighlightRect] = []) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        var card = oldCard
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        card.emphasisList.removeAll { emp in
            emp == clean ||
            emp.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty } ==
            clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        }

        let rectsToRemove = rects
        if let path = activeDocument?.filePath, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            var newEmpRects: [HighlightRect] = []
            for phrase in card.emphasisList {
                let pRects = PDFHighlightResolver.lineRects(forPhrase: phrase, in: card, in: doc)
                for r in pRects {
                    if !newEmpRects.contains(where: { $0.page == r.page && abs($0.y - r.y) < 1.0 && abs($0.x - r.x) < 2.0 && abs($0.width - r.width) < 2.0 }) {
                        newEmpRects.append(r)
                    }
                }
            }
            card.emphasisRects = newEmpRects
        } else if !rectsToRemove.isEmpty {
            card.emphasisRects.removeAll { emp in
                rectsToRemove.contains { r in
                    r.page == emp.page &&
                    abs(r.y - emp.y) < 2.0 &&
                    abs(r.x - emp.x) < 4.0
                }
            }
        }

        card.updatedAt = Date()
        registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Delete Emphasis")
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = cardID
        activeToolbarOwner = .pdf
        objectWillChange.send()
        Swift.print("[App] deleteEmphasisInCard cardID=\(cardID) text=\(text) remainingEmphasis=\(card.emphasisList)")
    }

    func unfoldAncestors(of cardID: UUID) {
        var current = mindMapCards.first(where: { $0.id == cardID })
            ?? (try? database.getCard(id: cardID))
        var visited = Set<UUID>()
        while let parentID = current?.groupNoteId, !visited.contains(parentID) {
            visited.insert(parentID)
            if let parent = mindMapCards.first(where: { $0.id == parentID }) ?? (try? database.getCard(id: parentID)) {
                if parent.isFolded {
                    toggleFold(cardID: parent.id, folded: false)
                }
                current = parent
            } else {
                break
            }
        }
    }

    func jumpToPDFFromReview(card: NoteCard) {
        isReviewPresented = false
        isInStudyWorkspace = true

        if workspaceMode == .mindMapOnly {
            workspaceMode = .splitView
        }

        if selectedTopicID != card.topicId {
            if let topic = topics.first(where: { $0.id == card.topicId }) ?? (try? database.getTopic(id: card.topicId)) {
                selectTopic(topic)
            }
        }

        if let md5 = card.bookMD5 {
            let doc = studyDocuments.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) })
                ?? documents.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) })
                ?? (try? database.document(byMD5: md5))
            if let doc, activeDocument?.md5 != doc.md5 {
                switchToDocument(doc, clearSelection: false)
            }
        }

        unfoldAncestors(of: card.id)

        selectedCardID = card.id
        activeToolbarOwner = .pdf
        cardIDToCenter = card.id
        navigateToCard(card)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedCardID = card.id
            self.activeToolbarOwner = .pdf
            self.cardIDToCenter = card.id
            self.navigateToCard(card)
        }
    }

    func navigateToCard(_ card: NoteCard) {
        if let md5 = card.bookMD5,
           let document = studyDocuments.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) }) ?? documents.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) }) {
            if !studyDocuments.contains(where: { $0.id == document.id }), let topicID = selectedTopicID {
                try? database.addDocument(to: topicID, md5: document.md5)
                reloadStudySet()
            }
            if activeDocument?.md5 != document.md5 {
                switchToDocument(document, clearSelection: false)
            }
        }

        selectedCardID = card.id

        if card.videoStartTime != nil {
            return
        }

        let allRects = !card.effectiveSegments.flatMap(\.rects).isEmpty
            ? card.effectiveSegments.flatMap(\.rects)
            : card.highlightRects

        let targetPage: Int
        if let sp = card.startPage {
            targetPage = sp
        } else if let hp = allRects.first?.page {
            targetPage = hp
        } else {
            return
        }

        let bounds: CGRect
        let pageLines = allRects.filter { $0.page == targetPage }
        if let first = pageLines.first {
            bounds = pageLines.dropFirst().reduce(
                CGRect(x: first.x, y: first.y, width: first.width, height: first.height)
            ) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        } else if let firstLine = allRects.first {
            bounds = CGRect(x: firstLine.x, y: firstLine.y, width: firstLine.width, height: firstLine.height)
        } else if let start = card.startPos, let end = card.endPos {
            bounds = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        } else {
            bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        jumpTarget = PDFJumpTarget(pageIndex: targetPage, bounds: bounds)
    }

    func deselect() {
        print("[App] deselect called")
        selectedCardID = nil
        activeToolbarOwner = .none
        jumpTarget = nil
    }

    func move(cardID: UUID, to position: CGPoint) {
        if var card = try? database.getCard(id: cardID) {
            let oldCard = card
            card.mindPos = position
            registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Move Card")
        }
        try? database.moveCard(id: cardID, to: position)
        reloadStudySet()
        objectWillChange.send()
    }

    func moveCardsBatch(_ updates: [(id: UUID, position: CGPoint)]) {
        let currentLayout = TreeLayout.layout(cards: mindMapCards)
        var oldPositions: [(id: UUID, position: CGPoint)] = []
        for u in updates {
            if let card = try? database.getCard(id: u.id) {
                let pos = card.mindPos ?? currentLayout.frames[card.id]?.origin ?? CGPoint(x: 40, y: 40)
                oldPositions.append((id: u.id, position: pos))
            }
        }

        let didChange = updates.contains { u in
            guard let old = oldPositions.first(where: { $0.id == u.id }) else { return false }
            return abs(old.position.x - u.position.x) > 0.5 || abs(old.position.y - u.position.y) > 0.5
        }
        if didChange {
            registerBatchMoveUndo(oldPositions: oldPositions, newPositions: updates)
        }

        try? database.updateCardPositions(updates)
        reloadStudySet()
        objectWillChange.send()
    }

    func reparent(cardID: UUID, to parentID: UUID?) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        if oldCard.groupNoteId == parentID { return }
        try? database.reparentCard(id: cardID, to: parentID)
        guard let newCard = try? database.getCard(id: cardID) else { return }
        registerCardUndo(oldCard: oldCard, newCard: newCard, actionName: "Reparent Note")
        reloadStudySet()
        objectWillChange.send()
    }

    func toggleFold(cardID: UUID, folded: Bool) {
        try? database.setCardFolded(id: cardID, folded: folded)
        reloadStudySet()
    }

    func indent(cardID: UUID, under siblingID: UUID) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        try? database.indentCard(id: cardID, under: siblingID)
        guard let newCard = try? database.getCard(id: cardID) else { return }
        registerCardUndo(oldCard: oldCard, newCard: newCard, actionName: "Indent Note")
        reloadStudySet()
        objectWillChange.send()
    }

    func outdent(cardID: UUID) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        try? database.outdentCard(id: cardID)
        guard let newCard = try? database.getCard(id: cardID) else { return }
        registerCardUndo(oldCard: oldCard, newCard: newCard, actionName: "Outdent Note")
        reloadStudySet()
        objectWillChange.send()
    }

    func delete(cardID: UUID) {
        if let oldCard = try? database.getCard(id: cardID) {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.restoreDeletedCard(oldCard)
                }
            }
            undoManager.setActionName("Delete Note")

            // Remove any lingering original highlight annotations on the PDF for this card
            if let mgr = self.manager {
                removeOriginalAnnotations(for: oldCard, in: mgr.document, fileURL: mgr.url, bookMD5: mgr.md5)
            }
        }
        try? database.deleteCard(id: cardID)
        if selectedCardID == cardID {
            selectedCardID = nil
            activeToolbarOwner = .none
        }
        reloadStudySet()
        objectWillChange.send()
    }

    private func removeOriginalAnnotations(for card: NoteCard, in document: PDFDocument, fileURL: URL, bookMD5: String) {
        var didRemove = false
        let cardRects = card.effectiveSegments.flatMap(\.rects).isEmpty ? card.highlightRects : card.effectiveSegments.flatMap(\.rects)
        let pagesToCheck = Set(cardRects.map(\.page) + [card.startPage, card.endPage].compactMap { $0 })

        for pageIdx in pagesToCheck {
            guard pageIdx >= 0 && pageIdx < document.pageCount,
                  let page = document.page(at: pageIdx) else { continue }

            let pageRects = cardRects.filter { $0.page == pageIdx }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }

            let annotsToRemove = page.annotations.filter { annot in
                guard annot.contents?.hasPrefix("MarginGraph-") != true else { return false }
                let type = annot.type ?? ""
                guard type == "Highlight" || type == "Underline" || type == "StrikeOut" else { return false }

                if pageRects.isEmpty {
                    if let start = card.startPos, let end = card.endPos {
                        let spanBox = CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: max(abs(end.x - start.x), 10),
                            height: max(abs(end.y - start.y), 10)
                        )
                        return annot.bounds.intersects(spanBox.insetBy(dx: -5, dy: -5))
                    }
                    return false
                }

                return pageRects.contains { r in
                    annot.bounds.intersects(r.insetBy(dx: -4, dy: -4))
                }
            }

            for annot in annotsToRemove {
                page.removeAnnotation(annot)
                didRemove = true
            }
        }

        if didRemove {
            let sidecar1 = fileURL.appendingPathExtension("md5")
            let sidecar2 = fileURL.deletingPathExtension().appendingPathExtension("md5")
            if !FileManager.default.fileExists(atPath: sidecar1.path) && !FileManager.default.fileExists(atPath: sidecar2.path) {
                try? bookMD5.write(to: sidecar1, atomically: true, encoding: .utf8)
            }
            _ = document.write(to: fileURL)
        }
    }

    func changeCardColor(cardID: UUID, colorIndex: Int) {
        if var card = try? database.getCard(id: cardID) {
            let oldCard = card
            card.colorIndex = colorIndex
            registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Change Color")
        }
        try? database.setCardColor(id: cardID, colorIndex: colorIndex)
        reloadStudySet()
        objectWillChange.send()
    }

    func updateCard(_ card: NoteCard) {
        if let oldCard = try? database.getCard(id: card.id) {
            registerCardUndo(oldCard: oldCard, newCard: card, actionName: "Edit Card")
        }
        try? database.updateCard(card)
        reloadStudySet()
        selectedCardID = card.id
        activeToolbarOwner = .mindMap
        objectWillChange.send()
    }

    func createChildCard(under parentID: UUID) {
        _ = ensureTopic()
        if var parent = mindMapCards.first(where: { $0.id == parentID }) ?? (try? database.getCard(id: parentID)), parent.isFolded {
            parent.isFolded = false
            try? database.updateCard(parent)
        }
        guard let parent = mindMapCards.first(where: { $0.id == parentID }) ?? (try? database.getCard(id: parentID)) else { return }

        var allCardsInTopic = (try? database.cardsForTopic(id: parent.topicId)) ?? mindMapCards
        allCardsInTopic = NoteCard.filterMarginNoteDocumentRootCard(from: allCardsInTopic)
        let existingChildren = allCardsInTopic
            .filter { $0.groupNoteId == parentID }
            .sorted(by: TreeLayout.cardOrder)

        var targetMindPos: CGPoint? = nil
        var targetCreatedAt = Date()
        if let lastChild = existingChildren.last {
            if let ly = lastChild.mindPos?.y {
                let lastH = TreeLayout.estimatedCardHeight(for: lastChild, width: 220)
                targetMindPos = CGPoint(x: lastChild.mindPos?.x ?? 0, y: ly + lastH + 56.0)
            }
            targetCreatedAt = lastChild.createdAt.addingTimeInterval(1.0)
        } else {
            if let py = parent.mindPos?.y {
                targetMindPos = CGPoint(x: (parent.mindPos?.x ?? 0) + 260, y: py)
            }
            targetCreatedAt = parent.createdAt.addingTimeInterval(1.0)
        }

        var newCard = NoteCard(
            topicId: parent.topicId,
            title: "",
            groupNoteId: parentID,
            colorIndex: parent.colorIndex
        )
        newCard.bookMD5 = parent.bookMD5
        newCard.startPage = parent.startPage
        newCard.mindPos = targetMindPos
        newCard.createdAt = targetCreatedAt

        try? database.insertCard(newCard)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.delete(cardID: newCard.id)
            }
        }
        undoManager.setActionName("Create Child Note")
        selectedCardID = newCard.id
        editingCardTitleID = newCard.id
        activeToolbarOwner = .mindMap
        reloadStudySet()
        objectWillChange.send()
    }

    func createSiblingCard(after siblingID: UUID) {
        _ = ensureTopic()
        guard let sibling = mindMapCards.first(where: { $0.id == siblingID })
            ?? (try? database.getCard(id: siblingID)) else { return }

        var allCardsInTopic = (try? database.cardsForTopic(id: sibling.topicId)) ?? mindMapCards
        allCardsInTopic = NoteCard.filterMarginNoteDocumentRootCard(from: allCardsInTopic)
        let siblings = allCardsInTopic
            .filter { $0.groupNoteId == sibling.groupNoteId }
            .sorted(by: TreeLayout.cardOrder)

        var targetMindPos: CGPoint? = nil
        var targetCreatedAt = Date()

        if let idx = siblings.firstIndex(where: { $0.id == sibling.id }) {
            if idx + 1 < siblings.count {
                let nextSib = siblings[idx + 1]
                if let sy = sibling.mindPos?.y, let ny = nextSib.mindPos?.y {
                    targetMindPos = CGPoint(x: sibling.mindPos?.x ?? 0, y: (sy + ny) / 2)
                }
                let t1 = sibling.createdAt.timeIntervalSince1970
                let t2 = nextSib.createdAt.timeIntervalSince1970
                targetCreatedAt = Date(timeIntervalSince1970: (t1 + t2) / 2)
            } else {
                if let sy = sibling.mindPos?.y {
                    let sibH = TreeLayout.estimatedCardHeight(for: sibling, width: 220)
                    targetMindPos = CGPoint(x: sibling.mindPos?.x ?? 0, y: sy + sibH + 56.0)
                }
                targetCreatedAt = sibling.createdAt.addingTimeInterval(1.0)
            }
        }

        var newCard = NoteCard(
            topicId: sibling.topicId,
            title: "",
            groupNoteId: sibling.groupNoteId,
            colorIndex: sibling.colorIndex
        )
        newCard.bookMD5 = sibling.bookMD5
        newCard.startPage = sibling.startPage
        newCard.mindPos = targetMindPos
        newCard.createdAt = targetCreatedAt

        try? database.insertCard(newCard)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.delete(cardID: newCard.id)
            }
        }
        undoManager.setActionName("Create Sibling Note")
        selectedCardID = newCard.id
        editingCardTitleID = newCard.id
        activeToolbarOwner = .mindMap
        reloadStudySet()
        objectWillChange.send()
    }

    func createFreeNote(at canvasPos: CGPoint) {
        freeNoteDraft = NoteCard(topicId: selectedTopicID ?? UUID(), mindPos: canvasPos)
    }

    func saveFreeNote(_ draft: NoteCard) {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var newCard = draft
        newCard.topicId = ensureTopic().id
        do {
            try database.insertCard(newCard)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let newID = newCard.id
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.delete(cardID: newID)
            }
        }
        undoManager.setActionName("Create Note")
        selectedCardID = newID
        activeToolbarOwner = .mindMap
        reloadStudySet()
        objectWillChange.send()
    }

    func updateCardTitle(cardID: UUID, title: String) {
        guard var card = mindMapCards.first(where: { $0.id == cardID }) ?? (try? database.getCard(id: cardID)) else { return }
        if card.title == title { return }
        card.title = title
        updateCard(card)
    }

    func reorder(cardID: UUID, before siblingID: UUID?) {
        guard let oldCard = try? database.getCard(id: cardID) else { return }
        try? database.reorderCard(id: cardID, before: siblingID)
        guard let newCard = try? database.getCard(id: cardID) else { return }
        registerCardUndo(oldCard: oldCard, newCard: newCard, actionName: "Reorder Note")
        reloadStudySet()
        objectWillChange.send()
    }

    func importMarginNote() {
        guard !isImportingMarginNote else { return }
        let panel = NSOpenPanel()
        let marginpkgType = UTType(filenameExtension: "marginpkg")
        let marginnotesType = UTType(filenameExtension: "marginnotes")
        let sqliteType = UTType(filenameExtension: "sqlite")
        panel.allowedContentTypes = [marginpkgType, marginnotesType, sqliteType].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
        let sourceURL = isDirectory.boolValue
            ? selected.appendingPathComponent("MarginNotes.sqlite")
            : selected
        Task { await importMarginNoteOrPackage(url: sourceURL) }
    }

    func exportMarkdown() {
        guard let topic = selectedTopic else { return }
        saveExport(
            content: MarkdownExporter.export(topic: topic, cards: mindMapCards),
            suggestedName: "\(safeFilename(topic.title)).md",
            type: UTType(filenameExtension: "md") ?? .plainText
        )
    }

    func exportOPML() {
        guard let topic = selectedTopic else { return }
        saveExport(
            content: OPMLExporter.export(topic: topic, cards: mindMapCards),
            suggestedName: "\(safeFilename(topic.title)).opml",
            type: UTType(filenameExtension: "opml") ?? .xml
        )
    }

    func exportOrg() {
        guard let topic = selectedTopic, !isExportingOrg else { return }
        let cards = mindMapCards
        let documents = studyDocuments
        let sourceDatabase = database
        let destination = externalLibraryDirectory.map { _ in importedDocumentsDirectory }
        isExportingOrg = true
        Task {
            defer { isExportingOrg = false }
            do {
                let legacyDirectory = MarginNoteImporter.defaultDocumentsDirectory
                let exportDocuments: [Document]
                var replacementPaths: [String: String] = [:]
                if let destination {
                    exportDocuments = try await Task.detached(priority: .userInitiated) {
                        try documents.map {
                            try sourceDatabase.relocateLegacyPackageDocument($0, from: legacyDirectory, into: destination)
                        }
                    }.value
                    let managedPath = destination.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                    for document in exportDocuments where document.filePath.hasPrefix(managedPath) {
                        let name = (document.filePath as NSString).lastPathComponent
                        replacementPaths[legacyDirectory.appendingPathComponent(name).path] = document.filePath
                        if let previous = documents.first(where: { $0.id == document.id }),
                           previous.filePath != document.filePath {
                            replacementPaths[previous.filePath] = document.filePath
                        }
                        if exportDocuments.count == 1 { replacementPaths[legacyDirectory.path] = document.filePath }
                    }
                    if database === sourceDatabase {
                        updateRelocatedStudyDocuments(exportDocuments)
                    }
                } else {
                    exportDocuments = documents
                }
                if let result = try await referenceWorkspace.export(topic: topic, cards: cards, documents: exportDocuments,
                                                                     replacementDocumentPaths: replacementPaths) {
                    try sourceDatabase.saveReferenceStudyLink(
                        ReferenceStudyLink(topicID: topic.id, bookMD5: result.bookMD5),
                        bibliography: result.bibliography, key: result.key
                    )
                    showOrgExportResult(url: result.note, key: result.key)
                }
            } catch {
                let alert = NSAlert(error: error)
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else { alert.runModal() }
            }
        }
    }

    private func updateRelocatedStudyDocuments(_ relocated: [Document]) {
        for document in relocated {
            if let index = documents.firstIndex(where: { $0.id == document.id }), documents[index].filePath != document.filePath {
                documents[index].filePath = document.filePath
            }
            if let index = studyDocuments.firstIndex(where: { $0.id == document.id }), studyDocuments[index].filePath != document.filePath {
                studyDocuments[index].filePath = document.filePath
            }
            if let activeDocument, activeDocument.id == document.id, activeDocument.filePath != document.filePath {
                switchToDocument(document, clearSelection: false)
            }
        }
    }

    private func showOrgExportResult(url: URL, key: String) {
        let alert = NSAlert()
        alert.messageText = "Literature Note Saved"
        alert.informativeText = "\(key)\n\(url.path)"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Show in Finder")
        let respond: (NSApplication.ModalResponse) -> Void = { result in
            if result == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else { respond(alert.runModal()) }
    }

    func exportAnki() {
        guard let topic = selectedTopic else { return }
        saveExport(
            content: AnkiExporter.export(topic: topic, cards: mindMapCards),
            suggestedName: "\(safeFilename(topic.title))-anki.tsv",
            type: .tabSeparatedText
        )
    }

    func startReview() {
        guard !dueFlashcards.isEmpty else { return }
        if let topicID = selectedTopicID {
            try? database.recordDeckReview(id: topicID, date: Date())
            reloadLibrary()
        }
        activeReviewCards = dueFlashcards
        activeReviewDocuments = studyDocuments
        isReviewPresented = true
    }

    func startReviewForDeck(_ deck: ReviewDeckItem) {
        let now = Date()
        try? database.recordDeckReview(id: deck.id, date: now)
        reloadLibrary()

        if let deckId = deck.deckId {
            let cards = (try? database.cardsForDeck(deckId: deckId)) ?? []
            let due = (try? database.dueCardsForDeck(deckId: deckId)) ?? []
            activeReviewCards = due.isEmpty ? cards : due
            let md5s = Set(cards.compactMap { $0.bookMD5 })
            activeReviewDocuments = documents.filter { md5s.contains($0.md5) }
            isReviewPresented = true
            return
        }

        if let topicId = deck.topicId,
           let topic = topics.first(where: { $0.id == topicId }) {
            selectTopic(topic)
            let cards = (try? database.cardsForTopic(id: topicId)) ?? []
            let due = (try? database.dueCardsForTopic(id: topicId)) ?? []
            activeReviewCards = due.isEmpty ? cards : due
            activeReviewDocuments = studyDocuments
        }
        isReviewPresented = true
    }

    func availableDecksForAddToSheet() -> [ReviewDeckItem] {
        var sheetDecks: [ReviewDeckItem] = customDecks.map { deck in
            ReviewDeckItem(
                id: deck.id,
                title: deck.title,
                dueCount: dueDeckCounts[deck.id] ?? 0,
                totalCount: deckCardCounts[deck.id] ?? 0,
                deckId: deck.id
            )
        }
        let customIDs = Set(customDecks.map(\.id))
        for topicDeck in reviewDecks where !customIDs.contains(topicDeck.id) {
            sheetDecks.append(topicDeck)
        }
        return sheetDecks
    }

    func addCardsToDeck(deckId: UUID?, newTitle: String?, cardIds: [UUID]) {
        do {
            let targetDeckId: UUID
            if let deckId {
                targetDeckId = deckId
                if (try? database.getDeck(id: targetDeckId)) == nil,
                   let topic = topics.first(where: { $0.id == targetDeckId }) {
                    _ = try database.createDeck(id: targetDeckId, title: topic.title)
                    let topicCards = (try? database.cardsForTopic(id: targetDeckId)) ?? []
                    try database.addCardsToDeck(cardIds: topicCards.map(\.id), deckId: targetDeckId)
                }
            } else if let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let newDeck = try database.createDeck(title: trimmed)
                targetDeckId = newDeck.id
            } else {
                return
            }
            try database.addCardsToDeck(cardIds: cardIds, deckId: targetDeckId)
            reloadLibrary()
            reloadStudySet()
        } catch {
            print("[AppModel] Failed to add cards to deck: \(error)")
        }
    }

    func deleteDeck(_ deckItem: ReviewDeckItem) {
        if let deckId = deckItem.deckId {
            try? database.deleteDeck(id: deckId)
            reloadLibrary()
        }
    }

    func previewNoteLink(_ url: URL) {
        guard case .openCard(let id) = DeepLinkHandler.parse(url) else { return }
        guard let card = try? database.cardForNoteLink(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Linked Note Unavailable"
            alert.informativeText = "This note is not in the current library. Import its notebook or switch libraries."
            alert.runModal()
            return
        }
        linkedMindMapCard = card
    }

    func handleDeepLink(_ url: URL) {
        guard let destination = DeepLinkHandler.parse(url) else { return }

        switch destination {
        case .openTopic(let topicId):
            guard let topic = topics.first(where: { $0.id == topicId }) else { return }
            enterStudyWorkspace(topic: topic)

        case .openCard(let cardId):
            guard let card = try? database.cardForNoteLink(id: cardId) else {
                let alert = NSAlert()
                alert.messageText = "Linked Note Unavailable"
                alert.informativeText = "This note is not in the current library. Import its notebook or switch to the library containing it."
                alert.runModal()
                return
            }
            if selectedTopicID != card.topicId,
               let topic = topics.first(where: { $0.id == card.topicId }) {
                selectTopic(topic)
            }
            reloadStudySet()
            isInStudyWorkspace = true
            let visibleCard = (try? database.cardForNoteLink(id: cardId)) ?? card
            select(card: visibleCard)
            cardIDToCenter = visibleCard.id
        }
    }

    private func saveExport(content: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                if let window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }

    private func ensureTopic() -> Topic {
        if let topic = selectedTopic { return topic }
        let topic = Topic(title: "Inbox")
        try? database.insertTopic(topic)
        reloadLibrary()
        selectedTopicID = topic.id
        reloadStudySet()
        return topic
    }

    func createNewTopic(title: String = "MindMap Layer") -> Topic {
        let topic = Topic(title: "\(title) \(topics.count + 1)")
        try? database.insertTopic(topic)
        reloadLibrary()
        selectTopic(topic)
        return topic
    }

    private func reloadDocumentCards() {
        guard let md5 = manager?.md5 else {
            documentCards = []
            return
        }
        // Notebook rendering already owns the topic's cards. Do not fetch every
        // matching card from every notebook again (twice during shelf opening).
        if selectedTopicID != nil {
            documentCards = mindMapCards.filter {
                guard let bookMD5 = $0.bookMD5 else { return false }
                return bookMD5 == md5 || bookMD5.hasPrefix(md5) || md5.hasPrefix(bookMD5)
            }
            return
        }
        let rawCards = (try? database.cardsForDocument(md5: md5)) ?? []
        documentCards = NoteCard.filterMarginNoteDocumentRootCard(from: rawCards)
    }
}

// MARK: - Study Workspace Views

struct WorkspaceDocumentTabs: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.studyDocuments, id: \.id) { document in
                        Button {
                            model.switchToDocument(document)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 11))
                                Text(document.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                model.activeDocument?.md5 == document.md5
                                    ? Color(red: 0.18, green: 0.65, blue: 0.65).opacity(0.18)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Detach from Study Set") {
                                model.detachDocument(document)
                            }
                        }
                    }
                }
            }

            Menu {
                if !model.documents.isEmpty {
                    Section("Existing Documents") {
                        ForEach(model.documents, id: \.id) { document in
                            Button(document.title) {
                                model.attachExistingDocument(document)
                            }
                        }
                    }
                }
                Button("Open New Document…") {
                    model.openDocumentPicker(attachToTopic: true)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("Manage")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }
}

struct StudyWorkspaceView: View {
    @ObservedObject var model: AppModel

    @State private var pdfWidth: CGFloat? = nil
    @State private var savedSplitPDFWidth: CGFloat? = nil
    @State private var dragStartPDFWidth: CGFloat? = nil
    @State private var isDraggingSplitDivider: Bool = false
    @State private var liveDividerX: CGFloat? = nil
    @State private var commitDebounceTask: Task<Void, Never>? = nil
    @State private var outlineWidth: CGFloat = 240
    @State private var dragStartOutlineWidth: CGFloat? = nil
    @State private var bibliographyDocument: Document?

    var body: some View {
        GeometryReader { workspaceGeo in
            let totalWidth = workspaceGeo.size.width
            let totalHeight = workspaceGeo.size.height

            let isReaderOnly = model.workspaceMode == .readerOnly
            let isMindMapOnly = model.workspaceMode == .mindMapOnly
            let showOutline = (model.workspaceMode == .threeView || (model.workspaceMode == .splitView && model.isOutlineVisible)) && !isReaderOnly && !isMindMapOnly
            let currentOutlineWidth = showOutline ? outlineWidth : 0
            let availableMainWidth = max(680, totalWidth - currentOutlineWidth)

            let minPDF: CGFloat = 360
            let minMindMap: CGFloat = 320
            let maxPDF: CGFloat = max(minPDF, availableMainWidth - minMindMap)

            let currentPDFWidth: CGFloat = {
                let base = pdfWidth ?? (availableMainWidth * 0.5)
                return min(max(minPDF, base), maxPDF)
            }()

            let currentMindMapWidth = max(minMindMap, availableMainWidth - currentPDFWidth)
            let committedDividerX = currentOutlineWidth + currentMindMapWidth
            let activeDividerX = (isDraggingSplitDivider && liveDividerX != nil) ? liveDividerX! : committedDividerX

            ZStack(alignment: .topLeading) {
                // 1. Outline Pane (if shown)
                if showOutline {
                    outlinePane
                        .frame(width: outlineWidth, height: totalHeight)
                        .offset(x: 0, y: 0)

                    // Outline separator line
                    Rectangle()
                        .fill(MarginNoteTheme.separatorColor)
                        .frame(width: 1, height: totalHeight)
                        .background(
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 7)
                                .contentShape(Rectangle())
                        )
                        .offset(x: outlineWidth, y: 0)
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.set()
                            } else if dragStartOutlineWidth == nil {
                                NSCursor.arrow.set()
                                NSApp.keyWindow?.resetCursorRects()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { gesture in
                                    if dragStartOutlineWidth == nil {
                                        dragStartOutlineWidth = outlineWidth
                                    }
                                    NSCursor.resizeLeftRight.set()
                                    guard let start = dragStartOutlineWidth else { return }
                                    let newW = start + gesture.translation.width
                                    outlineWidth = min(max(180, newW), 340)
                                }
                                .onEnded { _ in
                                    dragStartOutlineWidth = nil
                                    NSCursor.arrow.set()
                                    NSApp.keyWindow?.resetCursorRects()
                                }
                        )
                }

                // 2. MindMap Pane (always kept mounted, offset offscreen when readerOnly)
                mindMapPane
                    .frame(
                        width: isMindMapOnly ? totalWidth : currentMindMapWidth,
                        height: totalHeight
                    )
                    .offset(
                        x: isReaderOnly ? -currentMindMapWidth - 100 : currentOutlineWidth,
                        y: 0
                    )
                    .opacity(isReaderOnly ? 0 : 1)
                    .allowsHitTesting(!isReaderOnly)
                    .zIndex((model.activeToolbarOwner == .mindMap && !isDraggingSplitDivider) ? 250 : 0)

                // 3. PDF Pane (always kept mounted, with readerOnlyHeader when readerOnly)
                VStack(spacing: 0) {
                    if isReaderOnly {
                        readerOnlyHeader
                    }
                    pdfPane
                }
                .frame(
                    width: isReaderOnly ? totalWidth : currentPDFWidth,
                    height: totalHeight
                )
                .offset(
                    x: isReaderOnly ? 0 : (isMindMapOnly ? totalWidth + 100 : currentOutlineWidth + currentMindMapWidth),
                    y: 0
                )
                .opacity(isMindMapOnly ? 0 : 1)
                .allowsHitTesting(!isMindMapOnly)
                .zIndex((model.activeToolbarOwner == .pdf && !isDraggingSplitDivider) ? 250 : 0)

                // 4. Split Divider Line & Pill (only in split / three view)
                if !isReaderOnly && !isMindMapOnly {
                    if isDraggingSplitDivider {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.85))
                            .frame(width: 2, height: totalHeight)
                            .shadow(color: Color.black.opacity(0.18), radius: 2)
                            .offset(x: activeDividerX - 1, y: 0)
                            .allowsHitTesting(false)
                            .zIndex(350)
                    }

                    Rectangle()
                        .fill(MarginNoteTheme.separatorColor)
                        .frame(width: 1, height: totalHeight)
                        .frame(width: 9, height: totalHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.set()
                            } else if !isDraggingSplitDivider {
                                NSCursor.arrow.set()
                                NSApp.keyWindow?.resetCursorRects()
                            }
                        }
                        .gesture(
                            makeSplitDragGesture(
                                totalWidth: totalWidth,
                                currentPDFWidth: currentPDFWidth,
                                minPDF: minPDF,
                                maxPDF: maxPDF
                            )
                        )
                        .offset(x: activeDividerX - 4.5, y: 0)
                        .zIndex(150)

                    splitDividerPill(
                        totalWidth: totalWidth,
                        currentPDFWidth: currentPDFWidth,
                        minPDF: minPDF,
                        maxPDF: maxPDF
                    )
                    .frame(width: 52, height: 28)
                    .offset(x: activeDividerX - 26, y: totalHeight * 0.74 - 14)
                    .zIndex(300)
                }

                // 5. Left edge restore handle (MarginNote 3 signature half-pill)
                if isReaderOnly {
                    edgeRestoreHandle(side: .leading)
                        .frame(width: 26, height: 28)
                        .offset(x: 0, y: totalHeight * 0.74 - 14)
                        .zIndex(300)
                }

                // 6. Right edge restore handle (MarginNote 3 signature half-pill)
                if isMindMapOnly {
                    edgeRestoreHandle(side: .trailing)
                        .frame(width: 26, height: 28)
                        .offset(x: totalWidth - 26, y: totalHeight * 0.74 - 14)
                        .zIndex(300)
                }
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $model.linkedMindMapCard) { card in
            LinkedMindMapPreview(model: model, destination: card)
        }
        .sheet(item: $model.editingCard) { card in
            CardEditorSheet(
                card: card,
                onSave: { updated in
                    model.updateCard(updated)
                },
                onDelete: { id in
                    model.delete(cardID: id)
                }
            )
        }
        .sheet(item: $model.freeNoteDraft) { draft in
            CardEditorSheet(card: draft, isNewNote: true, onSave: model.saveFreeNote)
        }
        .sheet(item: $model.cardForAddToDeck) { card in
            AddToDeckSheet(
                card: card,
                allCards: model.mindMapCards,
                existingDecks: model.availableDecksForAddToSheet(),
                onAdd: { deckId, newTitle, cardIds in
                    model.addCardsToDeck(deckId: deckId, newTitle: newTitle, cardIds: cardIds)
                },
                onDismiss: {
                    model.cardForAddToDeck = nil
                }
            )
        }
        .sheet(isPresented: $model.isManagingDocuments) {
            StudyDocumentManagementSheet(
                documents: model.studyDocuments,
                allDocuments: model.documents,
                activeDocument: model.activeDocument,
                initialMode: model.studyDocumentSheetMode,
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onDetachDocument: { doc in
                    model.detachDocument(doc)
                },
                onAddExistingDocument: { doc in
                    model.attachExistingDocument(doc)
                },
                onImportDocument: {
                    model.isManagingDocuments = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        model.openDocumentPicker(attachToTopic: true)
                    }
                },
                onDismiss: {
                    model.isManagingDocuments = false
                }
            )
        }
        .sheet(item: $bibliographyDocument) { document in
            let database = model.database
            let topicID = model.selectedTopicID
            let includesNotebookLink = model.studyDocuments.count == 1 && model.studyDocuments.first?.id == document.id
            DocumentBibliographySheet {
                try await model.referenceWorkspace.bibliography(for: document, database: database, topicID: topicID,
                                                                includesNotebookLink: includesNotebookLink)
            }
        }
        .onDisappear {
            commitDebounceTask?.cancel()
            commitDebounceTask = nil
            NSCursor.arrow.set()
            NSApp.keyWindow?.resetCursorRects()
        }
    }

    private func makeSplitDragGesture(
        totalWidth: CGFloat,
        currentPDFWidth: CGFloat,
        minPDF: CGFloat,
        maxPDF: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if dragStartPDFWidth == nil {
                    dragStartPDFWidth = currentPDFWidth
                    isDraggingSplitDivider = true
                }
                NSCursor.resizeLeftRight.set()
                guard let start = dragStartPDFWidth else { return }
                let candidatePDF = min(max(minPDF, start - gesture.translation.width), maxPDF)
                let candidateX = totalWidth - candidatePDF
                liveDividerX = candidateX

                // Debounce commit: if user pauses dragging for ~100ms, commit PDFView resize
                commitDebounceTask?.cancel()
                commitDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    if isDraggingSplitDivider {
                        withAnimation(.easeOut(duration: 0.12)) {
                            self.pdfWidth = candidatePDF
                        }
                    }
                }
            }
            .onEnded { _ in
                commitDebounceTask?.cancel()
                commitDebounceTask = nil

                if let liveX = liveDividerX {
                    let finalPDF = min(max(minPDF, totalWidth - liveX), maxPDF)
                    withAnimation(.easeOut(duration: 0.12)) {
                        self.pdfWidth = finalPDF
                    }
                }

                dragStartPDFWidth = nil
                liveDividerX = nil
                isDraggingSplitDivider = false

                NSCursor.arrow.set()
                NSApp.keyWindow?.resetCursorRects()
            }
    }

    private func splitDividerPill(
        totalWidth: CGFloat,
        currentPDFWidth: CGFloat,
        minPDF: CGFloat,
        maxPDF: CGFloat
    ) -> some View {
        HStack(spacing: 1) {
            Button {
                guard !isDraggingSplitDivider else { return }
                savedSplitPDFWidth = currentPDFWidth
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.workspaceMode = .readerOnly
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(white: 0.35))
                    .frame(width: 14, height: 22)
                    .enlargedHitTarget(width: 20, height: 26)
            }
            .buttonStyle(.plain)
            .help("Collapse MindMap (Document Only)")

            Circle()
                .fill(Color(white: 0.50))
                .frame(width: 3.5, height: 3.5)
                .padding(.horizontal, 1)

            Button {
                guard !isDraggingSplitDivider else { return }
                savedSplitPDFWidth = currentPDFWidth
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.workspaceMode = .mindMapOnly
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(white: 0.35))
                    .frame(width: 14, height: 22)
                    .enlargedHitTarget(width: 20, height: 26)
            }
            .buttonStyle(.plain)
            .help("Collapse Document (MindMap Only)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(white: 0.98).opacity(0.80))
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .overlay(Capsule().stroke(Color(white: 0.82).opacity(0.70), lineWidth: 0.75))
        )
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.set()
            } else if !isDraggingSplitDivider {
                NSCursor.arrow.set()
                NSApp.keyWindow?.resetCursorRects()
            }
        }
        .simultaneousGesture(
            makeSplitDragGesture(
                totalWidth: totalWidth,
                currentPDFWidth: currentPDFWidth,
                minPDF: minPDF,
                maxPDF: maxPDF
            )
        )
    }

    private enum EdgeSide {
        case leading  // Document-only mode: mindmap is collapsed to the left edge
        case trailing // MindMap-only mode: document is collapsed to the right edge
    }

    private func edgeRestoreHandle(side: EdgeSide) -> some View {
        let isLeading = (side == .leading)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isLeading ? 0 : 14,
            bottomLeadingRadius: isLeading ? 0 : 14,
            bottomTrailingRadius: isLeading ? 14 : 0,
            topTrailingRadius: isLeading ? 14 : 0
        )

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.workspaceMode = .splitView
                if let saved = savedSplitPDFWidth {
                    self.pdfWidth = saved
                }
            }
        } label: {
            HStack(spacing: 0) {
                if isLeading {
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 14, height: 22)
                    Spacer(minLength: 4)
                } else {
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 14, height: 22)
                    Spacer(minLength: 2)
                }
            }
            .frame(width: 26, height: 28)
            .background(
                shape
                    .fill(Color(white: 0.98).opacity(0.80))
                    .background(.ultraThinMaterial, in: shape)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .overlay(shape.stroke(Color(white: 0.82).opacity(0.70), lineWidth: 0.75))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .enlargedHitTarget(width: 32, height: 34)
        .help("Restore Split View")
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
                NSApp.keyWindow?.resetCursorRects()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { gesture in
                    let triggered = isLeading ? (gesture.translation.width > 8) : (gesture.translation.width < -8)
                    if triggered {
                        withAnimation(.easeOut(duration: 0.2)) {
                            model.workspaceMode = .splitView
                            if let saved = savedSplitPDFWidth {
                                self.pdfWidth = saved
                            }
                        }
                    }
                }
                .onEnded { _ in
                    NSCursor.arrow.set()
                    NSApp.keyWindow?.resetCursorRects()
                }
        )
    }

    private var readerOnlyHeader: some View {
        HStack(spacing: 12) {
            Button {
                model.exitStudyWorkspace()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .enlargedHitTarget(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .marginNoteTooltip(model.selectedMainTab == .reference ? "Back to Reference" : "Back to Notebooks")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.workspaceMode = .splitView
                    if let saved = savedSplitPDFWidth {
                        self.pdfWidth = saved
                    }
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .enlargedHitTarget(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .marginNoteTooltip("Restore Split View")

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: MarginNoteTheme.topToolbarHeight)
        .background(MarginNoteTheme.headerBarBackground)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .bottom
        )
        .tooltipContainer()
        .zIndex(100)
    }

    private var mindMapPane: some View {
        StudyMindMapPane(model: model) {
            if model.isMindMapSearchPresented {
                MindMapSearchBarView(model: model)
            }
            MindMapCanvasView(
                cards: model.mindMapCards,
                links: model.links,
                selectedCardID: model.selectedCardID,
                cardIDToCenter: $model.cardIDToCenter,
                editingCardTitleID: $model.editingCardTitleID,
                initialPanOffset: model.currentMindPan,
                initialZoomScale: model.currentMindZoom,
                onViewportChanged: { [weak model] pan, zoom in
                    model?.updateMindMapPosition(pan: pan, zoom: zoom)
                },
                activeToolbarOwner: model.activeToolbarOwner,
                mediaStorage: model.mediaStorage,
                topics: model.topics,
                selectedTopic: model.selectedTopic,
                onSelectTopic: { topic in
                    model.selectTopic(topic)
                },
                onNewTopic: {
                    _ = model.createNewTopic()
                },
                onSelect: { card in
                    if let card { model.select(card: card) } else { model.deselect() }
                },
                onMove: model.move,
                onMoveBatch: model.moveCardsBatch,
                onReparent: model.reparent,
                onToggleFold: model.toggleFold,
                onChangeColor: { cardID, colorIdx in
                    model.changeCardColor(cardID: cardID, colorIndex: colorIdx)
                },
                onDeleteCard: { cardID in
                    model.delete(cardID: cardID)
                },
                onEditCard: { card in
                    model.editingCard = card
                },
                onNewSibling: { cardID in
                    model.createSiblingCard(after: cardID)
                },
                onNewChild: { cardID in
                    model.createChildCard(under: cardID)
                },
                onNewNote: { pos in
                    model.createFreeNote(at: pos)
                },
                onUpdateTitle: { cardID, title in
                    model.updateCardTitle(cardID: cardID, title: title)
                },
                onAddToDeck: { card in
                    model.cardForAddToDeck = card
                },
                onOpenNoteLink: model.previewNoteLink,
                onSaveNoteLinks: model.updateCard,
                searchQuery: model.mindMapSearchQuery,
                searchScope: model.mindMapSearchScope,
                currentSearchMatchID: model.matchingMindMapCards.indices.contains(model.currentMindMapMatchIndex) ? model.matchingMindMapCards[model.currentMindMapMatchIndex].id : nil,
                isSearchActive: model.isMindMapSearchPresented
            )
        }
    }

    private var outlinePane: some View {
        OutlineSidebarView(
            cards: model.mindMapCards,
            selectedCardID: model.selectedCardID,
            onSelect: model.select,
            onToggleFold: model.toggleFold,
            onIndent: model.indent,
            onOutdent: model.outdent,
            onDelete: model.delete,
            onReorderBefore: model.reorder
        )
    }

    @ViewBuilder
    private var pdfPane: some View {
        if let manager = model.manager {
            let onReplacePDF: (() -> Void)? = model.activeDocument?.documentType == "pdf"
                ? { model.chooseReplacementPDF() }
                : nil
            MarginNotePDFContainerView(
                manager: manager,
                cards: model.activePDFCards,
                selectedCardID: model.selectedCardID,
                activeToolbarOwner: model.activeToolbarOwner,
                jumpTarget: model.jumpTarget,
                studyDocuments: model.studyDocuments,
                activeDocument: model.activeDocument,
                showsDocumentTabBar: !model.studyDocuments.isEmpty,
                bookmarks: model.documentBookmarks,
                initialPageIndex: model.documentCurrentPage[manager.md5] ?? model.activeDocument?.lastPageIndex ?? 0,
                initialPageOffsetY: model.documentPageOffsets[manager.md5] ?? model.activeDocument?.lastPageOffsetY ?? 0.0,
                onPageChanged: { [weak model] page in
                    model?.documentCurrentPage[manager.md5] = page
                },
                onPositionChanged: { [weak model] page, offset in
                    model?.updatePDFPosition(md5: manager.md5, pageIndex: page, pageOffsetY: offset)
                },
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onCloseDocument: { doc in
                    if model.studyDocuments.count > 1 {
                        model.detachDocument(doc)
                    }
                },
                onAddDocument: {
                    model.studyDocumentSheetMode = .addExisting
                    model.isManagingDocuments = true
                },
                onManageDocuments: {
                    model.studyDocumentSheetMode = .manage
                    model.isManagingDocuments = true
                },
                onToggleBookmark: { page, isBookmarked in
                    model.toggleBookmark(pageIndex: page, isBookmarked: isBookmarked)
                },
                onExcerpt: { excerpt in
                    model.createExcerpt(excerpt)
                },
                onCreateCardWithColor: { excerpt, colorIdx in
                    model.createExcerpt(excerpt, colorIndex: colorIdx)
                },
                onEditCard: { cardID in
                    if let card = model.mindMapCards.first(where: { $0.id == cardID })
                        ?? (try? model.database.getCard(id: cardID)) {
                        model.editingCard = card
                    }
                },
                onChangeCardColor: { cardID, colorIdx in
                    model.changeCardColor(cardID: cardID, colorIndex: colorIdx)
                },
                onDeleteCard: { cardID in
                    model.delete(cardID: cardID)
                },
                onDeleteSegment: { cardID, segmentID in
                    model.deleteSegment(cardID: cardID, segmentID: segmentID)
                },
                onSelectCard: { cardID in
                    model.selectCardFromPDF(cardID: cardID)
                },
                onUpdateCardHighlight: { cardID, segmentID, newText, rects, startPos, endPos in
                    model.updateHighlight(
                        cardID: cardID,
                        segmentID: segmentID,
                        newText: newText,
                        rects: rects,
                        startPos: startPos,
                        endPos: endPos
                    )
                },
                onAsTitle: { cardID, text in
                    model.setCardTitleFromSelection(cardID: cardID, text: text)
                },
                onAddToComments: { cardID, text in
                    model.addCommentFromSelection(cardID: cardID, text: text)
                },
                onMerge: { cardID, text, rects in
                    model.mergeSelectionIntoCard(cardID: cardID, text: text, rects: rects)
                },
                onEmphasize: { cardID, text, rects in
                    model.emphasizeTextInCard(cardID: cardID, text: text, rects: rects)
                },
                onDeleteEmphasis: { cardID, text, rects in
                    model.deleteEmphasisInCard(cardID: cardID, text: text, rects: rects)
                },
                onUpdateTypography: { [weak model] options in
                    model?.updateTypography(options: options)
                },
                onImportHighlights: { [weak model] in
                    if let doc = model?.activeDocument {
                        model?.importPDFHighlightsManually(for: doc)
                    }
                },
                onReplacePDF: onReplacePDF,
                onCleanPageNumbers: { [weak model] in model?.cleanExistingNotePageNumbers() },
                onOpenBibliography: { bibliographyDocument = model.activeDocument }
            )
        } else if let doc = model.activeDocument, doc.documentType == "video" || doc.documentType == "audio" {
            MediaPlaybackContainerView(
                document: doc,
                cards: model.mindMapCards,
                selectedCardID: model.selectedCardID,
                studyDocuments: model.studyDocuments,
                mediaStorage: model.mediaStorage,
                showsHeader: true,
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onCloseDocument: { doc in
                    if model.studyDocuments.count > 1 {
                        model.detachDocument(doc)
                    }
                },
                onAddDocument: {
                    model.studyDocumentSheetMode = .addExisting
                    model.isManagingDocuments = true
                },
                onManageDocuments: {
                    model.studyDocumentSheetMode = .manage
                    model.isManagingDocuments = true
                },
                onCreateVideoCard: { startTime, endTime, title in
                    model.createVideoExcerptCard(startTime: startTime, endTime: endTime, title: title)
                },
                onSelectCard: { cardID in model.select(cardID: cardID) },
                onOpenBibliography: { bibliographyDocument = doc }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Document Attached")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("Attach Document…") {
                    model.studyDocumentSheetMode = .addExisting
                    model.isManagingDocuments = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        }
    }
}

struct ExternalDatabaseBannerView: View {
    let databaseName: String
    var isCurrentDefault: Bool = false
    let onSwitchToDefault: () -> Void
    var onSwitchToBuiltIn: (() -> Void)? = nil
    let onOpenAnother: () -> Void
    var onManageLibraries: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("External Library:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(databaseName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if isCurrentDefault {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("DEFAULT")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                    }
                }
                Text("Using documents directly in-place without copying • Modifications saved to sidecar folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onManageLibraries {
                Button("Manage Libraries…") {
                    onManageLibraries()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !isCurrentDefault {
                Button("Switch to Default Library") {
                    onSwitchToDefault()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if let onSwitchToBuiltIn {
                Button("Switch to Built-in Library") {
                    onSwitchToBuiltIn()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Open Another Backup…") {
                onOpenAnother()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .bottom
        )
    }
}

// MARK: - Main Application Shell

@main
struct MarginGraphApp: App {
    @StateObject private var model = AppModel()
    @State private var isShowingSidebarMenu = false

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HStack(spacing: 0) {
                    // Left MarginNote 3 Sidebar (shelves only, hidden inside Study Workspace)
                    if !model.isInStudyWorkspace {
                        MarginNoteSidebar(
                            selectedTab: $model.selectedMainTab,
                            isMenuPresented: $isShowingSidebarMenu,
                            isSearchActive: model.isShelfSearchPresented,
                            recentBackupPaths: model.recentDatabasePaths,
                            libraries: LibraryManager.shared.libraries,
                            isExternalDatabase: model.isExternalDatabase,
                            activeDatabaseName: model.activeDatabaseName,
                            onSearch: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    model.isShelfSearchPresented.toggle()
                                }
                            },
                            onHelp: {},
                            onOpenMarginNoteBackup: {
                                model.openMarginNoteBackupPicker()
                            },
                            onSelectRecentBackup: { path in
                                Task { @MainActor in
                                    await model.openMarginNoteBackup(at: URL(fileURLWithPath: path))
                                }
                            },
                            onSelectLibrary: { entry in
                                if entry.isBuiltIn {
                                    model.switchToDefaultDatabase()
                                } else {
                                    Task { @MainActor in
                                        await model.openMarginNoteBackup(at: URL(fileURLWithPath: entry.path))
                                    }
                                }
                            },
                            onManageLibraries: {
                                model.isShowingManageLibraries = true
                            },
                            onSwitchToDefaultDatabase: {
                                model.switchToDefaultDatabase()
                            },
                            onImportDocument: {
                                model.openDocumentPicker(attachToTopic: false)
                            }
                        )
                        .onChange(of: model.selectedMainTab) { _, _ in
                            isShowingSidebarMenu = false
                            model.flushPendingPositions()
                            model.isInStudyWorkspace = false
                            model.shelfSearchQuery = ""
                        }
                        .transition(.move(edge: .leading))
                    }

                    // Main Content View
                    VStack(spacing: 0) {
                        if model.isExternalDatabase {
                            let isCurDef = LibraryManager.shared.defaultLibrary.map {
                                LibraryManager.shared.isLibrary(entry: $0, matchesPath: model.activeDatabaseURL?.path ?? "")
                            } ?? false
                            ExternalDatabaseBannerView(
                                databaseName: model.activeDatabaseName,
                                isCurrentDefault: isCurDef,
                                onSwitchToDefault: {
                                    model.switchToDefaultDatabase()
                                },
                                onSwitchToBuiltIn: {
                                    model.switchToBuiltInDatabase()
                                },
                                onOpenAnother: {
                                    model.openMarginNoteBackupPicker()
                                },
                                onManageLibraries: {
                                    model.isShowingManageLibraries = true
                                }
                            )
                        }

                        Group {
                            if model.isInStudyWorkspace {
                                StudyWorkspaceView(model: model)
                            } else {
                                switch model.selectedMainTab {
                        case .document:
                            DocumentShelfView(
                                documents: model.documents,
                                folders: model.documentFolders,
                                topics: model.topics,
                                documentCardCounts: model.documentCardCounts,
                                isSearchPresented: $model.isShelfSearchPresented,
                                searchQuery: $model.shelfSearchQuery,
                                onOpenDocument: { doc in
                                    model.openDocumentInReader(document: doc)
                                },
                                onImportDocument: {
                                    model.openDocumentPicker(attachToTopic: false)
                                },
                                onImportURLs: { urls in model.openOrImportFiles(urls: urls) },
                                onDeleteDocument: { doc in
                                    model.deleteDocument(doc)
                                },
                                onRenameDocument: { doc, newTitle in
                                    model.renameDocument(doc, newTitle: newTitle)
                                },
                                onCreateFolder: { name, parentID in
                                    model.createFolder(name: name, parentId: parentID)
                                },
                                onRenameFolder: { id, name in
                                    model.renameFolder(id: id, newName: name)
                                },
                                onDeleteFolder: { id in
                                    model.deleteFolder(id: id)
                                },
                                onMoveDocument: { doc, folderID in
                                    model.moveDocument(doc, to: folderID)
                                },
                                onMoveFolder: { folder, parentID in
                                    model.moveFolder(folder, to: parentID)
                                },
                                onAddToStudy: { docs, topicID, newTitle in
                                    model.addDocumentsToStudy(documents: docs, targetTopicID: topicID, newTopicTitle: newTitle)
                                },
                                onExportDocumentMarginPkg: { doc in
                                    model.exportDocumentAsMarginPkg(document: doc)
                                },
                                onExportFolderMarginPkg: { folder in
                                    model.exportFolderAsMarginPkg(folder: folder)
                                },
                                onManageLibraries: {
                                    model.isShowingManageLibraries = true
                                },
                                onImportHighlights: { doc in
                                    model.importPDFHighlightsManually(for: doc)
                                }
                            )
                        case .study:
                            StudyNotebooksView(
                                topics: model.topics,
                                documents: model.documents,
                                cardCounts: model.cardCounts,
                                isSearchPresented: $model.isShelfSearchPresented,
                                searchQuery: $model.shelfSearchQuery,
                                onOpenTopic: { topic in
                                    model.enterStudyWorkspace(topic: topic)
                                },
                                onCreateTopic: {
                                    model.createTopic()
                                },
                                onDeleteTopic: { topic in
                                    model.deleteTopic(topic)
                                },
                                onRenameTopic: { topic, newTitle in
                                    model.renameTopic(topic, newTitle: newTitle)
                                }
                            )
                        case .review:
                            ReviewDecksView(
                                decks: model.reviewDecks,
                                isSearchPresented: $model.isShelfSearchPresented,
                                searchQuery: $model.shelfSearchQuery,
                                onStartReview: { deck in
                                    model.startReviewForDeck(deck)
                                },
                                onDeleteDeck: { deck in
                                    model.deleteDeck(deck)
                                }
                            )
                        case .reference:
                            ReferencePage(workspace: model.referenceWorkspace, model: model, search: $model.shelfSearchQuery)
                        }
                    }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if model.isOpeningDatabase || model.isImportingMarginNote || model.isExportingDocument || model.isExportingOrg || model.isReplacingPDF {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text(model.isReplacingPDF ? "Replacing PDF…" :
                                 model.isExportingOrg ? "Preparing literature note…" :
                                 model.isExportingDocument ? "Exporting PDF and notes…" :
                                 model.isImportingMarginNote ? "Importing MarginNote notes…" :
                                 (model.databaseOpeningStatus.isEmpty ? "Opening library..." : model.databaseOpeningStatus))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .padding(28)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(white: 0.15).opacity(0.94))
                                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 6)
                        )
                    }
                    .zIndex(999)
                }

                // In-window floating popup menu for sidebar ellipsis button (guaranteed inside window boundary)
                if isShowingSidebarMenu && !model.isInStudyWorkspace {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.12)) {
                                isShowingSidebarMenu = false
                            }
                        }

                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 0) {
                            SidebarActionCardView(
                                onOpenMarginNoteBackup: {
                                    isShowingSidebarMenu = false
                                    DispatchQueue.main.async {
                                        model.openMarginNoteBackupPicker()
                                    }
                                },
                                recentBackupPaths: model.recentDatabasePaths,
                                isExternalDatabase: model.isExternalDatabase,
                                activeDatabaseName: model.activeDatabaseName,
                                onSelectRecentBackup: { path in
                                    isShowingSidebarMenu = false
                                    Task { @MainActor in
                                        await model.openMarginNoteBackup(at: URL(fileURLWithPath: path))
                                    }
                                },
                                onSwitchToDefaultDatabase: {
                                    isShowingSidebarMenu = false
                                    model.switchToDefaultDatabase()
                                },
                                onImportDocument: {
                                    isShowingSidebarMenu = false
                                    model.openDocumentPicker(attachToTopic: false)
                                },
                                onCreateFolder: nil,
                                onHelp: {
                                    isShowingSidebarMenu = false
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        isShowingSidebarMenu = false
                                    }
                                }
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(NSColor.windowBackgroundColor))
                                    .shadow(color: Color.black.opacity(0.24), radius: 14, x: 2, y: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                            )
                            .padding(.leading, MarginNoteTheme.sidebarWidth + 6)
                            .padding(.bottom, 16)

                            Spacer()
                        }
                    }
                    .zIndex(600)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    .onExitCommand {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isShowingSidebarMenu = false
                        }
                    }
                }
            }
            .frame(minWidth: 1050, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity)
            .preferredColorScheme(.light)
            .alert("Database Error", isPresented: Binding(
                get: { model.databaseErrorMessage != nil },
                set: { if !$0 { model.databaseErrorMessage = nil } }
            )) {
                Button("OK") { model.databaseErrorMessage = nil }
            } message: {
                Text(model.databaseErrorMessage ?? "")
            }
            .navigationTitle("MarginGraph" + (model.isExternalDatabase ? " — \(model.activeDatabaseName) [External Backup]" : ""))
            .sheet(isPresented: $model.isShowingManageLibraries) {
                LibraryManagementView(model: model)
            }
            .sheet(isPresented: $model.isReviewPresented) {
                FlashcardReviewView(
                    cards: model.activeReviewCards.isEmpty ? (model.dueFlashcards.isEmpty ? model.mindMapCards : model.dueFlashcards) : model.activeReviewCards,
                    documents: model.activeReviewDocuments.isEmpty ? model.studyDocuments : model.activeReviewDocuments,
                    database: model.database,
                    mediaStorage: model.mediaStorage,
                    onJumpToPDF: { card in
                        model.jumpToPDFFromReview(card: card)
                    },
                    onDismiss: {
                        model.isReviewPresented = false
                        model.reloadLibrary()
                        model.reloadStudySet()
                    }
                )
            }
            .onOpenURL { url in
                if url.isFileURL {
                    model.openOrImportFiles(urls: [url])
                } else {
                    model.handleDeepLink(url)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                        if let screen = window.screen ?? NSScreen.main {
                            let screenRect = screen.visibleFrame
                            let targetWidth = min(1440, screenRect.width * 0.92)
                            let targetHeight = min(920, screenRect.height * 0.90)
                            if window.frame.width < 1250 || window.frame.height < 780 {
                                let x = screenRect.midX - targetWidth / 2
                                let y = screenRect.midY - targetHeight / 2
                                window.setFrame(NSRect(x: x, y: y, width: targetWidth, height: targetHeight), display: true, animate: false)
                            }
                        }
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Document…") {
                    model.openDocumentPicker(attachToTopic: false)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open MarginNote Database or Backup…") {
                    model.openMarginNoteBackupPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                let isAlreadyInDefault = model.isExternalDatabase
                    ? (LibraryManager.shared.defaultLibrary != nil && LibraryManager.shared.isLibrary(entry: LibraryManager.shared.defaultLibrary!, matchesPath: model.activeDatabaseURL?.path ?? ""))
                    : (LibraryManager.shared.defaultLibrary?.isBuiltIn ?? true)

                Button("Switch to Default Library") {
                    model.switchToDefaultDatabase()
                }
                .disabled(isAlreadyInDefault)

                Divider()

                Button("Manage Libraries…") {
                    model.isShowingManageLibraries = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                if !model.recentDatabasePaths.isEmpty {
                    Menu("Open Recent Library") {
                        ForEach(model.recentDatabasePaths, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                Task { @MainActor in
                                    await model.openMarginNoteBackup(at: URL(fileURLWithPath: path))
                                }
                            }
                        }
                    }
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
                    if let editor = responder as? NSTextView,
                       let um = editor.undoManager,
                       um !== model.undoManager,
                       um.canUndo {
                        um.undo()
                        editor.didChangeText()
                    } else if model.canUndo {
                        model.undo()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
                    if let editor = responder as? NSTextView,
                       let um = editor.undoManager,
                       um !== model.undoManager,
                       um.canRedo {
                        um.redo()
                        editor.didChangeText()
                    } else if model.canRedo {
                        model.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Button("Document Only (1-View)") {
                    model.workspaceMode = .readerOnly
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Split View (2-View)") {
                    model.workspaceMode = .splitView
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Three View (3-View)") {
                    model.workspaceMode = .threeView
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("MindMap Only") {
                    model.workspaceMode = .mindMapOnly
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button(model.isOutlineVisible ? "Hide Outline" : "Show Outline") {
                    model.isOutlineVisible.toggle()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .marginGraphZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .marginGraphZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .marginGraphZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Go") {
                Button("Go to Page...") {
                    NotificationCenter.default.post(name: .marginGraphGoToPage, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
            }

            CommandMenu("Find") {
                Button("Find in MindMap") {
                    model.toggleMindMapSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
