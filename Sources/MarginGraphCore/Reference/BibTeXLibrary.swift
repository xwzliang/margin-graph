import Foundation

public struct BibTeXEntry: Identifiable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let fields: [String: String]
    public let source: String
    public var id: String { key }

    public var title: String { Self.visibleText(fields["title"] ?? "") }
    public var author: String { Self.visibleText(fields["author"] ?? fields["editor"] ?? "") }
    public var year: String {
        fields["year"] ?? String((fields["date"] ?? "").prefix(4))
    }

    /// Strip grouping and common LaTeX punctuation for display. Keep the original BibTeX for saves.
    public static func visibleText(_ text: String) -> String {
        text.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: #"\\([&#%_$])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum BibTeXError: LocalizedError {
    case malformed(String)
    case duplicate(String)
    case invalidEntry
    case changed(String)
    case keyChanged

    public var errorDescription: String? {
        switch self {
        case .malformed(let entry): "Unclosed BibTeX entry near \(entry)."
        case .duplicate(let key): "The citation key “\(key)” already exists."
        case .invalidEntry: "Enter exactly one BibTeX entry with a citation key."
        case .changed(let key): "“\(key)” changed on disk. Reload the bibliography and try again."
        case .keyChanged: "Keep the existing citation key to preserve links from your notes."
        }
    }
}

/// Edits replace byte ranges in the latest on-disk file, preserving untouched entries, comments,
/// macros, line endings, and Ebib's file-wide metadata.
public struct BibTeXLibrary: Sendable {
    private let bytes: [UInt8]
    private let records: [Record]
    private struct Record: Sendable {
        let range: Range<Int>
        let entry: BibTeXEntry
    }

    public var entries: [BibTeXEntry] { records.map(\.entry) }

    public init(source: String) throws {
        let bytes = Array(source.utf8)
        self.bytes = bytes
        var position = 0
        var records: [Record] = []
        var macros: [String: String] = [:]
        while position < bytes.count {
            if bytes[position] == 37 {
                position = Self.endOfLine(bytes, from: position)
                continue
            }
            guard bytes[position] == 64 else {
                position += 1
                continue
            }
            let start = position
            position += 1
            let typeStart = position
            while position < bytes.count, Self.isName(bytes[position]) { position += 1 }
            let type = Self.text(bytes, typeStart..<position).lowercased()
            Self.skipWhitespace(bytes, position: &position, end: bytes.count)
            guard !type.isEmpty, position < bytes.count, bytes[position] == 123 || bytes[position] == 40 else {
                if type == "comment" { position = Self.endOfLine(bytes, from: position) }
                continue
            }
            let open = position
            guard let close = Self.entryEnd(bytes, open: open) else {
                throw BibTeXError.malformed(Self.text(bytes, start..<min(open + 40, bytes.count)))
            }
            position = close + 1
            if type == "preamble" || type == "comment" { continue }
            if type == "string" {
                for (name, value) in Self.fields(bytes, from: open + 1, to: close, macros: macros) {
                    macros[name] = value
                }
                continue
            }
            let comma = (open + 1..<close).first { bytes[$0] == 44 } ?? close
            let key = Self.text(bytes, open + 1..<comma).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validKey(key) else { continue }
            let entry = BibTeXEntry(key: key, type: type,
                fields: Self.fields(bytes, from: min(comma + 1, close), to: close, macros: macros),
                source: Self.text(bytes, start..<position))
            records.append(Record(range: start..<position, entry: entry))
        }
        self.records = records
    }

    public static func load(_ url: URL) throws -> Self {
        try Self(source: String(contentsOf: url, encoding: .utf8))
    }

    public static func entry(_ source: String) throws -> BibTeXEntry {
        let parsed = try Self(source: source)
        guard let entry = parsed.entries.first, parsed.entries.count == 1,
              entry.source == source.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw BibTeXError.invalidEntry
        }
        return entry
    }

    /// A citation key can be used in both BibTeX and Org's cite:&key form.
    public static func validKey(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-.:+/@!?*".unicodeScalars.contains($0)
        }
    }

    public static func rendered(type: String, key: String, fields: [String: String]) -> String {
        let lines = fields.keys.sorted().compactMap { name -> String? in
            guard let value = fields[name], !value.isEmpty else { return nil }
            // Plain lookup text can include literal braces and percent characters.
            let escaped = value.replacingOccurrences(of: #"([{}%])"#, with: #"\\$1"#, options: .regularExpression)
            return "    \(name) = {\(escaped)}"
        }
        return "@\(type){\(key),\n" + lines.joined(separator: ",\n") + "\n}"
    }

    public static func save(_ entry: BibTeXEntry, replacing original: BibTeXEntry? = nil, in url: URL) throws {
        try coordinate(url) { actualURL in
            let current = try load(actualURL)
            if let original {
                guard entry.key == original.key else { throw BibTeXError.keyChanged }
                return try current.replacing(original, with: entry.source)
            }
            guard !current.records.contains(where: { $0.entry.key == entry.key }) else {
                throw BibTeXError.duplicate(entry.key)
            }
            if current.bytes.isEmpty { return Data((entry.source + "\n").utf8) }
            let newline = current.bytes.last == 10 ? "\n" : "\n\n"
            return Data(current.bytes + Array((newline + entry.source + "\n").utf8))
        }
    }

    public static func delete(_ entry: BibTeXEntry, from url: URL) throws {
        try coordinate(url) { try load($0).replacing(entry, with: "") }
    }

    private static func coordinate(_ url: URL, edit: (URL) throws -> Data) throws {
        var error: NSError?
        var editError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
            do { try edit(target).write(to: target, options: .atomic) }
            catch { editError = error }
        }
        if let editError { throw editError }
        if let error { throw error }
    }

    private func replacing(_ original: BibTeXEntry, with content: String) throws -> Data {
        let matches = records.filter { $0.entry.key == original.key }
        guard matches.count < 2 else { throw BibTeXError.duplicate(original.key) }
        guard let record = matches.first, record.entry.source == original.source else {
            throw BibTeXError.changed(original.key)
        }
        var result = bytes
        result.replaceSubrange(record.range, with: content.utf8)
        return Data(result)
    }

    private static func entryEnd(_ bytes: [UInt8], open: Int) -> Int? {
        let close: UInt8 = bytes[open] == 123 ? 125 : 41
        var position = open + 1
        var braces = 0
        var quoted = false
        while position < bytes.count {
            switch bytes[position] {
            case 92: position += 2; continue
            case 37 where braces == 0 && !quoted:
                position = endOfLine(bytes, from: position)
                continue
            case 34 where braces == 0: quoted.toggle()
            case 123: braces += 1
            case 125 where braces > 0: braces -= 1
            case close where braces == 0 && !quoted: return position
            default: break
            }
            position += 1
        }
        return nil
    }

    private static func fields(_ bytes: [UInt8], from start: Int, to end: Int,
                               macros: [String: String]) -> [String: String] {
        var position = start
        var output: [String: String] = [:]
        while position < end {
            skipWhitespace(bytes, position: &position, end: end)
            if position == end { break }
            if bytes[position] == 37 {
                position = min(end, endOfLine(bytes, from: position))
                continue
            }
            if bytes[position] == 44 { position += 1; continue }
            let nameStart = position
            while position < end, isName(bytes[position]) { position += 1 }
            let name = text(bytes, nameStart..<position).lowercased()
            skipWhitespace(bytes, position: &position, end: end)
            guard !name.isEmpty, position < end, bytes[position] == 61 else { break }
            position += 1
            var pieces: [String] = []
            repeat {
                skipWhitespace(bytes, position: &position, end: end)
                guard position < end else { break }
                pieces.append(fieldValue(bytes, position: &position, end: end, macros: macros))
                skipWhitespace(bytes, position: &position, end: end)
                guard position < end, bytes[position] == 35 else { break }
                position += 1
            } while true
            output[name] = pieces.joined()
        }
        return output
    }

    private static func fieldValue(_ bytes: [UInt8], position: inout Int, end: Int,
                                   macros: [String: String]) -> String {
        let first = bytes[position]
        guard first == 34 || first == 123 else {
            let start = position
            while position < end, !isWhitespace(bytes[position]), ![35, 37, 44].contains(bytes[position]) {
                position += 1
            }
            let token = text(bytes, start..<position)
            return macros[token.lowercased()] ?? token
        }
        position += 1
        let start = position
        var braces = 0
        while position < end {
            switch bytes[position] {
            case 92: position = min(end, position + 2); continue
            case 123: braces += 1
            case 125 where braces > 0: braces -= 1
            case 125 where first == 123, 34 where first == 34 && braces == 0:
                let value = text(bytes, start..<position)
                position += 1
                return value
            default: break
            }
            position += 1
        }
        return text(bytes, start..<position)
    }

    private static func isName(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
            byte == 95 || byte == 45
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func skipWhitespace(_ bytes: [UInt8], position: inout Int, end: Int) {
        while position < end, isWhitespace(bytes[position]) { position += 1 }
    }

    private static func endOfLine(_ bytes: [UInt8], from start: Int) -> Int {
        var end = start
        while end < bytes.count, bytes[end] != 10 { end += 1 }
        return end
    }

    private static func text(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }
}
