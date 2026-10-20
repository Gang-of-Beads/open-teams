import Foundation

/// Static configuration for the iOS wrapper. Mirrors the desktop defaults in
/// `app/config/options.js` where an equivalent exists.
enum TeamsConfig {
    /// Same default as the desktop `url` option.
    static let startURL = URL(string: "https://teams.cloud.microsoft")!

    /// Teams web blocks every phone and tablet browser user agent (iPhone,
    /// iPad and Android alike) with an "open in the app" page, so the wrapper
    /// has to present a desktop browser. Desktop Safari reaches sign-in, but
    /// tenants with a Conditional Access policy that requires Microsoft Edge
    /// then reject it (AADSTS 530081, "You must use Microsoft Edge"), so the
    /// wrapper identifies as Edge on Windows. Verified with a real tenant
    /// sign-in. The page still runs on WebKit, so Chromium-only features that
    /// Teams enables for Edge may not work.
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.3800.65"

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
