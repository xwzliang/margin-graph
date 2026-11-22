import Foundation

public enum OrgExporter {
    public enum ReferenceKind: Sendable {
        case book
        case video
    }

    /// Use the notebook's creation time so subsequent exports suggest the same filename.
    public static func suggestedFilename(for topic: Topic, timeZone: TimeZone = .current) -> String {
        let stamp = formatter("yyyyMMddHHmmss", timeZone: timeZone).string(from: topic.createdAt)
        let title = singleLine(topic.title).folding(options: .diacriticInsensitive, locale: posixLocale)
        let slug = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        var result = ""
        var width = 0
        for character in slug {
            // Org-roam's truncate-string-to-width counts wide CJK characters as two columns.
            let characterWidth = String(character).range(of: wideCharacter, options: .regularExpression) == nil ? 1 : 2
            guard width + characterWidth <= 60 else { break }
            width += characterWidth
            result.append(character)
        }
        return "\(stamp)-\(result.isEmpty ? "untitled" : result.lowercased()).org"
    }

    /// Pass the notebook's full set of displayed cards, including folded notes and child maps.
    public static func export(
        topic: Topic,
        cards: [NoteCard],
        documents: [Document] = [],
        reference: BibTeXEntry? = nil,
        referenceKind: ReferenceKind? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        let timestamp = formatter("yyyy-MM-dd EEE HH:mm", timeZone: timeZone)
        let candidateTitle = singleLine(reference.flatMap { $0.title.isEmpty ? nil : $0.title } ?? topic.title)
        let title = candidateTitle.isEmpty ? "Untitled" : candidateTitle
        let documentPaths = documents.compactMap { document -> (hash: String, path: String)? in
            guard document.documentType == "pdf", !document.filePath.isEmpty else { return nil }
            return (document.md5, singleLine(document.filePath))
        }
        let inheritedPath = documents.count == 1 ? documentPaths.first?.path : nil
        var sourceTags = documents.isEmpty
            ? [cards.isEmpty || cards.contains(where: { !isMedia($0) }) ? "book" : "video"]
            : ["book", "video"].filter { tag in
                documents.contains { document in
                    (document.documentType == "video" || document.documentType == "audio") == (tag == "video")
                }
            }

        let videoReference = reference.map { ["movie", "video", "audio"].contains($0.type) } ?? false
        if let referenceKind {
            sourceTags = referenceKind == .video ? ["video"] : ["book"]
        } else if documents.isEmpty, videoReference {
            sourceTags = ["video"]
        }
        if let reference, tagCharacters.isSuperset(of: CharacterSet(charactersIn: reference.key)) {
            sourceTags.insert(reference.key, at: 0)
        }
        let referenceFile = singleLine(reference?.fields["file"] ?? "")
        let videoDirectory: String? = sourceTags.contains("video") && !sourceTags.contains("book") ? {
            let folders = Set(documents.filter { !$0.filePath.isEmpty }.map {
                URL(fileURLWithPath: $0.filePath).deletingLastPathComponent().path
            })
            if folders.count == 1 { return folders.first }
            guard documents.isEmpty, !referenceFile.isEmpty else { return nil }
            let url = URL(fileURLWithPath: referenceFile)
            let videoExtensions = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "m4a", "mp3", "wav"]
            return videoExtensions.contains(url.pathExtension.lowercased())
                ? url.deletingLastPathComponent().path : referenceFile
        }() : nil

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
        var lines = [
            ":PROPERTIES:",
            ":ID:       \(topic.id.uuidString.lowercased())",
        ]
        if let reference { lines.append(":ROAM_REFS: cite:&\(reference.key)") }
        lines.append(contentsOf: [
            ":END:",
            "#+title: \(title)",
            "#+filetags: :\((sourceTags + ["literature"]).joined(separator: ":")):",
            "",
            "* \(title)"
        ])
        if sourceTags.contains("book") {
            let path = inheritedPath ?? (documents.isEmpty ? referenceFile : "")
            let property = path.isEmpty ? ":NOTER_DOCUMENT:" : ":NOTER_DOCUMENT: \(path)"
            lines.append(contentsOf: [":PROPERTIES:", property, ":END:"])
        } else if sourceTags.contains("video") {
            let property = videoDirectory.map { ":MPV_VIDEO_DIRECTORY: \($0)" } ?? ":MPV_VIDEO_DIRECTORY:"
            lines.append(contentsOf: [":PROPERTIES:", property, ":END:"])
        }
        lines.append("")
        var visited = Set<UUID>()

        // The second pass gives any disconnected cycles a root and still emits each note once.
        for root in (children[nil] ?? []) + ordered {
            var pending: [(card: NoteCard, level: Int)] = [(root, 2)]
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
                    ":ID:       \(card.id.uuidString)",
                    ":CREATED: [\(timestamp.string(from: card.createdAt))]",
                    ":MODIFIED: [\(timestamp.string(from: card.updatedAt))]"
                ])
                if isMedia(card) {
                    if let hash = card.bookMD5,
                       let document = documents.first(where: { Database.bookHashesMatch(hash, $0.md5) }),
                       !document.filePath.isEmpty {
                        let url = URL(fileURLWithPath: document.filePath)
                        if videoDirectory == nil {
                            lines.append(":MPV_VIDEO_DIRECTORY: \(singleLine(url.deletingLastPathComponent().path))")
                        }
                        lines.append(":MPV_VIDEO_FILENAME: \(singleLine(url.lastPathComponent))")
                    }
                    if let start = videoTimestamp(card.videoStartTime) {
                        lines.append(":MPV_POSITION_START: \(start)")
                    }
                    if let end = videoTimestamp(card.videoEndTime) {
                        lines.append(":MPV_POSITION_END: \(end)")
                    }
                } else {
                    if inheritedPath == nil, let hash = card.bookMD5,
                       let source = documentPaths.first(where: { Database.bookHashesMatch(hash, $0.hash) }) {
                        lines.append(":NOTER_DOCUMENT: \(source.path)")
                    }
                    if let start = card.startPage, start >= 0 {
                        lines.append(":NOTER_PAGE: \(UInt(start) + 1)")
                    }
                    if let end = card.endPage, end >= 0 {
                        lines.append(":NOTER_PAGE_END: \(UInt(end) + 1)")
                    }
                }
                lines.append(":HIGHLIGHT_COLOR_INDEX: \(card.colorIndex)")
                lines.append(":MARGINNOTE_LINK: marginnote3app://note/\(card.id.uuidString)")
                lines.append(":MARGINGRAPH_LINK: \(card.deepLinkURL.absoluteString)")
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

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let wideCharacter = #"\p{ea=W}|\p{ea=F}"#

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func isMedia(_ card: NoteCard) -> Bool {
        card.mediaType == "video" || card.mediaType == "audio" || card.videoStartTime != nil
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
