import Foundation

/// A field-based draft retains the source ranges of entries loaded from a bibliography.
public struct BibTeXEntryDraft {
    public struct Field: Identifiable {
        public let id = UUID()
        public var name: String
        public var value: String

        public init(name: String = "", value: String = "") {
            self.name = name
            self.value = value
        }
    }

    public var type: String
    public var key: String
    public var fields: [Field]
    private let source: Source?

    public init() {
        type = "book"
        key = ""
        fields = ["title", "author", "year"].map { Field(name: $0) }
        source = nil
    }

    public init(_ entry: BibTeXEntry) throws {
        let source = try Source(entry)
        type = entry.type
        key = entry.key
        fields = source.fields.map(\.field)
        self.source = source
    }

    public func entry() throws -> BibTeXEntry {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BibTeXLibrary.validKey(key) else { throw BibTeXError.invalidCitationKey }
        guard Self.validName(type), !["preamble", "string", "comment"].contains(type) else {
            throw BibTeXError.invalidEntryType
        }

        let originals = source?.fields ?? []
        let fields = try self.fields.map { field in
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validName(name) || originals.contains(where: { $0.field.id == field.id && $0.field.name == name }) else {
                throw BibTeXError.invalidFieldName(name)
            }
            var trimmed = field
            trimmed.name = name
            return trimmed
        }
        for (name, rows) in Dictionary(grouping: fields, by: { $0.name.lowercased() }) where rows.count > 1 {
            // Existing duplicate fields can be kept or repaired independently.
            let originalIDs = Set(originals.filter { $0.range.name == name }.map(\.field.id))
            guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ originalIDs.contains($0.id) }) else {
                throw BibTeXError.duplicateField(name)
            }
        }

        if let source {
            return try source.applying(type: type, key: key, fields: fields)
        }

        let lines = fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "    \($0.name) = \(Self.valueToken($0.value))" }
        let body = lines.isEmpty ? "" : ",\n" + lines.joined(separator: ",\n") + "\n"
        return try BibTeXLibrary.entry("@\(type){\(key)\(body)}")
    }

    var fieldNames: Set<String> {
        Set(fields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    public func fieldNameForAddition(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw BibTeXError.invalidFieldName(name) }
        guard !fieldNames.contains(name.lowercased()) else { throw BibTeXError.duplicateField(name) }
        return name
    }

    private static func validName(_ name: String) -> Bool {
        guard let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return name.utf8.allSatisfy(BibTeXLibrary.isName)
    }

    private static func valueToken(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var groups: [Int] = []
        var escape: Set<Int> = []
        var escaped = false
        for (offset, byte) in bytes.enumerated() {
            if escaped { escaped = false; continue }
            switch byte {
            case 92: escaped = true
            case 123: groups.append(offset)
            case 125:
                if groups.popLast() == nil { escape.insert(offset) }
            default: break
            }
        }
        escape.formUnion(groups)
        if escaped { escape.insert(bytes.count - 1) }

        var result: [UInt8] = [123]
        for (offset, byte) in bytes.enumerated() {
            if escape.contains(offset) { result.append(92) }
            result.append(byte)
        }
        result.append(125)
        return String(decoding: result, as: UTF8.self)
    }

    private struct Source {
        struct OriginalField {
            let field: Field
            let range: BibTeXLibrary.FieldRange
        }

        let entry: BibTeXEntry
        let bytes: [UInt8]
        let typeRange: Range<Int>
        let keyRange: Range<Int>
        let keyComma: Int?
        let close: Int
        let fields: [OriginalField]

        init(_ entry: BibTeXEntry) throws {
            self.entry = entry
            let bytes = Array(entry.source.utf8)
            self.bytes = bytes
            guard let open = bytes.firstIndex(where: { $0 == 123 || $0 == 40 }),
                  let close = BibTeXLibrary.entryEnd(bytes, open: open) else { throw BibTeXError.invalidEntry }
            self.close = close
            let typeEnd = (1..<open).first { BibTeXLibrary.isWhitespace(bytes[$0]) } ?? open
            typeRange = 1..<typeEnd
            let comma = (open + 1..<close).first { bytes[$0] == 44 }
            keyComma = comma
            let keyEnd = comma ?? close
            let keyStart = (open + 1..<keyEnd).first { !BibTeXLibrary.isWhitespace(bytes[$0]) } ?? keyEnd
            keyRange = keyStart..<(keyStart + entry.key.utf8.count)
            var ranges: [(BibTeXLibrary.FieldRange, String)] = []
            if let comma {
                _ = BibTeXLibrary.fields(bytes, from: comma + 1, to: close, macros: [:]) { ranges.append(($0, $1)) }
            }
            var seen: Set<String> = []
            fields = ranges.reversed().map { range, value in
                let name = BibTeXLibrary.text(bytes, range.label)
                // The loaded entry resolves file-level macros. Earlier duplicate fields retain their own token values.
                let content = seen.insert(range.name).inserted ? entry.fields[range.name, default: value] : value
                return OriginalField(field: Field(name: name, value: content), range: range)
            }.reversed()
        }

        func applying(type: String, key: String, fields edited: [Field]) throws -> BibTeXEntry {
            let remaining = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let originalIDs = Set(fields.map(\.field.id))
            let added = edited.filter { !originalIDs.contains($0.id) }
            var changes: [(range: Range<Int>, text: String)] = []
            if type != entry.type { changes.append((typeRange, type)) }
            if key != entry.key { changes.append((keyRange, key)) }

            for existing in fields {
                let range = existing.range
                guard let field = remaining[existing.field.id] else {
                    changes.append(contentsOf: removal(range))
                    continue
                }
                if field.name != existing.field.name { changes.append((range.label, field.name)) }
                if field.value != existing.field.value {
                    changes.append((range.value, BibTeXEntryDraft.valueToken(field.value)))
                }
            }

            if !added.isEmpty {
                let newline = entry.source.contains("\r\n") ? "\r\n" : "\n"
                let line = lineStart(at: close)
                let ownLine = bytes[line..<close].allSatisfy { $0 == 32 || $0 == 9 }
                let insertion = ownLine ? line : close
                let rows = added.map { "    \($0.name) = \(BibTeXEntryDraft.valueToken($0.value))" }
                changes.append((insertion..<insertion, (ownLine ? "" : newline) + rows.joined(separator: "," + newline) + newline))

                if let last = fields.last(where: { remaining[$0.field.id] != nil }) {
                    let end = last.range.value.upperBound
                    if delimiter(after: end) == nil { changes.append((end..<end, ",")) }
                } else if keyComma == nil {
                    let end = keyRange.upperBound
                    changes.append((end..<end, ","))
                }
            }

            if changes.isEmpty { return entry }
            var result = bytes
            // Apply from the end so the source offsets stay valid. At one position, insert new rows before inserting their leading comma.
            for change in changes.enumerated().sorted(by: { lhs, rhs in
                let left = lhs.element.range, right = rhs.element.range
                if left.lowerBound != right.lowerBound { return left.lowerBound > right.lowerBound }
                if left.upperBound != right.upperBound { return left.upperBound > right.upperBound }
                return lhs.offset < rhs.offset
            }).map(\.element) {
                result.replaceSubrange(change.range, with: change.text.utf8)
            }
            return try BibTeXLibrary.entry(String(decoding: result, as: UTF8.self))
        }

        private func removal(_ field: BibTeXLibrary.FieldRange) -> [(range: Range<Int>, text: String)] {
            let start = field.label.lowerBound
            let end = field.value.upperBound
            let comma = delimiter(after: end)
            let adjacent = comma.map { bytes[end..<$0].allSatisfy { $0 == 32 || $0 == 9 } } ?? false
            let fieldEnd = adjacent ? (comma ?? end) + 1 : end
            let line = lineStart(at: start)
            var lineEnd = fieldEnd
            while lineEnd < close && [32, 9, 13].contains(bytes[lineEnd]) { lineEnd += 1 }
            let wholeLine = bytes[line..<start].allSatisfy { $0 == 32 || $0 == 9 } &&
                lineEnd < close && bytes[lineEnd] == 10
            var edits = [(wholeLine ? line..<(lineEnd + 1) : start..<fieldEnd, "")]
            if let comma, !adjacent { edits.append((comma..<(comma + 1), "")) }
            return edits
        }

        private func lineStart(at offset: Int) -> Int {
            bytes[..<offset].lastIndex(of: 10).map { $0 + 1 } ?? 0
        }

        private func delimiter(after end: Int) -> Int? {
            var offset = end
            while offset < close {
                switch bytes[offset] {
                case 44: return offset
                case 37: offset = BibTeXLibrary.endOfLine(bytes, from: offset)
                case let byte where BibTeXLibrary.isWhitespace(byte): offset += 1
                default: return nil
                }
            }
            return nil
        }
    }
}
