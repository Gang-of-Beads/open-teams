import Foundation

/// Static configuration for the iOS wrapper. Mirrors the desktop defaults in
/// `app/config/options.js` where an equivalent exists.
enum TeamsConfig {
    /// Same default as the desktop `url` option.
    static let startURL = URL(string: "https://teams.cloud.microsoft")!

    /// Teams web sends iPhone/iPad Safari to an "open in the app" page, so the
    /// wrapper identifies as desktop Safari on macOS, which Teams supports.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Hosts (and their subdomains) that belong to Teams, Microsoft 365 or
    /// Microsoft sign-in. New windows to these hosts open inside the app; new
    /// windows to anything else open in Safari. Top-level navigations are
    /// never redirected, so third-party SSO providers keep working.
    static let trustedHostSuffixes: [String] = [
        "cloud.microsoft",
        "microsoft.com",
        "microsoftonline.com",
        "microsoftonline-p.com",
        "msauth.net",
        "msftauth.net",
        "live.com",
        "office.com",
        "office.net",
        "office365.com",
        "sharepoint.com",
        "skype.com",
        "teams.live.com",
        "windows.net",
    ]

    static func isTrusted(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return trustedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isWebURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
