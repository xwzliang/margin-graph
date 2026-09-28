import SwiftUI
import AppKit

public struct DocumentOptionsMenuView: View {
    public var isReflowable: Bool
    public var displayMode: PDFReaderDisplayMode
    public var onSelectDisplayMode: (PDFReaderDisplayMode) -> Void
    public var onOpenReadingAppearance: () -> Void

    @State private var hoveredItem: String? = nil

    public init(
        isReflowable: Bool,
        displayMode: PDFReaderDisplayMode,
        onSelectDisplayMode: @escaping (PDFReaderDisplayMode) -> Void,
        onOpenReadingAppearance: @escaping () -> Void
    ) {
        self.isReflowable = isReflowable
        self.displayMode = displayMode
        self.onSelectDisplayMode = onSelectDisplayMode
        self.onOpenReadingAppearance = onOpenReadingAppearance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isReflowable {
                menuRow(
                    id: "reading_appearance",
                    title: "Reading Appearance…",
                    icon: "textformat.size",
                    isSelected: false
                ) {
                    onOpenReadingAppearance()
                }

                Divider()
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
            }

            menuRow(
                id: "continuous",
                title: "Continuous Scroll",
                icon: "doc.text",
                isSelected: displayMode == .continuous
            ) {
                onSelectDisplayMode(.continuous)
            }

            menuRow(
                id: "singlePage",
                title: "Single Page",
                icon: "doc",
                isSelected: displayMode == .singlePage
            ) {
                onSelectDisplayMode(.singlePage)
            }
        }
        .padding(6)
        .frame(width: 195)
    }

    @ViewBuilder
    private func menuRow(
        id: String,
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredItem == id
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                        .frame(width: 14)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = id
            } else if hoveredItem == id {
                hoveredItem = nil
            }
        }
    }
}
