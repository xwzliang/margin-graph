import XCTest
import CoreGraphics
import SwiftUI
@testable import MarginGraphCore

final class MindMapTests: XCTestCase {
    func testTreeLayoutPlacesChildrenToRightWithoutOverlap() {
        let topic = UUID()
        let root = NoteCard(id: UUID(), topicId: topic, title: "Root")
        let childA = NoteCard(id: UUID(), topicId: topic, title: "A", groupNoteId: root.id)
        let childB = NoteCard(id: UUID(), topicId: topic, title: "B", groupNoteId: root.id)
        let grandchild = NoteCard(id: UUID(), topicId: topic, title: "A1", groupNoteId: childA.id)

        let result = TreeLayout.layout(cards: [root, childA, childB, grandchild])

        let rootFrame = try! XCTUnwrap(result.frames[root.id])
        let childAFrame = try! XCTUnwrap(result.frames[childA.id])
        let childBFrame = try! XCTUnwrap(result.frames[childB.id])
        let grandchildFrame = try! XCTUnwrap(result.frames[grandchild.id])

        XCTAssertGreaterThan(childAFrame.minX, rootFrame.maxX)
        XCTAssertGreaterThan(grandchildFrame.minX, childAFrame.maxX)
        XCTAssertFalse(childAFrame.intersects(childBFrame))
        XCTAssertEqual(result.visibleCardIDs.count, 4)
        XCTAssertNotNil(result.connectorPath(parentID: root.id, childID: childA.id))
    }

    func testFoldedBranchHidesDescendants() {
        let topic = UUID()
        let root = NoteCard(id: UUID(), topicId: topic, title: "Root", isFolded: true)
        let child = NoteCard(id: UUID(), topicId: topic, title: "Child", groupNoteId: root.id)
        let grandchild = NoteCard(id: UUID(), topicId: topic, title: "Grandchild", groupNoteId: child.id)

        let result = TreeLayout.layout(cards: [root, child, grandchild])

        XCTAssertNotNil(result.frames[root.id])
        XCTAssertNil(result.frames[child.id])
        XCTAssertNil(result.frames[grandchild.id])
        XCTAssertEqual(result.visibleCardIDs, Set([root.id]))
    }

    func testViewportRoundTripAndZoomToFit() {
        var viewport = CanvasViewport(
            panOffset: CGPoint(x: 35, y: -18),
            zoomScale: 1.7,
            viewportSize: CGSize(width: 1000, height: 700)
        )

        let canvas = CGPoint(x: 123.5, y: 98.25)
        let screen = viewport.canvasToScreen(canvas)
        let roundTrip = viewport.screenToCanvas(screen)

        XCTAssertEqual(roundTrip.x, canvas.x, accuracy: 0.0001)
        XCTAssertEqual(roundTrip.y, canvas.y, accuracy: 0.0001)

        viewport.zoomToFit(nodes: [
            CGRect(x: 0, y: 0, width: 200, height: 100),
            CGRect(x: 500, y: 300, width: 200, height: 100)
        ])

        XCTAssertGreaterThanOrEqual(viewport.zoomScale, 0.1)
        XCTAssertLessThanOrEqual(viewport.zoomScale, 3.0)
    }

    func testLayoutAspectRatioInspection() throws {
        let db = try Database()
        let topics = try db.allTopics()
        if let topic = topics.first(where: { $0.title.contains("Ahrens") }) {
            let cards = try db.cardsForTopic(id: topic.id)
            let result = TreeLayout.layout(cards: cards)
            let frames = Array(result.frames.values)
            if let first = frames.first {
                let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
                let aspect = bounds.width / bounds.height
                print("DEBUG_FINAL_ASPECT: bounds=\(bounds) aspect=\(aspect)")
                XCTAssertGreaterThan(aspect, 1.0, "Layout should be wider than tall")
                XCTAssertLessThan(aspect, 2.5, "Layout should reasonably match minimap aspect ratio")
            }
        }
    }

    func testDatabaseReparentIndentAndOutdent() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "MindMap")
        try database.insertTopic(topic)

        let root = NoteCard(topicId: topic.id, title: "Root")
        let sibling = NoteCard(topicId: topic.id, title: "Sibling")
        let child = NoteCard(topicId: topic.id, title: "Child")

        try database.insertCard(root)
        try database.insertCard(sibling)
        try database.insertCard(child)

        try database.reparentCard(id: child.id, to: root.id)
        XCTAssertEqual(try database.getCard(id: child.id)?.groupNoteId, root.id)

        try database.outdentCard(id: child.id)
        XCTAssertNil(try database.getCard(id: child.id)?.groupNoteId)

        try database.indentCard(id: child.id, under: sibling.id)
        XCTAssertEqual(try database.getCard(id: child.id)?.groupNoteId, sibling.id)

        try database.moveCard(id: child.id, to: CGPoint(x: 420, y: 180))
        XCTAssertEqual(try database.getCard(id: child.id)?.mindPos, CGPoint(x: 420, y: 180))

        try database.setCardFolded(id: sibling.id, folded: true)
        XCTAssertEqual(try database.getCard(id: sibling.id)?.isFolded, true)

        try database.reparentCard(id: sibling.id, to: child.id)
        XCTAssertNil(try database.getCard(id: sibling.id)?.groupNoteId)
    }

    func testTreeLayoutCalculatesDynamicCardHeightsForMultilineContent() {
        let topic = UUID()
        let shortCard = NoteCard(id: UUID(), topicId: topic, title: "Short Title")
        let longCard = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "This is a very long title that spans across multiple lines in the header section of the note card",
            highlightText: "This is an extensive multi-sentence excerpt extracted from the book that also spans across multiple lines of text in the card body.",
            notesText: "User notes and reflections on this topic.\nSecond line of notes.\nThird line of notes."
        )

        let shortHeight = TreeLayout.estimatedCardHeight(for: shortCard, width: 220)
        let longHeight = TreeLayout.estimatedCardHeight(for: longCard, width: 220)

        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertGreaterThanOrEqual(shortHeight, 44)
        XCTAssertGreaterThanOrEqual(longHeight, 140)

        let result = TreeLayout.layout(cards: [shortCard, longCard])
        let shortFrame = try! XCTUnwrap(result.frames[shortCard.id])
        let longFrame = try! XCTUnwrap(result.frames[longCard.id])

        XCTAssertEqual(shortFrame.height, shortHeight)
        XCTAssertEqual(longFrame.height, longHeight)
    }

    func testMarginNoteThemeColorsAndBlueCursor() {
        let yellow = MarginNoteTheme.cardColors(for: 0)
        let green = MarginNoteTheme.cardColors(for: 1)
        let blue = MarginNoteTheme.cardColors(for: 2)

        XCTAssertEqual(MarginNoteTheme.cursorBlueHex, "#1265dd")
        XCTAssertNotNil(yellow.accent)
        XCTAssertNotNil(green.accent)
        XCTAssertNotNil(blue.accent)
    }

    func testTreeLayoutPreventsCollisionsWithExpandedCards() {
        let topic = UUID()
        let tallParent = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "Parent with huge text",
            highlightText: String(repeating: "This is a very long text that expands the card height significantly. ", count: 20)
        )
        let smallChild = NoteCard(id: UUID(), topicId: topic, title: "Small child", groupNoteId: tallParent.id)
        let nextCard = NoteCard(id: UUID(), topicId: topic, title: "Next card below")

        let result = TreeLayout.layout(cards: [tallParent, smallChild, nextCard])
        let parentFrame = try! XCTUnwrap(result.frames[tallParent.id])
        let nextFrame = try! XCTUnwrap(result.frames[nextCard.id])

        // Next card must be placed completely below tallParent
        XCTAssertGreaterThanOrEqual(nextFrame.minY, parentFrame.maxY)
        XCTAssertFalse(parentFrame.intersects(nextFrame))
    }

    func testCanvasViewportAnchorZoom() {
        var viewport = CanvasViewport(
            panOffset: CGPoint(x: 100, y: 100),
            zoomScale: 1.0,
            viewportSize: CGSize(width: 800, height: 600)
        )
        let cursor = CGPoint(x: 400, y: 300)
        let canvasPointBefore = viewport.screenToCanvas(cursor)

        viewport.zoom(by: 1.5, around: cursor)

        let canvasPointAfter = viewport.screenToCanvas(cursor)
        XCTAssertEqual(viewport.zoomScale, 1.5, accuracy: 0.001)
        XCTAssertEqual(canvasPointBefore.x, canvasPointAfter.x, accuracy: 0.001)
        XCTAssertEqual(canvasPointBefore.y, canvasPointAfter.y, accuracy: 0.001)
    }

    func testRangesOfPhraseCrossLineMatching() {
        let cardText = "Having read more does not\nautomatically mean having more\nideas."
        let emphasisPhrase = "Having read more does not automatically"

        let ranges = PDFHighlightResolver.rangesOfPhrase(emphasisPhrase, in: cardText)
        XCTAssertEqual(ranges.count, 1)
        if let first = ranges.first {
            XCTAssertEqual(String(cardText[first]), "Having read more does not\nautomatically")
        }

        // Reverse: phrase has newline, text has space
        let textWithSpace = "Having read more does not automatically mean having more ideas."
        let phraseWithNewline = "Having read more does not\nautomatically"
        let ranges2 = PDFHighlightResolver.rangesOfPhrase(phraseWithNewline, in: textWithSpace)
        XCTAssertEqual(ranges2.count, 1)
        if let first = ranges2.first {
            XCTAssertEqual(String(textWithSpace[first]), "Having read more does not automatically")
        }
    }

    func testCardReparentingBecomesChildAndPlacesToRight() throws {
        let topicId = UUID()
        var parentCard = NoteCard(
            id: UUID(),
            topicId: topicId,
            title: "Parent Note",
            notesText: "Root note content",
            groupNoteId: nil
        )
        var childCard = NoteCard(
            id: UUID(),
            topicId: topicId,
            title: "Child Note",
            notesText: "Becomes child of parent",
            groupNoteId: nil
        )

        // Initial layout: both are roots, placed vertically in column
        let initialLayout = TreeLayout.layout(cards: [parentCard, childCard])
        let initialParentFrame = try XCTUnwrap(initialLayout.frames[parentCard.id])
        let initialChildFrame = try XCTUnwrap(initialLayout.frames[childCard.id])
        XCTAssertEqual(initialParentFrame.minX, initialChildFrame.minX, "Roots share the same column X")

        // Reparent: child becomes child of parent
        childCard.groupNoteId = parentCard.id
        let reparentedLayout = TreeLayout.layout(cards: [parentCard, childCard])
        let reparentedParentFrame = try XCTUnwrap(reparentedLayout.frames[parentCard.id])
        let reparentedChildFrame = try XCTUnwrap(reparentedLayout.frames[childCard.id])

        // Child should be placed to the right of parent
        XCTAssertGreaterThan(reparentedChildFrame.minX, reparentedParentFrame.maxX, "Child should be placed to the right of parent")

        // Connector path should exist between parent and child
        let path = reparentedLayout.connectorPath(parentID: parentCard.id, childID: childCard.id)
        XCTAssertNotNil(path, "Connector path should exist between parent and reparented child")
    }

    func testCardOrderingByMindPosYSpacesOutInTreeLayout() throws {
        let topicId = UUID()
        let card1 = NoteCard(
            id: UUID(),
            topicId: topicId,
            title: "Card 1",
            mindPos: CGPoint(x: 0, y: 100)
        )
        let card2 = NoteCard(
            id: UUID(),
            topicId: topicId,
            title: "Card 2",
            mindPos: CGPoint(x: 0, y: 300)
        )
        let insertedCard = NoteCard(
            id: UUID(),
            topicId: topicId,
            title: "Inserted Card",
            mindPos: CGPoint(x: 0, y: 200) // Inserted between card1 and card2
        )

        let layout = TreeLayout.layout(cards: [card1, card2, insertedCard])
        let f1 = try XCTUnwrap(layout.frames[card1.id])
        let fInserted = try XCTUnwrap(layout.frames[insertedCard.id])
        let f2 = try XCTUnwrap(layout.frames[card2.id])

        // Verify vertical order: f1.minY < fInserted.minY < f2.minY
        XCTAssertLessThan(f1.minY, fInserted.minY)
        XCTAssertLessThan(fInserted.minY, f2.minY)
    }

    func testArrowKeyNavigation() throws {
        let topicId = UUID()
        let root = NoteCard(id: UUID(), topicId: topicId, title: "Root")
        let childA = NoteCard(id: UUID(), topicId: topicId, title: "Child A", groupNoteId: root.id)
        let childB = NoteCard(id: UUID(), topicId: topicId, title: "Child B", groupNoteId: root.id)
        let grandchild = NoteCard(id: UUID(), topicId: topicId, title: "Grandchild", groupNoteId: childA.id)

        let allCards = [root, childA, childB, grandchild]
        let layout = TreeLayout.layout(cards: allCards)

        // 1. Right arrow from root should select its first child (childA)
        let rightFromRoot = MindMapCanvasView.nextCardID(
            from: root.id,
            direction: .right,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(rightFromRoot, childA.id, "Right from root should navigate to first child")

        // 2. Down arrow from childA should select next sibling (childB)
        let downFromChildA = MindMapCanvasView.nextCardID(
            from: childA.id,
            direction: .down,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(downFromChildA, childB.id, "Down from childA should navigate to next sibling childB")

        // 3. Up arrow from childB should select previous sibling (childA)
        let upFromChildB = MindMapCanvasView.nextCardID(
            from: childB.id,
            direction: .up,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(upFromChildB, childA.id, "Up from childB should navigate to previous sibling childA")

        // 4. Right arrow from childA should select its child (grandchild)
        let rightFromChildA = MindMapCanvasView.nextCardID(
            from: childA.id,
            direction: .right,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(rightFromChildA, grandchild.id, "Right from childA should navigate to grandchild")

        // 5. Left arrow from grandchild should select parent (childA)
        let leftFromGrandchild = MindMapCanvasView.nextCardID(
            from: grandchild.id,
            direction: .left,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(leftFromGrandchild, childA.id, "Left from grandchild should navigate to parent childA")

        // 6. Left arrow from childA should select root
        let leftFromChildA = MindMapCanvasView.nextCardID(
            from: childA.id,
            direction: .left,
            cards: allCards,
            frames: layout.frames,
            visibleCardIDs: layout.visibleCardIDs
        )
        XCTAssertEqual(leftFromChildA, root.id, "Left from childA should navigate to root")
    }

    func testViewportZoomInZoomOutReset() {
        var viewport = CanvasViewport(
            panOffset: CGPoint(x: 100, y: 100),
            zoomScale: 1.0,
            viewportSize: CGSize(width: 800, height: 600)
        )

        viewport.zoomIn(factor: 1.2)
        XCTAssertEqual(viewport.zoomScale, 1.2, accuracy: 0.001)

        viewport.zoomOut(factor: 1.2)
        XCTAssertEqual(viewport.zoomScale, 1.0, accuracy: 0.001)

        viewport.zoomIn(factor: 1.5)
        XCTAssertEqual(viewport.zoomScale, 1.5, accuracy: 0.001)

        viewport.resetZoom()
        XCTAssertEqual(viewport.zoomScale, 1.0, accuracy: 0.001)
    }

    func testSiblingCardCreationInheritsParentOrNil() {
        let topicID = UUID()
        let root = NoteCard(id: UUID(), topicId: topicID, title: "Root", groupNoteId: nil)
        let child = NoteCard(id: UUID(), topicId: topicID, title: "Child", groupNoteId: root.id)

        // Sibling of root has same parent (nil)
        let rootSibling = NoteCard(id: UUID(), topicId: topicID, title: "", groupNoteId: root.groupNoteId)
        XCTAssertNil(rootSibling.groupNoteId)

        // Sibling of child has same parent (root.id)
        let childSibling = NoteCard(id: UUID(), topicId: topicID, title: "", groupNoteId: child.groupNoteId)
        XCTAssertEqual(childSibling.groupNoteId, root.id)
    }

    func testChildCardCreationSetsParentAndUnfolds() {
        let topicID = UUID()
        var parent = NoteCard(id: UUID(), topicId: topicID, title: "Parent", isFolded: true)

        let child = NoteCard(id: UUID(), topicId: topicID, title: "", groupNoteId: parent.id)
        XCTAssertEqual(child.groupNoteId, parent.id)

        if parent.isFolded {
            parent.isFolded = false
        }
        XCTAssertFalse(parent.isFolded)

        let result = TreeLayout.layout(cards: [parent, child])
        XCTAssertTrue(result.visibleCardIDs.contains(child.id))
    }

    func testEmptyCardLayoutAndDimensions() {
        let topicID = UUID()
        let emptyCard = NoteCard(id: UUID(), topicId: topicID, title: "")
        let height = TreeLayout.estimatedCardHeight(for: emptyCard)
        XCTAssertGreaterThanOrEqual(height, 56.0)

        let result = TreeLayout.layout(cards: [emptyCard])
        let frame = try! XCTUnwrap(result.frames[emptyCard.id])
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }

    func testSiblingCardOrderingInTreeLayout() {
        let topicID = UUID()
        var cardA = NoteCard(id: UUID(), topicId: topicID, title: "Card A")
        cardA.mindPos = CGPoint(x: 100, y: 100)
        cardA.createdAt = Date(timeIntervalSince1970: 1000)

        var cardB = NoteCard(id: UUID(), topicId: topicID, title: "Card B")
        cardB.mindPos = CGPoint(x: 100, y: 300)
        cardB.createdAt = Date(timeIntervalSince1970: 2000)

        // Interpolated sibling between A and B
        var siblingC = NoteCard(id: UUID(), topicId: topicID, title: "")
        siblingC.mindPos = CGPoint(x: 100, y: 200)
        siblingC.createdAt = Date(timeIntervalSince1970: 1500)

        XCTAssertTrue(TreeLayout.cardOrder(cardA, siblingC))
        XCTAssertTrue(TreeLayout.cardOrder(siblingC, cardB))

        let result = TreeLayout.layout(cards: [cardB, cardA, siblingC])
        let frameA = try! XCTUnwrap(result.frames[cardA.id])
        let frameC = try! XCTUnwrap(result.frames[siblingC.id])
        let frameB = try! XCTUnwrap(result.frames[cardB.id])

        XCTAssertLessThan(frameA.minY, frameC.minY)
        XCTAssertLessThan(frameC.minY, frameB.minY)
    }

    func testFreeNoteCreationAtCanvasCoordinatesAndTitleUpdate() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Free Note Test")
        try database.insertTopic(topic)

        let targetPos = CGPoint(x: 450, y: 320)
        var freeNote = NoteCard(
            topicId: topic.id,
            title: "",
            groupNoteId: nil,
            colorIndex: 0
        )
        freeNote.mindPos = targetPos
        try database.insertCard(freeNote)

        let fetched = try XCTUnwrap(database.getCard(id: freeNote.id))
        XCTAssertEqual(fetched.title, "")
        XCTAssertEqual(fetched.mindPos?.x ?? 0, targetPos.x, accuracy: 0.001)
        XCTAssertEqual(fetched.mindPos?.y ?? 0, targetPos.y, accuracy: 0.001)
        XCTAssertNil(fetched.groupNoteId)

        var updated = fetched
        updated.title = "Direct Inline Title"
        try database.updateCard(updated)

        let afterUpdate = try XCTUnwrap(database.getCard(id: freeNote.id))
        XCTAssertEqual(afterUpdate.title, "Direct Inline Title")
    }

    func testSiblingAndChildNoteCreationDefaultsEmptyTitle() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Creation Test")
        try database.insertTopic(topic)

        let root = NoteCard(topicId: topic.id, title: "Root Note")
        try database.insertCard(root)

        let child = NoteCard(topicId: topic.id, title: "", groupNoteId: root.id)
        try database.insertCard(child)
        XCTAssertEqual(child.title, "")
        XCTAssertEqual(child.groupNoteId, root.id)

        let sibling = NoteCard(topicId: topic.id, title: "", groupNoteId: nil)
        try database.insertCard(sibling)
        XCTAssertEqual(sibling.title, "")
        XCTAssertNil(sibling.groupNoteId)
    }

    func testAnchoredRootNoteLayoutAtExactPosition() throws {
        let topic = UUID()
        var freeRoot = NoteCard(id: UUID(), topicId: topic, title: "Free Root")
        freeRoot.mindPos = CGPoint(x: 520, y: 380)

        let child = NoteCard(id: UUID(), topicId: topic, title: "Child", groupNoteId: freeRoot.id)

        let config = TreeLayoutConfiguration(nodeSize: CGSize(width: 220, height: 100), horizontalSpacing: 80, verticalSpacing: 28)
        let result = TreeLayout.layout(cards: [freeRoot, child], configuration: config)

        let rootFrame = try XCTUnwrap(result.frames[freeRoot.id])
        XCTAssertEqual(rootFrame.minX, 520, accuracy: 0.001)
        XCTAssertEqual(rootFrame.minY, 380, accuracy: 0.001)

        let childFrame = try XCTUnwrap(result.frames[child.id])
        XCTAssertEqual(childFrame.minX, 520 + 220 + 80, accuracy: 0.001)
    }

    @MainActor
    func testInlineTitleEditorBindingAndCommit() throws {
        var text = "Initial Title"
        let binding = Binding(get: { text }, set: { text = $0 })
        let editor = InlineTitleEditorView(
            text: binding,
            placeholder: "Untitled Note",
            onCommit: { _ in },
            onCancel: {}
        )
        XCTAssertNotNil(editor)
        XCTAssertEqual(text, "Initial Title")
    }

    @MainActor
    func testPDFPopoverToolbarViewModesInstantiation() throws {
        let createToolbar = PDFPopoverToolbarView(mode: .create)
        XCTAssertNotNil(createToolbar)
        let editToolbar = PDFPopoverToolbarView(mode: .edit(colorIndex: 2))
        XCTAssertNotNil(editToolbar)
        let emphasisToolbar = PDFPopoverToolbarView(mode: .emphasisSelection(phrase: "important phrase"))
        XCTAssertNotNil(emphasisToolbar)
    }
}

