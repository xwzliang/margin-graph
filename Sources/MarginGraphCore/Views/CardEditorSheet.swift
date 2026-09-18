import SwiftUI

public struct CardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notesText: String
    @State private var colorIndex: Int
    @State private var tags: [String]
    @State private var newTagText: String = ""

    public var card: NoteCard
    public var onSave: (NoteCard) -> Void
    public var onDelete: ((UUID) -> Void)?

    public init(
        card: NoteCard,
        onSave: @escaping (NoteCard) -> Void,
        onDelete: ((UUID) -> Void)? = nil
    ) {
        self.card = card
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: card.title)
        _notesText = State(initialValue: card.notesText)
        _colorIndex = State(initialValue: card.colorIndex)
        _tags = State(initialValue: card.tags)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Edit Card")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Button("Save") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.96))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Color Palette Selector
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Card Color")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            ForEach(0..<6, id: \.self) { idx in
                                let colors = MarginNoteTheme.cardColors(for: idx)
                                Button {
                                    colorIndex = idx
                                } label: {
                                    Circle()
                                        .fill(colors.accent)
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary.opacity(0.6), lineWidth: colorIndex == idx ? 2.5 : 0)
                                                .padding(-2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Color \(idx + 1)")
                            }
                        }
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("Card Title", text: $title, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .lineLimit(2...6)
                            .padding(.vertical, 2)
                    }

                    // Excerpt (Read-only preview from PDF)
                    if !card.highlightText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Excerpt")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text(card.highlightText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Comments / Markdown Notes
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comments & Notes")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $notesText)
                            .font(.system(size: 12))
                            .frame(minHeight: 110)
                            .padding(4)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.82), lineWidth: 1))
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                        .font(.system(size: 11, weight: .medium))
                                    Button {
                                        tags.removeAll { $0 == tag }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.blue)
                            }
                        }

                        HStack {
                            TextField("Add tag...", text: $newTagText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit {
                                    addTag()
                                }

                            Button("Add") {
                                addTag()
                            }
                            .buttonStyle(.bordered)
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    // Delete Button
                    if let onDelete {
                        Divider()
                            .padding(.top, 10)

                        Button(role: .destructive) {
                            onDelete(card.id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Note Card")
                            }
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 520)
        .background(MarginNoteTheme.shelfBackground)
    }

    private func addTag() {
        let cleaned = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard !cleaned.isEmpty, !tags.contains(cleaned) else { return }
        tags.append(cleaned)
        newTagText = ""
    }

    private func saveAndDismiss() {
        var updated = card
        updated.title = title
        updated.notesText = notesText
        updated.colorIndex = colorIndex
        updated.tags = tags
        updated.updatedAt = Date()
        onSave(updated)
        dismiss()
    }
}
