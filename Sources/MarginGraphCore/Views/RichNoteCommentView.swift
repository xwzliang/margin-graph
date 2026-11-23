import AppKit
import SwiftUI

enum RichNoteCommentText {
    static func attributed(text: String, comments: [RichNoteComment], scale: CGFloat = 1) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]
        var start = text.startIndex
        for comment in comments {
            guard let range = text.range(of: comment.text, range: start..<text.endIndex),
                  let formatted = NSAttributedString(rtf: comment.rtf, documentAttributes: nil) else { continue }
            result.append(NSAttributedString(string: String(text[start..<range.lowerBound]), attributes: attributes))
            result.append(formatted)
            start = range.upperBound
        }
        result.append(NSAttributedString(string: String(text[start...]), attributes: attributes))
        if scale != 1 {
            let range = NSRange(location: 0, length: result.length)
            let unscaled = NSAttributedString(attributedString: result)
            unscaled.enumerateAttribute(.font, in: range) { value, run, _ in
                if let font = value as? NSFont {
                    result.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor,
                                                            size: max(10, font.pointSize * scale)) ?? font, range: run)
                }
            }
        }
        return result
    }

    static let cardScale: CGFloat = 0.55

    static func cardHeight(text: String, comments: [RichNoteComment], width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed(text: text, comments: comments, scale: cardScale))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

/// TextKit 1 keeps RTF paragraph styles and NSTextTable blocks intact.
struct RichNoteCommentView: NSViewRepresentable {
    let text: String
    let comments: [RichNoteComment]
    var onEdit: ((String, [RichNoteComment]?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        // Explicitly select TextKit 1. Rich text tables use its layout manager.
        _ = view.layoutManager
        view.isRichText = true
        view.isEditable = onEdit != nil
        view.isSelectable = onEdit != nil
        view.drawsBackground = onEdit != nil
        view.textContainerInset = onEdit == nil ? .zero : NSSize(width: 10, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        scroll.drawsBackground = onEdit != nil
        scroll.hasVerticalScroller = onEdit != nil
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        guard coordinator.loadedText != text || coordinator.loadedComments != comments else { return }
        coordinator.loadedText = text
        coordinator.loadedComments = comments
        view.textStorage?.setAttributedString(RichNoteCommentText.attributed(
            text: text, comments: comments, scale: onEdit == nil ? RichNoteCommentText.cardScale : 1
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard onEdit == nil, let width = proposal.width, width > 0,
              let view = nsView.documentView as? NSTextView,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var loadedText: String?
        var loadedComments: [RichNoteComment]?
        var onEdit: ((String, [RichNoteComment]?) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let onEdit, let view = notification.object as? NSTextView, let content = view.textStorage else { return }
            let text = content.string
            let range = NSRange(location: 0, length: content.length)
            let comments = content.rtf(from: range, documentAttributes: [:]).flatMap {
                text.isEmpty ? nil : [RichNoteComment(text: text, rtf: $0)]
            }
            loadedText = text
            loadedComments = comments ?? []
            onEdit(text, comments)
        }
    }
}
