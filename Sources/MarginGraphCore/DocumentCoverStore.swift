import AppKit
import CryptoKit
import Foundation

/// Durable previews are read without touching the original file or its container.
/// Source paths are hashed so different libraries cannot overwrite one another.
enum DocumentCoverStore {
    static func cacheURL(path: String, variant: String, directory: URL? = nil) -> URL {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarginGraph/CoverThumbnails", isDirectory: true)
        let digest = SHA256.hash(data: Data((variant + "\n" + path).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest).appendingPathExtension("png")
    }

    static func load(path: String, variant: String, directory: URL? = nil) -> NSImage? {
        NSImage(contentsOf: cacheURL(path: path, variant: variant, directory: directory))
    }

    static func save(_ image: NSImage, path: String, variant: String, directory: URL? = nil) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let destination = cacheURL(path: path, variant: variant, directory: directory)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
        } catch {
            // A cache failure must never prevent displaying a generated cover.
        }
    }
}
