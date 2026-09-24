import SwiftUI
import AppKit

public struct DocumentTabBarView: View {
    public var documents: [Document]
    public var activeDocument: Document?
    public var onSelectDocument: (Document) -> Void
    public var onCloseDocument: ((Document) -> Void)?
    public var onAddDocument: (() -> Void)?
    public var onManageDocuments: (() -> Void)?

    @State private var hoveredDocID: UUID? = nil

    public init(
        documents: [Document],
        activeDocument: Document?,
        onSelectDocument: @escaping (Document) -> Void,
        onCloseDocument: ((Document) -> Void)? = nil,
        onAddDocument: (() -> Void)? = nil,
        onManageDocuments: (() -> Void)? = nil
    ) {
        self.documents = documents
        self.activeDocument = activeDocument
        self.onSelectDocument = onSelectDocument
        self.onCloseDocument = onCloseDocument
        self.onAddDocument = onAddDocument
        self.onManageDocuments = onManageDocuments
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Horizontal scrollable tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(documents, id: \.id) { doc in
                        tabItem(for: doc)
                    }

                    // Add Document (+) button
                    if let onAddDocument {
                        Button(action: onAddDocument) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 26, height: 26)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 4)
                        .help("Add Document to Notebook…")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            Spacer(minLength: 8)

            // Trailing "Manage" button
            if let onManageDocuments {
                Button(action: onManageDocuments) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5))
                        Text("Manage")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Manage Notebook Documents")
            }
        }
        .frame(height: 34)
        .background(Color(white: 0.93))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color(white: 0.82)),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func tabItem(for doc: Document) -> some View {
        let isActive = (activeDocument?.id == doc.id || activeDocument?.md5 == doc.md5)
        let isHovered = (hoveredDocID == doc.id)
        let docType = doc.documentType.isEmpty ? MediaDocumentHelper.documentType(for: URL(fileURLWithPath: doc.filePath)) : doc.documentType

        HStack(spacing: 6) {
            // Icon
            Group {
                if docType == "video" {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                } else if docType == "audio" {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.12, green: 0.60, blue: 0.42))
                } else if docType == "epub" {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.25))
                }
            }

            // Title
            Text(doc.title)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: 170, alignment: .leading)

            // Close (x) button
            if documents.count > 1, let onCloseDocument {
                Button {
                    onCloseDocument(doc)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle((isHovered || isActive) ? Color.secondary : Color.clear)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(isHovered ? Color.secondary.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Close Document Tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 5,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 5
                )
                .fill(isActive ? Color.white : (isHovered ? Color(white: 0.88) : Color.clear))

                // Active tab top indicator accent line
                if isActive {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 5,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 5
                    )
                    .fill(Color.accentColor)
                    .frame(height: 2)
                }
            }
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 5,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 5
            )
            .stroke(isActive ? Color(white: 0.82) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectDocument(doc)
        }
        .onHover { inside in
            if inside {
                hoveredDocID = doc.id
            } else if hoveredDocID == doc.id {
                hoveredDocID = nil
            }
        }
    }
}
