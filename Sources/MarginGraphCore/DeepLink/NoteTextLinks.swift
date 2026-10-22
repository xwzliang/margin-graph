import Foundation
import SwiftUI

/// Text references are kept in the note itself so imports and exports retain them.
public enum NoteTextLinks {
    public struct Reference: Identifiable, Equatable {
        public var id: Int { range.location }
        public let range: NSRange
        public let target: UUID
        public let label: String
    }

    private static let regex: NSRegularExpression = {
        let uuid = "[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
        let url = "(?:margin-graph|marginnote3app)://note/(\(uuid))"
        let pattern = "\\[([^\\]\\n]+)\\]\\(\(url)\\)|\(url)(?:[ \\t]*\\r?\\n(?:[ \\t]*\\r?\\n)*([^\\r\\n]+))?"
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    public static func references(in text: String) -> [Reference] {
        guard text.localizedCaseInsensitiveContains("://note/") else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let markdown = match.range(at: 2).location != NSNotFound
            let idRange = match.range(at: markdown ? 2 : 3)
            guard let target = UUID(uuidString: source.substring(with: idRange)) else { return nil }
            let labelRange = match.range(at: markdown ? 1 : 4)
            let label = labelRange.location == NSNotFound ? "Open linked note" : source.substring(with: labelRange)
            return Reference(range: match.range, target: target, label: label)
        }
    }

    public static func attributed(_ text: String) -> AttributedString {
        let source = text as NSString
        var result = AttributedString()
        var offset = 0
        for reference in references(in: text) {
            result.append(AttributedString(source.substring(with: NSRange(location: offset, length: reference.range.location - offset))))
            var link = AttributedString(reference.label)
            link.link = DeepLinkHandler.url(forCard: reference.target)
            link.foregroundColor = .blue
            link.underlineStyle = .single
            result.append(link)
            offset = NSMaxRange(reference.range)
        }
        result.append(AttributedString(source.substring(from: offset)))
        return result
    }

    public static func displayText(_ text: String) -> String {
        let matches = references(in: text)
        guard !matches.isEmpty else { return text }
        return replacing(in: text, edits: matches.map { ($0.range, $0.label) })
    }

    public static func markup(label: String, target: UUID) -> String {
        let title = label.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
        return "[\(title.isEmpty ? "Open linked note" : title)](\(DeepLinkHandler.url(forCard: target).absoluteString))"
    }

    /// Replace existing references from the end so Unicode ranges stay valid.
    public static func replacing(in text: String, edits: [(range: NSRange, replacement: String)]) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location != NSNotFound, NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    public static func connections(in cards: [NoteCard]) -> [CardLink] {
        let topics = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.topicId) })
        return cards.flatMap { card in
            var seen = Set<UUID>()
            return references(in: card.highlightText + "\n" + card.notesText).compactMap { reference -> CardLink? in
                guard reference.target != card.id, topics[reference.target] == card.topicId, seen.insert(reference.target).inserted else { return nil }
                return CardLink(id: Document.stableUUID("text-link-\(card.id)-\(reference.target)"), topicId: card.topicId,
                                sourceCardId: card.id, targetCardId: reference.target, label: reference.label)
            }
        }
    }
}
