import Foundation
import WebKit

/// Narrows the app-wide cookie policy back down for non-Microsoft sites.
///
/// Teams' media gateway (*.asyncgw.teams.microsoft.com: custom emoji,
/// images) must set its own cookie from a cross-site request, which the
/// default `onlyFromMainDocumentDomain` policy rejects, so the app accepts
/// cookies always (TeamsViewController). iOS has no per-domain policy, so
/// this restores the default behaviour for everyone else: a cookie survives
/// only if its domain is a trusted Microsoft host (`TeamsConfig.isTrusted`)
/// or a site the user opened as a page in the last 30 days (for example a
/// federated sign-in provider). Other cookies are deleted as soon as
/// CookieStoreMonitor reports them. Only counts are logged.
final class ThirdPartyCookieFilter {
    private let store: WKHTTPCookieStore
    /// Host -> when it was last opened as a page.
    private var firstPartyHosts: [String: Date]
    #if DEBUG
    private var lastGateway: [String] = []
    #endif
    private static let hostsKey = "CookieFilter.firstPartyHostsSeen"
    private static let legacyHostsKey = "CookieFilter.firstPartyHosts"
    private static let hostLifetime: TimeInterval = 30 * 24 * 3600
    private static let maxHosts = 50

    init(store: WKHTTPCookieStore) {
        self.store = store
        let defaults = UserDefaults.standard
        var hosts = (defaults.dictionary(forKey: Self.hostsKey) as? [String: Date]) ?? [:]
        // Earlier builds kept a plain list without dates.
        for host in defaults.stringArray(forKey: Self.legacyHostsKey) ?? [] where hosts[host] == nil {
            hosts[host] = Date()
        }
        defaults.removeObject(forKey: Self.legacyHostsKey)
        firstPartyHosts = Self.pruned(hosts)
        defaults.set(firstPartyHosts, forKey: Self.hostsKey)
    }

    /// A page the user opened (main frame or popup): its cookies are first-party.
    func noteFirstParty(_ url: URL?) {
        guard let host = url?.host?.lowercased(), !host.isEmpty, !TeamsConfig.isTrusted(url) else { return }
        let now = Date()
        // Refresh at most daily; a page load is not worth a write each time.
        if let seen = firstPartyHosts[host], now.timeIntervalSince(seen) < 24 * 3600 { return }
        firstPartyHosts[host] = now
        firstPartyHosts = Self.pruned(firstPartyHosts)
        UserDefaults.standard.set(firstPartyHosts, forKey: Self.hostsKey)
    }

    /// Drops hosts not opened for 30 days and keeps the 50 most recent.
    private static func pruned(_ hosts: [String: Date]) -> [String: Date] {
        let cutoff = Date().addingTimeInterval(-hostLifetime)
        let recent = hosts.filter { $0.value > cutoff }.sorted { $0.value > $1.value }.prefix(maxHosts)
        return Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
    }

    private func allowed(_ cookie: HTTPCookie) -> Bool {
        let domain = (cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain).lowercased()
        if TeamsConfig.isTrusted(URL(string: "https://\(domain)/")) { return true }
        // A first-party host may set cookies for itself or a parent domain.
        return firstPartyHosts.keys.contains { $0 == domain || $0.hasSuffix("." + domain) }
    }

    /// Deletes cookies of untrusted, non-first-party domains.
    func filter(_ cookies: [HTTPCookie]) {
        #if DEBUG
        // Media gateway cookie shape for diagnosis: never values.
        let gateway = cookies.filter { $0.domain.contains("asyncgw") }.map { cookie in
            let path = cookie.path.replacingOccurrences(
                of: "[0-9a-f]{8}-[0-9a-f-]{27}", with: "<oid>", options: .regularExpression)
            let lifetime = cookie.expiresDate.map { "\(Int($0.timeIntervalSinceNow / 60))min" } ?? "session"
            return (key: "\(cookie.name) path=\(path) size=\(cookie.value.count)", lifetime: lifetime)
        }.sorted { $0.key < $1.key }
        // Compare without the lifetime, which changes every second.
        let keys = gateway.map(\.key)
        if keys != lastGateway {
            lastGateway = keys
            let summary = gateway.map { "\($0.key) expires=\($0.lifetime)" }
            print("[COOKIES] gateway: \(summary.isEmpty ? "none" : summary.joined(separator: "; "))")
        }
        #endif
        let rejected = cookies.filter { !allowed($0) }
        guard !rejected.isEmpty else { return }
        for cookie in rejected { store.delete(cookie) }
        print("[COOKIES] Removed \(rejected.count) third-party cookies from untrusted sites")
    }
}
