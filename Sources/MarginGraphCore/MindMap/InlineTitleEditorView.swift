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
            .lineLimit(1...15)
            .fixedSize(horizontal: false, vertical: true)
            .focused($isFocused)
            .onAppear {
                draftText = text
                hasCommitted = false
                isFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
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
        text = draftText
        onCommit(draftText)
    }

    private func cancel() {
        guard !hasCommitted else { return }
        hasCommitted = true
        onCancel()
    }
}
