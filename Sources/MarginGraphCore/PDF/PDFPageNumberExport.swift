import Foundation
import CoreGraphics
import PDFKit
import zlib

public enum PDFPageNumberPreferences {
    public static func key(for md5: String) -> String { "pdf.hidePageNumbers.\(md5)" }
    public static func isHidden(for md5: String) -> Bool { UserDefaults.standard.bool(forKey: key(for: md5)) }
}

public enum PDFPageNumberExportError: LocalizedError {
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "Could not remove page numbers from the exported PDF: \(detail). The original PDF was not changed."
        }
    }
}

/// Rewrites only footer text-show operands, retaining vector content, fonts, page coordinates,
/// annotations and navigation. A white content-stream fill also covers image-backed OCR footers.
/// This is a reader/export formatting feature, not a security-redaction API.
public enum PDFPageNumberExport {
    public static func write(source: URL, destination: URL, hidingPageNumbers: Bool) throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw PDFPageNumberExportError.unsupported("export must use a separate destination")
        }
        guard hidingPageNumbers else {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            return
        }
        guard let pdf = PDFDocument(url: source), !pdf.isLocked,
              let cg = CGPDFDocument(source as CFURL), !cg.isEncrypted else {
            throw PDFPageNumberExportError.unsupported("the PDF is unreadable or encrypted")
        }
        let writer = PDFObjectWriter()
        let filter = PDFPageNumberFilter()
        var expected: [Int: String] = [:]
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), let cgPage = cg.page(at: index + 1),
                  let dictionary = cgPage.dictionary else { continue }
            let footers = filter.footers(on: page)
            guard !footers.isEmpty else { continue }
            guard let full = page.selection(for: page.bounds(for: .mediaBox)) else {
                throw PDFPageNumberExportError.unsupported("page \(index + 1) has no selectable text")
            }
            expected[index] = compact(filter.excludingPageNumbers(from: full)?.string ?? "")
            let resources = inheritedDictionary("Resources", from: dictionary)
            let content = try contentData(in: dictionary)
            let rewrite = try PDFFooterStream.rewrite(content, resources: resources,
                state: .init(), footers: footers.map(\.bounds), writer: writer)
            var result = rewrite.data
            // A PDF page's content uses unrotated page coordinates. Preserve boxes and rotation.
            result.append(Data("\nq 1 1 1 rg\n".utf8))
            for footer in footers {
                let r = footer.bounds.insetBy(dx: -1, dy: -1)
                result.append(Data("\(r.minX) \(r.minY) \(r.width) \(r.height) re f\n".utf8))
            }
            result.append(Data("Q\n".utf8))
            var changes = ["Contents": try writer.stream(data: result)]
            if !rewrite.forms.isEmpty {
                changes["Resources"] = try writer.resources(resources, forms: rewrite.forms)
            }
            writer.overrides[dictionary] = changes
        }
        guard !expected.isEmpty else {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            return
        }
        guard let catalog = cg.catalog else { throw PDFPageNumberExportError.unsupported("missing catalog") }
        let bytes = try writer.finish(catalog: catalog, info: cg.info)
        guard let exported = PDFDocument(data: bytes), exported.pageCount == pdf.pageCount else {
            throw PDFPageNumberExportError.unsupported("output validation failed")
        }
        for index in 0..<pdf.pageCount {
            let text = expected[index] ?? compact(pdf.page(at: index)?.string ?? "")
            guard let page = exported.page(at: index), compact(page.string ?? "") == text else {
                throw PDFPageNumberExportError.unsupported("page \(index + 1) uses an unsupported text layout")
            }
        }
        try bytes.write(to: destination, options: .atomic)
    }

    private static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func inheritedDictionary(_ key: String, from dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var current: CGPDFDictionaryRef? = dictionary
        var seen = Set<CGPDFDictionaryRef>()
        while let node = current, seen.insert(node).inserted {
            var value: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, key, &value) { return value }
            var parent: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(node, "Parent", &parent)
            current = parent
        }
        return nil
    }

    private static func contentData(in dictionary: CGPDFDictionaryRef) throws -> Data {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            return try PDFObjectWriter.decoded(stream).0
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return Data() }
        var result = Data()
        for index in 0..<CGPDFArrayGetCount(array) {
            guard CGPDFArrayGetStream(array, index, &stream), let stream else {
                throw PDFPageNumberExportError.unsupported("invalid content stream")
            }
            result.append(try PDFObjectWriter.decoded(stream).0)
            result.append(10)
        }
        return result
    }
}

/// A fresh object graph avoids incremental-save remnants. CoreGraphics resolves compressed
/// objects, inherited references and stream encodings; this writer retains their PDF values.
private final class PDFObjectWriter {
    var overrides: [CGPDFDictionaryRef: [String: String]] = [:]
    private var objects: [Data] = []
    private var references: [OpaquePointer: Int] = [:]
    private enum Pending {
        case dictionary(CGPDFDictionaryRef)
        case array(CGPDFArrayRef)
        case stream(CGPDFStreamRef)
    }
    private var pending: [(Int, Pending)] = []

    // PDF graphs contain long /Next chains and cycles through /Parent and page
    // references. Reserve references now; serialize one object at a time in finish.
    // Recursively walking those links exhausts a background worker's small stack.
    private func enqueue(_ pointer: OpaquePointer, _ value: Pending) -> String {
        if let id = references[pointer] { return reference(id) }
        let id = reserve()
        references[pointer] = id
        pending.append((id, value))
        return reference(id)
    }

    private func reserve() -> Int { objects.append(Data()); return objects.count }
    private func reference(_ id: Int) -> String { "\(id) 0 R" }
    private func add(_ data: Data) -> String {
        let id = reserve(); objects[id - 1] = data; return reference(id)
    }
    static func name(_ text: String) -> String {
        "/" + text.utf8.map { byte in
            if byte > 32, byte < 127, !Array("()<>[]{}/%#".utf8).contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "#%02X", byte)
        }.joined()
    }
    static func decoded(_ stream: CGPDFStreamRef) throws -> (Data, CGPDFDataFormat) {
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else {
            throw PDFPageNumberExportError.unsupported("a stream could not be decoded")
        }
        return (bytes as Data, format)
    }
    private final class Entries { var values: [(String, CGPDFObjectRef)] = [] }
    private func entries(_ dictionary: CGPDFDictionaryRef) -> [(String, CGPDFObjectRef)] {
        let entries = Entries()
        CGPDFDictionaryApplyFunction(dictionary, { key, object, info in
            Unmanaged<Entries>.fromOpaque(info!).takeUnretainedValue().values.append((String(cString: key), object))
        }, Unmanaged.passUnretained(entries).toOpaque())
        return entries.values.sorted { $0.0 < $1.0 }
    }
    private static func number(_ value: CGFloat) -> String {
        // PDF numbers cannot use exponent notation.
        var result = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result == "-0" ? "0" : result
    }
    func dictionary(_ dictionary: CGPDFDictionaryRef?, changes: [String: String] = [:], omit: Set<String> = []) throws -> String {
        var fields = changes
        if let dictionary {
            for (key, value) in entries(dictionary) where fields[key] == nil && !omit.contains(key) {
                fields[key] = try object(value)
            }
        }
        return "<< " + fields.keys.sorted().map { Self.name($0) + " " + fields[$0]! }.joined(separator: "\n") + " >>"
    }
    private func dictionaryReference(_ dictionary: CGPDFDictionaryRef) throws -> String {
        enqueue(dictionary, .dictionary(dictionary))
    }
    func stream(data: Data, dictionary: CGPDFDictionaryRef? = nil, changes: [String: String] = [:], format: CGPDFDataFormat = .raw) throws -> String {
        add(try streamBody(data: data, dictionary: dictionary, changes: changes, format: format))
    }
    private func streamBody(data: Data, dictionary: CGPDFDictionaryRef?, changes: [String: String], format: CGPDFDataFormat) throws -> Data {
        var changes = changes
        let bytes: Data
        if format == .raw, !data.isEmpty {
            var capacity = compressBound(uLong(data.count))
            var compressed = Data(count: Int(capacity))
            let status = compressed.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { source in
                    compress2(target.bindMemory(to: Bytef.self).baseAddress, &capacity,
                              source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
                }
            }
            guard status == Z_OK else { throw PDFPageNumberExportError.unsupported("stream compression failed") }
            compressed.count = Int(capacity); bytes = compressed; changes["Filter"] = "/FlateDecode"
        } else {
            bytes = data
            if format == .jpegEncoded { changes["Filter"] = "/DCTDecode" }
            if format == .JPEG2000 { changes["Filter"] = "/JPXDecode" }
        }
        changes["Length"] = "\(bytes.count)"
        var result = Data(try self.dictionary(dictionary, changes: changes, omit: ["Length", "Filter", "DecodeParms"]).utf8)
        result.append(Data("\nstream\n".utf8)); result.append(bytes); result.append(Data("\nendstream".utf8))
        return result
    }
    func resources(_ original: CGPDFDictionaryRef?, forms: [String: String]) throws -> String {
        var xobjects: CGPDFDictionaryRef?
        if let original { CGPDFDictionaryGetDictionary(original, "XObject", &xobjects) }
        return try dictionary(original, changes: ["XObject": dictionary(xobjects, changes: forms)])
    }
    private func object(_ object: CGPDFObjectRef) throws -> String {
        switch CGPDFObjectGetType(object) {
        case .null: return "null"
        case .boolean:
            var value: CGPDFBoolean = 0; CGPDFObjectGetValue(object, .boolean, &value); return value == 0 ? "false" : "true"
        case .integer:
            var value: CGPDFInteger = 0; CGPDFObjectGetValue(object, .integer, &value); return "\(value)"
        case .real:
            var value: CGPDFReal = 0; CGPDFObjectGetValue(object, .real, &value); return Self.number(value)
        case .name:
            var value: UnsafePointer<CChar>?; CGPDFObjectGetValue(object, .name, &value)
            return Self.name(value.map { String(cString: $0) } ?? "")
        case .string:
            var value: CGPDFStringRef?; CGPDFObjectGetValue(object, .string, &value)
            guard let value, let bytes = CGPDFStringGetBytePtr(value) else { return "<>" }
            return "<" + UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(value)).map { String(format: "%02X", $0) }.joined() + ">"
        case .array:
            var value: CGPDFArrayRef?; CGPDFObjectGetValue(object, .array, &value)
            guard let value else { return "[]" }
            return enqueue(value, .array(value))
        case .dictionary:
            var value: CGPDFDictionaryRef?; CGPDFObjectGetValue(object, .dictionary, &value)
            return try value.map { try dictionaryReference($0) } ?? "<<>>"
        case .stream:
            var value: CGPDFStreamRef?; CGPDFObjectGetValue(object, .stream, &value)
            guard let value else { throw PDFPageNumberExportError.unsupported("invalid stream reference") }
            return enqueue(value, .stream(value))
        @unknown default: throw PDFPageNumberExportError.unsupported("unknown PDF object")
        }
    }
    func finish(catalog: CGPDFDictionaryRef, info: CGPDFDictionaryRef?) throws -> Data {
        let root = try dictionaryReference(catalog)
        let metadata = try info.map { try dictionaryReference($0) }
        var cursor = 0
        while cursor < pending.count {
            let (id, value) = pending[cursor]
            cursor += 1
            // Rendering may enqueue more objects. Never recursively render them.
            switch value {
            case .dictionary(let dictionary):
                objects[id - 1] = Data(try self.dictionary(dictionary, changes: overrides[dictionary] ?? [:]).utf8)
            case .array(let array):
                var values: [String] = []
                for index in 0..<CGPDFArrayGetCount(array) {
                    var item: CGPDFObjectRef?
                    CGPDFArrayGetObject(array, index, &item)
                    values.append(try item.map { try object($0) } ?? "null")
                }
                objects[id - 1] = Data(("[" + values.joined(separator: " ") + "]").utf8)
            case .stream(let stream):
                let (data, format) = try Self.decoded(stream)
                objects[id - 1] = try streamBody(data: data, dictionary: CGPDFStreamGetDictionary(stream), changes: [:], format: format)
            }
        }
        var data = Data("%PDF-1.7\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root \(root)\(metadata.map { " /Info " + $0 } ?? "") >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}

private enum PDFFooterStream {
    struct State {
        var ctm = CGAffineTransform.identity
        var line = CGAffineTransform.identity
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }
    struct Result { var data: Data; var forms: [String: String]; var changed: Bool }
    private struct Token { var range: Range<Int>; var value: String; var operand: Bool }

    static func rewrite(_ data: Data, resources: CGPDFDictionaryRef?, state initial: State,
                        footers: [CGRect], writer: PDFObjectWriter, depth: Int = 0) throws -> Result {
        guard depth < 32 else { throw PDFPageNumberExportError.unsupported("recursive page forms") }
        let bytes = [UInt8](data)
        var cursor = 0, operands: [Token] = [], replacements: [(Range<Int>, Data)] = []
        var state = initial, stack: [State] = [], forms: [String: String] = [:]
        func numbers() -> [CGFloat] { operands.compactMap { Double($0.value).map { CGFloat($0) } } }
        func nextLine() { state.line = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(state.line) }
        func suppressText() {
            let transform = state.line.concatenating(state.ctm)
            let point = CGPoint(x: 0, y: state.rise).applying(transform)
            let vertical = abs(transform.b) > abs(transform.a)
            guard footers.contains(where: { bounds in
                let r = bounds.insetBy(dx: -2, dy: -2)
                return vertical ? (r.minX...r.maxX).contains(point.x) : (r.minY...r.maxY).contains(point.y)
            }), let operand = operands.last else { return }
            replacements.append((operand.range, Data((operand.value.hasPrefix("[") ? "[]" : "()").utf8)))
        }
        while let token = try nextToken(bytes, cursor: &cursor) {
            if token.operand { operands.append(token); continue }
            // Text arrays can be large; only parse numbers for operators that use them.
            let n: [CGFloat]
            switch token.value {
            case "cm", "Tm", "Td", "TD", "TL", "Ts": n = numbers()
            default: n = []
            }
            switch token.value {
            case "BI":
                // Never guess where arbitrary inline-image bytes end or silently export unchanged footers.
                throw PDFPageNumberExportError.unsupported("inline images on a page with hidden numbers")
            case "q": stack.append(state)
            case "Q":
                if let saved = stack.popLast() {
                    let line = state.line // Text matrices are not part of the saved graphics state.
                    state = saved; state.line = line
                }
            case "cm" where n.count == 6:
                state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.ctm)
            case "BT": state.line = .identity
            case "Tm" where n.count == 6:
                state.line = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "Td", "TD":
                if n.count == 2 {
                    if token.value == "TD" { state.leading = -n[1] }
                    state.line = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(state.line)
                }
            case "TL": if let first = n.first { state.leading = first }
            case "Ts": if let first = n.first { state.rise = first }
            case "T*": nextLine()
            case "'", "\"": nextLine(); suppressText()
            case "Tj", "TJ": suppressText()
            case "Do":
                if let operand = operands.last, operand.value.hasPrefix("/"), let resources {
                    let name = decodeName(String(operand.value.dropFirst()))
                    var xobjects: CGPDFDictionaryRef?, form: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
                       CGPDFDictionaryGetStream(xobjects, name, &form), let form,
                       let dictionary = CGPDFStreamGetDictionary(form),
                       CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" {
                        var child = state, matrix: CGPDFArrayRef?, localResources: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                            var values = [CGFloat](repeating: 0, count: 6)
                            for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &values[i]) }
                            child.ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.ctm)
                        }
                        CGPDFDictionaryGetDictionary(dictionary, "Resources", &localResources)
                        let childResources = localResources ?? resources
                        let result = try rewrite(PDFObjectWriter.decoded(form).0, resources: childResources,
                                                 state: child, footers: footers, writer: writer, depth: depth + 1)
                        if result.changed {
                            let resourceName = "MGFooter" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            let changes = ["Resources": try writer.resources(childResources, forms: result.forms)]
                            forms[resourceName] = try writer.stream(data: result.data, dictionary: dictionary, changes: changes)
                            replacements.append((operand.range, Data(PDFObjectWriter.name(resourceName).utf8)))
                        }
                    }
                }
            default: break
            }
            operands.removeAll(keepingCapacity: true)
        }
        var output = data
        for (range, value) in replacements.reversed() { output.replaceSubrange(range, with: value) }
        return Result(data: output, forms: forms, changed: !replacements.isEmpty)
    }

    private static func decodeName(_ text: String) -> String {
        let bytes = Array(text.utf8); var result: [UInt8] = []; var i = 0
        while i < bytes.count {
            if bytes[i] == 35, i + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                result.append(byte); i += 3
            } else { result.append(bytes[i]); i += 1 }
        }
        return String(decoding: result, as: UTF8.self)
    }
    private static func whitespace(_ b: UInt8) -> Bool {
        switch b {
        case 0, 9, 10, 12, 13, 32: return true
        default: return false
        }
    }
    private static func delimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0, 9, 10, 12, 13, 32, 40, 41, 60, 62, 91, 93, 123, 125, 47, 37: return true
        default: return false
        }
    }
    private static func skipSpace(_ bytes: [UInt8], cursor: inout Int) {
        while cursor < bytes.count {
            if whitespace(bytes[cursor]) { cursor += 1 }
            else if bytes[cursor] == 37 {
                while cursor < bytes.count && bytes[cursor] != 10 && bytes[cursor] != 13 { cursor += 1 }
            } else { break }
        }
    }
    private static func nextToken(_ bytes: [UInt8], cursor: inout Int, materialize: Bool = true, depth: Int = 0) throws -> Token? {
        guard depth < 64 else { throw PDFPageNumberExportError.unsupported("excessively nested PDF operands") }
        skipSpace(bytes, cursor: &cursor)
        guard cursor < bytes.count else { return nil }
        let start = cursor, first = bytes[cursor]; cursor += 1
        if first == 40 {
            var nesting = 1
            while cursor < bytes.count && nesting > 0 {
                let c = bytes[cursor]; cursor += 1
                if c == 92 { if cursor < bytes.count { cursor += 1 } }
                else if c == 40 { nesting += 1 }
                else if c == 41 { nesting -= 1 }
            }
            guard nesting == 0 else { throw PDFPageNumberExportError.unsupported("unterminated PDF string") }
        } else if first == 91 || (first == 60 && cursor < bytes.count && bytes[cursor] == 60) {
            let dictionary = first == 60
            if dictionary { cursor += 1 }
            var closed = false
            while cursor < bytes.count {
                skipSpace(bytes, cursor: &cursor)
                if cursor < bytes.count && ((!dictionary && bytes[cursor] == 93) ||
                    (dictionary && cursor + 1 < bytes.count && bytes[cursor] == 62 && bytes[cursor + 1] == 62)) {
                    cursor += dictionary ? 2 : 1; closed = true; break
                }
                _ = try nextToken(bytes, cursor: &cursor, materialize: false, depth: depth + 1)
            }
            guard closed else { throw PDFPageNumberExportError.unsupported("unterminated PDF object") }
        } else if first == 60 {
            while cursor < bytes.count && bytes[cursor] != 62 { cursor += 1 }
            guard cursor < bytes.count else { throw PDFPageNumberExportError.unsupported("unterminated PDF hex string") }
            cursor += 1
        } else {
            while cursor < bytes.count && !delimiter(bytes[cursor]) { cursor += 1 }
        }
        // Nested array members only need their end offset, not allocated strings.
        guard materialize else { return Token(range: start..<cursor, value: "", operand: true) }
        let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
        let operand: Bool
        switch first {
        case 40, 47, 60, 91: operand = true
        case 43, 45, 46, 48...57: operand = Double(value) != nil
        default: operand = value == "true" || value == "false" || value == "null"
        }
        return Token(range: start..<cursor, value: value, operand: operand)
    }
}
