import Foundation
import CryptoKit
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

public enum MediaDocumentHelper {
    public static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
    public static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "caf"]
    public static let supportedDocumentExtensions: Set<String> = ["pdf", "epub", "marginpkg", "marginnotes", "sqlite"]

    public static func documentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) {
            return "video"
        } else if supportedAudioExtensions.contains(ext) {
            return "audio"
        } else if ext == "epub" {
            return "epub"
        } else {
            return "pdf"
        }
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
