import SwiftUI
import AppKit
import MarginGraphCore

struct LibraryManagementView: View {
    @ObservedObject var libraryManager: LibraryManager = LibraryManager.shared
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingAliasID: UUID? = nil
    @State private var aliasDraft: String = ""
    @State private var hoveredID: String? = nil

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                        Text("Manage Libraries")
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text("Give short aliases, choose your startup default library, and manage external backups.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    model.openMarginNoteBackupPicker { selectedURL in
                        _ = libraryManager.addOrUpdateLibrary(path: selectedURL.path)
                        Task { @MainActor in
                            await model.openMarginNoteBackup(at: selectedURL)
                        }
                    }
                } label: {
                    Label("Add Library…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Library List
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(libraryManager.libraries) { entry in
                        let isCurrent = entry.isBuiltIn
                            ? !model.isExternalDatabase
                            : (model.isExternalDatabase && model.activeDatabaseURL?.path == entry.path)

                        libraryRow(entry: entry, isCurrent: isCurrent)
                    }
                }
                .padding(16)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Footer
            HStack {
                Text("\(libraryManager.libraries.count) \(libraryManager.libraries.count == 1 ? "library" : "libraries") registered")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 620, height: 460)
    }

    @ViewBuilder
    private func libraryRow(entry: LibraryEntry, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: entry.isBuiltIn ? "house.fill" : "externaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .padding(.top, 2)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Name / Alias Row
                HStack(spacing: 8) {
                    if editingAliasID == entry.id {
                        TextField("Short alias name", text: $aliasDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit {
                                commitAlias(entry: entry)
                            }
                        Button {
                            commitAlias(entry: entry)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingAliasID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(entry.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if !entry.alias.isEmpty {
                            Text("(\(entry.name))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            aliasDraft = entry.alias
                            editingAliasID = entry.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Set or edit short alias name")
                    }

                    Spacer()

                    // Badges
                    if isCurrent {
                        Text("ACTIVE")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    }

                    if entry.isDefault {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("DEFAULT")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                    }
                }

                // Subtitle: Path or Working folder
                if entry.isBuiltIn {
                    Text("Built-in application storage (~/Library/Application Support/MarginGraph)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let working = entry.workingFolderPath, !working.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text("Working folder: \(working)")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                }

                // Actions row
                HStack(spacing: 8) {
                    if !entry.isDefault {
                        Button {
                            libraryManager.setDefault(id: entry.id)
                        } label: {
                            Label("Set as Default", systemImage: "star")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !isCurrent {
                        Button {
                            switchToLibrary(entry: entry)
                        } label: {
                            Label("Open Library", systemImage: "arrow.right.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if !entry.isBuiltIn && FileManager.default.fileExists(atPath: entry.path) {
                        Button {
                            NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Show in Finder")
                    }

                    if !entry.isBuiltIn {
                        Button(role: .destructive) {
                            deleteLibrary(entry: entry)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Remove library from list")
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
    }

    private func commitAlias(entry: LibraryEntry) {
        let newAlias = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        libraryManager.setAlias(id: entry.id, alias: newAlias)
        editingAliasID = nil

        // If this is currently active, update display name
        if model.activeDatabaseURL?.path == entry.path {
            model.activeDatabaseName = entry.displayName
        }

        // If an external library has a sidecar working folder, rename the folder if appropriate
        if !entry.isBuiltIn {
            let backupURL = URL(fileURLWithPath: entry.path)
            let oldWorking = entry.workingFolderPath.map { URL(fileURLWithPath: $0) }
                ?? LibraryManager.resolveSidecarFolderURL(for: backupURL, alias: entry.alias)
            let newWorking = LibraryManager.resolveSidecarFolderURL(for: backupURL, alias: newAlias)

            if oldWorking != newWorking && FileManager.default.fileExists(atPath: oldWorking.path) && !FileManager.default.fileExists(atPath: newWorking.path) {
                try? FileManager.default.moveItem(at: oldWorking, to: newWorking)
                libraryManager.updateWorkingFolderPath(id: entry.id, workingFolderPath: newWorking.path)
            }
        }
    }

    private func switchToLibrary(entry: LibraryEntry) {
        if entry.isBuiltIn {
            model.switchToDefaultDatabase()
        } else {
            Task { @MainActor in
                await model.openMarginNoteBackup(at: URL(fileURLWithPath: entry.path))
            }
        }
    }

    private func deleteLibrary(entry: LibraryEntry) {
        let wasActive = (model.activeDatabaseURL?.path == entry.path)
        libraryManager.deleteLibrary(id: entry.id)
        if wasActive {
            model.switchToDefaultDatabase()
        }
    }
}
