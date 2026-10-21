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
