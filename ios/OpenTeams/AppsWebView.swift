import UIKit
import WebKit

/// Microsoft 365 apps other than chat and calls (Outlook mail and calendar,
/// OneDrive, Copilot), shown in a web view of their own instead of inside
/// Teams.
///
/// Every WKWebView gets its own web content process, and iOS limits each one
/// to 2 GB (see "Memory budget" in ios/README.md). Inside Teams these apps
/// are iframes in Teams' own process, so an open Calendar or OneDrive left
/// less room for a call; here they use a separate process that can be killed
/// or discarded without touching Teams. The apps are opened directly
/// (Outlook's calendar rather than Teams' hosted copy of it) and share the
/// sign-in cookies of the default website data store.
///
/// Teams links (meeting joins) are handed back to the Teams web view.
final class AppsWebView: NSObject {
    enum App: String, CaseIterable {
        case mail
        case calendar
        case onedrive
        case copilot

        var url: URL {
            switch self {
            case .mail: return URL(string: "https://outlook.office.com/mail/")!
            case .calendar: return URL(string: "https://outlook.office.com/calendar/")!
            // Redirects to the signed-in user's own OneDrive
            // (<tenant>-my.sharepoint.com). microsoft365.com/onedrive and
            // m365.cloud.microsoft/onedrive open Microsoft 365 Copilot instead.
            case .onedrive: return URL(string: "https://www.office.com/launch/onedrive")!
            case .copilot: return URL(string: "https://m365.cloud.microsoft/chat")!
            }
        }

        var title: String {
            switch self {
            case .mail: return String(localized: "Mail")
            case .calendar: return String(localized: "Calendar")
            case .onedrive: return "OneDrive"
            case .copilot: return "Copilot"
            }
        }
    }

    /// Covers the Teams web view while an app is shown.
    let container = UIView()
    /// A Teams link opened from an app, for the Teams web view to open.
    var onTeamsLink: ((URL) -> Void)?
    /// Presents sheets and alerts (Teams' controller, above any popup).
    var presenter: (() -> UIViewController)?

    private var webView: WKWebView?
    private(set) var current: App?
    private var discardTimer: Timer?
    /// Discarded after this long hidden, so the process does not stay
    /// resident; showing the app again loads it afresh.
    private static let discardAfterHidden: TimeInterval = 300

    var isShown: Bool { !container.isHidden }

    override init() {
        super.init()
        container.isHidden = true
        container.backgroundColor = .systemBackground
    }

    func show(_ app: App) {
        discardTimer?.invalidate()
        // A fresh web view per app: loading the next app into the same one
        // kept the previous page in the back/forward cache, in a second
        // process (measured: Mail 528 MB still resident under Calendar).
        if current != app { release() }
        let webView = self.webView ?? makeWebView()
        if current != app || webView.url == nil {
            current = app
            print("[APPS] load \(app.rawValue)")
            webView.load(URLRequest(url: app.url))
        }
        container.isHidden = false
    }

    func hide() {
        guard !container.isHidden else { return }
        container.isHidden = true
        discardTimer?.invalidate()
        discardTimer = Timer.scheduledTimer(withTimeInterval: Self.discardAfterHidden, repeats: false) { [weak self] _ in
            self?.discard()
        }
    }

    /// Releases the web view and its process after it has been hidden for a
    /// while.
    func discard() {
        discardTimer?.invalidate()
        guard container.isHidden else { return }
        release()
        current = nil
    }

    /// The app went to the background: release the process in any case. An
    /// app still on screen is reloaded by `resume()`.
    func suspend() {
        discardTimer?.invalidate()
        release()
        if container.isHidden { current = nil }
    }

    /// The app is active again: reload the app that was on screen.
    func resume() {
        if isShown, webView == nil, let current { show(current) }
    }

    private func release() {
        guard let webView else { return }
        print("[APPS] release")
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: BundledScript.viewport.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = TeamsConfig.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.webView = webView
        return webView
    }

    /// Teams deep links (meeting joins, chats) open in the Teams web view.
    static func isTeamsLink(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else {
            return url?.scheme?.lowercased() == "msteams"
        }
        let teamsHost = host == "teams.microsoft.com" || host == "teams.cloud.microsoft" || host == "teams.live.com"
        return teamsHost && url.path.hasPrefix("/l/")
    }
}

// MARK: - WKNavigationDelegate

extension AppsWebView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if Self.isTeamsLink(url), let url {
            print("[APPS] Teams link handed to Teams")
            onTeamsLink?(url)
            decisionHandler(.cancel)
            return
        }
        if let url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("[APPS] web content process terminated shown=\(isShown)")
        if isShown, let current {
            webView.load(URLRequest(url: current.url))
        } else {
            discard()
        }
    }
}

// MARK: - WKUIDelegate

extension AppsWebView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if Self.isTeamsLink(url), let url {
            onTeamsLink?(url)
        } else if TeamsConfig.isTrusted(url), let url {
            // Microsoft pages (events, attachments) open in place.
            webView.load(URLRequest(url: url))
        } else if let url, TeamsConfig.isWebURL(url) {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        guard let presenter = presenter?() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let presenter = presenter?() else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }
}
