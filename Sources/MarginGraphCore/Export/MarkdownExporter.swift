import Foundation

public enum MarkdownExporter {
    public static func export(topic: Topic, cards: [NoteCard]) -> String {
        let grouped = OutlineHierarchy.group(cards)
        var lines: [String] = ["# \(escape(topic.title))", ""]

        func append(_ card: NoteCard, depth: Int) {
            if depth == 0 {
                lines.append("## \(escape(card.title.isEmpty ? "Untitled" : card.title))")
            } else {
                let indent = String(repeating: "  ", count: max(0, depth - 1))
                lines.append("\(indent)- **\(escape(card.title.isEmpty ? "Untitled" : card.title))**")
            }

            let contentIndent = depth == 0 ? "" : String(repeating: "  ", count: depth)
            if !card.highlightText.isEmpty {
                for line in card.highlightText.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("\(contentIndent)> \(line)")
                }
            }
            if !card.notesText.isEmpty {
                lines.append("\(contentIndent)\(card.notesText)")
            }
            if !card.tags.isEmpty {
                lines.append("\(contentIndent)\(card.tags.map { "#\($0)" }.joined(separator: " "))")
            }
            if !card.mindLinks.isEmpty {
                lines.append("\(contentIndent)Relations: \(card.mindLinks.map { "[\($0.uuidString)]" }.joined(separator: ", "))")
            }
            lines.append("")

            for child in grouped[card.id] ?? [] {
                append(child, depth: depth + 1)
            }
        }

        for root in grouped[nil] ?? [] {
            append(root, depth: 0)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }
}
