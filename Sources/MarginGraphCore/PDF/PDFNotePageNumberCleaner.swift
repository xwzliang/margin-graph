import Foundation
import PDFKit

/// Repairs only excerpts anchored to detected footer characters, never arbitrary digits in notes.
public final class PDFNotePageNumberCleaner {
    private let document: PDFDocument
    private let filter = PDFPageNumberFilter()

    public init(document: PDFDocument) { self.document = document }

    public func clean(_ original: NoteCard) -> NoteCard {
        guard original.mediaType == "pdf", original.highlightPicHash == nil else { return original }
        var card = original
        var rects = original.highlightRects
        if rects.isEmpty { rects = original.excerptSegments.flatMap(\.rects) }
        if rects.isEmpty, let startPage = card.startPage, let start = card.startPos, let end = card.endPos,
           let selection = PDFHighlightResolver.selection(in: document, startPage: startPage, startPoint: start,
               endPage: card.endPage ?? startPage, endPoint: end) {
            rects = PDFHighlightResolver.lineRects(from: selection, document: document)
        }
        let cleanedRects = cleanRects(rects)
        guard cleanedRects != rects || original.excerptSegments.contains(where: { cleanRects($0.rects) != $0.rects }) else { return original }
        card.highlightText = cleanText(original.highlightText, rects: rects)
        card.highlightRects = cleanedRects
        card.emphasisRects = cleanRects(original.emphasisRects)
        card.excerptSegments = original.excerptSegments.map { segment in
            ExcerptSegment(id: segment.id, text: cleanText(segment.text, rects: segment.rects), rects: cleanRects(segment.rects))
        }
        // Keep empty segments/cards rather than deleting user content or changing identities.
        let anchors = PDFHighlightResolver.sortInReadingOrder(cleanedRects)
        if let first = anchors.first, let last = anchors.last {
            card.startPage = first.page; card.endPage = last.page
            card.startPos = CGPoint(x: first.x, y: first.y + first.height / 2)
            card.endPos = CGPoint(x: last.x + last.width, y: last.y + last.height / 2)
        } else {
            card.startPos = nil; card.endPos = nil
        }
        return card
    }

    private func cleanRects(_ rects: [HighlightRect]) -> [HighlightRect] {
        rects.flatMap { rect -> [HighlightRect] in
            guard let page = document.page(at: rect.page) else { return [rect] }
            let box = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            let footers = filter.footers(on: page).filter { $0.bounds.intersects(box) }
            guard !footers.isEmpty else { return [rect] }
            // A padded footer-only highlight must disappear entirely, including its colored edge.
            if footers.contains(where: { $0.bounds.insetBy(dx: -6, dy: -6).contains(box) }) { return [] }
            guard let selection = page.selection(for: box) else { return [rect] }
            guard let kept = filter.excludingPageNumbers(from: selection) else { return [] }
            return PDFHighlightResolver.lineRects(from: kept, document: document)
        }
    }

    private struct Glyph { var character: Character; var footer: Bool }

    private func cleanText(_ text: String, rects: [HighlightRect]) -> String {
        guard !text.isEmpty else { return text }
        var glyphs: [Glyph] = []
        for (index, boxes) in Dictionary(grouping: rects, by: \.page).sorted(by: { $0.key < $1.key }) {
            guard let page = document.page(at: index), let raw = page.string else { continue }
            var selected = IndexSet()
            for box in boxes {
                guard let selection = page.selection(for: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) else { continue }
                for i in 0..<selection.numberOfTextRanges(on: page) {
                    let range = selection.range(at: i, on: page)
                    if range.location != NSNotFound { selected.insert(integersIn: range.location..<NSMaxRange(range)) }
                }
            }
            let footers = filter.footers(on: page).flatMap(\.ranges)
            var offset = 0
            for character in raw {
                let length = String(character).utf16.count
                defer { offset += length }
                guard selected.contains(offset), !character.isWhitespace else { continue }
                glyphs.append(Glyph(character: character, footer: footers.contains { NSLocationInRange(offset, $0) }))
            }
        }
        let source = glyphs.map(\.character)
        let indices = text.indices.filter { !text[$0].isWhitespace }
        let target = indices.map { text[$0] }
        var removals: [Range<Int>] = [], i = 0
        while i < glyphs.count {
            guard glyphs[i].footer else { i += 1; continue }
            let start = i
            while i < glyphs.count && glyphs[i].footer { i += 1 }
            let end = i
            // Require unique surrounding PDF text. This preserves legitimate matching body numbers,
            // user edits elsewhere, and skips an ambiguous edited excerpt rather than rebuilding it.
            let left = max(0, start - 24), right = min(source.count, end + 24)
            guard source == target || right - left - (end - start) >= 8 else { continue }
            let needle = Array(source[left..<right])
            guard !needle.isEmpty, target.count >= needle.count else { continue }
            let matches = (0...(target.count - needle.count)).filter { Array(target[$0..<($0 + needle.count)]) == needle }
            guard matches.count == 1, let match = matches.first else { continue }
            removals.append((match + start - left)..<(match + end - left))
        }
        var result = text
        for range in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            var lower = indices[range.lowerBound]
            var upper = text.index(after: indices[range.upperBound - 1])
            while lower > text.startIndex && text[text.index(before: lower)].isWhitespace { lower = text.index(before: lower) }
            while upper < text.endIndex && text[upper].isWhitespace { upper = text.index(after: upper) }
            result.replaceSubrange(lower..<upper, with: lower > text.startIndex && upper < text.endIndex ? " " : "")
        }
        return result
    }
}
