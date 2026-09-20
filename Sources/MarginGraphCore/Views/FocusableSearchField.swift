import SwiftUI
import AppKit

public struct FocusableSearchField: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public var onSubmit: () -> Void
    public var onCancel: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String = "Search in document…",
        onSubmit: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> CustomTextField {
        let field = CustomTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        field.onEscape = onCancel

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            field.window?.makeKeyAndOrderFront(nil)
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
        return field
    }

    public func updateNSView(_ nsView: CustomTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onEscape = onCancel
    }

    public final class CustomTextField: NSTextField {
        var onEscape: (() -> Void)?

        public override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    self.window?.makeKeyAndOrderFront(nil)
                    self.window?.makeFirstResponder(self)
                }
            }
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableSearchField

        init(_ parent: FocusableSearchField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

