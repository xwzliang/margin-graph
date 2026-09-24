import Foundation
import AppKit
import PDFKit
import CryptoKit

public struct ConvertedEPUBResult: Sendable {
    public let originalURL: URL
    public let pdfURL: URL
    public let md5: String
    public let title: String
    public let author: String
    public let pageCount: Int

    public init(
        originalURL: URL,
        pdfURL: URL,
        md5: String,
        title: String,
        author: String,
        pageCount: Int
    ) {
        self.originalURL = originalURL
        self.pdfURL = pdfURL
        self.md5 = md5
        self.title = title
        self.author = author
        self.pageCount = pageCount
    }
}

public enum EPUBConverterError: LocalizedError {
    case fileNotFound(String)
    case conversionFailed(String)
    case noConverterAvailable

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "EPUB file not found at: \(path)"
        case .conversionFailed(let message):
            return "Failed to convert EPUB to PDF: \(message)"
        case .noConverterAvailable:
            return "No converter (PyMuPDF or ebook-convert) available on system."
        }
    }
}

public final class EPUBConverter: Sendable {

    public static func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/homebrew/opt/python/libexec/bin/\(name)"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty, FileManager.default.isExecutableFile(atPath: str) {
                    return URL(fileURLWithPath: str)
                }
            }
        }
        return nil
    }

    public static func documentsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let docs = appSupport.appendingPathComponent("MarginGraph/Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    public static func ensureConvertedPDF(for epubURL: URL) throws -> ConvertedEPUBResult {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            throw EPUBConverterError.fileNotFound(epubURL.path)
        }

        let md5 = MediaDocumentHelper.computeFileMD5(url: epubURL)
        let docsDir = documentsDirectory()
        let targetPDF = docsDir.appendingPathComponent("\(md5).pdf")

        // If converted PDF already exists and is non-empty, use it immediately
        if FileManager.default.fileExists(atPath: targetPDF.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: targetPDF.path),
           let size = attrs[.size] as? Int64, size > 1024,
           let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 {
            let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
            let fallbackTitle = epubURL.deletingPathExtension().lastPathComponent
            let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle
            return ConvertedEPUBResult(
                originalURL: epubURL,
                pdfURL: targetPDF,
                md5: md5,
                title: title,
                author: authorAttr ?? "",
                pageCount: doc.pageCount
            )
        }

        // Perform conversion
        var conversionError: String? = nil

        // Method 1: PyMuPDF (fast, preserves Table of Contents & vector layout)
        if let pythonURL = findExecutable(named: "python3") {
            do {
                try convertWithPyMuPDF(pythonURL: pythonURL, epubPath: epubURL.path, pdfPath: targetPDF.path)
            } catch {
                conversionError = error.localizedDescription
            }
        }

        // Method 2: Fallback to ebook-convert if target PDF wasn't created or failed
        let pdfCreated = FileManager.default.fileExists(atPath: targetPDF.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: targetPDF.path)[.size] as? Int64) ?? 0) > 1024

        if !pdfCreated {
            if let calibreURL = findExecutable(named: "ebook-convert") {
                do {
                    try convertWithCalibre(calibreURL: calibreURL, epubPath: epubURL.path, pdfPath: targetPDF.path)
                } catch {
                    conversionError = (conversionError ?? "") + " | " + error.localizedDescription
                }
            }
        }

        guard FileManager.default.fileExists(atPath: targetPDF.path),
              let doc = PDFDocument(url: targetPDF), doc.pageCount > 0 else {
            throw EPUBConverterError.conversionFailed(conversionError ?? "Unknown conversion failure")
        }

        // Write MD5 sidecars
        let sidecarPDF = targetPDF.appendingPathExtension("md5")
        try? md5.write(to: sidecarPDF, atomically: true, encoding: .utf8)
        let sidecarEPUB = epubURL.appendingPathExtension("md5")
        try? md5.write(to: sidecarEPUB, atomically: true, encoding: .utf8)

        let titleAttr = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let authorAttr = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let fallbackTitle = epubURL.deletingPathExtension().lastPathComponent
        let title = (titleAttr?.isEmpty == false ? titleAttr : nil) ?? fallbackTitle

        return ConvertedEPUBResult(
            originalURL: epubURL,
            pdfURL: targetPDF,
            md5: md5,
            title: title,
            author: authorAttr ?? "",
            pageCount: doc.pageCount
        )
    }

    private static func convertWithPyMuPDF(pythonURL: URL, epubPath: String, pdfPath: String) throws {
        let script = """
import pymupdf, sys
epub_path = sys.argv[1]
pdf_path = sys.argv[2]
doc = pymupdf.open(epub_path)
pdf_bytes = doc.convert_to_pdf()
pdf_doc = pymupdf.open('pdf', pdf_bytes)
toc = doc.get_toc()
if toc:
    pdf_doc.set_toc(toc)
meta = doc.metadata
if meta:
    pdf_doc.set_metadata(meta)
pdf_doc.save(pdf_path)
"""
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, epubPath, pdfPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: data, encoding: .utf8) ?? "PyMuPDF exited with code \(process.terminationStatus)"
            throw NSError(domain: "EPUBConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }

    private static func convertWithCalibre(calibreURL: URL, epubPath: String, pdfPath: String) throws {
        let process = Process()
        process.executableURL = calibreURL
        process.arguments = [
            epubPath,
            pdfPath,
            "--paper-size", "letter",
            "--pdf-page-numbers",
            "--pdf-footer-template", "<p style=\"text-align:center; font-size:9pt; color:#666;\">_PAGENUM_</p>",
            "--margin-top", "36",
            "--margin-bottom", "36",
            "--margin-left", "48",
            "--margin-right", "48"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: data, encoding: .utf8) ?? "ebook-convert exited with code \(process.terminationStatus)"
            throw NSError(domain: "EPUBConverter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
    }
}
