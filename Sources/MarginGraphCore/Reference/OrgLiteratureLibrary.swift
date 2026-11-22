import Foundation

public enum OrgLiteratureLibrary {
    public enum WriteError: LocalizedError {
        case duplicateReference(String)
        case filenameOccupied(String)
        case changed

        public var errorDescription: String? {
            switch self {
            case .duplicateReference(let key): "Several Org files already reference “\(key)”. Resolve the duplicates before exporting."
            case .filenameOccupied(let name): "A different note already uses “\(name)”."
            case .changed: "The Org note changed while exporting. Run the export again."
            }
        }
    }

    /// Find the existing Org-roam literature node by citation key before creating a new file.
    @discardableResult
    public static func write(_ generated: String, reference: BibTeXEntry, filename: String,
                             directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles])
        let matches = try files.filter {
            guard $0.pathExtension.lowercased() == "org",
                  try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return false }
            let handle = try FileHandle(forReadingFrom: $0)
            defer { try? handle.close() }
            let head = String(decoding: try handle.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
            return citationKeys(in: head).contains(reference.key)
        }
        guard matches.count <= 1 else { throw WriteError.duplicateReference(reference.key) }
        let target = matches.first ?? directory.appendingPathComponent(filename)
        var fileError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &fileError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let existing = try String(contentsOf: url, encoding: .utf8)
                    guard citationKeys(in: existing).contains(reference.key) else {
                        throw WriteError.filenameOccupied(url.lastPathComponent)
                    }
                    let result = merge(existing: existing, generated: generated)
                    guard result != existing else { return }
                    guard try String(contentsOf: url, encoding: .utf8) == existing else { throw WriteError.changed }
                    try result.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try Data(generated.utf8).write(to: url, options: .withoutOverwriting)
                }
            } catch { writeError = error }
        }
        if let writeError { throw writeError }
        if let fileError { throw fileError }
        return target
    }

    static func citationKeys(in org: String) -> Set<String> {
        var keys = Set<String>()
        for line in org.prefix(16_384).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("* ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix(":ROAM_REFS:") {
                for word in trimmed.dropFirst(":ROAM_REFS:".count).split(whereSeparator: \.isWhitespace) {
                    if word.hasPrefix("cite:&") { keys.insert(String(word.dropFirst(6))) }
                    else if word.hasPrefix("cite:") { keys.insert(String(word.dropFirst(5))) }
                }
            }
        }
        return keys
    }

    private struct Heading {
        let level: Int
        let title: String
        let start: Int
        var bodyEnd: Int
        var subtreeEnd: Int
        var id: UUID?
    }

    private static func outline(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var stack: [Int] = []
        var block: String?
        var readingProperties = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if let active = block {
                if trimmed == "#+end_\(active)" { block = nil }
                continue
            }
            if trimmed.hasPrefix("#+begin_") {
                block = trimmed.dropFirst(8).split(whereSeparator: \.isWhitespace).first.map(String.init)
                continue
            }
            let level = line.prefix { $0 == "*" }.count
            if level > 0 && line.dropFirst(level).first == " " {
                if let previous = result.indices.last { result[previous].bodyEnd = index }
                while let previous = stack.last, result[previous].level >= level {
                    result[previous].subtreeEnd = index
                    stack.removeLast()
                }
                result.append(Heading(level: level, title: String(line.dropFirst(level + 1)),
                                      start: index, bodyEnd: lines.count, subtreeEnd: lines.count))
                stack.append(result.count - 1)
                readingProperties = false
            } else if let current = result.indices.last {
                if trimmed == ":properties:" { readingProperties = true }
                if trimmed == ":end:" { readingProperties = false }
                if readingProperties, result[current].id == nil,
                   trimmed.hasPrefix(":id:") || trimmed.hasPrefix(":marginnote_link:") {
                    let value = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    result[current].id = UUID(uuidString: value.components(separatedBy: "/").last ?? value)
                }
            }
        }
        return result
    }

    /// Reuse existing card nodes and text. Insert only new headings, under the nearest known parent.
    static func merge(existing: String, generated: String) -> String {
        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let currentLines = existing.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let newLines = generated.components(separatedBy: "\n")
        let current = outline(currentLines)
        let incoming = outline(newLines)
        guard let root = incoming.first else { return existing }
        let matchingRoot = current.first { $0.level == 1 && $0.title == root.title }
        let rootCount = current.filter { $0.level == 1 }.count
        let existingRoot = matchingRoot ?? (rootCount == 1 ? current.first : nil)
        if current.isEmpty {
            let suffix = newLines[root.start...].joined(separator: newline)
            return existing + (existing.hasSuffix(newline) ? newline : newline + newline) + suffix
        }
        let indexed = Dictionary(current.compactMap { heading in heading.id.map { ($0, heading) } },
                                 uniquingKeysWith: { first, _ in first })
        struct Anchor: Hashable {
            let insertion: Int
            let level: Int
        }
        var additions: [Anchor: [String]] = [:]
        var parents: [(original: Int, output: Int, anchor: Anchor)] = []
        let end = Anchor(insertion: currentLines.count, level: 0)
        if let existingRoot {
            parents.append((1, existingRoot.level, Anchor(insertion: existingRoot.subtreeEnd, level: existingRoot.level)))
        } else {
            additions[end, default: []].append(contentsOf: newLines[root.start..<root.bodyEnd])
            parents.append((1, 1, end))
        }
        for heading in incoming.dropFirst() {
            while let parent = parents.last, parent.original >= heading.level { parents.removeLast() }
            let parent = parents.last ?? (1, 1, end)
            if let id = heading.id, let current = indexed[id] {
                parents.append((heading.level, current.level, Anchor(insertion: current.subtreeEnd, level: current.level)))
                continue
            }
            let level = parent.output + 1
            let title = String(repeating: "*", count: level) + " " + heading.title
            additions[parent.anchor, default: []].append(title)
            additions[parent.anchor, default: []].append(contentsOf: newLines[(heading.start + 1)..<heading.bodyEnd])
            parents.append((heading.level, level, parent.anchor))
        }
        guard !additions.isEmpty else { return existing }
        var output = currentLines
        // Insert earlier in the array last. When two ancestors end on the same line,
        // insert the deeper parent's children before the shallower parent's siblings.
        let anchors = additions.keys.sorted {
            $0.insertion == $1.insertion ? $0.level < $1.level : $0.insertion > $1.insertion
        }
        for anchor in anchors {
            let index = anchor.insertion
            var lines = additions[anchor] ?? []
            if index > 0 && !currentLines[index - 1].isEmpty { lines.insert("", at: 0) }
            if lines.last != "" { lines.append("") }
            output.insert(contentsOf: lines, at: index)
        }
        return output.joined(separator: newline)
    }
}
