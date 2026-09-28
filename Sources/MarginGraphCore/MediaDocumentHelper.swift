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

    public static func extractEPUBCoverImage(url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Check disk cache first
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MarginGraph/Thumbnails", isDirectory: true)
        if let cacheDir {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        let fileMD5 = computeFileMD5(url: url)
        let cacheFile = cacheDir?.appendingPathComponent("epub_\(fileMD5).jpg")
        if let cacheFile, FileManager.default.fileExists(atPath: cacheFile.path),
           let cachedImg = NSImage(contentsOf: cacheFile) {
            return cachedImg
        }

        func runUnzip(args: [String]) -> Data? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
            } catch {
                return nil
            }
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + 5.0)
            watchdog.setEventHandler {
                if p.isRunning { p.terminate() }
            }
            watchdog.resume()
            defer { watchdog.cancel() }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return data
        }

        let epubPath = url.path
        guard let containerData = runUnzip(args: ["-p", epubPath, "META-INF/container.xml"]),
              let containerStr = String(data: containerData, encoding: .utf8) else {
            return nil
        }

        var opfRelPath = "OEBPS/content.opf"
        if let match = containerStr.range(of: "full-path=\"([^\"]+)\"", options: .regularExpression) {
            let sub = containerStr[match]
            opfRelPath = String(sub.dropFirst(11).dropLast(1))
        }

        guard let opfData = runUnzip(args: ["-p", epubPath, opfRelPath]),
              let opfStr = String(data: opfData, encoding: .utf8) else {
            return nil
        }

        let opfDir = (opfRelPath as NSString).deletingLastPathComponent
        func resolve(_ rel: String) -> String {
            let clean = rel.components(separatedBy: "#").first ?? rel
            if opfDir.isEmpty || opfDir == "." { return clean }
            return "\(opfDir)/\(clean)"
        }

        var coverHref: String? = nil

        // A. EPUB 3 cover-image property
        if let regex = try? NSRegularExpression(pattern: "<item\\s+[^>]*properties=\"[^\"]*cover-image[^\"]*\"[^>]*href=\"([^\"]+)\"", options: .caseInsensitive),
           let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
           let r = Range(match.range(at: 1), in: opfStr) {
            coverHref = resolve(String(opfStr[r]))
        }

        // B. EPUB 2 meta name="cover"
        if coverHref == nil {
            var coverId: String? = nil
            if let regex = try? NSRegularExpression(pattern: "<meta\\s+[^>]*name=\"cover\"[^>]*content=\"([^\"]+)\"", options: .caseInsensitive),
               let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
               let r = Range(match.range(at: 1), in: opfStr) {
                coverId = String(opfStr[r])
            } else if let regex = try? NSRegularExpression(pattern: "<meta\\s+[^>]*content=\"([^\"]+)\"[^>]*name=\"cover\"", options: .caseInsensitive),
                      let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
                      let r = Range(match.range(at: 1), in: opfStr) {
                coverId = String(opfStr[r])
            }

            if let coverId {
                let lower = coverId.lowercased()
                if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") {
                    coverHref = resolve(coverId)
                } else {
                    let pat1 = "<item\\s+[^>]*id=\"\(NSRegularExpression.escapedPattern(for: coverId))\"[^>]*href=\"([^\"]+)\""
                    let pat2 = "<item\\s+[^>]*href=\"([^\"]+)\"[^>]*id=\"\(NSRegularExpression.escapedPattern(for: coverId))\""
                    if let regex = try? NSRegularExpression(pattern: pat1, options: .caseInsensitive),
                       let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
                       let r = Range(match.range(at: 1), in: opfStr) {
                        coverHref = resolve(String(opfStr[r]))
                    } else if let regex = try? NSRegularExpression(pattern: pat2, options: .caseInsensitive),
                              let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
                              let r = Range(match.range(at: 1), in: opfStr) {
                        coverHref = resolve(String(opfStr[r]))
                    }
                }
            }
        }

        // C. Fallback id="cover" or id="cover-image"
        if coverHref == nil {
            if let regex = try? NSRegularExpression(pattern: "<item\\s+[^>]*id=\"(?:cover|cover-image|coverimage)\"[^>]*href=\"([^\"]+)\"", options: .caseInsensitive),
               let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
               let r = Range(match.range(at: 1), in: opfStr) {
                coverHref = resolve(String(opfStr[r]))
            }
        }

        // D. Fallback guide reference type="cover"
        if coverHref == nil {
            if let regex = try? NSRegularExpression(pattern: "<reference\\s+[^>]*type=\"cover\"[^>]*href=\"([^\"]+)\"", options: .caseInsensitive),
               let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
               let r = Range(match.range(at: 1), in: opfStr) {
                let refHref = String(opfStr[r])
                let resolvedRef = resolve(refHref)
                let lower = resolvedRef.lowercased()
                if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") {
                    coverHref = resolvedRef
                } else if lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
                    if let htmlData = runUnzip(args: ["-p", epubPath, resolvedRef]),
                       let htmlStr = String(data: htmlData, encoding: .utf8) {
                        let pageDir = (resolvedRef as NSString).deletingLastPathComponent
                        if let imgReg = try? NSRegularExpression(pattern: "<(?:img|image)\\s+[^>]*(?:src|href|xlink:href)=\"([^\"]+)\"", options: .caseInsensitive),
                           let imMatch = imgReg.firstMatch(in: htmlStr, options: [], range: NSRange(location: 0, length: htmlStr.utf16.count)),
                           let imR = Range(imMatch.range(at: 1), in: htmlStr) {
                            let imSrc = String(htmlStr[imR])
                            coverHref = pageDir.isEmpty || pageDir == "." ? imSrc : "\(pageDir)/\(imSrc)"
                        }
                    }
                }
            }
        }

        // E. Fallback manifest item href containing cover
        if coverHref == nil {
            if let regex = try? NSRegularExpression(pattern: "<item\\s+[^>]*href=\"([^\"]*cover[^\"]*\\.(?:jpe?g|png|webp))\"", options: .caseInsensitive),
               let match = regex.firstMatch(in: opfStr, options: [], range: NSRange(location: 0, length: opfStr.utf16.count)),
               let r = Range(match.range(at: 1), in: opfStr) {
                coverHref = resolve(String(opfStr[r]))
            }
        }

        guard let foundPath = coverHref else { return nil }
        let standardPath = (foundPath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let imgData = runUnzip(args: ["-p", epubPath, standardPath]),
              let img = NSImage(data: imgData) else {
            return nil
        }

        if let cacheFile {
            try? imgData.write(to: cacheFile, options: .atomic)
        }
        return img
    }
    #endif
}
