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
    @Published var isReviewPresented = false
    @Published var editingCard: NoteCard? = nil

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
        autoImportLiveMarginNoteIfEmpty()
        reloadLibrary()
        if selectedTopicID == nil {
            selectedTopicID = topics.first?.id
        }
        reloadStudySet()

        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
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
        let existingDocs = (try? database.allDocuments()) ?? []
        let ahrensTopic = existingTopics.first(where: { $0.title.contains("Ahrens") })
        let ahrensCards = (try? database.cardsForTopic(id: ahrensTopic?.id ?? UUID())) ?? []
        let hasHighlightRects = ahrensCards.contains { !$0.highlightRects.isEmpty }
        let existingCards = existingTopics.flatMap { (try? database.cardsForTopic(id: $0.id)) ?? [] }
        let colorsNeedRefresh = !existingCards.isEmpty && existingCards.allSatisfy { $0.colorIndex == 0 }
        let needsImport = existingTopics.isEmpty || !hasHighlightRects || colorsNeedRefresh || existingDocs.contains(where: { $0.filePath.isEmpty })
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

        var counts: [UUID: Int] = [:]
        var decks: [ReviewDeckItem] = []

        for topic in topics {
            let cards = (try? database.cardsForTopic(id: topic.id)) ?? []
            counts[topic.id] = cards.count
            let due = (try? database.dueCardsForTopic(id: topic.id)) ?? []
            decks.append(ReviewDeckItem(
                id: topic.id,
                title: topic.title,
                dueCount: due.count,
                totalCount: cards.count,
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
        if let matchingTopic = topics.first(where: { topic in
            topic.bookMD5List.contains { bmd5 in
                bmd5 == document.md5 || bmd5.hasPrefix(document.md5) || document.md5.hasPrefix(bmd5)
            }
        }) {
            selectedTopicID = matchingTopic.id
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

    func openPDFPicker(attachToTopic: Bool = true) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPDF(url: url, attachToTopic: attachToTopic)
    }

    func openPDF(url: URL, attachToTopic: Bool = true) {
        guard let manager = try? PDFDocumentManager(url: url) else { return }
        let existing = try? database.getDocumentByMD5(md5: manager.md5)
        let document = existing ?? Document(
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
        reloadDocumentCards()
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
        activeToolbarOwner = .pdf
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

        var rectsToRemove = rects
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

        guard let page = card.startPage else { return }
        let bounds: CGRect
        if let firstLine = card.highlightRects.first {
            let pageLines = card.highlightRects.filter { $0.page == page }
            if let first = pageLines.first {
                bounds = pageLines.dropFirst().reduce(
                    CGRect(x: first.x, y: first.y, width: first.width, height: first.height)
                ) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
            } else {
                bounds = CGRect(x: firstLine.x, y: firstLine.y, width: firstLine.width, height: firstLine.height)
            }
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
        jumpTarget = PDFJumpTarget(pageIndex: page, bounds: bounds)
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

    func reparent(cardID: UUID, to parentID: UUID?) {
        try? database.reparentCard(id: cardID, to: parentID)
        reloadStudySet()
        objectWillChange.send()
    }

    func toggleFold(cardID: UUID, folded: Bool) {
        try? database.setCardFolded(id: cardID, folded: folded)
        reloadStudySet()
    }

    func indent(cardID: UUID, under siblingID: UUID) {
        try? database.indentCard(id: cardID, under: siblingID)
        reloadStudySet()
        objectWillChange.send()
    }

    func outdent(cardID: UUID) {
        try? database.outdentCard(id: cardID)
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

    func reorder(cardID: UUID, before siblingID: UUID?) {
        try? database.reorderCard(id: cardID, before: siblingID)
        reloadStudySet()
    }

    func importMarginNote() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["sqlite"]
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

        guard let sourceURL,
              let result = try? MarginNoteImporter(url: sourceURL).importInto(database) else { return }

        reloadLibrary()
        if let first = result.topics.first {
            selectedTopicID = first.id
        }
        reloadStudySet()
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
        isReviewPresented = true
    }

    func startReviewForDeck(_ deck: ReviewDeckItem) {
        if let topicId = deck.topicId,
           let topic = topics.first(where: { $0.id == topicId }) {
            selectTopic(topic)
        }
        isReviewPresented = true
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
        VStack(spacing: 0) {
            // Row 1: Study Tools (symmetrical with PDF tools row)
            HStack(spacing: 12) {
                // Back button (<) to Library
                Button {
                    model.exitStudyWorkspace()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Back to Notebooks")

                // Undo / Redo
                HStack(spacing: 2) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12))
                            .foregroundStyle(model.canUndo ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")

                    Button {
                        model.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 12))
                            .foregroundStyle(model.canRedo ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
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
                }
                .buttonStyle(.plain)
                .help("Toggle Outline")

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
                }
                .buttonStyle(.plain)
                .help("Edit Card")

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
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Share / Export")

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
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Notebook Settings")

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
        }
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

    var body: some View {
        Group {
            switch model.workspaceMode {
            case .readerOnly:
                VStack(spacing: 0) {
                    readerOnlyHeader
                    pdfPane
                }
            case .mindMapOnly:
                mindMapPane
            case .splitView:
                ZStack {
                    if model.isOutlineVisible {
                        HSplitView {
                            outlinePane
                                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                            mindMapPane
                                .frame(minWidth: 340)
                            pdfPane
                                .frame(minWidth: 380)
                        }
                    } else {
                        HSplitView {
                            mindMapPane
                                .frame(minWidth: 360)
                            pdfPane
                                .frame(minWidth: 400)
                        }
                    }

                    // Circular < > split view divider handle (MarginNote 3 signature)
                    HStack(spacing: 0) {
                        Button {
                            if model.workspaceMode == .splitView {
                                model.workspaceMode = .readerOnly
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color(white: 0.35))
                                .frame(width: 14, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Collapse MindMap (1-View)")

                        Divider()
                            .frame(height: 12)

                        Button {
                            if model.workspaceMode == .splitView {
                                model.workspaceMode = .mindMapOnly
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color(white: 0.35))
                                .frame(width: 14, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Collapse Document (MindMap Only)")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.98))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .overlay(Capsule().stroke(Color(white: 0.82), lineWidth: 0.75))
                    )
                }
            case .threeView:
                HSplitView {
                    outlinePane
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
                    mindMapPane
                        .frame(minWidth: 340)
                    pdfPane
                        .frame(minWidth: 380)
                }
            }
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
            }
            .buttonStyle(.plain)
            .help("Back to Library")

            Button {
                model.workspaceMode = .splitView
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Restore Split View")

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
    }

    private var mindMapPane: some View {
        VStack(spacing: 0) {
            StudyWorkspaceHeaderView(model: model)
            MindMapCanvasView(
                cards: model.mindMapCards,
                links: model.links,
                selectedCardID: model.selectedCardID,
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
                onSwitchDocument: { doc in
                    model.switchToDocument(doc)
                },
                onManageDocuments: {
                    model.openPDFPicker(attachToTopic: true)
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
                                    model.openPDFPicker(attachToTopic: false)
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
                                }
                            )
                        }
                    }
                }
            }
            .frame(minWidth: 1000, minHeight: 650)
            .preferredColorScheme(.light)
            .sheet(isPresented: $model.isReviewPresented) {
                FlashcardReviewView(
                    cards: model.dueFlashcards.isEmpty ? model.mindMapCards : model.dueFlashcards,
                    documents: model.studyDocuments,
                    database: model.database,
                    mediaStorage: model.mediaStorage,
                    onJumpToPDF: { card in
                        model.isReviewPresented = false
                        model.isInStudyWorkspace = true
                        model.select(card: card)
                    },
                    onDismiss: {
                        model.isReviewPresented = false
                        model.reloadStudySet()
                    }
                )
            }
            .onOpenURL { url in
                model.handleDeepLink(url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                Button("Redo") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
        }
    }
}
