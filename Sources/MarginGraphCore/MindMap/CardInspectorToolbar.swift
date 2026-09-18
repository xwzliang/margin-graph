import SwiftUI

public struct CardInspectorToolbar: View {
    public var card: NoteCard
    public var onEdit: () -> Void
    public var onChangeColor: (Int) -> Void
    public var onDelete: () -> Void
    public var onLink: () -> Void
    public var onFocus: () -> Void

    public init(
        card: NoteCard,
        onEdit: @escaping () -> Void = {},
        onChangeColor: @escaping (Int) -> Void = { _ in },
        onDelete: @escaping () -> Void = {},
        onLink: @escaping () -> Void = {},
        onFocus: @escaping () -> Void = {}
    ) {
        self.card = card
        self.onEdit = onEdit
        self.onChangeColor = onChangeColor
        self.onDelete = onDelete
        self.onLink = onLink
        self.onFocus = onFocus
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Edit Card")

            Divider()
                .frame(height: 14)

            // Color Swatches
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { idx in
                    let colors = MarginNoteTheme.cardColors(for: idx)
                    Button {
                        onChangeColor(idx)
                    } label: {
                        Circle()
                            .fill(colors.accent)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: card.colorIndex == idx ? 2 : 0)
                            )
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(idx + 1)")
                    .help("Color \(idx + 1)")
                }
            }

            Divider()
                .frame(height: 14)

            Button(action: onLink) {
                Image(systemName: "link")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Link")

            Button(action: onFocus) {
                Image(systemName: "scope")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Focus")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Delete Card")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.18).opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        )
        .foregroundStyle(.white)
    }
}
