import SwiftUI
import AppKit
import PDFKit

public struct DocumentShelfView: View {
    public var documents: [Document]
    public var onOpenDocument: (Document) -> Void
    public var onImportDocument: () -> Void
    public var onDeleteDocument: (Document) -> Void

    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var selectedFolder: String = "Root"

    public init(
        documents: [Document],
        onOpenDocument: @escaping (Document) -> Void,
        onImportDocument: @escaping () -> Void,
        onDeleteDocument: @escaping (Document) -> Void
    ) {
        self.documents = documents
        self.onOpenDocument = onOpenDocument
        self.onImportDocument = onImportDocument
        self.onDeleteDocument = onDeleteDocument
    }

    private var sortedDocuments: [Document] {
        if sortMode == 0 {
            return documents.sorted { ($0.lastVisited ?? .distantPast) > ($1.lastVisited ?? .distantPast) }
        } else {
            return documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(spacing: 12) {
                Button(action: onImportDocument) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14))
                        Text("Import")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                // Folder picker
                Menu {
                    Button("Root") { selectedFolder = "Root" }
                } label: {
                    HStack(spacing: 4) {
                        Text("Folder: \(selectedFolder)")
                            .font(.system(size: 13, weight: .regular))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button("Select") {
                    // Selection mode toggle
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                Image(systemName: "list.bullet")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Subheader with Recent / Name segmented control
            Picker("", selection: $sortMode) {
                Text("Recent").tag(0)
                Text("Name").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .padding(.bottom, 18)

            Divider()
                .background(MarginNoteTheme.separatorColor)

            // Documents Grid
            ScrollView {
                if sortedDocuments.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Documents")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button("Import PDF…", action: onImportDocument)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                        ForEach(sortedDocuments, id: \.id) { doc in
                            DocumentCardView(document: doc, onOpen: { onOpenDocument(doc) })
                                .contextMenu {
                                    Button("Open") { onOpenDocument(doc) }
                                    Divider()
                                    Button("Delete", role: .destructive) { onDeleteDocument(doc) }
                                }
                        }
                    }
                    .padding(28)
                }
            }
        }
        .background(MarginNoteTheme.shelfBackground)
    }
}

public struct DocumentCardView: View {
    public var document: Document
    public var onOpen: () -> Void

    public init(document: Document, onOpen: @escaping () -> Void) {
        self.document = document
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                // Book Cover Container
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.93, green: 0.91, blue: 0.86))
                        .frame(height: 180)
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    // Cover thumbnail or preview
                    if let image = loadCoverThumbnail(path: document.filePath) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary.opacity(0.6))
                            Text(document.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: 180)
                    }

                    // Top Left "PDF" Badge
                    Text("PDF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(MarginNoteTheme.badgePDFRed, in: RoundedRectangle(cornerRadius: 2))
                        .padding(5)

                    // Top Right Page Count Badge
                    if document.totalPages > 0 {
                        HStack {
                            Spacer()
                            Text("\(document.totalPages)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(MarginNoteTheme.badgeGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                                .padding(5)
                        }
                    }
                }

                // Title Below Card
                Text(document.title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)

                // Cloud & More dots
                HStack {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadCoverThumbnail(path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let pdfDoc = PDFDocument(url: URL(fileURLWithPath: path)),
              let page = pdfDoc.page(at: 0) else {
            return nil
        }
        let thumbSize = NSSize(width: 148, height: 180)
        return page.thumbnail(of: thumbSize, for: .mediaBox)
    }
}
