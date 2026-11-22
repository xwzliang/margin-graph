import MarginGraphCore
import SwiftUI

struct ReferenceEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: EditorFocus?
    @State var draft: BibTeXEntryDraft
    let isEditing: Bool
    let save: (BibTeXEntry) async throws -> Void
    @State private var error: String?
    @State private var busy = false
    private enum EditorFocus: Hashable {
        case fieldName(UUID)
        case fieldValue(UUID)
        case addField
    }

    private let nameWidth: CGFloat = 132
    private let removeWidth: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Reference" : "Add Reference")
                .font(.headline)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Entry type").font(.caption.weight(.medium))
                    TextField("book", text: $draft.type)
                        .accessibilityLabel("Entry type")
                }
                .frame(width: nameWidth)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Citation key").font(.caption.weight(.medium))
                    if isEditing {
                        Text(draft.key)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.vertical, 3)
                            .accessibilityLabel("Citation key, \(draft.key)")
                    } else {
                        TextField("e.g. Snyder_2005_SaveTheCat", text: $draft.key)
                            .accessibilityLabel("Citation key")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Text("Field").frame(width: nameWidth, alignment: .leading)
                Text("Value")
                Spacer()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            fieldList
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Entry", action: saveDraft)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 630, height: 530)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
    }

    private var fieldList: some View {
        ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach($draft.fields) { $field in
                            HStack(alignment: .top, spacing: 10) {
                                TextField("Field name", text: $field.name)
                                    .accessibilityLabel("Field name")
                                    .focused($focus, equals: .fieldName(field.id))
                                    .frame(width: nameWidth)
                                valueEditor($field)
                                Button {
                                    let id = field.id
                                    draft.fields.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .frame(width: removeWidth, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(field.name.isEmpty ? "Remove field" : "Remove \(field.name)")
                                .help(field.name.isEmpty ? "Remove field" : "Remove \(field.name)")
                            }
                            .id(field.id)
                        }
                    }
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                }
                .onChange(of: draft.fields.last?.id) { _, id in
                    guard let id, focus == .fieldName(id) else { return }
                    scroll.scrollTo(id, anchor: .bottom)
                }

                Button {
                    let field = BibTeXEntryDraft.Field()
                    draft.fields.append(field)
                    focus = .fieldName(field.id)
                } label: {
                    Label("Add Field", systemImage: "plus")
                }
                .focusable()
                .focused($focus, equals: .addField)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func valueEditor(_ field: Binding<BibTeXEntryDraft.Field>) -> some View {
        let id = field.wrappedValue.id
        let label = field.wrappedValue.name
        let focused = focus == .fieldValue(id)

        // Measure wrapped text without letting the editor grow beyond five lines.
        return Text(field.wrappedValue.value + "\u{200B}")
            .lineLimit(1...5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                TextEditor(text: field.value)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 1)
                    .focused($focus, equals: .fieldValue(id))
                    .accessibilityLabel(label.isEmpty ? "Field value" : "\(label) value")
                    .onKeyPress(.tab, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            focus = .fieldName(id)
                        } else if let next = draft.fields.drop(while: { $0.id != id }).dropFirst().first {
                            focus = .fieldName(next.id)
                        } else {
                            focus = .addField
                        }
                        return .handled
                    }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .font(.body)
    }

    private func saveDraft() {
        do {
            let entry = try draft.entry()
            error = nil
            busy = true
            Task {
                defer { busy = false }
                do {
                    try await save(entry)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
