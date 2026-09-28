import Foundation

public struct TypographyOptions: Codable, Equatable, Sendable {
    public var fontSize: CGFloat
    public var lineSpacing: CGFloat
    public var fontStyle: FontStyle

    public enum FontStyle: String, Codable, CaseIterable, Sendable {
        case system = "System"
        case serif = "Serif"
        case sansSerif = "Sans-Serif"
        case monospace = "Monospace"

        public var displayName: String {
            switch self {
            case .system: return "System"
            case .serif: return "Serif (Georgia)"
            case .sansSerif: return "Sans (Helvetica)"
            case .monospace: return "Mono (Menlo)"
            }
        }

        public var cssFontFamily: String {
            switch self {
            case .system:
                return "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Hiragino Sans GB', sans-serif"
            case .serif:
                return "Georgia, 'Times New Roman', 'Songti SC', 'Source Han Serif SC', serif"
            case .sansSerif:
                return "'Helvetica Neue', Helvetica, Arial, 'PingFang SC', sans-serif"
            case .monospace:
                return "Menlo, Monaco, Consolas, 'Courier New', monospace"
            }
        }
    }

    public static let defaultFontSize: CGFloat = 15.0
    public static let defaultLineSpacing: CGFloat = 1.5
    public static let defaultStyle: FontStyle = .system

    public static let `default` = TypographyOptions(
        fontSize: defaultFontSize,
        lineSpacing: defaultLineSpacing,
        fontStyle: defaultStyle
    )

    public init(
        fontSize: CGFloat = defaultFontSize,
        lineSpacing: CGFloat = defaultLineSpacing,
        fontStyle: FontStyle = defaultStyle
    ) {
        self.fontSize = max(11.0, min(28.0, fontSize))
        self.lineSpacing = max(1.1, min(2.5, lineSpacing))
        self.fontStyle = fontStyle
    }

    public var cacheKey: String {
        let fs = Int(fontSize.rounded())
        let ls = Int((lineSpacing * 100).rounded())
        return "v3_fs\(fs)_ls\(ls)_\(fontStyle.rawValue.lowercased())"
    }
}

public final class TypographyPreferences: @unchecked Sendable {
    public static let shared = TypographyPreferences()
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func globalOptions() -> TypographyOptions {
        let fs = (userDefaults.object(forKey: "mg_ebook_font_size") as? CGFloat) ?? TypographyOptions.defaultFontSize
        let ls = (userDefaults.object(forKey: "mg_ebook_line_spacing") as? CGFloat) ?? TypographyOptions.defaultLineSpacing
        let rawStyle = userDefaults.string(forKey: "mg_ebook_font_style") ?? TypographyOptions.defaultStyle.rawValue
        let style = TypographyOptions.FontStyle(rawValue: rawStyle) ?? TypographyOptions.defaultStyle
        return TypographyOptions(fontSize: fs, lineSpacing: ls, fontStyle: style)
    }

    public func setGlobalOptions(_ options: TypographyOptions) {
        userDefaults.set(options.fontSize, forKey: "mg_ebook_font_size")
        userDefaults.set(options.lineSpacing, forKey: "mg_ebook_line_spacing")
        userDefaults.set(options.fontStyle.rawValue, forKey: "mg_ebook_font_style")
    }

    public func options(forDocumentMD5 md5: String) -> TypographyOptions {
        let key = "mg_ebook_doc_typo_\(md5)"
        if let data = userDefaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(TypographyOptions.self, from: data) {
            return saved
        }
        return globalOptions()
    }

    public func setOptions(_ options: TypographyOptions, forDocumentMD5 md5: String) {
        let key = "mg_ebook_doc_typo_\(md5)"
        if let data = try? JSONEncoder().encode(options) {
            userDefaults.set(data, forKey: key)
        }
        setGlobalOptions(options)
    }

    public func resetOptions(forDocumentMD5 md5: String) {
        let key = "mg_ebook_doc_typo_\(md5)"
        userDefaults.removeObject(forKey: key)
    }
}
