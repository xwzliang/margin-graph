import AppKit
import MarginGraphCore
import SwiftUI

struct ReferencePage: View {
    @ObservedObject var workspace: ReferenceWorkspace
    @Binding var search: String
    @State private var selectedKey: String?
    @State private var editor: Editor?
    @State private var pendingDelete: Deletion?
    @State private var pendingNote: BibTeXEntry?
    @State private var noteToOpen: (BibTeXEntry, OrgExporter.ReferenceKind)?
    @State private var isISBNPresented = false
    @State private var isbn = ""

    private struct Editor: Identifiable {
        let id = UUID()
        let file: URL
        let original: BibTeXEntry?
        let source: String
    }

    private struct Deletion {
        let file: URL
        let entry: BibTeXEntry
    }

    private var matchingEntries: [BibTeXEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.entries.filter {
            query.isEmpty || [$0.title, $0.author, $0.year, $0.type, $0.key, $0.fields["isbn"] ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selected: BibTeXEntry? {
        workspace.entries.first { $0.key == selectedKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if workspace.files.isEmpty {
                ContentUnavailableView("No bibliography open", systemImage: "books.vertical",
                    description: Text("Open the .bib files you use in Ebib, or create a bibliography."))
            } else {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 0) {
                        entryList.frame(width: geometry.size.width * 0.48)
                        Divider()
                        entryDetail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
            if let message = workspace.message {
                Divider()
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { workspace.execute { try await workspace.reload() } }
        .onChange(of: workspace.entries) { _, entries in
            if !entries.contains(where: { $0.key == selectedKey }) { selectedKey = nil }
        }
        .sheet(item: $editor) { item in
            ReferenceEntryEditor(source: item.source, isEditing: item.original != nil) { source in
                try await workspace.save(source, replacing: item.original, in: item.file)
                selectedKey = try BibTeXLibrary.entry(source).key
            }
        }
        .alert("Look up a book by ISBN", isPresented: $isISBNPresented) {
            TextField("ISBN-10 or ISBN-13", text: $isbn)
            Button("Cancel", role: .cancel) {}
            Button("Look Up") {
                guard let file = workspace.selectedFile else { return }
                let number = isbn
                workspace.execute { try await show(workspace.proposeISBN(number), in: file) }
            }
        } message: {
            Text("MarginGraph sends the ISBN to Open Library to fetch citation details.")
        }
        .sheet(item: $pendingNote, onDismiss: openPendingNote) { entry in
            VStack(alignment: .leading, spacing: 14) {
                Text("Open Literature Note").font(.headline)
                Text(entry.title.isEmpty ? entry.key : entry.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Button("Cancel") { pendingNote = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Book / PDF Note") { queueNote(entry, kind: .book) }
                    Button("Video Note") { queueNote(entry, kind: .video) }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }
        .alert("Delete reference?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { deletion in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                workspace.execute { try await workspace.delete(deletion.entry, from: deletion.file) }
                selectedKey = nil
            }
        } message: { deletion in
            Text("“\(deletion.entry.key)” will be removed from \(deletion.file.lastPathComponent). Existing Org notes may still cite this key.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reference").font(.title2.bold())
                if workspace.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer()
                Button("Open Bibliography…") { workspace.execute { try await workspace.chooseBibliographies() } }
                Button("New Bibliography…") { workspace.execute { try await workspace.createBibliography() } }
            }
            HStack {
                Button("Literature Folder…") { workspace.execute { await workspace.chooseLiteratureDirectory() } }
                Text(workspace.literatureDirectory?.path ?? "Choose the literature folder inside your Org-roam directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace.literatureDirectory?.path ?? "")
            }
            if !workspace.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(workspace.files, id: \.self) { file in
                            let selected = workspace.selectedFile == file
                            Button { workspace.select(file) } label: {
                                Text(file.lastPathComponent)
                                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        selected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(file.path)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        Button("Close") { workspace.closeSelectedBibliography() }
                            .help("Close this bibliography")
                        Button("Reload") { workspace.execute { try await workspace.reload() } }
                            .help("Read changes made in Ebib or another editor")
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 28)
            }
        }
        .padding(16)
        .disabled(workspace.busy)
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search title, author, citation key, or ISBN", text: $search)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Add Entry…") {
                        guard let file = workspace.selectedFile else { return }
                        editor = Editor(file: file, original: nil, source: "@book{key,\n    title = {},\n    author = {},\n    year = {}\n}")
                    }
                    Button("From ISBN…") { isbn = ""; isISBNPresented = true }
                    Button("From PDF…") {
                        guard let file = workspace.selectedFile else { return }
                        workspace.execute {
                            guard let pdf = await workspace.choosePDF() else { return }
                            try await show(workspace.proposePDF(pdf), in: file)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .disabled(workspace.busy || workspace.selectedFile == nil)
            }
            .padding(12)

            List(selection: $selectedKey) {
                ForEach(Array(matchingEntries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title.isEmpty ? entry.key : entry.title)
                            .font(.body.weight(.medium)).lineLimit(2)
                        Text([entry.author, entry.year, entry.key].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(entry.key)
                }
            }
            Text("\(matchingEntries.count) references")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var entryDetail: some View {
        if let entry = selected, let file = workspace.selectedFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title.isEmpty ? entry.key : entry.title).font(.title3.bold())
                    Text(entry.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { editButtons(for: entry, in: file) }
                        VStack(alignment: .leading) { editButtons(for: entry, in: file) }
                    }
                    .disabled(workspace.busy)
                    Divider()
                    Text(entry.source)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a reference", systemImage: "doc.text",
                description: Text("View or edit its BibTeX entry and open its Org-roam literature note."))
        }
    }

    @ViewBuilder
    private func editButtons(for entry: BibTeXEntry, in file: URL) -> some View {
        Button("Edit…") { editor = Editor(file: file, original: entry, source: entry.source) }
        Button("Open Literature Note…") { pendingNote = entry }
        Button("Delete…", role: .destructive) { pendingDelete = Deletion(file: file, entry: entry) }
    }

    private func queueNote(_ entry: BibTeXEntry, kind: OrgExporter.ReferenceKind) {
        noteToOpen = (entry, kind)
        pendingNote = nil
    }

    private func openPendingNote() {
        guard let (entry, kind) = noteToOpen else { return }
        noteToOpen = nil
        workspace.execute {
            if let url = try await workspace.literatureNote(for: entry, kind: kind), !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func show(_ proposal: ReferenceWorkspace.Proposal, in file: URL) async throws {
        if let existingFile = proposal.existingFile {
            try await workspace.showExisting(existingFile)
            selectedKey = proposal.entry.key
            workspace.message = "This reference is already in \(existingFile.lastPathComponent)."
            return
        }
        editor = Editor(file: file, original: nil, source: proposal.entry.source)
    }
}

private struct ReferenceEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: String
    let isEditing: Bool
    let save: (String) async throws -> Void
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Reference" : "Add Reference").font(.headline)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
                .accessibilityLabel("BibTeX entry")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Entry") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await save(source); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 550, minHeight: 370)
        .disabled(busy)
    }
}
