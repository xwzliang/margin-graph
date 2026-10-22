import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

import AppKit
import SQLite3

public final class MediaStorage: @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

    public var fallbackDirectories: [URL] = []
    public var fallbackDatabaseURL: URL?
    public var mediaBlobResolver: (@Sendable (String) -> Data?)?

    private let displayImageCache = NSCache<NSString, NSImage>()
    private let memoryCache = NSCache<NSString, NSData>()
    private let dbQueue = DispatchQueue(label: "com.margingraph.mediastorage.db")
    private var cachedDbPointer: OpaquePointer?
    private var cachedDbURL: URL?

    public static func extractImageData(from rawData: Data) -> Data? {
        if isImageBytes(rawData) {
            return rawData
        }
        if rawData.starts(with: [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) {
            if let plist = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil) as? [String: Any],
               let objects = plist["$objects"] as? [Any] {
                for obj in objects {
                    if let d = obj as? Data, isImageBytes(d) {
                        return d
                    }
                }
            }
        }
        return nil
    }

    private static func isImageBytes(_ data: Data) -> Bool {
        if data.count < 8 { return false }
        // PNG
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        // JPEG
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        // GIF
        if data.starts(with: [0x47, 0x49, 0x46]) { return true }
        // TIFF (Intel / Motorola)
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // HEIC / AVIF
        if data.count >= 12 && data[4...7] == Data([0x66, 0x74, 0x79, 0x70]) { return true }
        return false
    }

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = base
                .appendingPathComponent("MarginGraph", isDirectory: true)
                .appendingPathComponent("media", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    @discardableResult
    public func saveImage(_ data: Data, format: String = "heic", quality: Double = 0.82) throws -> String {
        let requestedExt = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // If HEIC is requested and input data can be converted, recompress to hardware HEIC
        if requestedExt == "heic" {
            if let heicData = convertToHEIC(data: data, quality: quality) {
                return try writeData(heicData, ext: "heic")
            }
        }

        // If direct save or fallback
        let ext = requestedExt.isEmpty ? "png" : requestedExt
        return try writeData(data, ext: ext)
    }

    @discardableResult
    public func saveCGImage(_ image: CGImage, format: String = "heic", quality: Double = 0.82) throws -> String {
        let requestedExt = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let utType = (requestedExt == "heic" ? UTType.heic : (requestedExt == "jpg" || requestedExt == "jpeg" ? UTType.jpeg : UTType.png)).identifier

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, utType as CFString, 1, nil) else {
            // Fallback to PNG
            guard let pngDest = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "MediaStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
            }
            CGImageDestinationAddImage(pngDest, image, nil)
            CGImageDestinationFinalize(pngDest)
            return try writeData(mutableData as Data, ext: "png")
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if CGImageDestinationFinalize(destination) {
            return try writeData(mutableData as Data, ext: requestedExt)
        } else {
            throw NSError(domain: "MediaStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image destination"])
        }
    }

    @discardableResult
    public func generateVideoPosterFrame(url: URL, timestampSeconds: Double, quality: Double = 0.82) throws -> String {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)

        let targetTime = CMTime(seconds: max(0, timestampSeconds), preferredTimescale: 600)
        var actualTime = CMTime.zero
        let cgImage = try generator.copyCGImage(at: targetTime, actualTime: &actualTime)
        return try saveCGImage(cgImage, format: "heic", quality: quality)
    }

    /// Keep the decoded display representation across viewport redraws and card culling.
    /// Hashes are content identities; failed loads are deliberately not cached.
    @MainActor
    public func displayImage(hash: String) -> NSImage? {
        if let image = displayImageCache.object(forKey: hash as NSString) { return image }
        guard let data = loadImage(hash: hash), let image = NSImage(data: data) else { return nil }
        displayImageCache.countLimit = 256
        displayImageCache.setObject(image, forKey: hash as NSString)
        return image
    }

    public func loadImage(hash: String) -> Data? {
        let key = hash as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached as Data
        }

        let url = imageURL(hash: hash)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            if let img = Self.extractImageData(from: data) ?? (NSImage(data: data) != nil ? data : nil) {
                memoryCache.setObject(img as NSData, forKey: key)
                return img
            }
        }
        for fallback in fallbackDirectories {
            let direct = fallback.appendingPathComponent(hash)
            if fileManager.fileExists(atPath: direct.path), let data = try? Data(contentsOf: direct), !data.isEmpty {
                if let img = Self.extractImageData(from: data) ?? (NSImage(data: data) != nil ? data : nil) {
                    memoryCache.setObject(img as NSData, forKey: key)
                    return img
                }
            }
            if !hash.contains(".") {
                for ext in ["heic", "png", "jpg", "jpeg", "webp"] {
                    let candidate = fallback.appendingPathComponent("\(hash).\(ext)")
                    if fileManager.fileExists(atPath: candidate.path), let data = try? Data(contentsOf: candidate), !data.isEmpty {
                        if let img = Self.extractImageData(from: data) ?? (NSImage(data: data) != nil ? data : nil) {
                            memoryCache.setObject(img as NSData, forKey: key)
                            return img
                        }
                    }
                }
            }
        }

        if let resolver = mediaBlobResolver, let data = resolver(hash) {
            if let img = Self.extractImageData(from: data) ?? (NSImage(data: data) != nil ? data : nil) {
                memoryCache.setObject(img as NSData, forKey: key)
                return img
            }
        }

        if let dbURL = fallbackDatabaseURL {
            if let data = loadMediaBlobFromDatabase(dbURL: dbURL, md5: hash) {
                memoryCache.setObject(data as NSData, forKey: key)
                return data
            }
        }

        return nil
    }

    private func loadMediaBlobFromDatabase(dbURL: URL, md5: String) -> Data? {
        dbQueue.sync {
            if cachedDbURL != dbURL {
                if let cachedDbPointer {
                    sqlite3_close(cachedDbPointer)
                    self.cachedDbPointer = nil
                }
                var db: OpaquePointer?
                let uri = "file:\(dbURL.path)?immutable=1"
                if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                    self.cachedDbPointer = db
                    self.cachedDbURL = dbURL
                }
            }
            guard let db = cachedDbPointer else { return nil }
            var stmt: OpaquePointer?
            let query = "SELECT ZDATA FROM ZMEDIA WHERE ZMD5=? LIMIT 1"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, md5, -1, transient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let bytes = sqlite3_column_blob(stmt, 0) {
                    let count = Int(sqlite3_column_bytes(stmt, 0))
                    if count > 0 {
                        let rawData = Data(bytes: bytes, count: count)
                        return Self.extractImageData(from: rawData) ?? (NSImage(data: rawData) != nil ? rawData : nil)
                    }
                }
            }
            return nil
        }
    }

    public func clearFallbackDatabase() {
        dbQueue.sync {
            if let cachedDbPointer {
                sqlite3_close(cachedDbPointer)
                self.cachedDbPointer = nil
            }
            self.cachedDbURL = nil
            self.fallbackDatabaseURL = nil
        }
    }

    deinit {
        if let cachedDbPointer {
            sqlite3_close(cachedDbPointer)
        }
    }

    public func imageURL(hash: String) -> URL {
        let directURL = directoryURL.appendingPathComponent(hash)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        // Try checking common extensions if hash has none
        if !hash.contains(".") {
            for ext in ["heic", "png", "jpg", "jpeg", "webp"] {
                let candidate = directoryURL.appendingPathComponent("\(hash).\(ext)")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // Try checking fallback directories (e.g. MarginNotes.sqlite.files in external backup)
        for fallback in fallbackDirectories {
            let candidateDirect = fallback.appendingPathComponent(hash)
            if fileManager.fileExists(atPath: candidateDirect.path) {
                return candidateDirect
            }
            if !hash.contains(".") {
                for ext in ["heic", "png", "jpg", "jpeg", "webp"] {
                    let candidate = fallback.appendingPathComponent("\(hash).\(ext)")
                    if fileManager.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        return directURL
    }

    private func writeData(_ data: Data, ext: String) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = ext.isEmpty ? digest : "\(digest).\(ext)"
        let fileURL = directoryURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }
        return filename
    }

    private func convertToHEIC(data: Data, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return mutableData as Data
    }
}
