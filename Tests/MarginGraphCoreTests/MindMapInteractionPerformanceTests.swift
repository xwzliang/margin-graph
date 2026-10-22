import XCTest
@testable import MarginGraphCore

final class MindMapInteractionPerformanceTests: XCTestCase {
    func testDragTargetsExcludeDescendantsAndHandleCycles() {
        let topic = UUID(), a = UUID(), b = UUID(), c = UUID(), target = UUID()
        let cards = [NoteCard(id: a, topicId: topic, title: "Root", groupNoteId: c),
                     NoteCard(id: b, topicId: topic, title: "Child", groupNoteId: a),
                     NoteCard(id: c, topicId: topic, title: "Grandchild", groupNoteId: b),
                     NoteCard(id: target, topicId: topic, title: "Target")]
        let frames = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($0.element.id, CGRect(x: $0.offset * 100, y: 0, width: 80, height: 50)) })
        let index = MindMapDragTargets(draggedID: a, cards: cards, frames: frames, visible: Set(cards.map(\.id)))
        XCTAssertEqual(index.excludedIDs, [a, b, c])
        XCTAssertNil(index.target(at: CGPoint(x: 110, y: 10)))
        XCTAssertEqual(index.target(at: CGPoint(x: 310, y: 10)), target)
    }

    func testLargeNotebookDragHitTestingAndPlainTextResolutionBudget() {
        let topic = UUID()
        let cards = (0..<1200).map { NoteCard(id: UUID(), topicId: topic, title: "Note \($0)") }
        let frames = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($0.element.id, CGRect(x: ($0.offset % 30) * 250, y: ($0.offset / 30) * 100, width: 220, height: 70)) })
        let start = Date()
        let index = MindMapDragTargets(draggedID: cards[0].id, cards: cards, frames: frames, visible: Set(cards.map(\.id)))
        for step in 0..<600 {
            _ = index.target(at: CGPoint(x: (step % 30) * 250 + 20, y: (step % 40) * 100 + 20))
            XCTAssertEqual(NoteTextLinks.displayText("Ordinary excerpt without any note references."), "Ordinary excerpt without any note references.")
        }
        let elapsed = Date().timeIntervalSince(start)
        print("1200-card drag index + 600 hit tests/text resolutions: \(elapsed * 1000) ms")
        XCTAssertLessThan(elapsed, 0.1)
    }
}
