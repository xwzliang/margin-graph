import SwiftUI
import AppKit
import PDFKit

public enum MarginNotePDFTool: String, CaseIterable, Identifiable {
    case hand = "Hand"
    case text = "Text"
    case marquee = "Marquee"
    case lasso = "Lasso"
    case highlighter = "Highlighter"
    case pen = "Pen"
    case eraser = "Eraser"
    case textbox = "TextBox"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .hand: return "hand.draw"
        case .text: return "character.cursor.ibeam"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .highlighter: return "highlighter"
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .textbox: return "character.textbox"
        }
    }
}

public struct MarginNotePDFContainerView: View {
    public var manager: PDFDocumentManager
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var jumpTarget: PDFJumpTarget?
    public var onExcerpt: (PDFExcerpt) -> Void

    @State private var activeTool: MarginNotePDFTool = .hand
    @State private var highlightColor: Color = .yellow
    @State private var currentPageIndex: Int = 0
    @State private var totalPageCount: Int = 1

    public init(
        manager: PDFDocumentManager,
        cards: [NoteCard],
        selectedCardID: UUID? = nil,
        jumpTarget: PDFJumpTarget? = nil,
        onExcerpt: @escaping (PDFExcerpt) -> Void
    ) {
        self.manager = manager
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.jumpTarget = jumpTarget
        self.onExcerpt = onExcerpt
    }

    public var body: some View {
        VStack(spacing: 0) {
            // PDF Annotation Toolbar (MarginNote 3 style)
            HStack(spacing: 12) {
                // Main Tools Group
                HStack(spacing: 8) {
                    toolButton(.hand)
                    toolButton(.text)
                    toolButton(.marquee)
                    toolButton(.lasso)
                }

                Divider()
                    .frame(height: 16)

                // Pens & Drawing Tools
                HStack(spacing: 8) {
                    toolButton(.highlighter)
                    toolButton(.pen)
                    toolButton(.eraser)
                    toolButton(.textbox)
                }

                Divider()
                    .frame(height: 16)

                // Color Picker
                ColorPicker("", selection: $highlightColor)
                    .labelsHidden()
                    .frame(width: 20)

                Spacer()

                // Right Utility Icons
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Image(systemName: "bookmark")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(white: 0.96))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 0.77)),
                alignment: .bottom
            )

            // PDF Reader Canvas
            ZStack(alignment: .bottom) {
                let selectionTool: PDFSelectionTool = (activeTool == .marquee) ? .rectMarquee : .textSelection
                PDFReaderView(
                    manager: manager,
                    displayMode: .continuous,
                    tool: selectionTool,
                    highlightColor: NSColor(highlightColor),
                    cards: cards,
                    selectedCardID: selectedCardID,
                    jumpTarget: jumpTarget,
                    currentPageIndex: $currentPageIndex,
                    onExcerpt: onExcerpt
                )
                .background(Color(white: 0.94))

                // Bottom Floating Page Scrubber (MarginNote 3 signature)
                HStack(spacing: 12) {
                    Button {
                        if currentPageIndex > 0 {
                            currentPageIndex -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(currentPageIndex > 0 ? Color.primary : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPageIndex <= 0)

                    Text("\(currentPageIndex + 1) / \(max(1, totalPageCount))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.3))

                    Button {
                        if currentPageIndex < totalPageCount - 1 {
                            currentPageIndex += 1
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(currentPageIndex < totalPageCount - 1 ? Color.primary : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPageIndex >= totalPageCount - 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(white: 0.98).opacity(0.88))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                )
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            totalPageCount = manager.pageCount
        }
        .onChange(of: jumpTarget) { _, target in
            if let target {
                currentPageIndex = target.pageIndex
            }
        }
    }

    private func toolButton(_ tool: MarginNotePDFTool) -> some View {
        let isSelected = activeTool == tool
        return Button {
            activeTool = tool
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color(red: 0.18, green: 0.65, blue: 0.65) : Color(white: 0.35))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color(red: 0.18, green: 0.65, blue: 0.65).opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
