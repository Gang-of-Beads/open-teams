import Foundation
import Security
import WebKit

/// Keeps Microsoft session cookies across app restarts, as browsers do when
/// they restore the previous session.
///
/// Teams' sign-in library (MSAL) encrypts its token cache in local storage
/// with a key held in a session cookie (`msal.cache.encryption`, verified on
/// device). WebKit keeps session cookies only in memory, so every full app
/// restart (iOS memory kills, reinstalls, swiping the app away) lost the key,
/// the stored tokens became unreadable, and Teams asked to sign in again:
/// silent renewal in a hidden login frame fails because WebKit blocks
/// third-party cookies there.
///
/// Session cookies of trusted Microsoft hosts are saved to the Keychain
/// (this device only, after first unlock) when the app leaves the foreground
/// and restored before Teams loads. The server still decides whether a
/// session is valid; saved cookies older than two weeks are dropped.
/// Only counts are logged, never names or values.
final class SessionCookiePersistence {
    private let store: WKHTTPCookieStore
    private var observers: [NSObjectProtocol] = []
    private static let service = "io.github.openteams.session-cookies"
    private static let account = "microsoft"
    private static let maxAge: TimeInterval = 14 * 24 * 3600

    init(store: WKHTTPCookieStore) {
        self.store = store
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.save()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Restores saved session cookies, then calls `completion` on the main
    /// queue. Cookies already in the store (same name, domain and path) win.
    func restore(completion: @escaping () -> Void) {
        guard let saved = Self.load() else {
            completion()
            return
        }
        store.getAllCookies { [store] existing in
            let present = Set(existing.map(Self.identity))
            let cookies = saved.compactMap(Self.cookie).filter { !present.contains(Self.identity($0)) }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                print("[SESSION] Restored \(cookies.count) session cookies")
                completion()
            }
        }
    }

    /// Saves the current session cookies of trusted Microsoft hosts.
    func save() {
        // Keep the app alive long enough to finish when it is backgrounding.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "SaveSessionCookies") {
            UIApplication.shared.endBackgroundTask(task)
        }
        store.getAllCookies { cookies in
            let session = cookies.filter { $0.isSessionOnly && Self.isTrustedDomain($0.domain) }
            let records: [[String: Any]] = session.map { cookie in
                var record: [String: Any] = [
                    "name": cookie.name, "value": cookie.value, "domain": cookie.domain,
                    "path": cookie.path, "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly,
                ]
                if let policy = cookie.sameSitePolicy { record["sameSite"] = policy.rawValue }
                return record
            }
            let payload: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "cookies": records]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                Self.write(data)
            }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: Cookies

    private static func identity(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
    }

    private static func isTrustedDomain(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return TeamsConfig.isTrusted(URL(string: "https://\(host)/"))
    }

    /// A session cookie again: no expiry, so it still ends with the session.
    private static func cookie(_ record: [String: Any]) -> HTTPCookie? {
        guard let name = record["name"] as? String, let value = record["value"] as? String,
              let domain = record["domain"] as? String, isTrustedDomain(domain) else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain,
            .path: record["path"] as? String ?? "/",
        ]
        if record["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if record["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = record["sameSite"] as? String { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func load() -> [[String: Any]]? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedAt = payload["savedAt"] as? TimeInterval,
              let cookies = payload["cookies"] as? [[String: Any]] else { return nil }
        guard Date().timeIntervalSince1970 - savedAt < maxAge else {
            SecItemDelete(query as CFDictionary)
            print("[SESSION] Saved session cookies expired; discarded")
            return nil
        }
        return cookies
    }

    private static func write(_ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[SESSION] Could not save session cookies (status \(status))")
        }
    }
}
