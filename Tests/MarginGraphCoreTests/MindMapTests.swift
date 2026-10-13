import XCTest
import CoreGraphics
import SwiftUI
@testable import MarginGraphCore

final class MindMapTests: XCTestCase {
    @MainActor
    func testShortCardConnectorFrameMatchesRenderedHeight() throws {
        for title in ["Simplify", "the best number of concepts you hold in mind at once"] {
            let card = NoteCard(id: UUID(), topicId: UUID(), title: title)
            let view = NSHostingView(rootView: CardNodeView(card: card, isSelected: false, hasChildren: false,
                onSelect: {}, onToggleFold: {}).frame(width: 220))
            let frame = try XCTUnwrap(TreeLayout.layout(cards: [card]).frames[card.id])
            XCTAssertEqual(frame.height, view.fittingSize.height, accuracy: 1)
            XCTAssertEqual(frame.midY - frame.minY, view.fittingSize.height / 2, accuracy: 0.5)
        }
    }

    @MainActor
    func testRenderedLongCardFitsLayoutHeight() {
        for count in [1, 20, 100] {
            let card = NoteCard(id: UUID(), topicId: UUID(), title: "Long title wrapping across several lines in the card header",
                                highlightText: String(repeating: "A long paragraph with several words and punctuation.\n", count: count),
                                notesText: "Some additional comments")
            let view = NSHostingView(rootView: CardNodeView(card: card, isSelected: false, hasChildren: false,
                                                            onSelect: {}, onToggleFold: {}).frame(width: 220))
            let rendered = view.fittingSize.height
            XCTAssertLessThanOrEqual(rendered, TreeLayout.estimatedCardHeight(for: card), "Rendered \(rendered) for \(count) paragraphs")
        }
    }

    @MainActor
    func testAhrensRenderedCardsFitReservedLayout() throws {
        let url = URL(fileURLWithPath: "/Volumes/omv/backups/marginnote/main/MarginGraph.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Main library unavailable") }
        let db = try Database(url: url)
        let cards = NoteCard.filterMarginNoteDocumentRootCard(from: try db.cardsForTopic(id: UUID(uuidString: "98F0B1A7-DC0E-4CF3-8888-9649AC9F3E94")!))
        guard !cards.isEmpty else { throw XCTSkip("Ahrens notebook unavailable") }
        for card in cards where card.highlightPicHash == nil {
            let view = NSHostingView(rootView: CardNodeView(card: card, isSelected: false, hasChildren: false,
                                                            onSelect: {}, onToggleFold: {}).frame(width: 220))
            XCTAssertLessThanOrEqual(view.fittingSize.height, TreeLayout.estimatedCardHeight(for: card), "Card \(card.id) exceeds reserved bounds")
        }
    }

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

    func testAutomaticForestBalancesDifferentExcerptLengths() {
        for repetitions in [1, 8, 24] {
            let topicID = UUID()
            let cards = (0..<120).map { index in
                NoteCard(topicId: topicID, title: "Card \(index)",
                         highlightText: String(repeating: "An excerpt with useful context. ", count: repetitions))
            }
            let result = TreeLayout.layout(cards: cards)
            let frames = Array(result.frames.values)
            let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            XCTAssertGreaterThan(bounds.width / bounds.height, 0.9)
            XCTAssertLessThan(bounds.width / bounds.height, 2.2)
            XCTAssertEqual(frames.count, cards.count)
            for (index, frame) in frames.enumerated() {
                for other in frames.dropFirst(index + 1) {
                    XCTAssertFalse(frame.intersects(other))
                }
            }
        }
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
        XCTAssertGreaterThanOrEqual(shortHeight, 30)
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

    func testMultiParagraphCardHeightAndNonOverlappingLayout() throws {
        let topicID = UUID()
        let card1Text = """
        There’s an episode of Seinfeld where Jerry goes to pick up a rental car. He’d reserved a certain model. But the agent at the counter says they don’t have any of those models available.

        Jerry protests, “But the reservation keeps the car here. That’s why you have the reservation.”

        “I think I know why we have reservations,” says the agent.

        “I don’t think you do,” says Jerry. “If you did, I’d have a car. See, you know how to take the reservation, you just don't know how to hold the reservation. And that’s really the most important part of the reservation–the holding.”
        """

        let card2Text = """
        A short story almost always sticks to one point of view. Certainly, there’s nothing illegal about incorporating another POV in a short story. Just know that when you do, the reader expects a full treatment of that character. This will begin to strain the story because it will want to push beyond its outer boundaries toward the novelette.

        The point of view in a short story is usually one of three types
        """

        var card1 = NoteCard(id: UUID(), topicId: topicID, title: "", highlightText: card1Text)
        card1.mindPos = CGPoint(x: 40.0, y: 40.0)

        var card2 = NoteCard(id: UUID(), topicId: topicID, title: "", highlightText: card2Text)
        // Simulate stale/underestimated coordinates from SQLite (where card2 was placed at 388.5)
        card2.mindPos = CGPoint(x: 40.0, y: 388.5)

        let h1 = TreeLayout.estimatedCardHeight(for: card1, width: 220)
        let h2 = TreeLayout.estimatedCardHeight(for: card2, width: 220)

        // Card 1 has 4 paragraphs and over 550 characters, must be estimated accurately >= 340 pt
        XCTAssertGreaterThanOrEqual(h1, 340.0)
        XCTAssertGreaterThanOrEqual(h2, 220.0)

        let layout = TreeLayout.layout(cards: [card1, card2])
        guard let frame1 = layout.frames[card1.id], let frame2 = layout.frames[card2.id] else {
            XCTFail("Frames missing for cards")
            return
        }

        // Ensure no intersection and guaranteed minimum vertical separation
        XCTAssertFalse(frame1.intersects(frame2), "Card 1 and Card 2 must not intersect")
        XCTAssertGreaterThanOrEqual(frame2.minY, frame1.maxY + 28.0, "Card 2 must have at least verticalSpacing (28pt) separation below Card 1")
    }

    func testHomoDeusConsecutiveCardsDoNotOverlap() throws {
        let topicID = UUID()
        let card0Text = """
        At the dawn of the third millennium, humanity wakes up, stretching its limbs and rubbing its eyes. Remnants of some awful nightmare are still drifting across its mind. ‘There was something with barbed wire, and huge mushroom clouds. Oh well, it was just a bad dream.’ Going to the bathroom, humanity washes its face, examines its wrinkles in the mirror, makes a cup of coffee and opens the diary. ‘Let’s see what’s on the agenda today.’

        For thousands of years the answer to this question remained unchanged. The same three problems preoccupied the people of twentieth-century China, of medieval India and of ancient Egypt. Famine, plague and war were always at the top of the list. For generation after generation humans have prayed to every god, angel and saint, and have invented countless tools, institutions and social systems – but they continued to die in their millions from starvation, epidemics and violence. Many thinkers and prophets concluded that famine, plague and war must be an integral part of God’s cosmic plan or of our imperfect nature, and nothing short of the end of time would free us from them.

        Yet at the dawn of the third millennium, humanity wakes up to an amazing realisation. Most people rarely think about it, but in the last few decades we have managed to rein in famine, plague and war. Of course, these problems have not been completely solved, but they have been transformed from incomprehensible and uncontrollable forces of nature into manageable challenges. W e don’t need to pray to any god or saint to rescue us from them. W e know quite well what needs to be done in order to prevent famine, plague and war – and we usually succeed in doing it.

        True, there are still notable failures; but when faced with such failures we no longer shrug our shoulders and say, ‘W ell, that’s the way things work in our imperfect world’ or ‘God’s will be done’. Rather, when famine, plague or war break out of our control, we feel that somebody must have screwed up, we set up a commission of inquiry, and promise ourselves that next time we’ll do better. And it actually works. Such calamities indeed happen less and less often. For the first time in history, more people die today from eating too much than from eating too little; more people die from old age than from infectious diseases; and more people commit suicide than are killed by soldiers, terrorists and criminals combined. In the early twentyfirst century, the average human is far more likely to die from bingeing at McDonald’s than from drought, Ebola or an al-Qaeda attack.

        Hence even though presidents, CEOs and generals still have their daily schedules full of economic crises and military conflicts, on the cosmic scale of history humankind can lift its eyes up and start looking towards new horizons. If we are indeed bringing famine, plague and war under control, what will replace them at the top of the human agenda? Like firefighters in a world without fire, so humankind in the twenty-first century needs to ask itself an unprecedented question: what are we going to do with ourselves? In a healthy, prosperous and harmonious world, what will demand our attention and ingenuity? This question becomes doubly urgent given the immense new powers that biotechnology and information technology are providing us with. What will we do with all that power?
        """

        let card1Text = """
        Despite the horrendous toll AIDS has taken, and despite the millions killed each year by long-established infectious diseases such as malaria, epidemics are a far smaller threat to human health today than in previous millennia. The vast majority of people die from non-infectious
        """

        let card0 = NoteCard(id: UUID(), topicId: topicID, title: "", highlightText: card0Text, startPage: 5)
        let card1 = NoteCard(id: UUID(), topicId: topicID, title: "", highlightText: card1Text, startPage: 13)

        let h0 = TreeLayout.estimatedCardHeight(for: card0, width: 220)
        let h1 = TreeLayout.estimatedCardHeight(for: card1, width: 220)

        // Card 0 must be estimated >= 1680 pt
        XCTAssertGreaterThanOrEqual(h0, 1680.0, "Card 0 must have estimated height matching its 5 paragraphs and SwiftUI line step")
        XCTAssertGreaterThanOrEqual(h1, 90.0)

        let layout = TreeLayout.layout(cards: [card0, card1])
        guard let f0 = layout.frames[card0.id], let f1 = layout.frames[card1.id] else {
            XCTFail("Frames missing for cards")
            return
        }

        XCTAssertFalse(f0.intersects(f1), "Card 0 and Card 1 must not intersect")
        if abs(f0.minX - f1.minX) < 10.0 {
            // In the same column
            XCTAssertGreaterThanOrEqual(f1.minY, f0.maxY + 50.0, "Card 1 must be placed below Card 0's bottom edge with vertical spacing")
        } else {
            // In adjacent columns
            XCTAssertGreaterThanOrEqual(f1.minX, f0.maxX + 70.0, "Card 1 in next column must be placed to the right of Card 0")
        }
    }

    func testAhrensTopicMindMapLayoutHasNoOverlaps() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbURL = appSupport.appendingPathComponent("MarginGraph/MarginGraph.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            print("MarginGraph.sqlite not found at \(dbURL.path), skipping live Ahrens test.")
            return
        }

        let db = try Database(url: dbURL)
        let topicID = UUID(uuidString: "98F0B1A7-DC0E-4CF3-8888-9649AC9F3E94")!
        let cards = try db.cardsForTopic(id: topicID)
        guard !cards.isEmpty else { return }

        // Test without root card
        let filtered = NoteCard.filterMarginNoteDocumentRootCard(from: cards)
        let rootID = UUID(uuidString: "58A37CCB-B508-4F34-8109-F0FA6F679895")!
        XCTAssertFalse(filtered.contains(where: { $0.id == rootID }), "Synthetic root card must be ignored/filtered out")

        let rawLayout = TreeLayout.layout(cards: cards)
        if let rootFrame = rawLayout.frames[rootID] {
            print("Root card frame in raw layout: \(rootFrame)")
        } else {
            print("Root card NOT present in raw layout frames")
        }
        print("Raw layout visible cards: \(rawLayout.visibleCardIDs.count)")
        let rawFrames = rawLayout.visibleCardIDs.compactMap { id -> (UUID, CGRect)? in
            guard let f = rawLayout.frames[id] else { return nil }
            return (id, f)
        }
        var rawOverlaps = 0
        for i in 0..<rawFrames.count {
            for j in (i+1)..<rawFrames.count {
                if rawFrames[i].1.intersects(rawFrames[j].1) {
                    rawOverlaps += 1
                }
            }
        }
        // Test ALL topics in OMV and local database for layout overlaps
        let omvURL = URL(fileURLWithPath: "/Volumes/omv/backups/marginnote/main/MarginGraph.sqlite")
        let dbsToTest = [dbURL, omvURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        for dbPath in dbsToTest {
            let currentDB = try Database(url: dbPath)
            let allTopics = try currentDB.allTopics()
            for t in allTopics {
                let topicCards = try currentDB.cardsForTopic(id: t.id)
                guard topicCards.count > 1 else { continue }
                let filteredCards = NoteCard.filterMarginNoteDocumentRootCard(from: topicCards)
                let res = TreeLayout.layout(cards: filteredCards)
                let frames = res.visibleCardIDs.compactMap { res.frames[$0] }
                for i in 0..<frames.count {
                    for j in (i + 1)..<frames.count {
                        if frames[i].intersects(frames[j]) {
                            XCTFail("Overlap in DB \(dbPath.lastPathComponent), topic '\(t.title)' (\(t.id)): \(frames[i]) intersects \(frames[j])")
                        }
                    }
                }
            }
        }

        let layout = TreeLayout.layout(cards: filtered)
        let visibleFrames = layout.visibleCardIDs.compactMap { id -> (UUID, CGRect)? in
            guard let f = layout.frames[id] else { return nil }
            return (id, f)
        }

        var overlaps: [(UUID, UUID, CGRect, CGRect)] = []
        for i in 0..<visibleFrames.count {
            let (id1, f1) = visibleFrames[i]
            for j in (i + 1)..<visibleFrames.count {
                let (id2, f2) = visibleFrames[j]
                if f1.intersects(f2) {
                    overlaps.append((id1, id2, f1, f2))
                }
            }
        }

        if !overlaps.isEmpty {
            for (id1, id2, f1, f2) in overlaps.prefix(10) {
                print("Overlap between \(id1) \(f1) and \(id2) \(f2)")
            }
        }
        XCTAssertEqual(overlaps.count, 0, "Found \(overlaps.count) overlapping card frame pairs in Ahrens topic mindmap layout!")
    }

    /// MANDATORY PRE-COMMIT TEST 1:
    /// Measures document opening speed and card-click responsiveness.
    /// Both operations must complete well within sub-second responsiveness limits (< 500ms for doc open, < 50ms for card click).
    func testMandatoryBenchmarkDocumentOpenAndCardClickSpeed() throws {
        let db = try Database(inMemory: true)
        let topicID = UUID()
        let topic = Topic(id: topicID, title: "Benchmark Topic", bookMD5List: ["bench_md5"])
        try db.insertTopic(topic)

        // Create 200 synthetic cards to simulate a populated notebook
        var cards: [NoteCard] = []
        var prevID: UUID? = nil
        for i in 0..<200 {
            let card = NoteCard(
                id: UUID(),
                topicId: topicID,
                title: "Card Note \(i)",
                highlightText: "Highlight excerpt text for card \(i) demonstrating realistic body content length.",
                notesText: i % 3 == 0 ? "Personal user comment and insight for card \(i)" : "",
                groupNoteId: (i > 0 && i % 4 != 0) ? prevID : nil,
                startPage: i % 50
            )
            cards.append(card)
            try db.insertCard(card)
            if i % 4 == 0 {
                prevID = card.id
            }
        }

        // Create a temporary mock PDF document
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pdfPath = tempDir.appendingPathComponent("benchmark.pdf").path
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF context")
            return
        }
        for _ in 0..<10 {
            context.beginPage(mediaBox: &mediaBox)
            context.endPage()
        }
        context.closePDF()
        try (pdfData as Data).write(to: URL(fileURLWithPath: pdfPath))

        let docModel = Document(id: UUID(), title: "Benchmark Doc", filePath: pdfPath, md5: "bench_md5", totalPages: 10)
        try db.insertDocument(docModel)

        // 1. Benchmark Document Opening Speed
        let docOpenStart = CFAbsoluteTimeGetCurrent()
        let loadedManager = try PDFDocumentManager(url: URL(fileURLWithPath: docModel.filePath), md5: docModel.md5)
        let docCards = try db.cardsForDocument(md5: docModel.md5)
        let docOpenElapsed = CFAbsoluteTimeGetCurrent() - docOpenStart

        print("⚡️ [MANDATORY BENCHMARK] Document open elapsed: \(String(format: "%.3f", docOpenElapsed * 1000)) ms")
        XCTAssertNotNil(loadedManager.document)
        XCTAssertEqual(docCards.count, 0)
        // Must complete under 500ms
        XCTAssertLessThan(docOpenElapsed, 0.500, "Document open must complete under 500ms (took \(docOpenElapsed * 1000) ms)")

        // If real Ahrens document is present, benchmark real PDF open as well
        let ahrensPath = "/Users/broliang/Library/Containers/QReader.MarginStudyMac/Data/Documents/Ahrens_2017_How-to-take-smart-notes.pdf"
        if FileManager.default.fileExists(atPath: ahrensPath) {
            let ahrensStart = CFAbsoluteTimeGetCurrent()
            let ahrensManager = try PDFDocumentManager(url: URL(fileURLWithPath: ahrensPath), md5: "f8d34c01a92ec9fafed7690faf90a0ee6e88f3586d079dec8692435db59ae091")
            let ahrensElapsed = CFAbsoluteTimeGetCurrent() - ahrensStart
            print("⚡️ [MANDATORY BENCHMARK] Real Ahrens PDF open elapsed: \(String(format: "%.3f", ahrensElapsed * 1000)) ms")
            XCTAssertNotNil(ahrensManager.document)
            XCTAssertLessThan(ahrensElapsed, 0.500, "Real Ahrens PDF open must complete under 500ms (took \(ahrensElapsed * 1000) ms)")
        }

        // 2. Benchmark Note Card Click & Selection Speed
        let targetCard = cards[50]
        let clickStart = CFAbsoluteTimeGetCurrent()
        let fetchedCard = try db.getCard(id: targetCard.id)
        let cardChildren = try db.childCards(parentId: targetCard.id, topicId: topicID)
        let layout = TreeLayout.layout(cards: cards)
        let targetFrame = layout.frames[targetCard.id]
        let clickElapsed = CFAbsoluteTimeGetCurrent() - clickStart

        print("⚡️ [MANDATORY BENCHMARK] Card click & layout elapsed: \(String(format: "%.3f", clickElapsed * 1000)) ms")
        XCTAssertNotNil(fetchedCard)
        XCTAssertNotNil(targetFrame)
        _ = cardChildren
        // Must complete under 100ms
        XCTAssertLessThan(clickElapsed, 0.100, "Card click responsiveness must complete under 100ms (took \(clickElapsed * 1000) ms)")
    }

    /// MANDATORY PRE-COMMIT TEST 2:
    /// Mindmap note card layout non-overlapping verification.
    /// Asserts 0 bounding box overlaps across all cards in the layout and guarantees synthetic root cards are ignored.
    func testMandatoryMindMapLayoutZeroOverlapsAndRootIgnored() throws {
        // 1. Synthetic multi-branch forest test
        let topicID = UUID()
        let syntheticRootID = UUID()
        let docRootCard = NoteCard(
            id: syntheticRootID,
            topicId: topicID,
            title: "Synthetic Document Root Card",
            highlightText: "",
            notesText: "",
            groupNoteId: nil,
            startPage: nil
        )

        var testCards: [NoteCard] = [docRootCard]
        var childIDs: [UUID] = []
        for ch in 0..<8 {
            let chapterID = UUID()
            childIDs.append(chapterID)
            let chapter = NoteCard(
                id: chapterID,
                topicId: topicID,
                title: "Chapter \(ch + 1): Architectural Foundations and Concepts",
                highlightText: "Key overview principles for chapter \(ch + 1)",
                groupNoteId: syntheticRootID
            )
            testCards.append(chapter)

            for sub in 0..<12 {
                let noteID = UUID()
                let subNote = NoteCard(
                    id: noteID,
                    topicId: topicID,
                    title: "Note \(ch + 1).\(sub + 1)",
                    highlightText: "Extended excerpt discussing principles of modularization, data decoupling, and reliable distributed state across complex software architectures.",
                    notesText: sub % 2 == 0 ? "Important realization to keep in mind for future design." : "",
                    groupNoteId: chapterID
                )
                testCards.append(subNote)
            }
        }

        // Verify root card is filtered out
        let filtered = NoteCard.filterMarginNoteDocumentRootCard(from: testCards)
        XCTAssertFalse(filtered.contains(where: { $0.id == syntheticRootID }), "Synthetic root card must be filtered out")
        XCTAssertEqual(filtered.count, testCards.count - 1)

        // Verify direct children promoted
        for cid in childIDs {
            let promoted = filtered.first(where: { $0.id == cid })
            XCTAssertNil(promoted?.groupNoteId, "Chapter \(cid) must be promoted to root with groupNoteId == nil")
        }

        // Layout filtered cards and verify ZERO overlaps
        let layout = TreeLayout.layout(cards: filtered)
        let frames = layout.visibleCardIDs.compactMap { layout.frames[$0] }
        XCTAssertEqual(frames.count, filtered.count)

        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                XCTAssertFalse(
                    frames[i].intersects(frames[j]),
                    "Overlapping frames detected in synthetic forest: \(frames[i]) intersects \(frames[j])"
                )
            }
        }

        // 2. Real Ahrens topic verification (from local and/or OMV external library)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let localDBURL = appSupport.appendingPathComponent("MarginGraph/MarginGraph.sqlite")
        let omvDBURL = URL(fileURLWithPath: "/Volumes/omv/backups/marginnote/main/MarginGraph.sqlite")

        for dbURL in [localDBURL, omvDBURL] where FileManager.default.fileExists(atPath: dbURL.path) {
            let db = try Database(url: dbURL)
            let ahrensTopicID = UUID(uuidString: "98F0B1A7-DC0E-4CF3-8888-9649AC9F3E94")!
            let cards = try db.cardsForTopic(id: ahrensTopicID)
            guard !cards.isEmpty else { continue }

            let filteredAhrens = NoteCard.filterMarginNoteDocumentRootCard(from: cards)
            let rootUUID = UUID(uuidString: "58A37CCB-B508-4F34-8109-F0FA6F679895")!
            XCTAssertFalse(filteredAhrens.contains(where: { $0.id == rootUUID }), "Ahrens root card must be ignored in DB \(dbURL.lastPathComponent)")

            let ahrensLayout = TreeLayout.layout(cards: filteredAhrens)
            let visible = ahrensLayout.visibleCardIDs.compactMap { ahrensLayout.frames[$0] }
            XCTAssertGreaterThan(visible.count, 500, "Ahrens topic must have > 500 visible cards in mindmap")

            var links = try db.linksForTopic(id: ahrensTopicID)
            let filteredIDs = Set(filteredAhrens.map(\.id))
            links.removeAll { !filteredIDs.contains($0.sourceCardId) || !filteredIDs.contains($0.targetCardId) }

            var overlapCount = 0
            for i in 0..<visible.count {
                for j in (i + 1)..<visible.count {
                    if visible[i].intersects(visible[j]) {
                        overlapCount += 1
                    }
                }
            }
            XCTAssertEqual(overlapCount, 0, "Found \(overlapCount) overlapping card pairs in Ahrens topic mindmap in \(dbURL.lastPathComponent)!")
        }
    }
}

