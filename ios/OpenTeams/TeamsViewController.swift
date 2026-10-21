import UIKit
import WebKit

/// Hosts the main Teams web view and handles everything WKWebView leaves to
/// the embedding app: popups (sign-in, links), JavaScript dialogs, camera and
/// microphone permission, file downloads and recovery from web process crashes.
final class TeamsViewController: UIViewController {
    private var webView: WKWebView!
    private var popups: [WKWebView: PopupViewController] = [:]
    private var downloadDestinations: [WKDownload: URL] = [:]
    private var lastAutomaticReload: Date?
    private let notificationBridge = NotificationBridge()
    private let keepAlive = BackgroundKeepAlive()
    private let callBridge = CallBridge()
    private var callManager: CallManager?
    private var cookiePathFixer: CookiePathFixer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = Self.makeConfiguration()
        cookiePathFixer = CookiePathFixer(store: configuration.websiteDataStore.httpCookieStore)
        notificationBridge.install(in: configuration.userContentController)
        keepAlive.install(in: configuration.userContentController)
        callBridge.install(in: configuration.userContentController)
        webView = makeWebView(configuration: configuration)
        notificationBridge.webView = webView
        notificationBridge.requestAuthorization()
        keepAlive.start(webView: webView)
        callBridge.webView = webView
        callManager = CallManager(bridge: callBridge, keepAlive: keepAlive, notifications: notificationBridge)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        webView.load(URLRequest(url: TeamsConfig.startURL))
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Persist cookies and storage across launches so the session survives.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Sign-in and "open in new window" flows call window.open from async code.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return configuration
    }

    /// Creates a web view wired to this controller. Popups must use the
    /// configuration WebKit passes in so they share the opener's session.
    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = TeamsConfig.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        // Allows Safari > Develop to attach to the web view on debug builds.
        webView.isInspectable = true
        #endif
        return webView
    }

    /// The controller currently on screen, used to present sheets and alerts
    /// above any open popup.
    private var presenter: UIViewController {
        var controller: UIViewController = self
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func closePopup(_ webView: WKWebView) {
        guard let popup = popups.removeValue(forKey: webView) else { return }
        popup.dismiss(animated: true)
    }

    private func showLoadError(_ error: Error) {
        let alert = UIAlertController(
            title: "Unable to load Teams",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            guard let self else { return }
            if self.webView.url == nil {
                self.webView.load(URLRequest(url: TeamsConfig.startURL))
            } else {
                self.webView.reload()
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func isIgnorableLoadError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        // "Frame load interrupted": raised when a navigation becomes a download
        // or is handed to another app.
        return nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    }
}

// MARK: - WKNavigationDelegate

extension TeamsViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            // msteams:, mailto:, tel: and similar belong to other apps.
            openExternally(url)
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !Self.isIgnorableLoadError(error) else { return }
        showLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS kills the web content process under memory pressure; reload
        // rather than leaving a blank screen.
        if webView === self.webView {
            // Reload once automatically; if the process keeps dying, ask the
            // user instead of looping.
            if let last = lastAutomaticReload, Date().timeIntervalSince(last) < 10 {
                showLoadError(NSError(
                    domain: "OpenTeams",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The web content process stopped unexpectedly."]
                ))
                return
            }
            lastAutomaticReload = Date()
            if webView.url == nil {
                webView.load(URLRequest(url: TeamsConfig.startURL))
            } else {
                webView.reload()
            }
        } else {
            closePopup(webView)
        }
    }
}

// MARK: - WKUIDelegate

extension TeamsViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if TeamsConfig.isWebURL(url), !TeamsConfig.isTrusted(url), let url {
            // Links shared in chats and meetings open in Safari.
            openExternally(url)
            return nil
        }

        let popupWebView = makeWebView(configuration: configuration)
        let popup = PopupViewController(webView: popupWebView) { [weak self] in
            self?.popups.removeValue(forKey: popupWebView)
        }
        popups[popupWebView] = popup
        presenter.present(UINavigationController(rootViewController: popup), animated: true)
        return popupWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(webView)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // iOS still shows its own camera/microphone prompt the first time;
        // this only skips WebKit's extra per-page prompt for Microsoft origins.
        let originURL = URL(string: "\(origin.protocol)://\(origin.host)")
        decisionHandler(TeamsConfig.isTrusted(originURL) ? .grant : .prompt)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
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
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }
}

// MARK: - WKDownloadDelegate

extension TeamsViewController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // A unique directory per download keeps the original file name intact.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let destination = directory.appendingPathComponent(suggestedFilename)
        downloadDestinations[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadDestinations.removeValue(forKey: download) else { return }
        // The share sheet lets the user save to Files, AirDrop or open in another app.
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = share.popoverPresentationController {
            let host = presenter.view!
            popover.sourceView = host
            popover.sourceRect = CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: download)
        let alert = UIAlertController(
            title: "Download failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
