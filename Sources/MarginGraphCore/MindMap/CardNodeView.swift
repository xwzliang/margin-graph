import SwiftUI
import AppKit

public struct CardNodeView: View {
    public var card: NoteCard
    public var isSelected: Bool
    public var hasChildren: Bool
    public var mediaStorage: MediaStorage?
    public var onSelect: () -> Void
    public var onToggleFold: () -> Void
    public var onEdit: (() -> Void)?

    public init(
        card: NoteCard,
        isSelected: Bool,
        hasChildren: Bool,
        mediaStorage: MediaStorage? = nil,
        onSelect: @escaping () -> Void,
        onToggleFold: @escaping () -> Void,
        onEdit: (() -> Void)? = nil
    ) {
        self.card = card
        self.isSelected = isSelected
        self.hasChildren = hasChildren
        self.mediaStorage = mediaStorage
        self.onSelect = onSelect
        self.onToggleFold = onToggleFold
        self.onEdit = onEdit
    }

    private var cardColors: (background: Color, border: Color, accent: Color) {
        MarginNoteTheme.cardColors(for: card.colorIndex)
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // 1. Accent Header Section (Title & chevron)
                if !card.title.isEmpty {
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

                        Text(card.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.12))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(cardColors.accent)
                } else {
                    HStack(alignment: .center, spacing: 5) {
                        if hasChildren {
                            Button(action: onToggleFold) {
                                Image(systemName: card.isFolded ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(white: 0.25))
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(cardColors.accent)
                }

                // 2. Cream Body Section (Excerpt & Notes)
                let hasExcerpt = !card.highlightText.isEmpty
                let hasNotes = !card.notesText.isEmpty
                let hasImage = thumbnail != nil
                let hasTags = !card.tags.isEmpty

                if hasExcerpt || hasNotes || hasImage || hasTags {
                    VStack(alignment: .leading, spacing: 6) {
                        // Highlight / Excerpt text
                        if hasExcerpt {
                            Text(card.highlightText)
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(Color(white: 0.20))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // User comments / notes
                        if hasNotes {
                            Text(card.notesText)
                                .font(.system(size: 11.5, weight: .regular))
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
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onEdit?()
            }
        )
        .contextMenu {
            Button("Edit Card") {
                onEdit?()
            }
            Divider()
            Button("Copy Deep Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.deepLinkURL.absoluteString, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            ZStack {
                // Dashed blue outline matching MarginNote 3
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        MarginNoteTheme.cursorBlue,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )

                // 4 Corner grab handles
                GeometryReader { geo in
                    let handleSize: CGFloat = 6
                    let w = geo.size.width
                    let h = geo.size.height

                    Group {
                        // Top-left
                        Circle()
                            .fill(MarginNoteTheme.cursorBlue)
                            .frame(width: handleSize, height: handleSize)
                            .position(x: 0, y: 0)

                        // Top-right
                        Circle()
                            .fill(MarginNoteTheme.cursorBlue)
                            .frame(width: handleSize, height: handleSize)
                            .position(x: w, y: 0)

                        // Bottom-left
                        Circle()
                            .fill(MarginNoteTheme.cursorBlue)
                            .frame(width: handleSize, height: handleSize)
                            .position(x: 0, y: h)

                        // Bottom-right
                        Circle()
                            .fill(MarginNoteTheme.cursorBlue)
                            .frame(width: handleSize, height: handleSize)
                            .position(x: w, y: h)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var thumbnail: NSImage? {
        guard let hash = card.highlightPicHash,
              let data = mediaStorage?.loadImage(hash: hash) else { return nil }
        return NSImage(data: data)
    }
}
