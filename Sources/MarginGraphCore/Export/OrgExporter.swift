import Foundation

public enum OrgExporter {
    /// Pass the notebook's full set of displayed cards, including folded notes and child maps.
    public static func export(
        topic: Topic,
        cards: [NoteCard],
        documents: [Document] = [],
        timeZone: TimeZone = .current
    ) -> String {
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.calendar = Calendar(identifier: .gregorian)
        timestamp.timeZone = timeZone
        timestamp.dateFormat = "yyyy-MM-dd EEE HH:mm"

        let cardIDs = Set(cards.map(\.id))
        var parents: [UUID: UUID] = [:]
        for card in cards {
            if let parent = card.groupNoteId, parent != card.id, cardIDs.contains(parent) {
                parents[card.id] = parent
            }
        }
        var assignedToMap = Set<UUID>()
        for anchor in MindMapLayers.anchors(in: cards) {
            let mapCards = MindMapLayers.cards(in: anchor.id, all: cards)
            let members = Set(mapCards.map(\.id))
            for card in mapCards where assignedToMap.insert(card.id).inserted {
                if let parent = card.groupNoteId, parent != card.id, members.contains(parent) {
                    parents[card.id] = parent
                } else {
                    parents[card.id] = anchor.id
                }
            }
        }
        let ordered = cards.sorted(by: TreeLayout.cardOrder)
        let children = Dictionary(grouping: ordered, by: { parents[$0.id] })
        var lines = ["#+TITLE: \(singleLine(topic.title))", ""]
        var visited = Set<UUID>()

        // The second pass gives any disconnected cycles a root and still emits each note once.
        for root in (children[nil] ?? []) + ordered {
            var pending: [(card: NoteCard, level: Int)] = [(root, 1)]
            while let (card, level) = pending.popLast() {
                guard visited.insert(card.id).inserted else { continue }
                let excerpt = card.highlightText.isEmpty
                    ? card.excerptSegments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    : card.highlightText
                let title = headingTitle(card.title, excerpt: excerpt)
                let (tags, otherTags) = card.tags.reduce(into: ([String](), [String]())) { result, tag in
                    if !tag.isEmpty, tag.unicodeScalars.allSatisfy(tagCharacters.contains) {
                        result.0.append(tag)
                    } else if !tag.isEmpty {
                        result.1.append(singleLine(tag))
                    }
                }
                let tagSuffix = tags.isEmpty ? "" : " :\(tags.joined(separator: ":")):"
                lines.append("\(String(repeating: "*", count: level)) \(title)\(tagSuffix)")
                lines.append(contentsOf: [
                    ":PROPERTIES:",
                    ":ID: \(card.id.uuidString)",
                    ":CREATED: [\(timestamp.string(from: card.createdAt))]",
                    ":MODIFIED: [\(timestamp.string(from: card.updatedAt))]",
                    ":MARGINNOTE_LINK: marginnote3app://note/\(card.id.uuidString)",
                    ":MARGINGRAPH_LINK: \(card.deepLinkURL.absoluteString)"
                ])
                if card.mediaType == "video" || card.videoStartTime != nil {
                    if let hash = card.bookMD5,
                       let document = documents.first(where: { Database.bookHashesMatch(hash, $0.md5) }),
                       !document.filePath.isEmpty {
                        lines.append(":MPV_VIDEO_FILENAME: \(singleLine(URL(fileURLWithPath: document.filePath).lastPathComponent))")
                    }
                    if let start = videoTimestamp(card.videoStartTime) {
                        lines.append(":MPV_POSITION_START: \(start)")
                    }
                    if let end = videoTimestamp(card.videoEndTime) {
                        lines.append(":MPV_POSITION_END: \(end)")
                    }
                } else {
                    if let start = card.startPage, start >= 0 {
                        lines.append(":NOTER_PAGE: \(UInt(start) + 1)")
                    }
                    if let end = card.endPage, end >= 0 {
                        lines.append(":NOTER_PAGE_END: \(UInt(end) + 1)")
                    }
                }
                lines.append(":HIGHLIGHT_COLOR_INDEX: \(card.colorIndex)")
                let merged = !card.notesText.isEmpty || card.excerptSegments.count > 1
                lines.append(":IS_MERGED: \(merged)")
                if !otherTags.isEmpty {
                    lines.append(":MARGINGRAPH_TAGS: \(otherTags.joined(separator: ", "))")
                }
                lines.append(":END:")

                for body in [excerpt, card.notesText] where !body.isEmpty {
                    lines.append(orgBody(body, cardIDs: cardIDs))
                    lines.append("")
                }
                if lines.last != "" { lines.append("") }
                for child in (children[card.id] ?? []).reversed() {
                    pending.append((child, level + 1))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@#%"))
    private static let structuralLine = try! NSRegularExpression(pattern: #"^(?:\*+[ \t]|[ \t]*(?:#\+|:[\w@#%]+:[ \t]*$|%%\())"#)

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func headingTitle(_ title: String, excerpt: String) -> String {
        let title = singleLine(title)
        if !title.isEmpty { return title }
        let displayText = NoteTextLinks.displayText(excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = displayText.split(whereSeparator: \.isNewline).first else { return "Untitled" }
        let limit = firstLine.index(firstLine.startIndex, offsetBy: 80, limitedBy: firstLine.endIndex)
        guard let limit, limit < firstLine.endIndex else { return String(firstLine) }
        return firstLine[..<limit] + "…"
    }

    private static func orgBody(_ text: String, cardIDs: Set<UUID>) -> String {
        let edits = NoteTextLinks.references(in: text).map { reference in
            let target = cardIDs.contains(reference.target)
                ? "id:\(reference.target.uuidString)"
                : DeepLinkHandler.url(forCard: reference.target).absoluteString
            let label = reference.label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            return (reference.range, "[[\(target)][\(label)]]")
        }
        let linkedText = NoteTextLinks.replacing(in: text, edits: edits)
        return linkedText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in
                let value = String(line)
                // Keep quoted headlines and directives as literal Org example lines.
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                return structuralLine.firstMatch(in: value, range: range) == nil ? value : ": \(value)"
            }
            .joined(separator: "\n")
    }

    private static func videoTimestamp(_ time: Double?) -> String? {
        guard let time, time >= 0, time < Double(Int64.max) else { return nil }
        let seconds = Int64(time)
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
