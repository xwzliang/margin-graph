import Foundation
import PDFKit

/// Reader-only footer suppression. Never changes the PDF's content, crop box, or annotations.
final class PDFPageNumberFilter {
    struct Footer {
        let bounds: CGRect
        let ranges: [NSRange]
    }

    private weak var document: PDFDocument?
    private var cache: [Int: [Footer]] = [:]
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^\s*[-–—(\[]?\s*(?:(?:page|p\.)\s*)?(?:[0-9]+|[ivxlcdm]+)(?:\s*(?:/|of)\s*[0-9]+)?\s*[-–—)\]]?\s*$"#,
        options: [.caseInsensitive]
    )

    func footers(on page: PDFPage) -> [Footer] {
        guard let owner = page.document else { return [] }
        if document !== owner {
            document = owner
            cache.removeAll()
        }
        let index = owner.index(for: page)
        if let cached = cache[index] { return cached }
        let box = page.bounds(for: .cropBox)
        let lines = page.selection(for: box)?.selectionsByLine() ?? []
        let footers = lines.compactMap { line -> Footer? in
            let bounds = line.bounds(for: page)
            // Classify in displayed page coordinates, including rotated pages and nonzero crop origins.
            let bottomDistance: CGFloat
            let height: CGFloat
            switch ((page.rotation % 360) + 360) % 360 {
            case 90: bottomDistance = box.maxX - bounds.minX; height = box.width
            case 180: bottomDistance = box.maxY - bounds.minY; height = box.height
            case 270: bottomDistance = bounds.maxX - box.minX; height = box.width
            default: bottomDistance = bounds.maxY - box.minY; height = box.height
            }
            guard bounds.width > 0, bounds.height > 0,
                  bottomDistance >= 0, bottomDistance <= height * 0.12,
                  let text = line.string,
                  Self.numberPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            else { return nil }
            // PDFKit can split a single body line into separate font runs. A numeric
            // run beside prose is not an isolated page number, even near the bottom.
            let sideways = abs(page.rotation % 180) == 90
            guard !lines.contains(where: { other in
                guard other !== line,
                      other.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return false }
                let otherBounds = other.bounds(for: page)
                return sideways
                    ? abs(otherBounds.midX - bounds.midX) < min(otherBounds.width, bounds.width) * 0.5
                    : abs(otherBounds.midY - bounds.midY) < min(otherBounds.height, bounds.height) * 0.5
            }) else { return nil }
            let ranges = (0..<line.numberOfTextRanges(on: page)).map { line.range(at: $0, on: page) }
            return Footer(bounds: bounds, ranges: ranges)
        }
        cache[index] = footers
        return footers
    }

    /// Subtract complete-page footer character ranges, preserving partial lines and page order.
    /// Looking only at the selected text would mistake a selected body number for a footer.
    func excludingPageNumbers(from selection: PDFSelection) -> PDFSelection? {
        guard let owner = selection.pages.first?.document else { return selection }
        guard selection.pages.contains(where: { !footers(on: $0).isEmpty }) else { return selection }
        let result = PDFSelection(document: owner)
        var changed = false
        var hasText = false
        for page in selection.pages {
            let excluded = footers(on: page).flatMap(\.ranges)
            for index in 0..<selection.numberOfTextRanges(on: page) {
                var kept = [selection.range(at: index, on: page)]
                for footer in excluded {
                    kept = kept.flatMap { range -> [NSRange] in
                        let overlap = NSIntersectionRange(range, footer)
                        guard overlap.length > 0 else { return [range] }
                        changed = true
                        return [
                            NSRange(location: range.location, length: overlap.location - range.location),
                            NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap))
                        ].filter { $0.length > 0 }
                    }
                }
                for range in kept {
                    if let part = page.selection(for: range),
                       part.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        result.add(part)
                        hasText = true
                    }
                }
            }
        }
        return changed ? (hasText ? result : nil) : selection
    }
}
