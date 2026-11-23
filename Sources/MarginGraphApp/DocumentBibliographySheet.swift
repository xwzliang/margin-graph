import SwiftUI

struct DocumentBibliographySheet: View {
    let load: () async throws -> [DocumentBibliographyEntry]

    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<[DocumentBibliographyEntry], Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Linked BibTeX").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let result {
                switch result {
                case .success(let entries) where entries.isEmpty:
                    ContentUnavailableView("No Linked BibTeX Entry", systemImage: "books.vertical")
                case .success(let entries):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(entries) { record in
                                if record.id != entries.first?.id { Divider() }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.entry.title.isEmpty ? record.entry.key : record.entry.title)
                                        .font(.title3.weight(.semibold))
                                    Text(record.bibliography.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help(record.bibliography.path)
                                    Text(record.entry.source)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(.top, 5)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .failure(let error):
                    ContentUnavailableView("Couldn’t Load BibTeX", systemImage: "exclamationmark.circle",
                                           description: Text(error.localizedDescription))
                }
            } else {
                ProgressView("Loading BibTeX…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 510, height: 360)
        .task {
            do {
                let entries = try await load()
                if !Task.isCancelled { result = .success(entries) }
            } catch {
                if !Task.isCancelled { result = .failure(error) }
            }
        }
    }
}
