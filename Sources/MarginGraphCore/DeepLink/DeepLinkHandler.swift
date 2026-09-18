import Foundation

public enum DeepLinkDestination: Equatable, Sendable {
    case openCard(cardId: UUID)
    case openTopic(topicId: UUID)
}

public enum DeepLinkHandler {
    public static func parse(_ url: URL) -> DeepLinkDestination? {
        guard url.scheme?.lowercased() == "margin-graph" else { return nil }
        let kind = url.host?.lowercased()
        let component = url.pathComponents.first(where: { $0 != "/" })
        guard let component, let id = UUID(uuidString: component) else { return nil }

        switch kind {
        case "note": return .openCard(cardId: id)
        case "topic": return .openTopic(topicId: id)
        default: return nil
        }
    }

    public static func url(forCard id: UUID) -> URL {
        URL(string: "margin-graph://note/\(id.uuidString)")!
    }

    public static func url(forTopic id: UUID) -> URL {
        URL(string: "margin-graph://topic/\(id.uuidString)")!
    }
}

public extension NoteCard {
    var deepLinkURL: URL {
        DeepLinkHandler.url(forCard: id)
    }
}
