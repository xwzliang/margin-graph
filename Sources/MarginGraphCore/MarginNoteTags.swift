import Foundation

/// MarginNote exports a notebook's hashtag catalog in ZTOPIC.ZHASHTAGS.
/// An assigned hashtag can appear as its own archived TextNote entry.
enum MarginNoteTags {
    struct Assignment {
        var tags: [String] = []
        var tagComments: [String: Int] = [:]

        func appendingComments(to text: String, activeTags: [String], moveArchivedEntries: Bool) -> String {
            let active = Set(activeTags.map { $0.lowercased() })
            let hashtags = tags.filter { active.contains($0.lowercased()) }.map { "#" + $0 }
            guard !hashtags.isEmpty else { return text }

            let body = moveArchivedEntries ? removingArchivedEntries(from: text) : text
            let existingLines = Set(body.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            })
            let missing = hashtags.filter { !existingLines.contains($0.lowercased()) }
            guard !missing.isEmpty else { return body }

            let newline = text.contains("\r\n") ? "\r\n" : "\n"
            let separator = body.isEmpty || body.last?.isNewline == true ? "" : newline
            return body + separator + missing.joined(separator: newline)
        }

        private func removingArchivedEntries(from text: String) -> String {
            guard !tagComments.isEmpty, !text.isEmpty else { return text }
            if tagComments[text.trimmingCharacters(in: .whitespacesAndNewlines)] != nil { return "" }

            var matches = [String: [Range<String.Index>]]()
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, range, _ in
                guard let entry = line?.trimmingCharacters(in: .whitespaces), tagComments[entry] != nil else { return }
                matches[entry, default: []].append(range)
            }
            // Leave ambiguous duplicates intact if the flattened text contains
            // more occurrences than the source has standalone tag entries.
            let ranges = matches.flatMap { entry, ranges in
                ranges.count == tagComments[entry] ? ranges : []
            }.sorted { $0.lowerBound < $1.lowerBound }
            guard !ranges.isEmpty else { return text }
            var comments = ""
            var start = text.startIndex
            for range in ranges {
                comments += text[start..<range.lowerBound]
                start = range.upperBound
            }
            comments += text[start...]
            return comments
        }
    }

    static func catalog(_ raw: String?) -> [String: String] {
        guard let raw else { return [:] }
        let list = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8)))
            ?? raw.split { $0 == "|" || $0 == "," || $0 == ";" || $0.isNewline }.map(String.init)
        var result = [String: String]()
        for entry in list {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = value.split(whereSeparator: \.isWhitespace)
            let names = words.allSatisfy { $0.hasPrefix("#") } ? words.map(String.init) : [value]
            for name in names where name.hasPrefix("#") && name.count > 1 {
                let key = name.lowercased()
                if result[key] == nil { result[key] = String(name.dropFirst()) }
            }
        }
        return result
    }

    static func assigned(in entries: [[String: Any]], catalog: [String: String]) -> Assignment {
        guard !catalog.isEmpty else { return Assignment() }
        var result = Assignment()
        for entry in entries {
            guard entry["type"] as? String == "TextNote", let text = entry["text"] as? String else { continue }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let names: [String]
            if let tag = catalog[value.lowercased()] {
                names = [tag]
            } else {
                let words = value.lowercased().split(whereSeparator: \.isWhitespace)
                names = words.compactMap { catalog[String($0)] }
                guard names.count == words.count, !names.isEmpty else { continue }
            }
            result.tags = adding(names, to: result.tags)
            result.tagComments[value, default: 0] += 1
        }
        return result
    }

    static func adding(_ imported: [String], to existing: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        return existing + imported.filter { seen.insert($0.lowercased()).inserted }
    }
}
