import QuickLook
import UIKit
import WebKit

/// Hosts the main Teams web view in a native shell and handles everything
/// WKWebView leaves to the embedding app: popups (sign-in, links), JavaScript
/// dialogs, camera and microphone permission, file downloads and recovery
/// from web process crashes.
///
/// The shell around Teams is native: a tab bar for Teams' main apps, the
/// status bar area in Teams' title bar color, a loading and error screen,
/// swipe from the left edge to go back, and Quick Look for downloads.
final class TeamsViewController: UIViewController {
    private var webView: WKWebView!
    private var popups: [WKWebView: PopupViewController] = [:]
    private var downloadDestinations: [WKDownload: URL] = [:]
    private var previewFile: URL?
    private var lastAutomaticReload: Date?
    private let notificationBridge = NotificationBridge()
    private let keepAlive = BackgroundKeepAlive()
    private let callBridge = CallBridge()
    private let mediaBridge = MediaBridge()
    private let sessionMaintenance = SessionMaintenance()
    private let shellBridge = ShellBridge()
    private var callManager: CallManager?
    private var cookiePathFixer: CookiePathFixer?

    private let tabBar = UITabBar()
    private let tabTransition = PageTransition()
    private var lastChatTap: TimeInterval?
    private var lastChatTapWasSelected = false
    private let loadingView = LoadingView()
    private var webViewAboveTabBar: NSLayoutConstraint!
    private var progressObservation: NSKeyValueObservation?
    private var loadingTimers: [Timer] = []
    private var loadAttempts = 0
    private var backGesture: UIScreenEdgePanGestureRecognizer!

    private static let tabItems: [(TeamsTab, String, String)] = [
        (.activity, String(localized: "Activity"), "bell"),
        (.chat, String(localized: "Chat"), "bubble.left.and.bubble.right"),
        (.calendar, String(localized: "Calendar"), "calendar"),
        (.calls, String(localized: "Calls"), "phone"),
        (.more, String(localized: "More"), "ellipsis"),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = Self.makeConfiguration()
        cookiePathFixer = CookiePathFixer(store: configuration.websiteDataStore.httpCookieStore)
        notificationBridge.install(in: configuration.userContentController)
        keepAlive.install(in: configuration.userContentController)
        mediaBridge.install(in: configuration.userContentController)
        callBridge.install(in: configuration.userContentController)
        shellBridge.install(in: configuration.userContentController)
        webView = makeWebView(configuration: configuration)
        // The outer page does not scroll; Teams scrolls its own panes. Without
        // this the whole app rubber-bands like a web page.
        webView.scrollView.bounces = false
        webView.removeInputAccessoryView()
        notificationBridge.webView = webView
        notificationBridge.requestAuthorization()
        keepAlive.start(webView: webView)
        callBridge.webView = webView
        shellBridge.webView = webView
        shellBridge.delegate = self
        callManager = CallManager(bridge: callBridge, keepAlive: keepAlive, notifications: notificationBridge)
        mediaBridge.onCallActivity = { [weak self] active in
            self?.keepAlive.callInProgress = active
            self?.callManager?.webRTCActivityChanged(active)
            UIApplication.shared.isIdleTimerDisabled = active
        }
        sessionMaintenance.onRetry = { [weak self] in self?.loadTeams() }
        sessionMaintenance.start(webView: webView)

        layOut()
        setUpTabBar()
        setUpBackGesture()
        setUpLoadingView()

        loadTeams()
    }

    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Layout

    private func layOut() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(tabBar)
        view.addSubview(loadingView)

        // The web view sits between the status bar and the tab bar, and above
        // the keyboard while it is up (the keyboard covers the tab bar).
        webViewAboveTabBar = webView.bottomAnchor.constraint(lessThanOrEqualTo: tabBar.topAnchor)
        let fill = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
            fill,

            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setUpTabBar() {
        tabBar.delegate = self
        tabBar.items = Self.tabItems.enumerated().map { index, item in
            UITabBarItem(title: item.1, image: UIImage(systemName: item.2), tag: index)
        }
        setTabBarShown(false)
    }

    private func setTabBarShown(_ shown: Bool) {
        tabBar.isHidden = !shown
        webViewAboveTabBar.isActive = shown
        shellBridge.setNativeTabsShown(shown)
    }

    private func setUpBackGesture() {
        backGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackGesture))
        backGesture.edges = .left
        backGesture.delegate = self
        backGesture.isEnabled = false
        webView.addGestureRecognizer(backGesture)
    }

    @objc private func handleBackGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        if translation > 80 || velocity > 600 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            shellBridge.goBack()
        }
    }

    // MARK: Loading

    private func setUpLoadingView() {
        loadingView.onRetry = { [weak self] in self?.loadTeams() }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.loadingView.setProgress(webView.estimatedProgress)
        }
    }

    private func loadTeams() {
        loadAttempts = 0
        if webView.url == nil {
            webView.load(URLRequest(url: TeamsConfig.startURL))
        } else {
            webView.reload()
        }
        showLoading()
    }

    /// Covers the page until Teams reports it is ready. Teams sometimes
    /// stalls while loading; reload once if it is not ready in time, and
    /// eventually reveal the page so Teams' own error or sign-in UI is usable.
    private func showLoading() {
        loadingTimers.forEach { $0.invalidate() }
        loadingView.showLoading()
        loadingView.isHidden = false
        loadingTimers = [
            Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
                guard let self, !self.shellBridge.state.ready, self.loadAttempts == 0,
                      !self.keepAlive.callInProgress,
                      ["teams.cloud.microsoft", "teams.microsoft.com"].contains(self.webView.url?.host ?? "")
                else { return }
                self.loadAttempts += 1
                self.webView.reload()
            },
            Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { [weak self] _ in
                self?.hideLoading()
            },
        ]
    }

    private func hideLoading() {
        loadingTimers.forEach { $0.invalidate() }
        loadingTimers = []
        guard !loadingView.isHidden else { return }
        UIView.animate(withDuration: 0.25, animations: {
            self.loadingView.alpha = 0
        }, completion: { _ in
            self.loadingView.isHidden = true
            self.loadingView.alpha = 1
        })
    }

    private func showLoadError(_ message: String) {
        loadingTimers.forEach { $0.invalidate() }
        loadingTimers = []
        loadingView.showError(message)
        loadingView.isHidden = false
    }

    // MARK: Theme

    /// Matches the status bar area, tab bar and system UI to Teams' theme.
    private func apply(themeColor: UIColor) {
        view.backgroundColor = themeColor
        loadingView.backgroundColor = themeColor
        var white: CGFloat = 1
        themeColor.getWhite(&white, alpha: nil)
        view.window?.overrideUserInterfaceStyle = white < 0.5 ? .dark : .light
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
        configuration.userContentController.addUserScript(WKUserScript(
            source: viewportScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        return configuration
    }

    /// iOS zooms into a focused text field whose font is smaller than 16px,
    /// and Teams' message box uses 14px, so typing zoomed the page and pushed
    /// the send button off screen. maximum-scale=1 turns that zoom off (and
    /// pinch zoom with it). Teams can rewrite the tag, so it is reapplied.
    private static let viewportScript = BundledScript.viewport.source

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
        sessionMaintenance.navigationFailed(error)
        showLoadError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        tabTransition.cancel()
        lastChatTap = nil
        sessionMaintenance.navigationStarted()
        keepAlive.callInProgress = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        sessionMaintenance.navigationSucceeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !Self.isIgnorableLoadError(error) else { return }
        sessionMaintenance.navigationFailed(error)
        showLoadError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        // A new page: Teams reports its state again once it has loaded.
        shellBridge.reset()
        setTabBarShown(false)
        backGesture.isEnabled = false
        // Do not turn ordinary in-session document navigation into another
        // cold start (and a new 40-second reload timer). loadTeams() alone
        // shows the native loading screen for explicit loads and recovery.
        if !["teams.cloud.microsoft", "teams.microsoft.com"].contains(webView.url?.host ?? "") {
            // Never cover interactive sign-in pages or reload them on a timer.
            hideLoading()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS kills the web content process under memory pressure; reload
        // rather than leaving a blank screen.
        if webView === self.webView {
            keepAlive.callInProgress = false
            UIApplication.shared.isIdleTimerDisabled = false
            // Reload once automatically; if the process keeps dying, ask the
            // user instead of looping.
            if let last = lastAutomaticReload, Date().timeIntervalSince(last) < 10 {
                showLoadError(String(localized: "Teams stopped unexpectedly."))
                return
            }
            lastAutomaticReload = Date()
            loadTeams()
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
        // Quick Look previews documents and images and has its own share
        // button; anything it cannot show goes straight to the share sheet.
        if QLPreviewController.canPreview(file as NSURL) {
            previewFile = file
            let preview = QLPreviewController()
            preview.dataSource = self
            presenter.present(preview, animated: true)
            return
        }
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

// MARK: - ShellBridgeDelegate

extension TeamsViewController: ShellBridgeDelegate {
    func shellBridge(_ bridge: ShellBridge, navigationSettled token: Int) {
        tabTransition.finish(token: token)
    }

    func shellBridge(_ bridge: ShellBridge, didUpdate state: ShellState) {
        if let themeColor = state.themeColor {
            apply(themeColor: themeColor)
        }
        backGesture.isEnabled = state.canGoBack
        setTabBarShown(state.ready)
        guard state.ready else { return }
        hideLoading()

        let items = tabBar.items ?? []
        for (index, entry) in Self.tabItems.enumerated() where index < items.count {
            let count = state.badges[entry.0] ?? 0
            items[index].badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
        }
        if let index = Self.tabItems.firstIndex(where: { $0.0 == state.activeTab }), index < items.count {
            tabBar.selectedItem = items[index]
        }
    }
}

// MARK: - UITabBarDelegate

extension TeamsViewController: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard Self.tabItems.indices.contains(item.tag) else { return }
        let tab = Self.tabItems[item.tag].0
        let alreadySelected = shellBridge.state.activeTab == tab
        let now = ProcessInfo.processInfo.systemUptime
        if tab == .chat {
            let doubleTap = alreadySelected && lastChatTapWasSelected &&
                lastChatTap.map { now - $0 <= 0.35 } == true
            lastChatTap = doubleTap ? nil : now
            lastChatTapWasSelected = alreadySelected
            if doubleTap {
                tabTransition.cancel()
                shellBridge.focusNextUnread()
                UISelectionFeedbackGenerator().selectionChanged()
                return
            }
        } else {
            lastChatTap = nil
            lastChatTapWasSelected = false
        }
        if tab == .more {
            tabTransition.cancel()
            shellBridge.select(tab)

            // "More" opens Teams' app list over the page; the selection stays
            // on the current app until Teams switches.
            let current = Self.tabItems.firstIndex { $0.0 == shellBridge.state.activeTab }
            if let current, let items = tabBar.items, current < items.count {
                tabBar.selectedItem = items[current]
            }
        } else if !alreadySelected {
            // activeTab follows the visible destination, not just Teams'
            // selected app tile (Activity can open Chat/Calls in place).
            let token = tabTransition.begin(over: webView)
            shellBridge.select(tab, transitionToken: token)
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TeamsViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // WebKit's own scroll and tap recognizers keep working alongside.
        true
    }
}

// MARK: - QLPreviewControllerDataSource

extension TeamsViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewFile == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewFile ?? FileManager.default.temporaryDirectory) as NSURL
    }
}
