import SwiftUI
import AppKit
import MarginGraphCore

struct StudyMindMapPane<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var content: () -> Content

    @State private var menu: ToolbarMenu?

    private enum ToolbarMenu {
        case share
        case settings
    }

    private let selectionColor = Color(red: 0.15, green: 0.45, blue: 0.85)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content()
        }
        .overlayPreferenceValue(StudyToolbarMenuAnchor.self) { anchor in
            if let menu, let anchor {
                GeometryReader { geometry in
                    InWindowPopoverContainer(
                        anchorFrame: geometry[anchor],
                        containerWidth: geometry.size.width,
                        popoverWidth: 218,
                        onDismiss: { self.menu = nil }
                    ) {
                        menuContents(menu)
                    }
                }
            }
        }
        .onChange(of: model.workspaceMode) {
            menu = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            toolbarButton("Back to Notebooks", icon: "chevron.left", color: .primary, weight: .semibold) {
                model.exitStudyWorkspace()
            }
            toolbarButton(
                "Undo", icon: "arrow.uturn.backward", color: model.canUndo ? .primary : .secondary.opacity(0.35),
                tooltip: "Undo (⌘Z)"
            ) {
                model.undo()
            }
            .disabled(!model.canUndo)

            toolbarButton(
                "Redo", icon: "arrow.uturn.forward", color: model.canRedo ? .primary : .secondary.opacity(0.35),
                tooltip: "Redo (⇧⌘Z)"
            ) {
                model.redo()
            }
            .disabled(!model.canRedo)

            toolbarButton("Toggle Outline", icon: "list.bullet", isSelected: model.isOutlineVisible) {
                model.isOutlineVisible.toggle()
            }
            toolbarButton("Edit Card", icon: "square.and.pencil") {
                model.editingCard = model.mindMapCards.first { $0.id == model.selectedCardID } ?? model.mindMapCards.first
            }
            menuTrigger("Share / Export", icon: "square.and.arrow.up", menu: .share)
            toolbarButton("Export to Emacs Org", icon: "arrow.down.document", action: model.exportOrg)
                .disabled(model.selectedTopic == nil)

            Spacer(minLength: 0)

            toolbarButton(
                "Search MindMap", icon: "magnifyingglass", isSelected: model.isMindMapSearchPresented,
                tooltip: "Search MindMap (⌘F)", action: model.toggleMindMapSearch
            )
            menuTrigger("Notebook Settings", icon: "ellipsis", menu: .settings)
        }
        .padding(.horizontal, 8)
        .frame(height: MarginNoteTheme.topToolbarHeight)
        .background(MarginNoteTheme.headerBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor)
        }
        .tooltipContainer()
        .zIndex(100)
    }

    private func toolbarButton(
        _ title: String,
        icon: String,
        color: Color = .secondary,
        weight: Font.Weight = .regular,
        isSelected: Bool = false,
        tooltip: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: isSelected ? .bold : weight))
                .foregroundStyle(isSelected ? selectionColor : color)
                .frame(width: 26, height: 26)
                .background(
                    isSelected ? selectionColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .enlargedHitTarget(width: 30, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .marginNoteTooltip(tooltip ?? title)
    }

    private func menuTrigger(_ title: String, icon: String, menu: ToolbarMenu) -> some View {
        toolbarButton(title, icon: icon, isSelected: self.menu == menu) {
            self.menu = self.menu == menu ? nil : menu
        }
        .anchorPreference(key: StudyToolbarMenuAnchor.self, value: .bounds) {
            self.menu == menu ? $0 : nil
        }
    }

    private func menuContents(_ menu: ToolbarMenu) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch menu {
            case .share:
                menuButton("Export to Markdown…", action: model.exportMarkdown)
                menuButton("Export to OPML…", action: model.exportOPML)
                menuButton("Export to Anki (TSV)…", action: model.exportAnki)
                Divider().padding(.vertical, 3)
                menuButton("Import MarginNote 3…", action: model.importMarginNote)
            case .settings:
                Text("View Mode")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                modeButton("Document Only (1-View)", mode: .readerOnly)
                modeButton("Split View (2-View)", mode: .splitView)
                modeButton("Three View (3-View)", mode: .threeView)
                modeButton("MindMap Only", mode: .mindMapOnly)
                Divider().padding(.vertical, 3)
                menuButton("Review Flashcards", action: model.startReview)
            }
        }
        .padding(6)
    }

    private func modeButton(_ title: String, mode: WorkspaceViewMode) -> some View {
        menuButton(title, isSelected: model.workspaceMode == mode) {
            model.workspaceMode = mode
        }
    }

    private func menuButton(_ title: String, isSelected: Bool? = nil, action: @escaping () -> Void) -> some View {
        StudyToolbarMenuButton(title: title, isSelected: isSelected) {
            menu = nil
            action()
        }
    }
}

private struct StudyToolbarMenuAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct StudyToolbarMenuButton: View {
    var title: String
    var isSelected: Bool?
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .onHover { isHovered = $0 }
    }
}
