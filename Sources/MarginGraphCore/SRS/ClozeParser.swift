import Foundation

public enum ClozeParser {
    public static func masked(_ text: String) -> String {
        var result = replacing(
            pattern: #"{{cd+::(.*?)}}"#,
            in: text,
            template: "[...]"
        )
        result = replacing(
            pattern: #"{{(.*?)}}"#,
            in: result,
            template: "[...]"
        )
        result = replacing(
            pattern: #"[[^]
]+]"#,
            in: result,
            template: "[...]"
        )
        return result
    }

    public static func revealed(_ text: String) -> String {
        var result = replacing(
            pattern: #"{{cd+::(.*?)}}"#,
            in: text,
            template: "$1"
        )
        result = replacing(
            pattern: #"{{(.*?)}}"#,
            in: result,
            template: "$1"
        )
        result = replacing(
            pattern: #"[([^]
]+)]"#,
            in: result,
            template: "$1"
        )
        return result
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
