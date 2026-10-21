import Foundation

/// Typed names for page scripts shipped as app resources in Scripts/.
/// Xcode's synchronized group includes them in Copy Bundle Resources without
/// a generator, shell build phase or reference to the developer's source tree.
enum BundledScript: String {
    case backgroundKeepAlive
    case calls
    case media
    case notifications
    case sessionMaintenance
    case shell
    case viewport

    var source: String {
        // Synchronized groups can flatten individual resource files into the
        // bundle root; also support a preserved Scripts directory.
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: rawValue, withExtension: "js", subdirectory: "Scripts")
            ?? bundle.url(forResource: rawValue, withExtension: "js") else {
            preconditionFailure("Missing bundled script: \(rawValue).js")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // A broken build must not silently run without media protection,
            // notification shims or the native-shell bridge.
            preconditionFailure("Cannot read bundled script: \(rawValue).js")
        }
    }
}
