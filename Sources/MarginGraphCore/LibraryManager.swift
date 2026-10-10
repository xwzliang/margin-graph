import Foundation
import Combine

public struct LibraryEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var path: String // path to backup file / folder, or "" for built-in Default Library
    public var workingFolderPath: String? // path to the sidecar working folder next to backup
    public var name: String // original filename or "Default Library"
    public var alias: String // short name / alias set by user
    public var isDefault: Bool // whether this library is default on startup
    public var dateAdded: Date
    public var lastOpened: Date?

    public init(
        id: UUID = UUID(),
        path: String,
        workingFolderPath: String? = nil,
        name: String,
        alias: String = "",
        isDefault: Bool = false,
        dateAdded: Date = Date(),
        lastOpened: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.workingFolderPath = workingFolderPath
        self.name = name
        self.alias = alias
        self.isDefault = isDefault
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
    }

    public var isBuiltIn: Bool {
        path.isEmpty || path == "default"
    }

    public var displayName: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isBuiltIn ? "Default Library" : name
    }
}

@MainActor
public final class LibraryManager: ObservableObject {
    public static let shared = LibraryManager()

    @Published public var libraries: [LibraryEntry] = []

    private let userDefaultsKey = "MarginGraph.LibraryEntries"
    private let legacyRecentKey = "MarginGraph.RecentDatabases"

    public init() {
        loadLibraries()
    }

    public func loadLibraries() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data),
           !entries.isEmpty {
            self.libraries = entries
            ensureBuiltInDefaultPresent()
            return
        }

        // Fresh or migrate from legacy recent database paths
        var initialList: [LibraryEntry] = []
        let builtIn = LibraryEntry(
            path: "",
            name: "Default Library",
            alias: "",
            isDefault: true,
            dateAdded: Date(),
            lastOpened: Date()
        )
        initialList.append(builtIn)

        let legacyPaths = UserDefaults.standard.stringArray(forKey: legacyRecentKey) ?? []
        for path in legacyPaths where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            initialList.append(LibraryEntry(
                path: path,
                workingFolderPath: nil,
                name: name,
                alias: "",
                isDefault: false,
                dateAdded: Date(),
                lastOpened: nil
            ))
        }

        self.libraries = initialList
        saveLibraries()
    }

    public func saveLibraries() {
        if let data = try? JSONEncoder().encode(libraries) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        // Also keep legacy recent key in sync for backwards compatibility
        let paths = libraries.filter { !$0.isBuiltIn }.map { $0.path }
        UserDefaults.standard.set(paths, forKey: legacyRecentKey)
    }

    private func ensureBuiltInDefaultPresent() {
        if !libraries.contains(where: { $0.isBuiltIn }) {
            libraries.insert(LibraryEntry(
                path: "",
                name: "Default Library",
                alias: "",
                isDefault: !libraries.contains(where: { $0.isDefault }),
                dateAdded: Date(),
                lastOpened: nil
            ), at: 0)
            saveLibraries()
        }
    }

    @discardableResult
    public func addOrUpdateLibrary(path: String, alias: String = "", setAsDefault: Bool = false) -> LibraryEntry {
        if let idx = libraries.firstIndex(where: { $0.path == path }) {
            if !alias.isEmpty {
                libraries[idx].alias = alias
            }
            if setAsDefault {
                setDefault(id: libraries[idx].id)
            } else {
                libraries[idx].lastOpened = Date()
                saveLibraries()
            }
            return libraries[idx]
        }

        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let entry = LibraryEntry(
            path: path,
            workingFolderPath: nil,
            name: name,
            alias: alias,
            isDefault: setAsDefault,
            dateAdded: Date(),
            lastOpened: Date()
        )
        if setAsDefault {
            for i in 0..<libraries.count {
                libraries[i].isDefault = false
            }
        }
        libraries.append(entry)
        saveLibraries()
        return entry
    }

    public func setAlias(id: UUID, alias: String) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        saveLibraries()
    }

    public func setDefault(id: UUID) {
        guard libraries.contains(where: { $0.id == id }) else { return }
        for i in 0..<libraries.count {
            libraries[i].isDefault = (libraries[i].id == id)
        }
        saveLibraries()
    }

    public func deleteLibrary(id: UUID) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        let entry = libraries[idx]
        guard !entry.isBuiltIn else { return } // Cannot delete built-in library

        let wasDefault = entry.isDefault
        libraries.remove(at: idx)

        if wasDefault {
            // Restore built-in library as default
            if let builtInIdx = libraries.firstIndex(where: { $0.isBuiltIn }) {
                libraries[builtInIdx].isDefault = true
            } else if !libraries.isEmpty {
                libraries[0].isDefault = true
            }
        }
        saveLibraries()
    }

    public func updateWorkingFolderPath(id: UUID, workingFolderPath: String) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].workingFolderPath = workingFolderPath
        saveLibraries()
    }

    public func touchLastOpened(id: UUID) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].lastOpened = Date()
        saveLibraries()
    }

    public func touchLastOpened(path: String) {
        guard let idx = libraries.firstIndex(where: { $0.path == path }) else { return }
        libraries[idx].lastOpened = Date()
        saveLibraries()
    }

    public var defaultLibrary: LibraryEntry? {
        libraries.first(where: { $0.isDefault }) ?? libraries.first(where: { $0.isBuiltIn })
    }

    public func entry(forPath path: String) -> LibraryEntry? {
        libraries.first(where: { $0.path == path })
    }

    public func entry(forId id: UUID) -> LibraryEntry? {
        libraries.first(where: { $0.id == id })
    }

    /// Resolves the sidecar working folder location next to a backup file/package.
    /// Uses the alias if present, otherwise uses the backup's filename without extension.
    public static func resolveSidecarFolderURL(for backupURL: URL, alias: String?) -> URL {
        let parentDir = backupURL.deletingLastPathComponent()
        let trimmedAlias = (alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName: String
        if !trimmedAlias.isEmpty {
            folderName = sanitizeFolderName(trimmedAlias)
        } else {
            folderName = backupURL.deletingPathExtension().lastPathComponent
        }
        return parentDir.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func sanitizeFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Library" : trimmed
    }
}
