import AppKit
import Foundation
import MarginGraphCore
import SwiftUI
import UniformTypeIdentifiers

struct DocumentBibliographyEntry: Identifiable, Sendable {
    let bibliography: URL
    let entry: BibTeXEntry
    var id: String { bibliography.absoluteString + "#" + entry.key }
}

private struct UnavailableBibliographyEntry: LocalizedError {
    let citation: ReferenceStudyCitation

    var errorDescription: String? {
        "“\(citation.key)” could not be read from \(citation.bibliography.lastPathComponent)."
    }
}

@MainActor
final class ReferenceWorkspace: ObservableObject {
    private static let filesKey = "Reference.bibliographies"
    private static let selectedKey = "Reference.activeBibliography"
    private static let directoryKey = "Reference.literatureDirectory"
    private let defaults: UserDefaults

    @Published private(set) var files: [URL]
    @Published private(set) var selectedFile: URL?
    @Published private(set) var literatureDirectory: URL?
    @Published private(set) var entries: [BibTeXEntry] = []
    @Published var selectedEntryKey: String?
    @Published private(set) var busy = false
    @Published var message: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        files = (defaults.stringArray(forKey: Self.filesKey) ?? []).map { URL(fileURLWithPath: $0) }
        let selected = defaults.string(forKey: Self.selectedKey)
        selectedFile = files.first(where: { $0.path == selected }) ?? files.first
        literatureDirectory = defaults.string(forKey: Self.directoryKey).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    struct Proposal: Sendable {
        let entry: BibTeXEntry
        let existingFile: URL?
    }

    func reload() async throws {
        guard let selectedFile else {
            entries = []
            return
        }
        let loaded = try await Task.detached { try BibTeXLibrary.load(selectedFile).entries }.value
        if selectedFile == self.selectedFile { entries = loaded }
    }

    func bibliography(for document: Document, database: Database, topicID: UUID?,
                      includesNotebookLink: Bool) async throws -> [DocumentBibliographyEntry] {
        let files = files
        return try await Task.detached {
            let citations = try database.referenceStudyCitations(bookMD5: document.md5, topicID: topicID,
                                                                includesNotebookLink: includesNotebookLink)
            var catalog: [URL: [BibTeXEntry]] = [:]
            var firstReadError: Error?
            func entries(in bibliography: URL) -> [BibTeXEntry] {
                if let entries = catalog[bibliography] { return entries }
                do {
                    let entries = try BibTeXLibrary.load(bibliography).entries
                    catalog[bibliography] = entries
                    return entries
                } catch {
                    if firstReadError == nil { firstReadError = error }
                    catalog[bibliography] = []
                    return []
                }
            }
            let saved = citations.compactMap { citation -> DocumentBibliographyEntry? in
                entries(in: citation.bibliography).first { $0.key == citation.key }
                    .map { DocumentBibliographyEntry(bibliography: citation.bibliography, entry: $0) }
            }
            if !saved.isEmpty { return saved }

            let path = URL(fileURLWithPath: document.filePath).standardizedFileURL.path
            if !document.filePath.isEmpty, path.lowercased().hasSuffix(".pdf") {
                let attached = files.flatMap { bibliography in
                    entries(in: bibliography).filter { entry in
                        ReferenceStudyMatcher.pdfAttachments(for: entry, bibliography: bibliography)
                            .contains { $0.path == path }
                    }.map { DocumentBibliographyEntry(bibliography: bibliography, entry: $0) }
                }
                if !attached.isEmpty { return attached }
            }
            if let citation = citations.first { throw UnavailableBibliographyEntry(citation: citation) }
            if let firstReadError { throw firstReadError }
            return []
        }.value
    }

    func select(_ file: URL) {
        selectedFile = file
        defaults.set(file.path, forKey: Self.selectedKey)
        entries = []
        execute { try await self.reload() }
    }

    func execute(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await work() }
            catch { message = error.localizedDescription }
        }
    }

    func chooseBibliographies() async throws {
        let panel = NSOpenPanel()
        panel.title = "Open Ebib / BibTeX Database"
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.directoryURL = selectedFile?.deletingLastPathComponent()
        guard await show(panel) else { return }
        let picked = panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let loaded = try await Task.detached {
            try picked.map { try BibTeXLibrary.load($0).entries }
        }.value
        for file in picked where !files.contains(file) { files.append(file) }
        defaults.set(files.map(\.path), forKey: Self.filesKey)
        if let first = picked.first {
            selectedFile = first
            defaults.set(first.path, forKey: Self.selectedKey)
            entries = loaded.first ?? []
        }
    }

    func createBibliography() async throws {
        let panel = NSSavePanel()
        panel.title = "Create BibTeX Database"
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.nameFieldStringValue = "references.bib"
        panel.directoryURL = selectedFile?.deletingLastPathComponent()
        guard await show(panel), let url = panel.url else { return }
        try Data().write(to: url, options: .withoutOverwriting)
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        if !files.contains(file) { files.append(file) }
        selectedFile = file
        entries = []
        defaults.set(files.map(\.path), forKey: Self.filesKey)
        defaults.set(file.path, forKey: Self.selectedKey)
    }

    func closeSelectedBibliography() {
        guard let selectedFile else { return }
        files.removeAll { $0 == selectedFile }
        defaults.set(files.map(\.path), forKey: Self.filesKey)
        self.selectedFile = nil
        entries = []
        if let next = files.first { select(next) }
        else { defaults.removeObject(forKey: Self.selectedKey) }
    }

    @discardableResult
    func chooseLiteratureDirectory() async -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Org-roam Literature Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = literatureDirectory
        guard await show(panel), let url = panel.url else { return false }
        literatureDirectory = url.standardizedFileURL
        defaults.set(url.path, forKey: Self.directoryKey)
        return true
    }

    func choosePDF(title: String = "Identify a PDF Reference") async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.pdf]
        guard await show(panel) else { return nil }
        return panel.url
    }

    func proposeISBN(_ isbn: String) async throws -> Proposal {
        let located = try await catalogByFile()
        let catalog = located.flatMap(\.entries)
        guard let number = ISBN.canonical(isbn) else { throw ISBNLookup.LookupError.invalidISBN }
        if let existing = ReferenceMetadata.match(ReferenceMetadata(fields: ["isbn": number]), in: catalog) {
            return proposal(existing, in: located)
        }
        let entry = try await ISBNLookup.fetch(number).entry(avoiding: Set(catalog.map(\.key)))
        return Proposal(entry: entry, existingFile: nil)
    }

    func proposePDF(_ url: URL) async throws -> Proposal {
        let located = try await catalogByFile()
        let entry = try await identify(url: url, title: "", catalog: located.flatMap(\.entries))
        return proposal(entry, in: located)
    }

    func showExisting(_ file: URL) async throws {
        selectedFile = file
        defaults.set(file.path, forKey: Self.selectedKey)
        try await reload()
    }

    private func proposal(_ entry: BibTeXEntry, in catalog: [(file: URL, entries: [BibTeXEntry])]) -> Proposal {
        Proposal(entry: entry, existingFile: catalog.first { $0.entries.contains(entry) }?.file)
    }

    func save(_ entry: BibTeXEntry, replacing original: BibTeXEntry? = nil, in file: URL) async throws {
        if original == nil {
            let catalog = try await snapshot()
            guard !catalog.contains(where: { $0.key == entry.key }) else { throw BibTeXError.duplicate(entry.key) }
        }
        try await Task.detached { try BibTeXLibrary.save(entry, replacing: original, in: file) }.value
        try await reload()
    }

    func delete(_ entry: BibTeXEntry, from file: URL) async throws {
        try await Task.detached { try BibTeXLibrary.delete(entry, from: file) }.value
        try await reload()
    }

    func literatureNote(for entry: BibTeXEntry, kind: OrgExporter.ReferenceKind) async throws -> URL? {
        if literatureDirectory == nil, !(await chooseLiteratureDirectory()) { return nil }
        guard let directory = literatureDirectory else { return nil }
        let title = entry.title.isEmpty ? entry.key : entry.title
        return try await Task.detached {
            try Self.writeNote(topic: Topic(title: title), cards: [], documents: [], entry: entry, directory: directory, kind: kind)
        }.value
    }

    struct ExportResult {
        let note: URL
        let key: String
        let bibliography: URL
        let bookMD5: String?
    }

    func export(topic: Topic, cards: [NoteCard], documents: [Document],
                replacementDocumentPaths: [String: String]) async throws -> ExportResult? {
        if selectedFile == nil { try await chooseBibliographies() }
        guard let file = selectedFile else { return nil }
        if literatureDirectory == nil, !(await chooseLiteratureDirectory()) { return nil }
        guard let directory = literatureDirectory else { return nil }
        let catalogFiles = try await catalogByFile()
        let catalog = catalogFiles.flatMap(\.entries)
        // A notebook describes its primary source. Use a stable order even when a child map
        // or another document tab is active, while keeping source information on every card.
        let document = topic.bookMD5List.compactMap { hash in
            documents.first { Database.bookHashesMatch(hash, $0.md5) }
        }.first ?? documents.first
        let url = document.flatMap { $0.filePath.isEmpty ? nil : URL(fileURLWithPath: $0.filePath) }
        let existing = ReferenceMetadata.match(ReferenceMetadata(fields: ["title": topic.title]), in: catalog, fileURL: url)
        let entry: BibTeXEntry
        if let existing {
            entry = existing
        } else {
            entry = try await identify(url: url, title: document?.title ?? topic.title, catalog: catalog)
        }
        let existingFile = catalogFiles.first { $0.entries.contains(entry) }?.file
        let output = try await Task.detached {
            let targetFile = existingFile ?? file
            let attached = try url.map { try BibTeXLibrary.attachingPDF($0, to: entry, bibliography: targetFile) } ?? entry
            if existingFile == nil {
                try BibTeXLibrary.save(attached, in: file)
            } else if attached.source != entry.source {
                try BibTeXLibrary.save(attached, replacing: entry, in: targetFile)
            }
            return try Self.writeNote(topic: topic, cards: cards, documents: documents, entry: entry, directory: directory,
                                      replacementDocumentPaths: replacementDocumentPaths)
        }.value
        try await reload()
        return ExportResult(note: output, key: entry.key, bibliography: existingFile ?? file, bookMD5: document?.md5)
    }

    private func snapshot() async throws -> [BibTeXEntry] {
        try await catalogByFile().flatMap(\.entries)
    }

    private func catalogByFile() async throws -> [(file: URL, entries: [BibTeXEntry])] {
        let files = files
        return try await Task.detached { try files.map { ($0, try BibTeXLibrary.load($0).entries) } }.value
    }

    private func identify(url: URL?, title: String, catalog: [BibTeXEntry]) async throws -> BibTeXEntry {
        let titleOnly = ReferenceMetadata(fields: ["title": title])
        if let existing = ReferenceMetadata.match(titleOnly, in: catalog, fileURL: url) { return existing }
        let local: ReferenceMetadata
        if let url {
            local = await Task.detached { ReferenceMetadata.inspect(url, titleHint: title) }.value
        } else {
            local = ReferenceMetadata(type: "misc", fields: ["title": title])
        }
        if let existing = ReferenceMetadata.match(local, in: catalog, fileURL: url) { return existing }
        var resolved = local
        if let isbn = local.fields["isbn"], let online = try? await ISBNLookup.fetch(isbn) {
            // Prefer catalog citation fields while preserving the local attachment.
            resolved.fields.merge(online.fields) { _, remote in remote }
            if let existing = ReferenceMetadata.match(resolved, in: catalog, fileURL: url) { return existing }
        }
        return try resolved.entry(avoiding: Set(catalog.map(\.key)))
    }

    nonisolated private static func writeNote(topic: Topic, cards: [NoteCard], documents: [Document],
                                              entry: BibTeXEntry, directory: URL, kind: OrgExporter.ReferenceKind? = nil,
                                              replacementDocumentPaths: [String: String] = [:]) throws -> URL {
        var namedTopic = topic
        if !entry.title.isEmpty { namedTopic.title = entry.title }
        let content = OrgExporter.export(topic: namedTopic, cards: cards, documents: documents,
                                         reference: entry, referenceKind: kind)
        return try OrgLiteratureLibrary.write(content, reference: entry,
            filename: OrgExporter.suggestedFilename(for: namedTopic), directory: directory,
            replacementDocumentPaths: replacementDocumentPaths)
    }

    private func show(_ panel: NSSavePanel) async -> Bool {
        await withCheckedContinuation { continuation in
            let respond: (NSApplication.ModalResponse) -> Void = { continuation.resume(returning: $0 == .OK) }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: respond)
            } else {
                panel.begin(completionHandler: respond)
            }
        }
    }
}
