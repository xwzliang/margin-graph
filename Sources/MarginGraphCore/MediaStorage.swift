import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public final class MediaStorage: @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

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

    public func loadImage(hash: String) -> Data? {
        let url = imageURL(hash: hash)
        return try? Data(contentsOf: url)
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
