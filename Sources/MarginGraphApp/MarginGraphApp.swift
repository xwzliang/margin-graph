import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
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
    @Published var selectedMainTab: MainNavigationTab = .study
    @Published var isInStudyWorkspace: Bool = false
    @Published var isOutlineVisible: Bool = false
    @Published var workspaceMode: WorkspaceViewMode = .splitView

    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    @Published var selectedTopicID: UUID?
    @Published var studyDocuments: [Document] = []
    @Published var activeDocument: Document?
    @Published var manager: PDFDocumentManager?
    @Published var documentCards: [NoteCard] = []
    @Published var mindMapCards: [NoteCard] = []
    @Published var links: [CardLink] = []
    @Published var selectedCardID: UUID?
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
    @Published var editingCard: NoteCard? = nil
    @Published var editingCardTitleID: UUID? = nil
    @Published var documentBookmarks: Set<Int> = []
    @Published var isManagingDocuments = false
    @Published var documentCurrentPage: [String: Int] = [:]

    let database: Database
    let mediaStorage: MediaStorage
    let undoManager = UndoManager()

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
        try? database.syncAvailableDocuments()
        autoImportLiveMarginNoteIfEmpty()
        reloadLibrary()
        if let ahrens = topics.first(where: { $0.title.contains("Ahrens") }) {
            selectedTopicID = ahrens.id
        } else if selectedTopicID == nil {
            selectedTopicID = topics.first?.id
        }
        reloadStudySet()
        if selectedTopicID != nil {
            isInStudyWorkspace = true
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
    }

    var selectedTopic: Topic? {
        topics.first(where: { $0.id == selectedTopicID })
    }

    var activePDFCards: [NoteCard] {
        var cardMap = [UUID: NoteCard]()
        for card in mindMapCards {
            cardMap[card.id] = card
        }
        for card in documentCards {
            cardMap[card.id] = card
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

    func reloadLibrary() {
        topics = (try? database.allTopics()) ?? []
        documents = (try? database.allDocuments()) ?? []
        customDecks = (try? database.allDecks()) ?? []
        deckCardCounts = (try? database.deckCardCounts()) ?? [:]
        dueDeckCounts = (try? database.dueDeckCardCounts()) ?? [:]

        let counts = (try? database.cardCountsByTopic()) ?? [:]
        let dueCounts = (try? database.dueCardCountsByTopic()) ?? [:]

        var decks: [ReviewDeckItem] = []
        decks.reserveCapacity(customDecks.count + topics.count)

        // 1. Custom Card Decks (only show decks with at least 1 card)
        for deck in customDecks {
            let total = deckCardCounts[deck.id] ?? 0
            guard total > 0 else { continue }
            let due = dueDeckCounts[deck.id] ?? 0
            decks.append(ReviewDeckItem(
                id: deck.id,
                title: deck.title,
                dueCount: due,
                totalCount: total,
                topicId: nil,
                deckId: deck.id
            ))
        }

        // 2. Topic Study Sets (only show decks with at least 1 card)
        let customDeckIDs = Set(customDecks.map(\.id))
        for topic in topics {
            guard !customDeckIDs.contains(topic.id) else { continue }
            let total = counts[topic.id] ?? 0
            guard total > 0 else { continue }
            let due = dueCounts[topic.id] ?? 0
            decks.append(ReviewDeckItem(
                id: topic.id,
                title: topic.title,
                dueCount: due,
                totalCount: total,
                topicId: topic.id
            ))
        }

        cardCounts = counts
        reviewDecks = decks

        if selectedTopicID == nil || !topics.contains(where: { $0.id == selectedTopicID }) {
            selectedTopicID = topics.first?.id
        }
    }

    func selectTopic(_ topic: Topic) {
        selectedTopicID = topic.id
        selectedCardID = nil
        activeToolbarOwner = .none
        jumpTarget = nil
        reloadStudySet()
    }

    func enterStudyWorkspace(topic: Topic) {
        selectTopic(topic)
        workspaceMode = .splitView
        isInStudyWorkspace = true
    }

    func exitStudyWorkspace() {
        isInStudyWorkspace = false
    }

    func openDocumentInReader(document: Document) {
        let cleanDocTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let docFileName = URL(fileURLWithPath: document.filePath).deletingPathExtension().lastPathComponent

        // 1. Direct match on topic.bookMD5List
        var matchingTopic = topics.first(where: { topic in
            topic.bookMD5List.contains { bmd5 in
                bmd5 == document.md5 || bmd5.hasPrefix(document.md5) || document.md5.hasPrefix(bmd5)
            }
        })

        // 2. Match on cards' bookMD5 in the topic
        if matchingTopic == nil {
            matchingTopic = topics.first(where: { topic in
                let cards = (try? database.cardsForTopic(id: topic.id)) ?? []
                return cards.contains {
                    guard let bmd5 = $0.bookMD5 else { return false }
                    return bmd5 == document.md5 || bmd5.hasPrefix(document.md5) || document.md5.hasPrefix(bmd5)
                }
            })
        }

        // 3. Match on topic title vs document title or document filename
        if matchingTopic == nil {
            matchingTopic = topics.first(where: { topic in
                let cleanTopicTitle = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanTopicTitle.localizedCaseInsensitiveCompare(cleanDocTitle) == .orderedSame ||
                       cleanTopicTitle.localizedCaseInsensitiveCompare(docFileName) == .orderedSame ||
                       cleanTopicTitle.localizedCaseInsensitiveContains(docFileName) ||
                       docFileName.localizedCaseInsensitiveContains(cleanTopicTitle) ||
                       cleanTopicTitle.localizedCaseInsensitiveContains(cleanDocTitle) ||
                       cleanDocTitle.localizedCaseInsensitiveContains(cleanTopicTitle)
            })
        }

        if let matchingTopic {
            if !matchingTopic.bookMD5List.contains(document.md5) {
                try? database.addDocument(to: matchingTopic.id, md5: document.md5)
                reloadLibrary()
            }
            selectedTopicID = matchingTopic.id
            reloadStudySet()
        } else {
            let newTopic = Topic(title: document.title, bookMD5List: [document.md5])
            try? database.insertTopic(newTopic)
            reloadLibrary()
            selectedTopicID = newTopic.id
            reloadStudySet()
        }
        switchToDocument(document)
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
        // Detach and clean up topic
        reloadLibrary()
    }

    func deleteDocument(_ document: Document) {
        try? database.deleteDocument(id: document.id)
        reloadLibrary()
    }

    func reloadStudySet() {
        guard let topicID = selectedTopicID else {
            studyDocuments = []
            mindMapCards = []
            links = []
            dueFlashcards = []
            return
        }
        studyDocuments = (try? database.documentsForTopic(id: topicID)) ?? []
        mindMapCards = (try? database.cardsForTopic(id: topicID)) ?? []
        links = (try? database.linksForTopic(id: topicID)) ?? []
        dueFlashcards = (try? database.dueCardsForTopic(id: topicID)) ?? []

        if let activeDocument, studyDocuments.contains(where: { $0.md5 == activeDocument.md5 }) {
            reloadDocumentCards()
        } else if let first = studyDocuments.first {
            switchToDocument(first)
        } else {
            activeDocument = nil
            manager = nil
            documentCards = []
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
        let panel = NSOpenPanel()
        let marginpkgType = UTType(filenameExtension: "marginpkg")
        let marginnotesType = UTType(filenameExtension: "marginnotes")
        let sqliteType = UTType(filenameExtension: "sqlite")
        panel.allowedContentTypes = [UTType.pdf, marginpkgType, marginnotesType, sqliteType].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openOrImportFile(url: url, attachToTopic: attachToTopic)
        }
    }

    func openOrImportFile(url: URL, attachToTopic: Bool = false) {
        let ext = url.pathExtension.lowercased()
        if ext == "marginpkg" || ext == "marginnotes" || ext == "sqlite" {
            importMarginNoteOrPackage(url: url)
        } else {
            openPDF(url: url, attachToTopic: attachToTopic)
        }
    }

    func importMarginNoteOrPackage(url: URL) {
        let importer = MarginNoteImporter(url: url)
        do {
            let result = try importer.importInto(database) { [weak self] existing, imported in
                guard let self else { return .cancel }
                return self.promptNotebookConflict(existing: existing, imported: imported)
            }
            guard let result else {
                print("Import cancelled by user.")
                return
            }

            try? database.syncAvailableDocuments()
            reloadLibrary()
            reloadStudySet()

            if let firstDoc = result.documents.first {
                openDocumentInReader(document: firstDoc)
            } else if let firstTopic = result.topics.first {
                enterStudyWorkspace(topic: firstTopic)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func openPDFPicker(attachToTopic: Bool = true) {
        openDocumentPicker(attachToTopic: attachToTopic)
    }

    func openPDF(url: URL, attachToTopic: Bool = true) {
        guard let manager = try? PDFDocumentManager(url: url) else { return }
        let existing = try? database.getDocumentByMD5(md5: manager.md5)
        let document = existing ?? Document(
            id: Document.stableUUID(manager.md5),
            title: manager.title,
            filePath: url.path,
            md5: manager.md5,
            totalPages: manager.pageCount,
            lastVisited: Date()
        )
        try? database.insertDocument(document)

        if attachToTopic, let topicID = selectedTopicID {
            try? database.addDocument(to: topicID, md5: document.md5)
        }

        reloadLibrary()
        reloadStudySet()
        switchToDocument(document)
    }

    func switchToDocument(_ document: Document) {
        guard let loaded = try? PDFDocumentManager(url: URL(fileURLWithPath: document.filePath), md5: document.md5) else { return }
        activeDocument = document
        manager = loaded
        loadBookmarks()
        reloadDocumentCards()
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
        segments.removeAll(where: { $0.id == segmentID })
        if segments.isEmpty {
            delete(cardID: cardID)
            return
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

    func navigateToCard(_ card: NoteCard) {
        if let md5 = card.bookMD5,
           let document = studyDocuments.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) }) ?? documents.first(where: { $0.md5 == md5 || md5.hasPrefix($0.md5) || $0.md5.hasPrefix(md5) }),
           activeDocument?.md5 != document.md5 {
            switchToDocument(document)
        }

        let targetPage: Int
        if let sp = card.startPage {
            targetPage = sp
        } else if let hp = card.highlightRects.first?.page {
            targetPage = hp
        } else {
            return
        }

        let bounds: CGRect
        let pageLines = card.highlightRects.filter { $0.page == targetPage }
        if let first = pageLines.first {
            bounds = pageLines.dropFirst().reduce(
                CGRect(x: first.x, y: first.y, width: first.width, height: first.height)
            ) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        } else if let firstLine = card.highlightRects.first {
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
        }
        try? database.deleteCard(id: cardID)
        if selectedCardID == cardID {
            selectedCardID = nil
            activeToolbarOwner = .none
        }
        reloadStudySet()
        objectWillChange.send()
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

        let allCardsInTopic = (try? database.cardsForTopic(id: parent.topicId)) ?? mindMapCards
        let existingChildren = allCardsInTopic
            .filter { $0.groupNoteId == parentID }
            .sorted(by: TreeLayout.cardOrder)

        var targetMindPos: CGPoint? = nil
        var targetCreatedAt = Date()
        if let lastChild = existingChildren.last {
            if let ly = lastChild.mindPos?.y {
                targetMindPos = CGPoint(x: lastChild.mindPos?.x ?? 0, y: ly + 100)
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

        let allCardsInTopic = (try? database.cardsForTopic(id: sibling.topicId)) ?? mindMapCards
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
                    targetMindPos = CGPoint(x: sibling.mindPos?.x ?? 0, y: sy + 100)
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
        let topic = ensureTopic()
        var newCard = NoteCard(
            topicId: topic.id,
            title: "",
            groupNoteId: nil,
            colorIndex: 0
        )
        newCard.mindPos = canvasPos
        newCard.createdAt = Date()

        try? database.insertCard(newCard)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.delete(cardID: newCard.id)
            }
        }
        undoManager.setActionName("Create Note")
        selectedCardID = newCard.id
        editingCardTitleID = newCard.id
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
        let panel = NSOpenPanel()
        let marginpkgType = UTType(filenameExtension: "marginpkg")
        let marginnotesType = UTType(filenameExtension: "marginnotes")
        let sqliteType = UTType(filenameExtension: "sqlite")
        panel.allowedContentTypes = [marginpkgType, marginnotesType, sqliteType].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        var sourceURL: URL?
        if panel.runModal() == .OK, let selected = panel.url {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
            sourceURL = isDirectory.boolValue
                ? selected.appendingPathComponent("MarginNotes.sqlite")
                : selected
        } else {
            let standard = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/QReader.MarginStudyMac/Data/Library/Application Support/QReader.MarginNoteMac/MarginNotes.sqlite")
            if FileManager.default.fileExists(atPath: standard.path) {
                sourceURL = standard
            }
        }

        guard let sourceURL else { return }
        importMarginNoteOrPackage(url: sourceURL)
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
        activeReviewCards = dueFlashcards
        activeReviewDocuments = studyDocuments
        isReviewPresented = true
    }

    func startReviewForDeck(_ deck: ReviewDeckItem) {
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

    func handleDeepLink(_ url: URL) {
        guard let destination = DeepLinkHandler.parse(url) else { return }

        switch destination {
        case .openTopic(let topicId):
            guard let topic = topics.first(where: { $0.id == topicId }) else { return }
            enterStudyWorkspace(topic: topic)

        case .openCard(let cardId):
            guard let card = try? database.getCard(id: cardId) else { return }
            if selectedTopicID != card.topicId,
               let topic = topics.first(where: { $0.id == card.topicId }) {
                selectTopic(topic)
            }
            reloadStudySet()
            isInStudyWorkspace = true
            select(card: card)
        }
    }

    private func saveExport(content: String, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
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
        documentCards = (try? database.cardsForDocument(md5: md5)) ?? []
    }
}

// MARK: - Study Workspace Views

struct StudyWorkspaceHeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
                // Back button (<) to Library
                Button {
                    model.exitStudyWorkspace()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .enlargedHitTarget(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .marginNoteTooltip("Back to Notebooks")

                // Undo / Redo
                HStack(spacing: 2) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12))
                            .foregroundStyle(model.canUndo ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 24)
                            .enlargedHitTarget(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canUndo)
                    .marginNoteTooltip("Undo (⌘Z)")

                    Button {
                        model.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 12))
                            .foregroundStyle(model.canRedo ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 24)
                            .enlargedHitTarget(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canRedo)
                    .marginNoteTooltip("Redo (⇧⌘Z)")
                }

                // Outline Toggle
                Button {
                    model.isOutlineVisible.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13, weight: model.isOutlineVisible ? .bold : .regular))
                        .foregroundStyle(model.isOutlineVisible ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.isOutlineVisible ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.15) : Color.clear)
                        )
                        .enlargedHitTarget(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .marginNoteTooltip("Toggle Outline")

                // Card Notes List / Editor Toggle
                Button {
                    if let selectedID = model.selectedCardID,
                       let card = model.mindMapCards.first(where: { $0.id == selectedID }) {
                        model.editingCard = card
                    } else if let first = model.mindMapCards.first {
                        model.editingCard = first
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 26, height: 26)
                        .enlargedHitTarget(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .marginNoteTooltip("Edit Card")

                // Export / Share Menu
                Menu {
                    Button("Export to Markdown…") { model.exportMarkdown() }
                    Button("Export to OPML…") { model.exportOPML() }
                    Button("Export to Anki (TSV)…") { model.exportAnki() }
                    Divider()
                    Button("Import MarginNote 3…") { model.importMarginNote() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .enlargedHitTarget(width: 34, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 32)
                .marginNoteTooltip("Share / Export")

                Spacer()

                // More Options Menu (...)
                Menu {
                    Menu("View Mode") {
                        Button(model.workspaceMode == .readerOnly ? "✓ Document Only (1-View)" : "Document Only (1-View)") {
                            model.workspaceMode = .readerOnly
                        }
                        Button(model.workspaceMode == .splitView ? "✓ Split View (2-View)" : "Split View (2-View)") {
                            model.workspaceMode = .splitView
                        }
                        Button(model.workspaceMode == .threeView ? "✓ Three View (3-View)" : "Three View (3-View)") {
                            model.workspaceMode = .threeView
                        }
                        Button(model.workspaceMode == .mindMapOnly ? "✓ MindMap Only" : "MindMap Only") {
                            model.workspaceMode = .mindMapOnly
                        }
                    }
                    Divider()
                    Button("Review Flashcards") { model.startReview() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .enlargedHitTarget(width: 34, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 32)
                .marginNoteTooltip("Notebook Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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
}

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
                Button("Open New PDF…") {
                    model.openPDFPicker(attachToTopic: true)
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
                activeDocument: model.activeDocument,
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onDetachDocument: { doc in
                    model.detachDocument(doc)
                },
                onAddDocument: {
                    model.openPDFPicker(attachToTopic: true)
                },
                onDismiss: {
                    model.isManagingDocuments = false
                }
            )
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
            .marginNoteTooltip("Back to Notebooks")

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
        .padding(.vertical, 7)
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
        VStack(spacing: 0) {
            StudyWorkspaceHeaderView(model: model)
            MindMapCanvasView(
                cards: model.mindMapCards,
                links: model.links,
                selectedCardID: model.selectedCardID,
                editingCardTitleID: $model.editingCardTitleID,
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
                }
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
            MarginNotePDFContainerView(
                manager: manager,
                cards: model.activePDFCards,
                selectedCardID: model.selectedCardID,
                activeToolbarOwner: model.activeToolbarOwner,
                jumpTarget: model.jumpTarget,
                studyDocuments: model.studyDocuments,
                activeDocument: model.activeDocument,
                bookmarks: model.documentBookmarks,
                initialPageIndex: model.documentCurrentPage[manager.md5] ?? 0,
                onPageChanged: { [weak model] page in
                    model?.documentCurrentPage[manager.md5] = page
                },
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onManageDocuments: {
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
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No PDF Document Attached")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("Attach PDF…") {
                    model.openPDFPicker(attachToTopic: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        }
    }
}

// MARK: - Main Application Shell

@main
struct MarginGraphApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HStack(spacing: 0) {
                // Left MarginNote 3 Sidebar (shelves only, hidden inside Study Workspace)
                if !model.isInStudyWorkspace {
                    MarginNoteSidebar(
                        selectedTab: $model.selectedMainTab,
                        onSearch: {},
                        onHelp: {},
                        onSettings: {
                            model.importMarginNote()
                        }
                    )
                    .onChange(of: model.selectedMainTab) { _, _ in
                        model.isInStudyWorkspace = false
                    }
                    .transition(.move(edge: .leading))
                }

                // Main Content View
                Group {
                    if model.isInStudyWorkspace {
                        StudyWorkspaceView(model: model)
                    } else {
                        switch model.selectedMainTab {
                        case .document:
                            DocumentShelfView(
                                documents: model.documents,
                                onOpenDocument: { doc in
                                    model.openDocumentInReader(document: doc)
                                },
                                onImportDocument: {
                                    model.openDocumentPicker(attachToTopic: false)
                                },
                                onDeleteDocument: { doc in
                                    model.deleteDocument(doc)
                                }
                            )
                        case .study:
                            StudyNotebooksView(
                                topics: model.topics,
                                documents: model.documents,
                                cardCounts: model.cardCounts,
                                onOpenTopic: { topic in
                                    model.enterStudyWorkspace(topic: topic)
                                },
                                onCreateTopic: {
                                    model.createTopic()
                                },
                                onDeleteTopic: { topic in
                                    model.deleteTopic(topic)
                                }
                            )
                        case .review:
                            ReviewDecksView(
                                decks: model.reviewDecks,
                                onStartReview: { deck in
                                    model.startReviewForDeck(deck)
                                },
                                onDeleteDeck: { deck in
                                    model.deleteDeck(deck)
                                }
                            )
                        }
                    }
                }
            }
            .frame(minWidth: 1050, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity)
            .preferredColorScheme(.light)
            .sheet(isPresented: $model.isReviewPresented) {
                FlashcardReviewView(
                    cards: model.activeReviewCards.isEmpty ? (model.dueFlashcards.isEmpty ? model.mindMapCards : model.dueFlashcards) : model.activeReviewCards,
                    documents: model.activeReviewDocuments.isEmpty ? model.studyDocuments : model.activeReviewDocuments,
                    database: model.database,
                    mediaStorage: model.mediaStorage,
                    onJumpToPDF: { card in
                        model.isReviewPresented = false
                        model.isInStudyWorkspace = true
                        model.select(card: card)
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
                    let ext = url.pathExtension.lowercased()
                    if ext == "marginpkg" || ext == "marginnotes" || ext == "sqlite" {
                        model.importMarginNoteOrPackage(url: url)
                    } else if ext == "pdf" {
                        model.openPDF(url: url, attachToTopic: false)
                    }
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
                Button("Open…") {
                    model.openDocumentPicker(attachToTopic: false)
                }
                .keyboardShortcut("o", modifiers: .command)
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
        }
    }
}
