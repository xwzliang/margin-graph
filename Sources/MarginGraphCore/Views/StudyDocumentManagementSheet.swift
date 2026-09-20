import SwiftUI
import AppKit

public struct StudyDocumentManagementSheet: View {
    public var documents: [Document]
    public var activeDocument: Document?
    public var onSwitchDocument: (Document) -> Void
    public var onDetachDocument: (Document) -> Void
    public var onAddDocument: () -> Void
    public var onDismiss: () -> Void

    public init(
        documents: [Document],
        activeDocument: Document?,
        onSwitchDocument: @escaping (Document) -> Void,
        onDetachDocument: @escaping (Document) -> Void,
        onAddDocument: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.documents = documents
        self.activeDocument = activeDocument
        self.onSwitchDocument = onSwitchDocument
        self.onDetachDocument = onDetachDocument
        self.onAddDocument = onAddDocument
        self.onDismiss = onDismiss
    }

    public var body: some View {
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
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.25))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(doc.totalPages) pages")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if activeDocument?.id == doc.id {
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
                }
                .frame(maxHeight: 220)
            }

            // Bottom Add Action
            HStack {
                Button {
                    onAddDocument()
                } label: {
                    Label("Add Document…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(white: 0.97))
    }
}
