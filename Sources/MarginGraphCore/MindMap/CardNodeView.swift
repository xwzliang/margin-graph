import SwiftUI
import AppKit

public struct CardNodeView: View {
    public var card: NoteCard
    public var isSelected: Bool
    public var hasChildren: Bool
    public var mediaStorage: MediaStorage?
    public var onSelect: () -> Void
    public var onToggleFold: () -> Void

    public init(
        card: NoteCard,
        isSelected: Bool,
        hasChildren: Bool,
        mediaStorage: MediaStorage? = nil,
        onSelect: @escaping () -> Void,
        onToggleFold: @escaping () -> Void
    ) {
        self.card = card
        self.isSelected = isSelected
        self.hasChildren = hasChildren
        self.mediaStorage = mediaStorage
        self.onSelect = onSelect
        self.onToggleFold = onToggleFold
    }

    public var body: some View {
        HStack(spacing: 0) {
            accentColor.frame(width: 6)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(card.title.isEmpty ? "Excerpt" : card.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if hasChildren {
                        Button(action: onToggleFold) {
                            Image(systemName: card.isFolded ? "chevron.right.circle.fill" : "chevron.down.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !card.highlightText.isEmpty {
                    Text(card.highlightText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                if !card.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 240, maxWidth: 240, minHeight: 100, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Copy Deep Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.deepLinkURL.absoluteString, forType: .string)
            }
        }
    }

    private var accentColor: some View {
        let colors: [Color] = [.yellow, .red, .orange, .green, .blue, .purple, .pink]
        return colors[abs(card.colorIndex) % colors.count]
    }

    private var thumbnail: NSImage? {
        guard let hash = card.highlightPicHash,
              let data = mediaStorage?.loadImage(hash: hash) else { return nil }
        return NSImage(data: data)
    }
}
