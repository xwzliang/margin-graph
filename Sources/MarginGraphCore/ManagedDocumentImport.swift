import Foundation

/// Imports own their working bytes. Source files and their sidecars are read-only.
public enum ManagedDocumentImport {
    public static func copySource(_ source: URL, into directory: URL) throws -> URL {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        if source.path.hasPrefix(directory.path + "/") { return source }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            for sidecar in [source.appendingPathExtension("md5"), source.deletingPathExtension().appendingPathExtension("md5")] {
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.copyItem(at: sidecar, to: copy.appendingPathExtension("md5"))
                    break
                }
            }
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
