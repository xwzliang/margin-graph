import SwiftUI
import AppKit

public struct CardNodeView: View {
    public var card: NoteCard
    public var isSelected: Bool
    public var hasChildren: Bool
    public var isEditingTitle: Bool
    public var mediaStorage: MediaStorage?
    public var onSelect: () -> Void
    public var onToggleFold: () -> Void
    public var onEdit: (() -> Void)?
    public var onStartEditTitle: (() -> Void)?
    public var onCommitTitle: ((String) -> Void)?
    public var onComment: (() -> Void)?
    public var onLink: (() -> Void)?
    public var onMerge: (() -> Void)?
    public var onBranchStyle: (() -> Void)?
    public var onChangeColor: ((Int) -> Void)?
    public var onDelete: (() -> Void)?
    public var onNewSibling: (() -> Void)?
    public var onNewChild: (() -> Void)?

    @State private var editingTitleText: String = ""

    public init(
        card: NoteCard,
        isSelected: Bool,
        hasChildren: Bool,
        mediaStorage: MediaStorage? = nil,
        isEditingTitle: Bool = false,
        onSelect: @escaping () -> Void,
        onToggleFold: @escaping () -> Void,
        onEdit: (() -> Void)? = nil,
        onStartEditTitle: (() -> Void)? = nil,
        onCommitTitle: ((String) -> Void)? = nil,
        onComment: (() -> Void)? = nil,
        onLink: (() -> Void)? = nil,
        onMerge: (() -> Void)? = nil,
        onBranchStyle: (() -> Void)? = nil,
        onChangeColor: ((Int) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onNewSibling: (() -> Void)? = nil,
        onNewChild: (() -> Void)? = nil
    ) {
        self.card = card
        self.isSelected = isSelected
        self.hasChildren = hasChildren
        self.mediaStorage = mediaStorage
        self.isEditingTitle = isEditingTitle
        self.onSelect = onSelect
        self.onToggleFold = onToggleFold
        self.onEdit = onEdit
        self.onStartEditTitle = onStartEditTitle
        self.onCommitTitle = onCommitTitle
        self.onComment = onComment
        self.onLink = onLink
        self.onMerge = onMerge
        self.onBranchStyle = onBranchStyle
        self.onChangeColor = onChangeColor
        self.onDelete = onDelete
        self.onNewSibling = onNewSibling
        self.onNewChild = onNewChild
        self._editingTitleText = State(initialValue: card.title)
    }

    private var cardColors: (background: Color, border: Color, accent: Color) {
        MarginNoteTheme.cardColors(for: card.colorIndex)
    }

    public var body: some View {
        let hasExcerpt = !card.highlightText.isEmpty
        let hasNotes = !card.notesText.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // 1. Accent Header Section (Title & chevron)
            HStack(alignment: .top, spacing: 5) {
                if hasChildren {
                    Button(action: onToggleFold) {
                        Image(systemName: card.isFolded ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(white: 0.25))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                }

                if isEditingTitle {
                    InlineTitleEditorView(
                        text: $editingTitleText,
                        placeholder: "Untitled Note",
                        onCommit: {
                            onCommitTitle?(editingTitleText)
                        },
                        onCancel: {
                            onCommitTitle?(card.title)
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .onAppear {
                        editingTitleText = card.title
                    }
                    .onChange(of: isEditingTitle) { _, editing in
                        if editing {
                            editingTitleText = card.title
                        }
                    }
                } else if !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.12))
                        .fixedSize(horizontal: false, vertical: true)
                } else if !hasExcerpt && !hasNotes {
                    Text("Untitled Note")
                        .font(.system(size: 11.5, weight: .regular))
                        .italic()
                        .foregroundStyle(Color(white: 0.45))
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(white: 0.35))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, (!card.title.isEmpty || isEditingTitle || (!hasExcerpt && !hasNotes)) ? 8 : 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(cardColors.accent)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onStartEditTitle?()
            }

                // 2. Cream Body Section (Excerpt & Notes)
                let hasImage = thumbnail != nil
                let hasTags = !card.tags.isEmpty

                if hasExcerpt || hasNotes || hasImage || hasTags {
                    VStack(alignment: .leading, spacing: 6) {
                        // Highlight / Excerpt text
                        if hasExcerpt {
                            Text(styledExcerptText)
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(Color(white: 0.20))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // User comments / notes
                        if hasNotes {
                            Text(card.notesText)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(Color(white: 0.32))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Image thumbnail
                        if let image = thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 82)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }

                        // Tags
                        if hasTags {
                            HStack(spacing: 4) {
                                ForEach(card.tags.prefix(3), id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.system(size: 9))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(cardColors.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(Color(white: 0.20))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(MarginNoteTheme.cardBodyBackground)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onEdit?()
                    }
                }

                // 3. Docked Bottom Action Bar (MarginNote 3 signature)
                if isSelected {
                    HStack(spacing: 7) {
                        Button {
                            onNewSibling?()
                        } label: {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Add Sibling Note (Return)")

                        Button {
                            onNewChild?()
                        } label: {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Add Child Note (Tab)")

                        Button {
                            onComment?()
                        } label: {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Add Comment")

                        Button {
                            onLink?()
                        } label: {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Link")

                        Button {
                            onMerge?()
                        } label: {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Merge")

                        Button {
                            onBranchStyle?()
                        } label: {
                            Image(systemName: "network")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(Color(red: 0.15, green: 0.45, blue: 0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Branch Style")

                        Spacer()

                        // Blue folded triangle corner
                        Path { p in
                            p.move(to: CGPoint(x: 12, y: 0))
                            p.addLine(to: CGPoint(x: 12, y: 12))
                            p.addLine(to: CGPoint(x: 0, y: 12))
                            p.closeSubpath()
                        }
                        .fill(Color(red: 0.15, green: 0.45, blue: 0.85))
                        .frame(width: 12, height: 12)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.94))
                }
            }
            .background(MarginNoteTheme.cardBodyBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(cardColors.border, lineWidth: 1)
            )
            // Blue selection handles overlay when selected
            .overlay(
                selectionOverlay
            )
            .shadow(color: isSelected ? Color(red: 0.10, green: 0.40, blue: 0.85).opacity(0.20) : .black.opacity(0.14), radius: isSelected ? 8 : 6, x: 0, y: isSelected ? 4 : 3)
            .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture(count: 1) {
                onSelect()
            }
        .contextMenu {
            Button("Edit Title") {
                onStartEditTitle?()
            }
            Button("Edit Details…") {
                onEdit?()
            }
            Divider()
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.title, forType: .string)
            }
            Button("Copy Note Content") {
                NSPasteboard.general.clearContents()
                let content = !card.highlightText.isEmpty ? card.highlightText : (!card.notesText.isEmpty ? card.notesText : card.title)
                NSPasteboard.general.setString(content, forType: .string)
            }
            Divider()
            Button("Copy Deep Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.deepLinkURL.absoluteString, forType: .string)
            }
            Divider()
            Menu("Card Color") {
                let colorNames = ["Yellow", "Green", "Blue", "Red", "Purple", "Orange"]
                ForEach(0..<6, id: \.self) { idx in
                    Button {
                        onChangeColor?(idx)
                    } label: {
                        let isCurrent = card.colorIndex == idx
                        Text(isCurrent ? "✓ \(colorNames[idx])" : colorNames[idx])
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        }
    }

    private var styledExcerptText: AttributedString {
        var attr = AttributedString(card.highlightText)
        for emphasis in card.emphasisList where !emphasis.isEmpty {
            let ranges = PDFHighlightResolver.rangesOfPhrase(emphasis, in: card.highlightText)
            for strRange in ranges {
                if let lower = AttributedString.Index(strRange.lowerBound, within: attr),
                   let upper = AttributedString.Index(strRange.upperBound, within: attr) {
                    let attrRange = lower..<upper
                    attr[attrRange].font = .system(size: 11.5, weight: .heavy)
                    attr[attrRange].underlineStyle = Text.LineStyle(pattern: .dot, color: Color(MarginNoteTheme.cursorBlue))
                }
            }
        }
        return attr
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            // Dashed blue outline matching MarginNote 3 (without corner circles)
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    MarginNoteTheme.cursorBlue,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .allowsHitTesting(false)
        }
    }

    private var thumbnail: NSImage? {
        guard let hash = card.highlightPicHash,
              let data = mediaStorage?.loadImage(hash: hash) else { return nil }
        return NSImage(data: data)
    }
}
