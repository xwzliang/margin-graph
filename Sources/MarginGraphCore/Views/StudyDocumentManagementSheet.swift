import SwiftUI
import AppKit

public enum StudyDocumentSheetMode: Sendable {
    case manage
    case addExisting
}

public struct StudyDocumentManagementSheet: View {
    public var documents: [Document]
    public var allDocuments: [Document]
    public var activeDocument: Document?
    public var onSwitchDocument: (Document) -> Void
    public var onDetachDocument: (Document) -> Void
    public var onAddExistingDocument: (Document) -> Void
    public var onImportDocument: (() -> Void)?
    public var onDismiss: () -> Void

    @State private var mode: StudyDocumentSheetMode
    @State private var searchText: String = ""
    @FocusState private var isSearchFieldFocused: Bool

    public init(
        documents: [Document],
        allDocuments: [Document] = [],
        activeDocument: Document?,
        initialMode: StudyDocumentSheetMode = .manage,
        onSwitchDocument: @escaping (Document) -> Void,
        onDetachDocument: @escaping (Document) -> Void,
        onAddExistingDocument: @escaping (Document) -> Void,
        onImportDocument: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.documents = documents
        self.allDocuments = allDocuments
        self.activeDocument = activeDocument
        self._mode = State(initialValue: initialMode)
        self.onSwitchDocument = onSwitchDocument
        self.onDetachDocument = onDetachDocument
        self.onAddExistingDocument = onAddExistingDocument
        self.onImportDocument = onImportDocument
        self.onDismiss = onDismiss
    }

    private var availableDocuments: [Document] {
        let attachedMD5s = Set(documents.map(\.md5))
        let candidates = allDocuments.filter { !attachedMD5s.contains($0.md5) }
        let clean = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return candidates
        }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(clean) }
    }

    public var body: some View {
        Group {
            if mode == .addExisting {
                addExistingView
            } else {
                manageView
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Color(white: 0.97))
    }

    // MARK: - Manage View

    @ViewBuilder
    private var manageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Manage Study Documents")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(white: 0.12))

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Documents attached to this study notebook. Excerpts and notes created across these documents appear on the shared MindMap.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Document List
            if documents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No documents attached")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(documents) { doc in
                            HStack(spacing: 12) {
                                Image(systemName: docIconName(for: doc))
                                    .font(.system(size: 18))
                                    .foregroundStyle(docIconColor(for: doc))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    metadataText(for: doc)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if activeDocument?.id == doc.id || activeDocument?.md5 == doc.md5 {
                                    Text("Active")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12), in: Capsule())
                                } else {
                                    Button("Switch") {
                                        onSwitchDocument(doc)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Button(role: .destructive) {
                                    onDetachDocument(doc)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color(white: 0.55))
                                }
                                .buttonStyle(.plain)
                                .help("Detach document from notebook")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.98))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(white: 0.88), lineWidth: 0.75)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }

            // Bottom Actions: Add Existing + Import Document
            HStack(spacing: 12) {
                Button {
                    mode = .addExisting
                } label: {
                    Label("Add Document…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Add existing documents from library")

                if let onImportDocument {
                    Button {
                        onImportDocument()
                    } label: {
                        Label("Import Document…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Import a new document from your computer")
                }

                Spacer()
            }
        }
    }

    // MARK: - Add Existing View

    @ViewBuilder
    private var addExistingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Button {
                    mode = .manage
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Manage")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text("Add Existing Document")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(white: 0.15))

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Search Bar with auto-focus
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search library documents…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFieldFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(white: 0.82), lineWidth: 0.75)
            )

            // Document List
            if availableDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "All library documents have been added" : "No matching documents found")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(availableDocuments) { doc in
                            HStack(spacing: 12) {
                                Image(systemName: docIconName(for: doc))
                                    .font(.system(size: 18))
                                    .foregroundStyle(docIconColor(for: doc))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    metadataText(for: doc)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    onAddExistingDocument(doc)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("Add")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(white: 0.88), lineWidth: 0.75)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 240)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
    }

    // MARK: - Helpers

    private func docIconName(for doc: Document) -> String {
        let docType = doc.documentType.isEmpty ? MediaDocumentHelper.documentType(for: URL(fileURLWithPath: doc.filePath)) : doc.documentType
        switch docType {
        case "video": return "video.fill"
        case "audio": return "waveform"
        case "comic": return "photo.stack.fill"
        case "markdown": return "arrow.down.doc.fill"
        case "text", "rst": return "doc.plaintext.fill"
        case "rtf", "djvu": return "doc.richtext.fill"
        case "html": return "safari.fill"
        case "chm": return "questionmark.folder.fill"
        case "latex": return "function"
        case "org": return "checklist"
        case "asciidoc": return "text.alignleft"
        case "epub", "mobi", "azw3", "pdb", "fb2": return "book.closed.fill"
        default: return "doc.text.fill"
        }
    }

    private func docIconColor(for doc: Document) -> Color {
        let docType = doc.documentType.isEmpty ? MediaDocumentHelper.documentType(for: URL(fileURLWithPath: doc.filePath)) : doc.documentType
        switch docType {
        case "video": return Color(red: 0.15, green: 0.45, blue: 0.85)
        case "audio": return Color(red: 0.12, green: 0.60, blue: 0.42)
        case "comic": return Color(red: 0.88, green: 0.28, blue: 0.55)
        case "mobi": return Color(red: 0.35, green: 0.55, blue: 0.85)
        case "azw3": return Color(red: 0.85, green: 0.48, blue: 0.12)
        case "pdb": return Color(red: 0.40, green: 0.55, blue: 0.30)
        case "docx": return Color(red: 0.16, green: 0.42, blue: 0.82)
        case "odt": return Color(red: 0.28, green: 0.35, blue: 0.78)
        case "chm": return Color(red: 0.10, green: 0.55, blue: 0.70)
        case "djvu": return Color(red: 0.65, green: 0.35, blue: 0.15)
        case "latex": return Color(red: 0.15, green: 0.55, blue: 0.45)
        case "asciidoc": return Color(red: 0.85, green: 0.35, blue: 0.25)
        case "org": return Color(red: 0.45, green: 0.35, blue: 0.65)
        case "rst": return Color(red: 0.25, green: 0.50, blue: 0.65)
        case "fb2": return Color(red: 0.75, green: 0.45, blue: 0.15)
        case "text": return Color(red: 0.45, green: 0.45, blue: 0.50)
        case "markdown": return Color(red: 0.20, green: 0.65, blue: 0.70)
        case "rtf": return Color(red: 0.50, green: 0.35, blue: 0.75)
        case "html": return Color(red: 0.20, green: 0.60, blue: 0.35)
        case "epub": return Color.orange
        default: return Color(red: 0.85, green: 0.35, blue: 0.25)
        }
    }

    @ViewBuilder
    private func metadataText(for doc: Document) -> some View {
        let docType = doc.documentType.isEmpty ? MediaDocumentHelper.documentType(for: URL(fileURLWithPath: doc.filePath)) : doc.documentType
        if docType == "video" {
            Text("Video")
        } else if docType == "audio" {
            Text("Audio")
        } else if docType == "comic" {
            Text("Comic Book (\(doc.totalPages) pages)")
        } else if docType == "epub" {
            Text("EPUB Document (\(doc.totalPages) pages)")
        } else if docType == "mobi" {
            Text("MOBI EBook (\(doc.totalPages) pages)")
        } else if docType == "azw3" {
            Text("AZW3 / KF8 EBook (\(doc.totalPages) pages)")
        } else if docType == "pdb" {
            Text("PalmDOC Book (\(doc.totalPages) pages)")
        } else if docType == "docx" {
            Text("Word Document (\(doc.totalPages) pages)")
        } else if docType == "odt" {
            Text("OpenDocument Text (\(doc.totalPages) pages)")
        } else if docType == "chm" {
            Text("HTML Help Book (\(doc.totalPages) pages)")
        } else if docType == "djvu" {
            Text("DjVu Document (\(doc.totalPages) pages)")
        } else if docType == "latex" {
            Text("LaTeX Document (\(doc.totalPages) pages)")
        } else if docType == "asciidoc" {
            Text("AsciiDoc Book (\(doc.totalPages) pages)")
        } else if docType == "org" {
            Text("Org Mode Book (\(doc.totalPages) pages)")
        } else if docType == "rst" {
            Text("reStructuredText (\(doc.totalPages) pages)")
        } else if docType == "fb2" {
            Text("FB2 Book (\(doc.totalPages) pages)")
        } else if docType == "text" {
            Text("Text Book (\(doc.totalPages) pages)")
        } else if docType == "markdown" {
            Text("Markdown Book (\(doc.totalPages) pages)")
        } else if docType == "rtf" {
            Text("Rich Text (\(doc.totalPages) pages)")
        } else if docType == "html" {
            Text("Web Book (\(doc.totalPages) pages)")
        } else {
            Text("\(doc.totalPages) pages")
        }
    }
}
