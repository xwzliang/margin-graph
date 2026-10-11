import Foundation

/// Other apps' containers require per-process macOS consent. Do not touch them
/// merely to render a library or check for missing files on startup.
public enum DocumentFileAccess {
    public static func requiresExplicitOpen(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return zip(components, components.dropFirst()).contains { parent, child in
            parent == "Library" && (child == "Containers" || child == "Group Containers")
        }
    }
}
