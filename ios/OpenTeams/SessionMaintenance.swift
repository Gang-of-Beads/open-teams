import Network
import UIKit
import WebKit

/// Recovers only failed top-level network navigations. Never reload a healthy
/// Teams page on a network switch: it may contain a draft or an active call.
/// Authentication remains owned by Teams; no tokens cross the JS bridge.
final class SessionMaintenance {
    private weak var webView: WKWebView?
    private let monitor = NWPathMonitor()
    private var online = false
    private var failedNetworkLoad = false
    private var lastAttempt = Date.distantPast
    private var activeObserver: NSObjectProtocol?
    private var timer: Timer?
    var onRetry: (() -> Void)?

    func start(webView: WKWebView) {
        self.webView = webView
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.online = path.status == .satisfied
                self.retryIfNeeded()
            }
        }
        monitor.start(queue: DispatchQueue(label: "OpenTeams.network"))
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryIfNeeded()
            self?.maintainSession()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.maintainSession()
        }
    }

    deinit {
        monitor.cancel()
        timer?.invalidate()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    func navigationStarted() { failedNetworkLoad = false }
    func navigationSucceeded() { failedNetworkLoad = false }

    func navigationFailed(_ error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain,
              [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
               NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
               NSURLErrorDNSLookupFailed].contains(error.code) else { return }
        // Wait for a network transition or foreground event; do not spin on
        // server failures just because the device still has a network path.
        failedNetworkLoad = true
    }

    private func retryIfNeeded() {
        guard online, failedNetworkLoad else { return }
        failedNetworkLoad = false
        onRetry?()
    }

    private func maintainSession() {
        guard online, !failedNetworkLoad,
              UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(lastAttempt) >= 3600,
              let webView, !webView.isLoading,
              ["teams.cloud.microsoft", "teams.microsoft.com"].contains(webView.url?.host ?? "") else { return }
        lastAttempt = Date()
        // Reuse Teams' own silent acquisition, allowing its cache and expiry
        // logic to decide whether to refresh. Never install Electron's cache
        // adapter, force an interactive login, or copy tokens into Swift.
        webView.evaluateJavaScript(Self.script) { _, error in
            if error != nil { print("[SESSION] Silent session maintenance unavailable") }
        }
    }

    private static let script = BundledScript.sessionMaintenance.source
}
