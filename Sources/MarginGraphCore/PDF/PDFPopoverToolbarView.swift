import SwiftUI
import AppKit

public enum PDFPopoverMode: Equatable {
    case create
    case edit(colorIndex: Int)
}

public struct PDFPopoverToolbarView: View {
    public var mode: PDFPopoverMode
    public var arrowOffset: CGFloat
    public var isArrowFlipped: Bool // true = arrow points down (toolbar above selection)
    public var onCopy: () -> Void
    public var onSelectColor: (Int) -> Void
    public var onEdit: () -> Void
    public var onDelete: () -> Void
    public var onEmphasize: () -> Void
    public var onAsTitle: () -> Void
    public var onAddToComments: () -> Void
    public var onMerge: () -> Void
    public var hasTargetCard: Bool
    public var isWithinTargetHighlight: Bool

    public init(
        mode: PDFPopoverMode,
        arrowOffset: CGFloat = 0,
        isArrowFlipped: Bool = false,
        onCopy: @escaping () -> Void = {},
        onSelectColor: @escaping (Int) -> Void = { _ in },
        onEdit: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onEmphasize: @escaping () -> Void = {},
        onAsTitle: @escaping () -> Void = {},
        onAddToComments: @escaping () -> Void = {},
        onMerge: @escaping () -> Void = {},
        hasTargetCard: Bool = false,
        isWithinTargetHighlight: Bool = false
    ) {
        self.mode = mode
        self.arrowOffset = arrowOffset
        self.isArrowFlipped = isArrowFlipped
        self.onCopy = onCopy
        self.onSelectColor = onSelectColor
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onEmphasize = onEmphasize
        self.onAsTitle = onAsTitle
        self.onAddToComments = onAddToComments
        self.onMerge = onMerge
        self.hasTargetCard = hasTargetCard
        self.isWithinTargetHighlight = isWithinTargetHighlight
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !isArrowFlipped {
                // Arrow pointing UP to knob
                HStack {
                    Spacer()
                        .frame(width: max(14, arrowOffset))
                    TriangleUp()
                        .fill(Color(white: 0.17).opacity(0.96))
                        .frame(width: 14, height: 7)
                    Spacer()
                }
            }

            // Main Toolbar Pill
            HStack(spacing: 7) {
                switch mode {
                case .create:
                    // Creation mode (media_1789795402558.png & media_1789816959834.png)
                    Button(action: onCopy) {
                        Text("Copy")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)

                    if hasTargetCard {
                        if isWithinTargetHighlight {
                            Button(action: onEmphasize) {
                                Text("Emphasize")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onAsTitle) {
                            Text("As title")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)

                        Button(action: onAddToComments) {
                            Text("Add to comments")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)

                        Button(action: onMerge) {
                            Text("Merge")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 14)
                        .overlay(Color.white.opacity(0.25))

                    // 4 Palette colors
                    colorSwatches(selectedIdx: nil)

                    Divider()
                        .frame(height: 14)
                        .overlay(Color.white.opacity(0.25))

                    Image(systemName: "text.bubble")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Image(systemName: "textformat")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Divider()
                        .frame(height: 14)
                        .overlay(Color.white.opacity(0.25))

                    Text("Research")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 2)

                case .edit(let currentColorIndex):
                    // Edit mode (media_1789795405168.png)
                    Button(action: onEdit) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Edit Note")

                    Image(systemName: "paintpalette")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))

                    // 4 Palette colors with active ring
                    colorSwatches(selectedIdx: currentColorIndex)

                    Image(systemName: "tag")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.85))

                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.85))

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Copy Content")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.95, green: 0.40, blue: 0.40))
                    }
                    .buttonStyle(.plain)
                    .help("Delete Note")

                    Divider()
                        .frame(height: 14)
                        .overlay(Color.white.opacity(0.25))

                    Text("Research")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Text("Link")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(white: 0.17).opacity(0.96))
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            if isArrowFlipped {
                // Arrow pointing DOWN
                HStack {
                    Spacer()
                        .frame(width: max(14, arrowOffset))
                    TriangleDown()
                        .fill(Color(white: 0.17).opacity(0.96))
                        .frame(width: 14, height: 7)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func colorSwatches(selectedIdx: Int?) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { idx in
                let colors = MarginNoteTheme.cardColors(for: idx)
                Button {
                    onSelectColor(idx)
                } label: {
                    Circle()
                        .fill(colors.accent)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: selectedIdx == idx ? 2.2 : 0)
                        )
                        .frame(width: 17, height: 17)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TriangleUp: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct TriangleDown: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
