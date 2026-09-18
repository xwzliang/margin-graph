import Foundation

public enum AnkiExporter {
    public static func export(topic: Topic, cards: [NoteCard]) -> String {
        var lines = ["Front\tBack\tTags\tSourceBook\tPage"]
        for card in cards.sorted(by: cardOrder) {
            let frontSource = card.highlightText.isEmpty ? card.title : card.highlightText
            let front = sanitize(ClozeParser.masked(frontSource))
            let revealed = ClozeParser.revealed(card.highlightText)
            let backParts = [revealed, card.notesText].filter { !$0.isEmpty }
            let back = sanitize(backParts.joined(separator: "\n\n"))
            let tags = sanitize(card.tags.joined(separator: " "))
            let sourceBook = sanitize(card.bookMD5 ?? "")
            let page = card.startPage.map { String($0 + 1) } ?? ""
            lines.append([front, back, tags, sourceBook, page].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static func cardOrder(_ lhs: NoteCard, _ rhs: NoteCard) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.createdAt < rhs.createdAt
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
