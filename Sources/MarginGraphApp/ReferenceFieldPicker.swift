import MarginGraphCore
import SwiftUI

struct ReferenceFieldPicker: View {
    let draft: BibTeXEntryDraft
    let add: (String) -> Void
    let cancel: () -> Void

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let suggestions = draft.fieldSuggestions(matching: query)
        let customName = customChoice(excluding: suggestions)
        let choices = suggestions.map(\.name) + [customName].compactMap { $0 }
        let entryType = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selection.flatMap { choices.contains($0) ? $0 : nil }
            ?? preferredChoice(suggestions: suggestions, customName: customName)

        VStack(alignment: .leading, spacing: 10) {
            Text(entryType.isEmpty ? "Add Field" : "Add Field to @\(entryType)")
                .font(.headline)
                .lineLimit(1)
            ReferenceSearchBar(text: $query, focus: $isSearchFocused) {
                TextField("Search fields or enter a custom name", text: $query)
                    .onKeyPress(.downArrow) { moveSelection(from: selected, by: 1, choices: choices) }
                    .onKeyPress(.upArrow) { moveSelection(from: selected, by: -1, choices: choices) }
                    .onSubmit { if let selected { add(selected) } }
            }

            if choices.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List(selection: Binding(get: { selected }, set: { selection = $0 })) {
                        ForEach(suggestions) { field in
                            HStack(spacing: 10) {
                                Text(field.name).font(.system(.body, design: .monospaced))
                                if let label = field.label {
                                    Text(label).foregroundStyle(.secondary)
                                }
                            }
                            .tag(field.name)
                            .id(field.name)
                        }
                        if let customName {
                            Label("Add custom field “\(customName)”", systemImage: "plus")
                                .tag(customName)
                                .id(customName)
                        }
                    }
                    .listStyle(.bordered)
                    .onChange(of: selected) { _, name in
                        if let name { scroll.scrollTo(name) }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add Field") { if let selected { add(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(18)
        .defaultFocus($isSearchFocused, true, priority: .userInitiated)
        .task {
            await Task.yield()
            if !Task.isCancelled { isSearchFocused = true }
        }
        .onChange(of: query) { selection = nil }
    }

    private func preferredChoice(suggestions: [BibTeXFieldSuggestion], customName: String?) -> String? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // A native list can clear its selection when search changes the set of rows.
        return suggestions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name
            ?? suggestions.first?.name ?? customName
    }

    private func customChoice(excluding suggestions: [BibTeXFieldSuggestion]) -> String? {
        guard let name = try? draft.fieldNameForAddition(query),
              !suggestions.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return name
    }

    private var emptyMessage: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "All suggested fields are already in this entry."
        }
        do {
            _ = try draft.fieldNameForAddition(query)
            return "No matching fields."
        } catch {
            return error.localizedDescription
        }
    }

    private func moveSelection(from selected: String?, by offset: Int, choices: [String]) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        if let selected, let index = choices.firstIndex(of: selected) {
            self.selection = choices[min(max(index + offset, 0), choices.count - 1)]
        } else {
            selection = offset > 0 ? choices.first : choices.last
        }
        return .handled
    }
}
