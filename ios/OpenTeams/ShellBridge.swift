import WebKit

/// The tabs the native tab bar offers. `more` covers every other Teams app
/// (Calendar, OneDrive and so on) through Teams' own app bar.
enum TeamsTab: String, CaseIterable {
    case activity
    case chat
    case calls
    case more
}

/// What the page reports about Teams' own navigation.
struct ShellState: Equatable {
    /// Teams' app bar exists: the app has loaded and the user is signed in.
    var ready = false
    var activeTab: TeamsTab = .chat
    var badges: [TeamsTab: Int] = [:]
    /// A chat or channel is open over the list (narrow layout), so going back
    /// is possible.
    var canGoBack = false
    /// Teams' title bar color (`<meta name="theme-color">`), if known.
    var themeColor: UIColor?
}

protocol ShellBridgeDelegate: AnyObject {
    func shellBridge(_ bridge: ShellBridge, didUpdate state: ShellState)
}

/// Connects the native shell (tab bar, swipe back, status bar color, loading
/// screen) to Teams' web UI.
///
/// The page reports Teams' state and the native side drives Teams by clicking
/// its own controls, found by attributes verified in Teams web:
/// - App bar buttons have the ids of Teams' built-in apps (the same in every
///   tenant), `aria-pressed="true"` on the current one, and an unread count in
///   the screen reader text of `readerBox-<id>` ("3 new notifications").
/// - `[data-tid="hamburger-button"]` opens the app bar with the other apps;
///   it is hidden while the native tab bar is shown.
/// - `[data-tid="layout-navigation-controls"]` ("Return to list") closes an
///   open chat in the narrow layout.
///
/// It also removes web-only touch behaviour: tap highlights and the long-press
/// callout on controls.
final class ShellBridge: NSObject {
    static let handlerName = "openTeamsShell"

    /// Teams' built-in app ids, as used for the app bar button ids.
    static let appIDs: [TeamsTab: String] = [
        .activity: "14d6962d-6eeb-4f48-8890-de55454bb136",
        .chat: "3b64df9d-7e97-4d9c-ac5c-2e0a5d8e6f40",
        .calls: "20c3440d-c67e-4420-9f80-0e50c39693df",
    ]

    weak var webView: WKWebView?
    weak var delegate: ShellBridgeDelegate?
    private(set) var state = ShellState()

    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        contentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
    }

    func select(_ tab: TeamsTab) {
        if tab == .more {
            run("openMore()")
        } else if let id = Self.appIDs[tab] {
            run("select(\"\(id)\")")
        }
    }

    func goBack() { run("goBack()") }

    /// Hides Teams' own app bar button while the native tab bar is shown.
    func setNativeTabsShown(_ shown: Bool) { run("setNativeTabs(\(shown))") }

    /// The page starts over (reload or new navigation).
    func reset() {
        state = ShellState()
    }

    private func run(_ call: String) {
        webView?.evaluateJavaScript("window.__openTeamsShell?.\(call); undefined")
    }

    private static func color(fromHex hex: String) -> UIColor? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

extension ShellBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              TeamsConfig.isTrusted(URL(string: "\(origin.protocol)://\(origin.host)")),
              let payload = message.body as? [String: Any],
              payload["type"] as? String == "state"
        else { return }

        var next = ShellState()
        next.ready = payload["ready"] as? Bool ?? false
        next.activeTab = TeamsTab(rawValue: payload["active"] as? String ?? "") ?? .more
        if let badges = payload["badges"] as? [String: Int] {
            for (key, count) in badges {
                if let tab = TeamsTab(rawValue: key) {
                    next.badges[tab] = count
                }
            }
        }
        next.canGoBack = payload["back"] as? Bool ?? false
        next.themeColor = Self.color(fromHex: payload["theme"] as? String ?? "")
        guard next != state else { return }
        state = next
        delegate?.shellBridge(self, didUpdate: next)
    }
}

// MARK: - Page script

extension ShellBridge {
    static var scriptSource: String {
        let apps = appIDs
            .map { "\"\($0.key.rawValue)\": \"\($0.value)\"" }
            .joined(separator: ", ")
        return "const OPEN_TEAMS_APPS = {\(apps)};\n" + pageScript
    }

    /// Injected at document end in the main frame. Must not throw.
    private static let pageScript = #"""
    (() => {
      const handler = window.webkit?.messageHandlers?.openTeamsShell;
      if (!handler || window.__openTeamsShell || window.opener) return;
      const post = (message) => {
        try { handler.postMessage(message); } catch (e) { /* bridge unavailable */ }
      };

      // Web-only touch behaviour that native apps do not have.
      const style = document.createElement("style");
      style.textContent = `
        html { -webkit-tap-highlight-color: transparent; }
        button, [role="button"], [role="tab"], [role="treeitem"], [role="menuitem"], img {
          -webkit-touch-callout: none;
        }
      `;
      (document.head || document.documentElement).appendChild(style);

      // Teams' app bar button, hidden while the native tab bar replaces it.
      const tabsStyle = document.createElement("style");
      tabsStyle.textContent = `[data-tid="hamburger-button"] { display: none !important; }`;
      tabsStyle.disabled = true;
      (document.head || document.documentElement).appendChild(tabsStyle);

      const unread = (id) => {
        const match = /\d+/.exec(document.getElementById("readerBox-" + id)?.textContent || "");
        return match ? Number.parseInt(match[0], 10) : 0;
      };

      let lastState = "";
      const report = () => {
        const entries = Object.entries(OPEN_TEAMS_APPS);
        const ready = entries.some(([, id]) => document.getElementById(id));
        const active = entries.find(([, id]) => document.getElementById(id)?.getAttribute("aria-pressed") === "true")?.[0] || "more";
        const badges = Object.fromEntries(entries.map(([tab, id]) => [tab, unread(id)]));
        const back = Boolean(document.querySelector('[data-tid="layout-navigation-controls"]'));
        const theme = document.querySelector('meta[name="theme-color"]')?.content || "";
        const state = JSON.stringify({ ready, active, badges, back, theme });
        if (state === lastState) return;
        lastState = state;
        post({ type: "state", ready, active, badges, back, theme });
      };

      // Coalesce Teams' frequent DOM changes into one report.
      let scheduled = false;
      const schedule = () => {
        if (scheduled) return;
        scheduled = true;
        setTimeout(() => { scheduled = false; report(); }, 250);
      };
      new MutationObserver(schedule).observe(document.documentElement, {
        subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ["aria-pressed", "content"],
      });
      report();

      const click = (element) => {
        element?.click();
        return Boolean(element);
      };

      Object.defineProperty(window, "__openTeamsShell", {
        value: Object.freeze({
          select: (id) => click(document.getElementById(id)),
          openMore: () => click(document.querySelector('[data-tid="hamburger-button"]')),
          goBack: () => click(document.querySelector('[data-tid="layout-navigation-controls"]')),
          setNativeTabs: (shown) => { tabsStyle.disabled = !shown; },
        }),
      });
    })();
    """#
}
