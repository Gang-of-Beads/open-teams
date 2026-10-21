/// Typed access to JavaScript embedded in the executable at build time.
/// EmbeddedScripts is generated in DERIVED_FILE_DIR before Compile Sources.
/// No runtime bundle lookup or file I/O is involved.
enum BundledScript: String {
    case backgroundKeepAlive
    case calls
    case media
    case notifications
    case sessionMaintenance
    case shell
    case viewport

    var source: String {
        switch self {
        case .backgroundKeepAlive: return EmbeddedScripts.backgroundKeepAlive
        case .calls: return EmbeddedScripts.calls
        case .media: return EmbeddedScripts.media
        case .notifications: return EmbeddedScripts.notifications
        case .sessionMaintenance: return EmbeddedScripts.sessionMaintenance
        case .shell: return EmbeddedScripts.shell
        case .viewport: return EmbeddedScripts.viewport
        }
    }
}
