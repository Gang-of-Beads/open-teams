import Foundation
import WebKit

/// Repairs Teams cookies that WebKit stores with an unusable path.
///
/// Teams sets its profile picture cookies (`authtoken`, `tenantId`,
/// `clienttype`) with a relative `Path` such as `users/<id>/`. RFC 6265 says to
/// ignore a path that does not start with "/" and use the request's directory
/// instead, which is what Chromium does, so the cookie reaches
/// `/api/mt/<region>/beta/users/<id>/profilepicturev2/...`. WebKit keeps the
/// literal relative path, which never matches a request path, so those
/// requests go out without credentials, get 401, and every avatar falls back
/// to a placeholder.
///
/// Whenever the cookie store changes, each Teams cookie with a relative path
/// is copied to `Path=/` with the same value, flags and expiry. The original is
/// left alone so Teams can keep refreshing it; the copy follows each refresh.
final class CookiePathFixer: NSObject {
    private let store: WKHTTPCookieStore

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
        store.add(self)
        repair()
    }

    deinit {
        store.remove(self)
    }

    private func repair() {
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let existing = Set(cookies.map(Self.key))
            for cookie in cookies {
                guard !cookie.path.hasPrefix("/"),
                      Self.isTeamsDomain(cookie.domain),
                      let fixed = Self.copy(cookie, path: "/"),
                      !existing.contains(Self.key(fixed))
                else { continue }
                // Setting it changes the store again; the key check above stops
                // the observer from copying the same cookie twice.
                self.store.setCookie(fixed)
            }
        }
    }

    /// Identity plus value, so a refreshed token is copied again.
    private static func key(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)|\(cookie.value)"
    }

    private static func isTeamsDomain(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return TeamsConfig.isTrusted(URL(string: "https://\(host)/"))
    }

    private static func copy(_ cookie: HTTPCookie, path: String) -> HTTPCookie? {
        guard var properties = cookie.properties else { return nil }
        properties[.path] = path
        return HTTPCookie(properties: properties)
    }
}

extension CookiePathFixer: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        repair()
    }
}
