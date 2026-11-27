import Foundation
import PDFKit

public enum PDFDocumentReplacement {
    static let directoryName = ".MarginGraphPDFReplacements"

    /// Keep the catalog identity because notes, bookmarks and notebook attachments use it.
    public static func replace(
        _ document: Document, with source: URL, in database: Database, managedDirectory: URL
    ) throws -> (document: Document, manager: PDFDocumentManager) {
        let oldURL = URL(fileURLWithPath: document.filePath)
        guard let original = PDFDocument(url: oldURL), !original.isLocked, original.pageCount > 0 else {
            throw ReplacementError.unreadableOriginal
        }

        // Discovery skips this directory, including copies staged before a catalog commit.
        let folder = managedDirectory.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = false
        defer {
            if !saved { try? fm.removeItem(at: folder) }
        }

        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: copy)
        guard let replacement = try? PDFDocumentManager(url: copy, md5: document.md5),
              !replacement.document.isLocked, replacement.pageCount > 0 else {
            throw ReplacementError.unreadableReplacement
        }
        guard replacement.pageCount == original.pageCount else {
            throw ReplacementError.pageCount(expected: original.pageCount, actual: replacement.pageCount)
        }
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index), let after = replacement.page(at: index),
                  before.rotation == after.rotation, before.bounds(for: .cropBox) == after.bounds(for: .cropBox) else {
                throw ReplacementError.pageLayout(page: index + 1)
            }
        }

        try document.md5.write(to: copy.appendingPathExtension("md5"), atomically: true, encoding: .utf8)
        let updated = try database.transaction {
            guard var current = try database.getDocument(id: document.id),
                  current.md5 == document.md5, current.filePath == document.filePath else {
                throw ReplacementError.documentChanged
            }
            try database.recordRetiredDocumentPath(current.filePath, md5: current.md5)
            try database.withStatement("UPDATE documents SET file_path = ?, total_pages = ? WHERE id = ?") { statement in
                database.bind(copy.path, to: 1, in: statement)
                database.bind(replacement.pageCount, to: 2, in: statement)
                database.bind(current.id.uuidString, to: 3, in: statement)
                try database.requireDone(statement)
            }
            current.filePath = copy.path
            current.totalPages = replacement.pageCount
            return current
        }
        saved = true
        return (updated, replacement)
    }

    private enum ReplacementError: LocalizedError {
        case unreadableOriginal
        case unreadableReplacement
        case pageCount(expected: Int, actual: Int)
        case pageLayout(page: Int)
        case documentChanged

        var errorDescription: String? {
            switch self {
            case .unreadableOriginal:
                "The current PDF could not be read."
            case .unreadableReplacement:
                "The selected file is not a readable, unlocked PDF."
            case .pageCount(let expected, let actual):
                "The current PDF has \(expected) pages. The selected PDF has \(actual). Choose a PDF with the same pages so your notes stay aligned."
            case .pageLayout(let page):
                "Page \(page) has a different size, crop, or rotation. Choose a PDF with the same page layout so your highlights stay aligned."
            case .documentChanged:
                "The current document changed while the replacement was being prepared. Reopen it and try again."
            }
        }
    }
}
