import SwiftUI
import AppKit

public struct DocumentOptionsMenuView: View {
    public var isReflowable: Bool
    public var displayMode: PDFReaderDisplayMode
    public var onSelectDisplayMode: (PDFReaderDisplayMode) -> Void
    public var onOpenReadingAppearance: () -> Void
    public var onImportHighlights: (() -> Void)?
    public var onReplacePDF: (() -> Void)?
    public var onRestorePreviousPDF: (() -> Void)?
    public var onRedoPDFReplacement: (() -> Void)?

    @State private var hoveredItem: String? = nil

    public init(
        isReflowable: Bool,
        displayMode: PDFReaderDisplayMode,
        onSelectDisplayMode: @escaping (PDFReaderDisplayMode) -> Void,
        onOpenReadingAppearance: @escaping () -> Void,
        onImportHighlights: (() -> Void)? = nil,
        onReplacePDF: (() -> Void)? = nil,
        onRestorePreviousPDF: (() -> Void)? = nil,
        onRedoPDFReplacement: (() -> Void)? = nil
    ) {
        self.isReflowable = isReflowable
        self.displayMode = displayMode
        self.onSelectDisplayMode = onSelectDisplayMode
        self.onOpenReadingAppearance = onOpenReadingAppearance
        self.onImportHighlights = onImportHighlights
        self.onReplacePDF = onReplacePDF
        self.onRestorePreviousPDF = onRestorePreviousPDF
        self.onRedoPDFReplacement = onRedoPDFReplacement
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

            if onImportHighlights != nil || onReplacePDF != nil || onRestorePreviousPDF != nil || onRedoPDFReplacement != nil {
                Divider()
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
            }

            if let onImportHighlights {
                menuRow(
                    id: "import_highlights",
                    title: "Import PDF Highlights…",
                    icon: "highlighter",
                    isSelected: false
                ) {
                    onImportHighlights()
                }
            }

            if let onReplacePDF {
                menuRow(
                    id: "replace_pdf",
                    title: "Replace PDF…",
                    icon: "arrow.trianglehead.clockwise",
                    isSelected: false,
                    action: onReplacePDF
                )
            }

            if let onRestorePreviousPDF {
                menuRow(
                    id: "restore_pdf",
                    title: "Restore Previous PDF",
                    icon: "arrow.uturn.backward",
                    isSelected: false,
                    action: onRestorePreviousPDF
                )
            }

            if let onRedoPDFReplacement {
                menuRow(
                    id: "redo_pdf_replacement",
                    title: "Redo PDF Replacement",
                    icon: "arrow.uturn.forward",
                    isSelected: false,
                    action: onRedoPDFReplacement
                )
            }
        }
        .padding(6)
        .frame(width: 205)
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
