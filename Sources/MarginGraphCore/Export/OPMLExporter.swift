import Foundation

public enum OPMLExporter {
    public static func export(topic: Topic, cards: [NoteCard]) -> String {
        let grouped = OutlineHierarchy.group(cards)
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\">",
            "  <head>",
            "    <title>\(xml(topic.title))</title>",
            "  </head>",
            "  <body>"
        ]

        func append(_ card: NoteCard, depth: Int) {
            let indent = String(repeating: "  ", count: depth + 2)
            let text = xml(card.title.isEmpty ? "Untitled" : card.title)
            var noteParts: [String] = []
            if !card.highlightText.isEmpty { noteParts.append(card.highlightText) }
            if !card.notesText.isEmpty { noteParts.append(card.notesText) }
            if !card.tags.isEmpty { noteParts.append(card.tags.map { "#\($0)" }.joined(separator: " ")) }
            if !card.mindLinks.isEmpty {
                noteParts.append("Relations: " + card.mindLinks.map(\.uuidString).joined(separator: ", "))
            }
            let note = xml(noteParts.joined(separator: "\n\n"))
            let children = grouped[card.id] ?? []

            if children.isEmpty {
                lines.append("\(indent)<outline text=\"\(text)\" _note=\"\(note)\"/>")
            } else {
                lines.append("\(indent)<outline text=\"\(text)\" _note=\"\(note)\">")
                for child in children {
                    append(child, depth: depth + 1)
                }
                lines.append("\(indent)</outline>")
            }
        }

        for root in grouped[nil] ?? [] {
            append(root, depth: 0)
        }

        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }
}
