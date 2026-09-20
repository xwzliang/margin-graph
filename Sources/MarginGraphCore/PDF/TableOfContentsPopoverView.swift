import SwiftUI
import AppKit

public struct TableOfContentsPopoverView: View {
    public var items: [PDFOutlineItem]
    public var currentPageIndex: Int
    public var cards: [NoteCard]
    public var totalPageCount: Int
    public var onJumpToPage: (Int) -> Void

    @State private var query: String = ""
    @State private var expandedItemIDs: Set<UUID> = []
    @State private var hoveredItemID: UUID? = nil

    public init(
        items: [PDFOutlineItem],
        currentPageIndex: Int,
        cards: [NoteCard] = [],
        totalPageCount: Int = 1,
        onJumpToPage: @escaping (Int) -> Void
    ) {
        self.items = items
        self.currentPageIndex = currentPageIndex
        self.cards = cards
        self.totalPageCount = totalPageCount
        self.onJumpToPage = onJumpToPage
        // By default expand top-level items that have children
        let initialExpanded = Set(items.filter { !$0.children.isEmpty }.map { $0.id })
        self._expandedItemIDs = State(initialValue: initialExpanded)
    }

    public var noteCounts: [UUID: Int] {
        Self.calculateSectionNoteCounts(items: items, cards: cards, totalPageCount: totalPageCount)
    }

    public static func calculateSectionNoteCounts(
        items: [PDFOutlineItem],
        cards: [NoteCard],
        totalPageCount: Int
    ) -> [UUID: Int] {
        func preorder(_ list: [PDFOutlineItem]) -> [PDFOutlineItem] {
            var result: [PDFOutlineItem] = []
            for item in list {
                result.append(item)
                result.append(contentsOf: preorder(item.children))
            }
            return result
        }

        func effectivePage(_ item: PDFOutlineItem) -> Int? {
            if let p = item.pageIndex { return p }
            for child in item.children {
                if let cp = effectivePage(child) { return cp }
            }
            return nil
        }

        let flat = preorder(items)
        guard !flat.isEmpty else { return [:] }

        var cardCountByPage: [Int: Int] = [:]
        for card in cards {
            if let page = card.startPage ?? card.highlightRects.first?.page ?? card.excerptSegments.first?.rects.first?.page {
                cardCountByPage[page, default: 0] += 1
            }
        }

        var counts: [UUID: Int] = [:]

        for i in 0..<flat.count {
            let item = flat[i]
            guard let startPage = effectivePage(item) else {
                counts[item.id] = 0
                continue
            }

            var nextStartPage = totalPageCount
            for j in (i + 1)..<flat.count {
                if let nextP = effectivePage(flat[j]) {
                    nextStartPage = nextP
                    break
                }
            }

            let endPage = max(startPage, nextStartPage)
            if startPage == endPage {
                counts[item.id] = 0
            } else {
                var sum = 0
                for p in startPage..<endPage {
                    sum += cardCountByPage[p, default: 0]
                }
                counts[item.id] = sum
            }
        }

        return counts
    }

    private struct FlattenedOutlineRow: Identifiable {
        let item: PDFOutlineItem
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool

        var id: UUID { item.id }
    }

    private static func matchesQuery(_ item: PDFOutlineItem, query: String) -> Bool {
        if query.isEmpty { return true }
        if item.title.localizedCaseInsensitiveContains(query) { return true }
        for child in item.children {
            if matchesQuery(child, query: query) { return true }
        }
        return false
    }

    private var flattenedRows: [FlattenedOutlineRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var result: [FlattenedOutlineRow] = []

        func traverse(_ list: [PDFOutlineItem], depth: Int) {
            for item in list {
                guard Self.matchesQuery(item, query: trimmed) else { continue }
                let hasChildren = !item.children.isEmpty
                let isExpanded = !trimmed.isEmpty || expandedItemIDs.contains(item.id)

                result.append(
                    FlattenedOutlineRow(
                        item: item,
                        depth: depth,
                        hasChildren: hasChildren,
                        isExpanded: isExpanded
                    )
                )

                if hasChildren && isExpanded {
                    traverse(item.children, depth: depth + 1)
                }
            }
        }

        traverse(items, depth: 0)
        return result
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))

                Text("Table of Contents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Spacer()

                Text("\(items.count) sections")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)

                TextField("Search contents…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.82), lineWidth: 0.7))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Content Rows
            if flattenedRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                    Text(query.isEmpty ? "No Table of Contents in this document" : "No matching sections")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(flattenedRows) { row in
                            let isCurrent = row.item.pageIndex == currentPageIndex
                            let isHovered = hoveredItemID == row.id

                            HStack(alignment: .top, spacing: 6) {
                                // Indentation
                                if row.depth > 0 {
                                    Spacer()
                                        .frame(width: CGFloat(row.depth) * 14)
                                }

                                // Disclosure triangle if item has children
                                if row.hasChildren {
                                    Button {
                                        if expandedItemIDs.contains(row.id) {
                                            expandedItemIDs.remove(row.id)
                                        } else {
                                            expandedItemIDs.insert(row.id)
                                        }
                                    } label: {
                                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color(white: 0.45))
                                            .frame(width: 14, height: 18)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 1)
                                } else {
                                    Spacer()
                                        .frame(width: 14)
                                }

                                // Title & Note Count
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.item.title)
                                        .font(.system(size: 12, weight: isCurrent ? .bold : .regular))
                                        .foregroundStyle(isCurrent ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    if let count = noteCounts[row.id], count > 0 {
                                        Text("\(count) note(s)")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(Color(red: 0.20, green: 0.50, blue: 0.90))
                                    }
                                }

                                Spacer()

                                // Page Number
                                if let page = row.item.pageIndex {
                                    Text("\(page + 1)")
                                        .font(.system(size: 10.5, weight: isCurrent ? .bold : .regular))
                                        .foregroundStyle(isCurrent ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary)
                                        .padding(.top, 1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        isCurrent
                                            ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.10)
                                            : (isHovered ? Color.black.opacity(0.04) : Color.clear)
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let page = row.item.pageIndex {
                                    onJumpToPage(page)
                                }
                            }
                            .onHover { hovering in
                                if hovering {
                                    hoveredItemID = row.id
                                } else if hoveredItemID == row.id {
                                    hoveredItemID = nil
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
