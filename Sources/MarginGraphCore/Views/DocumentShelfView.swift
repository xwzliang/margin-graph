import SwiftUI
import AppKit
import PDFKit

public struct DocumentShelfView: View {
    public var documents: [Document]
    public var onOpenDocument: (Document) -> Void
    public var onImportDocument: () -> Void
    public var onImportURLs: (([URL]) -> Void)?
    public var onDeleteDocument: (Document) -> Void

    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var selectedFolder: String = "Root"
    @State private var isDropTargeted: Bool = false

    public init(
        documents: [Document],
        onOpenDocument: @escaping (Document) -> Void,
        onImportDocument: @escaping () -> Void,
        onImportURLs: (([URL]) -> Void)? = nil,
        onDeleteDocument: @escaping (Document) -> Void
    ) {
        self.documents = documents
        self.onOpenDocument = onOpenDocument
        self.onImportDocument = onImportDocument
        self.onImportURLs = onImportURLs
        self.onDeleteDocument = onDeleteDocument
    }

    private var sortedDocuments: [Document] {
        if sortMode == 0 {
            return documents.sorted {
                let d0 = $0.lastVisited ?? .distantPast
                let d1 = $1.lastVisited ?? .distantPast
                if d0 != d1 {
                    return d0 > d1
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
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
                        Button("Import Document / Media…", action: onImportDocument)
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
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.selectFile(doc.filePath, inFileViewerRootedAtPath: "")
                                    }
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0)
                .padding(4)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let collector = URLCollector()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        collector.add(url)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !collector.urls.isEmpty {
                    onImportURLs?(collector.urls)
                }
            }
            return true
        }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }
}

public struct DocumentCardView: View {
    public var document: Document
    public var onOpen: () -> Void

    public init(document: Document, onOpen: @escaping () -> Void) {
        self.document = document
        self.onOpen = onOpen
    }

    private var docType: String {
        if !document.documentType.isEmpty {
            return document.documentType
        }
        return MediaDocumentHelper.documentType(for: URL(fileURLWithPath: document.filePath))
    }

    private var badgeColor: Color {
        switch docType {
        case "video":
            return Color(red: 0.15, green: 0.45, blue: 0.85) // Blue
        case "audio":
            return Color(red: 0.12, green: 0.60, blue: 0.42) // Emerald
        case "epub":
            return Color.orange
        default:
            return MarginNoteTheme.badgePDFRed
        }
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
                            if docType == "video" {
                                Image(systemName: "film.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            } else if docType == "audio" {
                                Image(systemName: "waveform.circle.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            } else {
                                Image(systemName: "book.closed.fill")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }

                            Text(document.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: 180)
                    }

                    // Top Left Type Badge
                    HStack(spacing: 3) {
                        if docType == "video" {
                            Image(systemName: "video.fill")
                                .font(.system(size: 7.5))
                            Text("VIDEO")
                                .font(.system(size: 8.5, weight: .bold))
                        } else if docType == "audio" {
                            Image(systemName: "waveform")
                                .font(.system(size: 7.5))
                            Text("AUDIO")
                                .font(.system(size: 8.5, weight: .bold))
                        } else if docType == "epub" {
                            Text("EPUB")
                                .font(.system(size: 8.5, weight: .bold))
                        } else {
                            Text("PDF")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(badgeColor, in: RoundedRectangle(cornerRadius: 2))
                    .padding(5)

                    // Top Right Page Count / Duration Badge
                    if document.totalPages > 0 {
                        HStack {
                            Spacer()
                            Text(docType == "video" || docType == "audio" ? MediaDocumentHelper.formatDuration(Double(document.totalPages)) : "\(document.totalPages)")
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
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let type = docType
        if type == "video" {
            return MediaDocumentHelper.generatePosterFrame(url: url)
        } else if type == "pdf" {
            guard let pdfDoc = PDFDocument(url: url),
                  let page = pdfDoc.page(at: 0) else {
                return nil
            }
            let thumbSize = NSSize(width: 148, height: 180)
            return page.thumbnail(of: thumbSize, for: .mediaBox)
        }
        return nil
    }
}
