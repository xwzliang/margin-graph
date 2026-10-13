import XCTest
@testable import MarginGraphCore

final class NoteTextLinksTests: XCTestCase {
    let destination = UUID(uuidString: "56781743-0383-4A21-98B2-6335A9C87FC7")!
    func testImportedTitleResolvesWithoutShowingRawURL() throws {
        let text = "marginnote3app://note/\(destination)\n\nBasal Ganglia"
        let reference = try XCTUnwrap(NoteTextLinks.references(in: text).first)
        XCTAssertEqual(reference.target, destination)
        XCTAssertEqual(reference.label, "Basal Ganglia")
        XCTAssertEqual(NoteTextLinks.displayText(text), "Basal Ganglia")
        XCTAssertEqual(DeepLinkHandler.parse(URL(string: "marginnote3app://note/\(destination)")!), .openCard(cardId: destination))
    }
    func testMultipleMarkdownLinksPreserveSurroundingText() {
        let first = NoteTextLinks.markup(label: "Brain", target: destination)
        let text = "Before \(first) and \(first) after."
        XCTAssertEqual(NoteTextLinks.references(in: text).count, 2)
        XCTAssertEqual(NoteTextLinks.displayText(text), "Before Brain and Brain after.")
        XCTAssertTrue(NoteTextLinks.references(in: "https://example.com\nTitle").isEmpty)
        XCTAssertTrue(NoteTextLinks.references(in: "margin-graph://note/invalid").isEmpty)
    }
    func testCreateUpdateDeleteLinksPersistWithoutRemovingOtherText() throws {
        let db = try Database(inMemory: true)
        let topic = Topic(id: UUID(), title: "Links")
        try db.insertTopic(topic)
        var card = NoteCard(id: UUID(), topicId: topic.id, title: "Source")
        card.notesText = "🧠 Context\n\n" + NoteTextLinks.markup(label: "Brain", target: destination)
        try db.insertCard(card)
        var saved = try XCTUnwrap(db.getCard(id: card.id))
        let reference = try XCTUnwrap(NoteTextLinks.references(in: saved.notesText).first)
        let next = UUID()
        saved.notesText = NoteTextLinks.replacing(in: saved.notesText, edits: [(reference.range, NoteTextLinks.markup(label: "Updated", target: next))])
        try db.updateCard(saved)
        saved = try XCTUnwrap(db.getCard(id: card.id))
        XCTAssertEqual(NoteTextLinks.references(in: saved.notesText).first?.target, next)
        XCTAssertEqual(NoteTextLinks.displayText(saved.notesText), "🧠 Context\n\nUpdated")
        saved.notesText = NoteTextLinks.replacing(in: saved.notesText, edits: [(NoteTextLinks.references(in: saved.notesText)[0].range, "")])
        try db.updateCard(saved)
        XCTAssertEqual(try db.getCard(id: card.id)?.notesText, "🧠 Context\n\n")
    }

    func testConnectionsRequireBothCardsAndDeduplicateTargets() {
        let topic = UUID()
        let target = NoteCard(id: destination, topicId: topic, title: "Basal Ganglia")
        var source = NoteCard(id: UUID(), topicId: topic, title: "Automatic habit")
        source.notesText = NoteTextLinks.markup(label: "Basal Ganglia", target: destination)
        source.highlightText = source.notesText
        XCTAssertEqual(NoteTextLinks.connections(in: [source, target]).count, 1)
        XCTAssertTrue(NoteTextLinks.connections(in: [source]).isEmpty)
    }
}
