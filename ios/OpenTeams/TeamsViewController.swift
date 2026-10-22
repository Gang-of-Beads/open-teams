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
    private var cookieMonitor: CookieStoreMonitor?
    private var sessionCookies: SessionCookiePersistence?
    private var cookieFilter: ThirdPartyCookieFilter?
    private var authAlertShown = false
    /// Set when Settings was opened for sign-in; retry renewal on return.
    private var reloadAfterSettings = false
    private var settingsObserver: NSObjectProtocol?

    private let tabBar = UITabBar()
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

        // Teams authenticates its media gateway (custom emoji, images:
        // *.asyncgw.teams.microsoft.com) by having that host set its own
        // cookie from a cross-site request. The default app policy,
        // onlyFromMainDocumentDomain, rejects cookies from hosts never visited
        // top-level, so every media image got 401 (verified on device).
        // WebKit reads this policy when it starts its network process, so it
        // must be set before the first web view exists. ThirdPartyCookieFilter
        // keeps "always" to Microsoft hosts and sites opened as pages.
        HTTPCookieStorage.shared.cookieAcceptPolicy = .always
        let configuration = Self.makeConfiguration()
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        sessionCookies = SessionCookiePersistence(store: cookieStore)
        let filter = ThirdPartyCookieFilter(store: cookieStore)
        cookieFilter = filter
        cookieMonitor = CookieStoreMonitor(store: cookieStore, filter: filter, pathFixer: CookiePathFixer(store: cookieStore))
        let controller = configuration.userContentController
        if Self.scriptEnabled("notifications") { notificationBridge.install(in: controller) }
        if Self.scriptEnabled("keepalive") { keepAlive.install(in: controller) }
        if Self.scriptEnabled("media") { mediaBridge.install(in: controller) }
        if Self.scriptEnabled("calls") { callBridge.install(in: controller) }
        if Self.scriptEnabled("shell") { shellBridge.install(in: controller) }
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
        sessionMaintenance.onRetry = { [weak self] in self?.loadTeams(reason: "network-retry") }
        sessionMaintenance.start(webView: webView)

        layOut()
        setUpTabBar()
        setUpBackGesture()
        setUpLoadingView()

        // Session cookies (MSAL's cache key among them) must be back before
        // Teams starts, or it cannot read its stored tokens.
        loadingView.isHidden = false
        sessionCookies?.restore { [weak self] in self?.loadTeams() }
        // If iOS did not restart the app after the setting changed, reload so
        // Teams retries its silent renewal with the new cookie policy.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.reloadAfterSettings else { return }
            self.reloadAfterSettings = false
            self.authAlertShown = false
            self.loadTeams(reason: "auth-settings")
        }
    }

    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Debug-only memory experiments: launch with `-OTDisable keepalive,shell`
    /// to leave page scripts out. Release builds always install every script.
    private static func scriptEnabled(_ name: String) -> Bool {
        #if DEBUG
        let disabled = (UserDefaults.standard.string(forKey: "OTDisable") ?? "").split(separator: ",")
        if disabled.contains(Substring(name)) || disabled.contains("all") {
            print("[DEBUG] page script disabled: \(name)")
            return false
        }
        #endif
        return true
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
        loadingView.onRetry = { [weak self] in self?.loadTeams(reason: "user-retry") }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.loadingView.setProgress(webView.estimatedProgress)
        }
    }

    private func loadTeams(reason: String = "start") {
        print("[NAV] loadTeams reason=\(reason)")
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
                print("[NAV] reload reason=startup-stall")
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
        if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true {
            // Navigation type and host category only: never URLs or queries.
            let host = navigationAction.request.url?.host ?? ""
            let category = ["teams.cloud.microsoft", "teams.microsoft.com"].contains(host) ? "teams"
                : TeamsConfig.isTrusted(navigationAction.request.url) ? "microsoft" : "other"
            print("[NAV] main-frame type=\(navigationAction.navigationType.rawValue) host=\(category) " +
                  "user=\(navigationAction.navigationType == .linkActivated) app=\(UIApplication.shared.applicationState.rawValue)")
        }
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
        print("[NAV] provisional failure domain=\((error as NSError).domain) code=\((error as NSError).code)")
        sessionMaintenance.navigationFailed(error)
        showLoadError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
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
        // Sites opened as pages (main view or popup) keep their own cookies.
        cookieFilter?.noteFirstParty(webView.url)
        guard webView === self.webView else { return }
        print("[NAV] commit app=\(UIApplication.shared.applicationState.rawValue)")
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
            print("[NAV] web content process terminated app=\(UIApplication.shared.applicationState.rawValue)")
            BackgroundKeepAlive.log("web content process terminated; reloading")
            keepAlive.callInProgress = false
            UIApplication.shared.isIdleTimerDisabled = false
            // Reload once automatically; if the process keeps dying, ask the
            // user instead of looping.
            if let last = lastAutomaticReload, Date().timeIntervalSince(last) < 10 {
                showLoadError(String(localized: "Teams stopped unexpectedly."))
                return
            }
            lastAutomaticReload = Date()
            loadTeams(reason: "process-terminated")
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
    /// Teams' silent renewal runs in a hidden login.microsoftonline.com frame,
    /// where WebKit's tracking prevention blocks the Microsoft sign-in cookie.
    /// "Allow Cross-Website Tracking" (NSCrossWebsiteTrackingUsageDescription)
    /// lifts that for this app. Explain once per launch and open Settings.
    func shellBridgeAuthRequired(_ bridge: ShellBridge) {
        guard !authAlertShown else { return }
        // The page reports the banner once per load, so never drop it: show
        // it above any open sheet or popup, and retry while one is still
        // animating in or out.
        let top = presenter
        if top.isBeingPresented || top.isBeingDismissed || top is UIAlertController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.shellBridgeAuthRequired(bridge)
            }
            return
        }
        authAlertShown = true
        print("[SESSION] Teams requires sign-in; offering cross-website tracking setting")
        let alert = UIAlertController(
            title: String(localized: "Teams can't renew your sign-in"),
            message: String(localized: """
                Microsoft renews your session in the background through its sign-in page, which iOS blocks \
                in apps by default. In Settings, turn on Allow Cross-Website Tracking for Open Teams, \
                then come back.
                """),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Open Settings"), style: .default) { [weak self] _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            self?.reloadAfterSettings = true
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
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
                shellBridge.focusNextUnread()
                UISelectionFeedbackGenerator().selectionChanged()
                return
            }
        } else {
            lastChatTap = nil
            lastChatTapWasSelected = false
        }
        if tab == .more {
            shellBridge.select(tab)

            // "More" opens Teams' app list over the page; the selection stays
            // on the current app until Teams switches.
            let current = Self.tabItems.firstIndex { $0.0 == shellBridge.state.activeTab }
            if let current, let items = tabBar.items, current < items.count {
                tabBar.selectedItem = items[current]
            }
        } else {
            // Always dispatch explicit tab taps. The page may still be
            // resolving a destination or displaying an in-app detail view.
            shellBridge.select(tab)
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
