import Foundation
import CryptoKit

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
    public func saveImage(_ data: Data, format: String = "png") throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let filename = ext.isEmpty ? digest : "\(digest).\(ext)"
        let url = directoryURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return filename
    }

    public func loadImage(hash: String) -> Data? {
        try? Data(contentsOf: imageURL(hash: hash))
    }

    public func imageURL(hash: String) -> URL {
        directoryURL.appendingPathComponent(hash)
    }
}
