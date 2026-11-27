import Foundation
import PDFKit
import SQLite3

public enum PDFDocumentReplacement {
    static let directoryName = ".MarginGraphPDFReplacements"

    public static func previousURL(for document: Document, in database: Database) throws -> URL? {
        try database.withStatement("SELECT previous_path FROM pdf_replacement_history WHERE replacement_path = ?") { statement in
            database.bind(document.filePath, to: 1, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return database.text(statement, 0).map { URL(fileURLWithPath: $0) }
            case SQLITE_DONE: return nil
            default: throw DatabaseError.sqlite("Unable to read PDF replacement history.")
            }
        }
    }

    /// Keep the catalog identity because notes, bookmarks and notebook attachments use it.
    public static func replace(
        _ document: Document, with source: URL, in database: Database, managedDirectory: URL
    ) throws -> (document: Document, manager: PDFDocumentManager) {
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
        let replacement = try loadCompatiblePDF(copy, for: document, onReadFailure: .unreadableReplacement)
        try document.md5.write(to: copy.appendingPathExtension("md5"), atomically: true, encoding: .utf8)
        let updated = try database.transaction {
            let current = try currentDocument(matching: document, in: database)
            try database.withStatement("INSERT INTO pdf_replacement_history(replacement_path,previous_path) VALUES(?,?)") { statement in
                database.bind(copy.path, to: 1, in: statement)
                database.bind(current.filePath, to: 2, in: statement)
                try database.requireDone(statement)
            }
            return try updatePDF(current, to: replacement, in: database)
        }
        saved = true
        return (updated, replacement)
    }

    public static func restore(
        _ document: Document, to previous: URL, in database: Database
    ) throws -> (document: Document, manager: PDFDocumentManager) {
        guard try previousURL(for: document, in: database) == previous else {
            throw ReplacementError.documentChanged
        }
        let restored = try loadCompatiblePDF(previous, for: document, onReadFailure: .unreadablePreviousPDF)
        let updated = try database.transaction {
            let current = try currentDocument(matching: document, in: database)
            guard try previousURL(for: current, in: database) == previous else {
                throw ReplacementError.documentChanged
            }
            guard try database.getDocumentByPath(filePath: previous.path) == nil else {
                throw ReplacementError.previousPDFInUse
            }
            try database.withStatement("DELETE FROM pdf_replacement_history WHERE replacement_path = ?") { statement in
                database.bind(current.filePath, to: 1, in: statement)
                try database.requireDone(statement)
            }
            return try updatePDF(current, to: restored, in: database)
        }
        return (updated, restored)
    }

    private static func loadCompatiblePDF(
        _ url: URL, for document: Document, onReadFailure: ReplacementError
    ) throws -> PDFDocumentManager {
        let originalURL = URL(fileURLWithPath: document.filePath)
        guard let original = PDFDocument(url: originalURL), !original.isLocked, original.pageCount > 0 else {
            throw ReplacementError.unreadableOriginal
        }
        guard let candidate = try? PDFDocumentManager(url: url, md5: document.md5),
              candidate.url == url, !candidate.document.isLocked, candidate.pageCount > 0 else {
            throw onReadFailure
        }
        guard candidate.pageCount == original.pageCount else {
            throw ReplacementError.pageCount(expected: original.pageCount, actual: candidate.pageCount)
        }
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index), let after = candidate.page(at: index),
                  before.rotation == after.rotation, before.bounds(for: .cropBox) == after.bounds(for: .cropBox) else {
                throw ReplacementError.pageLayout(page: index + 1)
            }
        }
        return candidate
    }

    private static func currentDocument(matching document: Document, in database: Database) throws -> Document {
        guard let current = try database.getDocument(id: document.id),
              current.md5 == document.md5, current.filePath == document.filePath else {
            throw ReplacementError.documentChanged
        }
        return current
    }

    private static func updatePDF(
        _ document: Document, to pdf: PDFDocumentManager, in database: Database
    ) throws -> Document {
        try database.recordRetiredDocumentPath(document.filePath, md5: document.md5)
        try database.clearRetiredDocumentPath(pdf.url.path)
        try database.withStatement("UPDATE documents SET file_path = ?, total_pages = ? WHERE id = ?") { statement in
            database.bind(pdf.url.path, to: 1, in: statement)
            database.bind(pdf.pageCount, to: 2, in: statement)
            database.bind(document.id.uuidString, to: 3, in: statement)
            try database.requireDone(statement)
        }
        var updated = document
        updated.filePath = pdf.url.path
        updated.totalPages = pdf.pageCount
        return updated
    }

    private enum ReplacementError: LocalizedError {
        case unreadableOriginal
        case unreadableReplacement
        case unreadablePreviousPDF
        case pageCount(expected: Int, actual: Int)
        case pageLayout(page: Int)
        case documentChanged
        case previousPDFInUse

        var errorDescription: String? {
            switch self {
            case .unreadableOriginal:
                "The current PDF could not be read."
            case .unreadableReplacement:
                "The selected file is not a readable, unlocked PDF."
            case .unreadablePreviousPDF:
                "The previous PDF is no longer available or could not be read."
            case .pageCount(let expected, let actual):
                "The current PDF has \(expected) pages. The selected PDF has \(actual). Choose a PDF with the same pages so your notes stay aligned."
            case .pageLayout(let page):
                "Page \(page) has a different size, crop, or rotation. Choose a PDF with the same page layout so your highlights stay aligned."
            case .documentChanged:
                "The current document changed while the PDF update was being prepared. Reopen it and try again."
            case .previousPDFInUse:
                "The previous PDF is already openable as a different document in this library."
            }
        }
    }
}

extension Database {
    func createPDFReplacementHistory() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS pdf_replacement_history(
                replacement_path TEXT PRIMARY KEY NOT NULL, previous_path TEXT NOT NULL
            );
            """)
        // Older replacements recorded a retired path without an explicit link to its successor.
        // Recover a predecessor only when the active file is a managed replacement and the match is unique.
        try withStatement("""
            INSERT OR IGNORE INTO pdf_replacement_history(replacement_path,previous_path)
            SELECT documents.file_path, legacy.file_path
            FROM documents
            JOIN (
                SELECT md5, MIN(file_path) AS file_path
                FROM retired_import_documents
                WHERE lower(file_path) LIKE '%.pdf'
                GROUP BY md5 HAVING COUNT(*) = 1
            ) AS legacy ON legacy.md5 = documents.md5
            WHERE documents.document_type = 'pdf'
                AND instr(documents.file_path, ?) > 0
                AND NOT EXISTS (SELECT 1 FROM documents AS active WHERE active.file_path = legacy.file_path)
            """) { statement in
            bind("/\(PDFDocumentReplacement.directoryName)/", to: 1, in: statement)
            try requireDone(statement)
        }
    }
}
