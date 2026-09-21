import SwiftUI

public struct InlineTitleEditorView: View {
    @Binding public var text: String
    public var placeholder: String
    public var onCommit: (String) -> Void
    public var onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var draftText: String
    @State private var hasCommitted: Bool = false

    public init(
        text: Binding<String>,
        placeholder: String = "Untitled Note",
        onCommit: @escaping (String) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._draftText = State(initialValue: text.wrappedValue)
    }

    public var body: some View {
        TextField(placeholder, text: $draftText, axis: .vertical)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(white: 0.12))
            .textFieldStyle(.plain)
            .tint(Color(red: 55/255.0, green: 88/255.0, blue: 127/255.0))
            .lineLimit(1...15)
            .fixedSize(horizontal: false, vertical: true)
            .focused($isFocused)
            .onAppear {
                draftText = text
                hasCommitted = false
                isFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                    applySelectionStyle()
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    DispatchQueue.main.async {
                        applySelectionStyle()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
                if let tv = note.object as? NSTextView, tv.window != nil {
                    let darkBlue = NSColor(srgbRed: 55/255.0, green: 88/255.0, blue: 127/255.0, alpha: 1.0)
                    tv.selectedTextAttributes = [
                        .backgroundColor: darkBlue,
                        .foregroundColor: NSColor.white
                    ]
                    tv.insertionPointColor = darkBlue
                }
            }
            .onKeyPress(phases: .down) { press in
                if press.key == .return {
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        return .ignored // Shift+Return or Option+Return inserts newline
                    } else {
                        commit()
                        return .handled // Plain Return commits the title
                    }
                } else if press.key == .escape {
                    cancel()
                    return .handled
                } else if press.key == KeyEquivalent("z") && press.modifiers.contains(.command) {
                    let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
                    if let editor = responder as? NSTextView, let um = editor.undoManager {
                        if press.modifiers.contains(.shift) {
                            if um.canRedo {
                                um.redo()
                                editor.didChangeText()
                                draftText = editor.string
                                return .handled
                            }
                        } else {
                            if um.canUndo {
                                um.undo()
                                editor.didChangeText()
                                draftText = editor.string
                                return .handled
                            }
                        }
                    }
                    return .ignored
                }
                return .ignored
            }
            .onSubmit {
                commit()
            }
            .onExitCommand {
                cancel()
            }
            .onDisappear {
                if !hasCommitted {
                    commit()
                }
            }
    }

    private func commit() {
        guard !hasCommitted else { return }
        hasCommitted = true
        let final = (NSApp.keyWindow?.firstResponder as? NSTextView)?.string ?? draftText
        text = final
        onCommit(final)
    }

    private func cancel() {
        guard !hasCommitted else { return }
        hasCommitted = true
        onCancel()
    }

    private func applySelectionStyle() {
        let responder = NSApp.keyWindow?.firstResponder
            ?? NSApp.mainWindow?.firstResponder
            ?? NSApp.windows.compactMap({ $0.firstResponder as? NSTextView }).first
        if let editor = responder as? NSTextView {
            let darkBlue = NSColor(srgbRed: 55/255.0, green: 88/255.0, blue: 127/255.0, alpha: 1.0)
            editor.selectedTextAttributes = [
                .backgroundColor: darkBlue,
                .foregroundColor: NSColor.white
            ]
            editor.insertionPointColor = darkBlue
        }
    }
}
