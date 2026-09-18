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
            VStack(alignment: .leading, spacing: 6) {
                // Header: Title and Fold button
                HStack(alignment: .top, spacing: 4) {
                    if hasChildren {
                        Button(action: onToggleFold) {
                            Image(systemName: card.isFolded ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(card.title.isEmpty ? (card.highlightText.isEmpty ? "Note" : card.highlightText) : card.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(card.title.isEmpty ? 3 : 2)

                    Spacer(minLength: 2)
                }

                // Highlight / Excerpt text if title was separate
                if !card.title.isEmpty && !card.highlightText.isEmpty {
                    Text(card.highlightText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(white: 0.25))
                        .lineLimit(4)
                        .padding(.leading, hasChildren ? 16 : 0)
                }

                // User notes
                if !card.notesText.isEmpty {
                    Text(card.notesText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(white: 0.35))
                        .lineLimit(3)
                        .padding(.leading, hasChildren ? 16 : 0)
                }

                // Image thumbnail
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(.leading, hasChildren ? 16 : 0)
                }

                // Tags
                if !card.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(cardColors.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(cardColors.accent)
                        }
                    }
                    .padding(.leading, hasChildren ? 16 : 0)
                }
            }
            .padding(9)
            .frame(width: 220, height: 120, alignment: .topLeading)
            .clipped()
            .background(cardColors.background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(cardColors.border, lineWidth: 1)
            )
            // Blue selection handles overlay when selected
            .overlay(
                selectionOverlay
            )
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1.5)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
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
                // Dashed blue outline
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        Color(red: 0.2, green: 0.45, blue: 0.9),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )

                // 4 Corner handle dots
                VStack {
                    HStack {
                        handleCircle
                        Spacer()
                        handleCircle
                    }
                    Spacer()
                    HStack {
                        handleCircle
                        Spacer()
                        handleCircle
                    }
                }
                .padding(-3)
            }
        }
    }

    private var handleCircle: some View {
        Circle()
            .fill(Color(red: 0.2, green: 0.45, blue: 0.9))
            .frame(width: 6, height: 6)
    }

    private var thumbnail: NSImage? {
        guard let hash = card.highlightPicHash,
              let data = mediaStorage?.loadImage(hash: hash) else { return nil }
        return NSImage(data: data)
    }
}
