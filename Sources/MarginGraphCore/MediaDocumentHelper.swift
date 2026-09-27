import Foundation
import CryptoKit
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

public enum MediaDocumentHelper {
    public static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
    public static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "caf"]
    public static let supportedEBookExtensions: Set<String> = [
        "epub",
        "cbz", "cbr", "cbt",
        "fb2", "zfb2",
        "txt", "text",
        "md", "markdown",
        "rtf", "rtfd",
        "html", "htm", "xhtml", "webarchive",
        "mobi", "prc", "azw", "azw3", "kf8", "pdb",
        "docx", "doc", "odt",
        "chm",
        "djvu", "djv",
        "tex", "latex",
        "adoc", "asciidoc",
        "org",
        "rst"
    ]
    public static let supportedDocumentExtensions: Set<String> = Set([
        "pdf", "marginpkg", "marginnotes", "sqlite"
    ]).union(supportedEBookExtensions)

    public static func documentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) {
            return "video"
        } else if supportedAudioExtensions.contains(ext) {
            return "audio"
        } else if ext == "cbz" || ext == "cbr" || ext == "cbt" {
            return "comic"
        } else if ext == "fb2" || ext == "zfb2" {
            return "fb2"
        } else if ext == "mobi" || ext == "prc" {
            return "mobi"
        } else if ext == "azw" || ext == "azw3" || ext == "kf8" {
            return "azw3"
        } else if ext == "pdb" {
            return "pdb"
        } else if ext == "docx" || ext == "doc" {
            return "docx"
        } else if ext == "odt" {
            return "odt"
        } else if ext == "chm" {
            return "chm"
        } else if ext == "djvu" || ext == "djv" {
            return "djvu"
        } else if ext == "tex" || ext == "latex" {
            return "latex"
        } else if ext == "adoc" || ext == "asciidoc" {
            return "asciidoc"
        } else if ext == "org" {
            return "org"
        } else if ext == "rst" {
            return "rst"
        } else if ext == "txt" || ext == "text" {
            return "text"
        } else if ext == "md" || ext == "markdown" {
            return "markdown"
        } else if ext == "rtf" || ext == "rtfd" {
            return "rtf"
        } else if ext == "html" || ext == "htm" || ext == "xhtml" || ext == "webarchive" {
            return "html"
        } else if ext == "epub" {
            return "epub"
        } else {
            return "pdf"
        }
    }

    public static func isEBook(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedEBookExtensions.contains(ext)
    }

    public static func isMedia(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext) || supportedAudioExtensions.contains(ext)
    }

    public static func isSupportedFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext) ||
               supportedAudioExtensions.contains(ext) ||
               supportedDocumentExtensions.contains(ext)
    }

    public static func computeFileMD5(url: URL) -> String {
        let sidecar1 = url.appendingPathExtension("md5")
        let sidecar2 = url.deletingPathExtension().appendingPathExtension("md5")
        if FileManager.default.fileExists(atPath: sidecar1.path),
           let sidecar = try? String(contentsOf: sidecar1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !sidecar.isEmpty {
            return sidecar
        }
        if FileManager.default.fileExists(atPath: sidecar2.path),
           let sidecar = try? String(contentsOf: sidecar2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !sidecar.isEmpty {
            return sidecar
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return UUID().uuidString
        }
        defer { try? handle.close() }

        var md5 = Insecure.MD5()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            md5.update(data: chunk)
            return true
        }) {}

        let hashString = md5.finalize().map { String(format: "%02x", $0) }.joined()
        try? hashString.write(to: sidecar1, atomically: true, encoding: .utf8)
        return hashString
    }

    public static func mediaDuration(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        let sec = CMTimeGetSeconds(duration)
        return sec.isFinite && !sec.isNaN ? max(0, sec) : 0
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let totalSec = max(0, Int(seconds.rounded()))
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    public static func formatRulerTime(_ seconds: Double) -> String {
        let totalSec = max(0, Int(seconds.rounded()))
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return "\(h)h\(m)m"
        } else if m > 0 {
            return "\(m)m\(s)s"
        } else {
            return "\(s)s"
        }
    }

    #if canImport(AppKit)
    public static func generatePosterFrame(url: URL, atSeconds seconds: Double = 1.0, size: CGSize = CGSize(width: 320, height: 320)) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImg = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        let w = CGFloat(cgImg.width)
        let h = CGFloat(cgImg.height)
        let naturalSize = (w > 0 && h > 0) ? NSSize(width: w, height: h) : NSSize(width: size.width, height: size.height)
        return NSImage(cgImage: cgImg, size: naturalSize)
    }
    #endif
}
