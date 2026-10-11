import XCTest
@testable import MarginGraphCore

final class MindMapLayersTests: XCTestCase {
    func testChildMapOwnershipHierarchyAndCycleSafety() {
        let brainID = UUID(), cortexID = UUID(), detailID = UUID()
        let anchor = NoteCard(topicId: UUID(), title: "Child Map 0", mindLinks: [brainID])
        let brain = NoteCard(id: brainID, topicId: anchor.topicId, title: "Your Brain", mindLinks: [cortexID])
        let cortex = NoteCard(id: cortexID, topicId: anchor.topicId, title: "Prefrontal Cortex", mindLinks: [detailID])
        let detail = NoteCard(id: detailID, topicId: anchor.topicId, title: "Space", mindLinks: [brainID])
        let main = NoteCard(topicId: anchor.topicId, title: "Main note")
        let cards = [anchor, brain, cortex, detail, main]
        XCTAssertEqual(MindMapLayers.layer(for: cortexID, cards: cards), anchor.id)
        let child = MindMapLayers.cards(in: anchor.id, all: cards)
        XCTAssertEqual(Set(child.map(\.id)), [brainID, cortexID, detailID])
        XCTAssertNil(child.first { $0.id == brainID }?.groupNoteId)
        XCTAssertEqual(child.first { $0.id == cortexID }?.groupNoteId, brainID)
        XCTAssertEqual(child.first { $0.id == detailID }?.groupNoteId, cortexID)
        XCTAssertEqual(Set(MindMapLayers.cards(in: nil, all: cards).map(\.id)), [anchor.id, main.id])
        XCTAssertEqual(TreeLayout.layout(cards: child).visibleCardIDs.count, 3)
    }
}
