import XCTest
import CoreGraphics
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
}
