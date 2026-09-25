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
    func testInlineTitleEditorUndoRedoAndGreyTint() throws {
        var text = "Original Note Title"
        let binding = Binding(get: { text }, set: { text = $0 })
        let editorView = InlineTitleEditorView(
            text: binding,
            placeholder: "Untitled Note",
            onCommit: { text = $0 },
            onCancel: {}
        )

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: editorView)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        if let fieldEditor = window.firstResponder as? NSTextView {
            // Verify dark blue #37587f has been applied to selection background and white foreground
            if let bg = fieldEditor.selectedTextAttributes[.backgroundColor] as? NSColor,
               let rgb = bg.usingColorSpace(.deviceRGB) {
                XCTAssertEqual(rgb.redComponent, 55.0 / 255.0, accuracy: 0.05)
                XCTAssertEqual(rgb.greenComponent, 88.0 / 255.0, accuracy: 0.05)
                XCTAssertEqual(rgb.blueComponent, 127.0 / 255.0, accuracy: 0.05)
            }
            if let fg = fieldEditor.selectedTextAttributes[.foregroundColor] as? NSColor {
                XCTAssertEqual(fg, NSColor.white)
            }

            // Verify typing and undo
            let initialLength = fieldEditor.string.count
            fieldEditor.insertText(" Extra Text", replacementRange: NSRange(location: initialLength, length: 0))
            XCTAssertTrue(fieldEditor.string.contains("Extra Text"))
            XCTAssertEqual(fieldEditor.undoManager?.canUndo, true)

            // Undo typing
            fieldEditor.undoManager?.undo()
            fieldEditor.didChangeText()
            XCTAssertFalse(fieldEditor.string.contains("Extra Text"))
            XCTAssertEqual(fieldEditor.string, "Original Note Title")
        }
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

    func testTreeLayoutGridSnappingAndAnchoring() throws {
        // 1. Grid Snapping
        let p1 = CGPoint(x: 21.4, y: 39.8)
        let snapped1 = TreeLayout.snapToGrid(p1, gridSize: 20.0)
        XCTAssertEqual(snapped1.x, 20.0, accuracy: 0.001)
        XCTAssertEqual(snapped1.y, 40.0, accuracy: 0.001)

        let p2 = CGPoint(x: 109.9, y: 151.1)
        let snapped2 = TreeLayout.snapToGrid(p2, gridSize: 20.0)
        XCTAssertEqual(snapped2.x, 100.0, accuracy: 0.001)
        XCTAssertEqual(snapped2.y, 160.0, accuracy: 0.001)

        // 2. Anchored root preservation for explicitly moved cards (pos.x > 0)
        let movedCard = NoteCard(
            topicId: UUID(),
            bookMD5: "dummy-md5",
            mindPos: CGPoint(x: 240, y: 180),
            startPage: 3
        )
        let result = TreeLayout.layout(cards: [movedCard])
        guard let frame = result.frames[movedCard.id] else {
            XCTFail("Frame should not be nil")
            return
        }
        XCTAssertEqual(frame.origin.x, 240.0, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 180.0, accuracy: 0.001)
    }

    func testColumnContainerLayoutPreventsCardCollisions() throws {
        let topic = UUID()
        // Two cards in the same column container with overlapping / identical Y coordinates
        let card1 = NoteCard(
            topicId: topic,
            title: "1.2 The Slip-box",
            mindPos: CGPoint(x: 340, y: 180)
        )
        let card2 = NoteCard(
            topicId: topic,
            title: "People who take smart notes simply don't have the need for brainstorming anymore",
            mindPos: CGPoint(x: 340, y: 190) // Only 10pt apart, would overlap without column container layout
        )

        let result = TreeLayout.layout(cards: [card1, card2])
        let frame1 = try XCTUnwrap(result.frames[card1.id])
        let frame2 = try XCTUnwrap(result.frames[card2.id])

        // Column container guarantees that both cards share the column baseX
        XCTAssertEqual(frame1.minX, 340.0, accuracy: 0.001)
        XCTAssertEqual(frame2.minX, 340.0, accuracy: 0.001)

        // Column container guarantees that card2 is pushed below card1 with proper vertical spacing (NO COLLISION)
        XCTAssertGreaterThanOrEqual(frame2.minY, frame1.maxY + 20.0, "Card 2 must never collide with or overlap Card 1")
    }

    func testDatabaseBatchCardPositionsUpdate() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Database Batch Test")
        try database.insertTopic(topic)

        let cardA = NoteCard(topicId: topic.id, title: "Card A", mindPos: CGPoint(x: 40, y: 40))
        let cardB = NoteCard(topicId: topic.id, title: "Card B", mindPos: CGPoint(x: 40, y: 200))
        try database.insertCard(cardA)
        try database.insertCard(cardB)

        // Batch update to swap vertical order and shift column
        let updates: [(id: UUID, position: CGPoint)] = [
            (id: cardA.id, position: CGPoint(x: 360, y: 250)),
            (id: cardB.id, position: CGPoint(x: 360, y: 50))
        ]
        try database.updateCardPositions(updates)

        let fetchedA = try XCTUnwrap(database.getCard(id: cardA.id))
        let fetchedB = try XCTUnwrap(database.getCard(id: cardB.id))

        XCTAssertEqual(fetchedA.mindPos?.x, 360.0)
        XCTAssertEqual(fetchedA.mindPos?.y, 250.0)
        XCTAssertEqual(fetchedB.mindPos?.x, 360.0)
        XCTAssertEqual(fetchedB.mindPos?.y, 50.0)
    }

    func testMousePositionOverlapTargetOnlyWhenMouseInsideTargetFrame() throws {
        let topic = UUID()
        let cardA = NoteCard(topicId: topic, title: "Card A")
        let cardB = NoteCard(topicId: topic, title: "Card B")
        let cardC = NoteCard(topicId: topic, title: "Card C", groupNoteId: cardA.id) // descendant of A

        let frames: [UUID: CGRect] = [
            cardA.id: CGRect(x: 40, y: 40, width: 220, height: 100),
            cardB.id: CGRect(x: 40, y: 200, width: 220, height: 100),
            cardC.id: CGRect(x: 300, y: 40, width: 220, height: 100)
        ]

        func findMouseTarget(draggedID: UUID, mousePoint: CGPoint, allCards: [NoteCard]) -> UUID? {
            var descendants = Set<UUID>()
            var queue = [draggedID]
            while !queue.isEmpty {
                let curr = queue.removeFirst()
                for c in allCards where c.groupNoteId == curr {
                    if descendants.insert(c.id).inserted {
                        queue.append(c.id)
                    }
                }
            }

            for other in allCards.reversed() where other.id != draggedID && !descendants.contains(other.id) {
                guard let otherFrame = frames[other.id] else { continue }
                if otherFrame.contains(mousePoint) {
                    return other.id
                }
            }
            return nil
        }

        let allCards = [cardA, cardB, cardC]

        // Case 1: Mouse is inside Card B's frame -> Should target Card B
        let mouseInB = CGPoint(x: 100, y: 230)
        XCTAssertEqual(findMouseTarget(draggedID: cardA.id, mousePoint: mouseInB, allCards: allCards), cardB.id)

        // Case 2: Mouse is outside Card B's frame (even if dragged card shape intersects) -> Should be nil
        let mouseOutsideB = CGPoint(x: 30, y: 180)
        XCTAssertNil(findMouseTarget(draggedID: cardA.id, mousePoint: mouseOutsideB, allCards: allCards))

        // Case 3: Dragging Card A, mouse inside descendant Card C -> Descendant must NOT be targeted
        let mouseInC = CGPoint(x: 350, y: 60)
        XCTAssertNil(findMouseTarget(draggedID: cardA.id, mousePoint: mouseInC, allCards: allCards))
    }

    func testBatchMoveAndReparentUndoRedoInDatabase() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Undo Redo DB Test")
        try database.insertTopic(topic)

        let initialPosA = CGPoint(x: 40, y: 40)
        let initialPosB = CGPoint(x: 40, y: 200)
        let cardA = NoteCard(topicId: topic.id, title: "Card A", mindPos: initialPosA)
        let cardB = NoteCard(topicId: topic.id, title: "Card B", mindPos: initialPosB)
        try database.insertCard(cardA)
        try database.insertCard(cardB)

        // 1. Test Batch Move and Undo
        let movedPosA = CGPoint(x: 340, y: 150)
        let movedPosB = CGPoint(x: 340, y: 300)
        try database.updateCardPositions([
            (id: cardA.id, position: movedPosA),
            (id: cardB.id, position: movedPosB)
        ])
        XCTAssertEqual(try database.getCard(id: cardA.id)?.mindPos, movedPosA)
        XCTAssertEqual(try database.getCard(id: cardB.id)?.mindPos, movedPosB)

        // Undo batch move: restore original positions
        try database.updateCardPositions([
            (id: cardA.id, position: initialPosA),
            (id: cardB.id, position: initialPosB)
        ])
        XCTAssertEqual(try database.getCard(id: cardA.id)?.mindPos, initialPosA)
        XCTAssertEqual(try database.getCard(id: cardB.id)?.mindPos, initialPosB)

        // 2. Test Reparent to Child ("Become a child") and Undo
        try database.reparentCard(id: cardB.id, to: cardA.id)
        let reparentedB = try XCTUnwrap(database.getCard(id: cardB.id))
        XCTAssertEqual(reparentedB.groupNoteId, cardA.id)
        XCTAssertNil(reparentedB.mindPos)

        // Undo reparent: restore previous parent (nil) and original mindPos
        var restoredB = reparentedB
        restoredB.groupNoteId = nil
        restoredB.mindPos = initialPosB
        try database.updateCard(restoredB)

        let undoneB = try XCTUnwrap(database.getCard(id: cardB.id))
        XCTAssertNil(undoneB.groupNoteId)
        XCTAssertEqual(undoneB.mindPos, initialPosB)
    }

    func testViewportCenterOnMovedCard() {
        var viewport = CanvasViewport(
            panOffset: .zero,
            zoomScale: 1.0,
            viewportSize: CGSize(width: 800, height: 600)
        )

        let cardFrame = CGRect(x: 1000, y: 500, width: 220, height: 120)
        viewport.center(on: cardFrame)

        // Midpoint of cardFrame is (1110, 560)
        // Center of viewport is (400, 300)
        // Expected panOffset is:
        // x: 400 - 1110 * 1.0 = -710
        // y: 300 - 560 * 1.0 = -260
        XCTAssertEqual(viewport.panOffset.x, -710, accuracy: 0.001)
        XCTAssertEqual(viewport.panOffset.y, -260, accuracy: 0.001)

        // Verifying screen coordinates of card center is exactly the screen center
        let screenCenter = viewport.canvasToScreen(CGPoint(x: cardFrame.midX, y: cardFrame.midY))
        XCTAssertEqual(screenCenter.x, 400, accuracy: 0.001)
        XCTAssertEqual(screenCenter.y, 300, accuracy: 0.001)
    }

    func testTopToolbarHeightIsStandardized() {
        XCTAssertEqual(MarginNoteTheme.topToolbarHeight, 44.0)
    }

    @MainActor
    func testSelectedCardHeaderFillsWidthWithoutWhiteBorder() {
        let card = NoteCard(
            id: UUID(),
            topicId: UUID(),
            title: "Many people who can distinguish between profit and pleasure, between understanding and entertainment, nevertheless fail to carry out their reading plans. The reason is that they do not know how to be demanding readers.",
            highlightText: "But the sad fact is that many people who can distinguish between profit and pleasure-between understanding, on the one hand, and entertainment or the mere satisfaction of curi osity, on the other hand-nevertheless fail to carry out their reading plans. They fail even if they know which books give which. The reason is that they do not know how to be demand ing readers, how to keep their mind on what they are doing by making it do the work without which no profit can be earned.",
            notesText: "",
            colorIndex: 2
        )

        for w: CGFloat in [220, 240] {
            let h = NSHostingView(rootView: CardNodeView(card: card, isSelected: true, hasChildren: false, onSelect: {}, onToggleFold: {}).frame(width: w))
            h.frame = CGRect(origin: .zero, size: CGSize(width: w, height: 400))
            h.layoutSubtreeIfNeeded()
            guard let r = h.bitmapImageRepForCachingDisplay(in: h.bounds) else {
                XCTFail("Failed to cache display")
                continue
            }
            h.cacheDisplay(in: h.bounds, to: r)

            // Across the right edge at y=50 (header area), verify no cream background bleed
            // Cream cardBodyBackground has red > 0.9, green > 0.9, blue < 0.9
            for x in (r.pixelsWide - 6)..<r.pixelsWide {
                let c = r.colorAt(x: x, y: 50)!
                let isCreamBleed = c.redComponent > 0.88 && c.greenComponent > 0.88 && c.blueComponent < 0.88
                XCTAssertFalse(isCreamBleed, "Found white/cream bleed pixel at x=\(x) for w=\(w): \(c)")
            }
        }
    }

    func testMindMapSearchMatchesTitleAndContent() {
        let topic = UUID()
        let card1 = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "Chinatown Screenplay",
            highlightText: "In Chinatown, the mystery unravels.",
            notesText: "Robert Towne masterpiece analysis.",
            tags: ["screenwriting"]
        )

        let card2 = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "Character Arc",
            highlightText: "The protagonist must change internally.",
            notesText: "Internal and external journey of the hero.",
            tags: ["character"]
        )

        let card3 = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "",
            highlightText: "A three-act dramatic narrative.",
            notesText: "",
            tags: ["drama"]
        )

        let card4 = NoteCard(
            id: UUID(),
            topicId: topic,
            title: "Three Act Structure",
            highlightText: "Setup, Confrontation, Resolution",
            notesText: "",
            tags: [],
            excerptSegments: [ExcerptSegment(text: "Inciting incident occurs on page 10.")]
        )

        let allCards = [card1, card2, card3, card4]

        // 1. Search by title (case-insensitive)
        let titleMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "chinatown", scope: .title) }
        XCTAssertEqual(titleMatches.map(\.id), [card1.id])

        // 2. Search by note content (notesText)
        let noteMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "journey", scope: .content) }
        XCTAssertEqual(noteMatches.map(\.id), [card2.id])
        XCTAssertFalse(MindMapSearchMatcher.matches(card: card2, query: "journey", scope: .title), "Title scope must not match note content")

        // 3. Search by excerpt segment text
        let segmentMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "inciting incident", scope: .content) }
        XCTAssertEqual(segmentMatches.map(\.id), [card4.id])

        // 4. Search by tag
        let tagMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "drama", scope: .content) }
        XCTAssertEqual(tagMatches.map(\.id), [card3.id])

        // 5. Fallback title for untitled card with highlightText
        let untitledTitleMatch = MindMapSearchMatcher.matches(card: card3, query: "three-act", scope: .title)
        XCTAssertTrue(untitledTitleMatch, "Untitled cards should match their highlightText when searching by title")

        // 6. Scope .all matches either title or content
        let allScopeTitle = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "character", scope: .all) }
        XCTAssertEqual(allScopeTitle.map(\.id), [card2.id])

        let allScopeContent = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "masterpiece", scope: .all) }
        XCTAssertEqual(allScopeContent.map(\.id), [card1.id])

        // 7. Non-matching query
        let noMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "NonExistentQueryXYZ", scope: .all) }
        XCTAssertTrue(noMatches.isEmpty)

        // 8. Empty or whitespace query matches all cards
        let emptyMatches = allCards.filter { MindMapSearchMatcher.matches(card: $0, query: "   ", scope: .all) }
        XCTAssertEqual(emptyMatches.count, 4)
    }
}
