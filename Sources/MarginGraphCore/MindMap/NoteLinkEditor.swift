import SwiftUI

struct NoteLinkEditor: View {
    struct Entry: Identifiable {
        let id = UUID()
        var label: String
        var destination: String
        var field: Int
        var range: NSRange?
        var removed = false
    }
    let card: NoteCard
    let candidates: [NoteCard]
    let onSave: (NoteCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry]
    @State private var query = ""

    init(card: NoteCard, candidates: [NoteCard], onSave: @escaping (NoteCard) -> Void) {
        self.card = card
        self.candidates = candidates
        self.onSave = onSave
        _entries = State(initialValue: [card.highlightText, card.notesText].enumerated().flatMap { field, text in
            NoteTextLinks.references(in: text).map {
                Entry(label: $0.label, destination: DeepLinkHandler.url(forCard: $0.target).absoluteString, field: field, range: $0.range)
            }
        })
    }

    private func target(_ value: String) -> UUID? {
        if let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) { return id }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              case .openCard(let id) = DeepLinkHandler.parse(url) else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note Links").font(.headline)
            Text("Edit the title and destination, or find a note below. Links can also point to a note in another notebook using its copied link.").font(.caption)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        if !entry.removed {
                            VStack(alignment: .leading) {
                                TextField("Link title", text: $entry.label)
                                HStack {
                                    TextField("Note URL or ID", text: $entry.destination)
                                    Button("Remove") { entry.removed = true }
                                }
                                if target(entry.destination) == nil { Text("Enter a valid note link or UUID.").font(.caption).foregroundStyle(.red) }
                            }
                        }
                    }
                }
            }.frame(height: 180)
            Button("Add Link") { entries.append(Entry(label: "", destination: "", field: 1)) }
            TextField("Find a note in this notebook", text: $query)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates.filter { $0.id != card.id && !query.isEmpty && ($0.title.localizedCaseInsensitiveContains(query) || $0.highlightText.localizedCaseInsensitiveContains(query)) }.prefix(20)) { candidate in
                        Button(candidate.title.isEmpty ? String(candidate.highlightText.prefix(80)) : candidate.title) {
                            entries.append(Entry(label: candidate.title.isEmpty ? "Open linked note" : candidate.title,
                                                 destination: candidate.deepLinkURL.absoluteString, field: 1))
                            query = ""
                        }.buttonStyle(.link)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = card
                    var fields = [card.highlightText, card.notesText]
                    for field in 0...1 {
                        let edits = entries.filter { $0.field == field && $0.range != nil }.map { entry in
                            (range: entry.range!, replacement: entry.removed ? "" : NoteTextLinks.markup(label: entry.label, target: target(entry.destination)!))
                        }
                        fields[field] = NoteTextLinks.replacing(in: fields[field], edits: edits)
                    }
                    for entry in entries where entry.range == nil && !entry.removed {
                        if !fields[entry.field].isEmpty { fields[entry.field] += "\n\n" }
                        fields[entry.field] += NoteTextLinks.markup(label: entry.label, target: target(entry.destination)!)
                    }
                    updated.highlightText = fields[0]
                    updated.notesText = fields[1]
                    onSave(updated)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(entries.contains { !$0.removed && target($0.destination) == nil })
            }
        }.padding(20).frame(width: 520)
    }
}
