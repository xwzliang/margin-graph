import AppKit
import MarginGraphCore
import SwiftUI

struct ReferencePage: View {
    @ObservedObject var workspace: ReferenceWorkspace
    @ObservedObject var model: AppModel
    @Binding var search: String
    @State private var studyMatch: StudyMatch?
    @State private var linkEditor: LinkEditor?
    @State private var linkRevision = 0
    @State private var editor: Editor?
    @State private var pendingDelete: Deletion?
    @State private var pendingNote: BibTeXEntry?
    @State private var noteToOpen: (BibTeXEntry, OrgExporter.ReferenceKind)?
    @State private var isISBNPresented = false
    @State private var isbn = ""

    private struct StudyRequest: Equatable {
        let file: URL
        let entry: BibTeXEntry
        let library: ObjectIdentifier
        let revision: Int
    }

    private struct StudyMatch {
        let request: StudyRequest
        let target: ReferenceStudyTarget
    }

    private struct LinkEditor: Identifiable {
        let id = UUID()
        let match: StudyMatch
    }

    private struct Editor: Identifiable {
        let id = UUID()
        let file: URL
        let original: BibTeXEntry?
        let draft: BibTeXEntryDraft
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
        workspace.entries.first { $0.key == workspace.selectedEntryKey }
    }

    private var studyRequest: StudyRequest? {
        guard let entry = selected, let file = workspace.selectedFile else { return nil }
        return StudyRequest(file: file, entry: entry, library: ObjectIdentifier(model.database), revision: linkRevision)
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
            if !entries.contains(where: { $0.key == workspace.selectedEntryKey }) { workspace.selectedEntryKey = nil }
        }
        .task(id: studyRequest) { [request = studyRequest] in
            guard let request else { return }
            do {
                let target = try await model.referenceStudyTarget(for: request.entry, bibliography: request.file)
                if !Task.isCancelled { studyMatch = StudyMatch(request: request, target: target) }
            } catch {
                if !Task.isCancelled {
                    workspace.message = error.localizedDescription
                    studyMatch = StudyMatch(request: request, target: ReferenceStudyTarget())
                }
            }
        }
        .sheet(item: $linkEditor) { editor in
            let match = editor.match
            ReferenceNotebookPicker(topics: model.topics, cardCounts: model.cardCounts, selectedID: match.target.topic?.id,
                                    canReset: match.target.isSaved) { topic in
                guard match.request.library == ObjectIdentifier(model.database) else {
                    throw ReferenceStudyError.cannotOpenNotebook
                }
                if let topic {
                    try model.saveReferenceStudyTarget(topic, for: match.request.entry, bibliography: match.request.file)
                } else {
                    try model.database.removeReferenceStudyLink(bibliography: match.request.file, key: match.request.entry.key)
                }
                linkRevision += 1
                linkEditor = nil
            }
        }
        .sheet(item: $editor) { item in
            ReferenceEntryEditor(draft: item.draft, isEditing: item.original != nil) { entry in
                try await workspace.save(entry, replacing: item.original, in: item.file)
                workspace.selectedEntryKey = entry.key
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
                workspace.selectedEntryKey = nil
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
                        editor = Editor(file: file, original: nil, draft: BibTeXEntryDraft())
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

            List(selection: $workspace.selectedEntryKey) {
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
                    if let studyMatch, studyMatch.request == studyRequest {
                        Divider()
                        studySection(studyMatch)
                            .disabled(workspace.busy)
                    }
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
                description: Text("View its BibTeX entry, PDF, mind map, and Org-roam literature note."))
        }
    }

    private func studySection(_ match: StudyMatch) -> some View {
        let target = match.target
        return VStack(alignment: .leading, spacing: 8) {
            Text("Study").font(.headline)
            if let title = target.title {
                Text(title).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Link a notebook or locate this reference’s PDF.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if target.document != nil {
                studyButton("Open PDF & Mind Map", match: match)
            } else if target.attachment != nil {
                studyButton("Add PDF & Open Study", match: match)
            } else if target.topic != nil {
                studyButton("Open Mind Map", match: match)
            }
            ViewThatFits(in: .horizontal) {
                HStack { studyLinkButtons(match) }
                VStack(alignment: .leading) { studyLinkButtons(match) }
            }
        }
    }

    private func studyButton(_ label: String, match: StudyMatch) -> some View {
        Button(label) {
            workspace.execute {
                try model.openReferenceStudy(match.target, entry: match.request.entry, bibliography: match.request.file)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private func studyLinkButtons(_ match: StudyMatch) -> some View {
        Button(match.target.isSaved ? "Change Link…" : "Link Notebook…") {
            linkEditor = LinkEditor(match: match)
        }
        .disabled(model.topics.isEmpty)
        if match.target.document == nil {
            Button("Locate PDF…") {
                workspace.execute {
                    guard let pdf = await workspace.choosePDF(title: "Locate the Reference PDF"),
                          match.request.library == ObjectIdentifier(model.database) else { return }
                    try model.openReferenceStudy(match.target, entry: match.request.entry,
                                                 bibliography: match.request.file, locatedPDF: pdf)
                }
            }
        }
    }

    @ViewBuilder
    private func editButtons(for entry: BibTeXEntry, in file: URL) -> some View {
        Button("Edit…") {
            workspace.execute {
                editor = Editor(file: file, original: entry, draft: try BibTeXEntryDraft(entry))
            }
        }
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
            workspace.selectedEntryKey = proposal.entry.key
            workspace.message = "This reference is already in \(existingFile.lastPathComponent)."
            return
        }
        editor = Editor(file: file, original: nil, draft: try BibTeXEntryDraft(proposal.entry))
    }
}

private struct ReferenceNotebookPicker: View {
    let topics: [Topic]
    let cardCounts: [UUID: Int]
    let canReset: Bool
    let save: (Topic?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var errorMessage: String?

    init(topics: [Topic], cardCounts: [UUID: Int], selectedID: UUID?, canReset: Bool,
         save: @escaping (Topic?) throws -> Void) {
        self.topics = topics
        self.cardCounts = cardCounts
        self.canReset = canReset
        self.save = save
        _selectedID = State(initialValue: selectedID)
    }

    private var matchingTopics: [Topic] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return topics.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.createdAt < rhs.createdAt
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Study Notebook").font(.headline)
            TextField("Search notebooks", text: $search)
            List(selection: $selectedID) {
                ForEach(matchingTopics) { topic in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topic.title)
                        Text("Cards: \(cardCounts[topic.id, default: 0]) · Created \(topic.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(topic.id)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if canReset { Button("Use Automatic Match") { finish(nil) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Link") {
                    if let topic = topics.first(where: { $0.id == selectedID }) { finish(topic) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private func finish(_ topic: Topic?) {
        do { try save(topic) }
        catch { errorMessage = error.localizedDescription }
    }
}
