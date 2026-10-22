import Foundation
import WebKit

/// The single observer of the web view's cookie store.
///
/// Teams changes cookies often and in bursts. Instead of each cookie helper
/// observing the store and reading every cookie on every change, this reads
/// the store once per burst (coalesced for 100 ms) and hands the snapshot to
/// the filter first (deleting untrusted third-party cookies) and then to the
/// path fixer (which only touches trusted Teams cookies).
final class CookieStoreMonitor: NSObject {
    private let store: WKHTTPCookieStore
    private let filter: ThirdPartyCookieFilter
    private let pathFixer: CookiePathFixer
    private var scheduled = false

    init(store: WKHTTPCookieStore, filter: ThirdPartyCookieFilter, pathFixer: CookiePathFixer) {
        self.store = store
        self.filter = filter
        self.pathFixer = pathFixer
        super.init()
        store.add(self)
        process()
    }

    deinit {
        store.remove(self)
    }

    private func process() {
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.filter.filter(cookies)
            self.pathFixer.repair(cookies)
        }
    }
}

extension CookieStoreMonitor: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.process()
        }
    }
}
