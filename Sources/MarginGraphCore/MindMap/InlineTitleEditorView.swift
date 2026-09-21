import SwiftUI
import AppKit

public struct InlineTitleEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public var onCommit: () -> Void
    public var onCancel: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String = "Untitled Note",
        onCommit: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> CustomTitleTextField {
        let field = CustomTitleTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        field.textColor = NSColor(white: 0.12, alpha: 1.0)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.stringValue = text
        field.onEscape = onCancel

        DispatchQueue.main.async {
            if let window = field.window {
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
        return field
    }

    public func updateNSView(_ nsView: CustomTitleTextField, context: Context) {
        if nsView.currentEditor() == nil && nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onEscape = onCancel
    }

    public final class CustomTitleTextField: NSTextField {
        var onEscape: (() -> Void)?

        public override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.main.async {
                    self.window?.makeFirstResponder(self)
                    self.selectText(nil)
                }
            }
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTitleEditorView
        var hasCommitted = false

        init(_ parent: InlineTitleEditorView) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            guard !hasCommitted else { return }
            hasCommitted = true
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
            parent.onCommit()
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
                guard !hasCommitted else { return true }
                hasCommitted = true
                if let field = control as? NSTextField {
                    parent.text = field.stringValue
                }
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !hasCommitted else { return true }
                hasCommitted = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
