import Foundation
import PageScripts

/// Typed access to JavaScript embedded in the executable at build time.
/// The local PageScripts package's Build Tool Plugin generates the constants.
/// No runtime bundle lookup or file I/O is involved.
enum BundledScript: String {
    case backgroundKeepAlive
    case calls
    case diagnostics
    case media
    case notifications
    case sessionMaintenance
    case shell
    case viewport

    var source: String {
        switch self {
        case .backgroundKeepAlive: return EmbeddedScripts.backgroundKeepAlive
        case .calls: return EmbeddedScripts.calls
        case .diagnostics: return EmbeddedScripts.diagnostics
        case .media: return EmbeddedScripts.media
        case .notifications: return EmbeddedScripts.notifications
        case .sessionMaintenance: return EmbeddedScripts.sessionMaintenance
        case .shell: return EmbeddedScripts.shell
        case .viewport: return EmbeddedScripts.viewport
        }
    }
}

/// Options passed into page scripts as a block-scoped constant. Debug builds
/// can select the previous shell/keep-alive implementations for memory
/// comparisons: launch with `-OTLegacy shell,keepalive`.
enum PageScriptOptions {
    static var literal: String {
        var legacy: [Substring] = []
        #if DEBUG
        legacy = (UserDefaults.standard.string(forKey: "OTLegacy") ?? "").split(separator: ",")
        if !legacy.isEmpty { print("[DEBUG] legacy page scripts: \(legacy.joined(separator: ","))") }
        #endif
        return "Object.freeze({ legacyShell: \(legacy.contains("shell")), legacyKeepAlive: \(legacy.contains("keepalive")) })"
    }

    /// Wraps a script in a block with the options constant in scope.
    static func scoped(_ source: String, prefix: String = "") -> String {
        "{\nconst OPEN_TEAMS_OPTIONS = \(literal);\n\(prefix)" + source + "\n}\n"
    }
}
