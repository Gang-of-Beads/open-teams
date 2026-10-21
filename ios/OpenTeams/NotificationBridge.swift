import UIKit
import UserNotifications
import WebKit

/// Turns Teams web notifications into iOS notifications and mirrors the
/// unread count onto the app icon badge.
///
/// WKWebView has no Web Notifications API, so a user script replaces
/// `window.Notification` before Teams loads (the same approach the desktop app
/// takes in `app/browser/preload.js`). The shim forwards each notification to
/// this bridge, which posts it with `UNUserNotificationCenter`. Tapping the
/// notification calls back into the page so Teams' own click handler opens
/// the conversation.
final class NotificationBridge: NSObject {
    static let handlerName = "openTeamsNotifications"

    weak var webView: WKWebView?
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Adds the shim and the message handler to a configuration's content
    /// controller. Popups receive copies of this configuration, so they share
    /// the same handler.
    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.shimSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        contentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
    }

    /// Asks for permission once; iOS remembers the answer. The shim always
    /// reports "granted" to Teams (as the desktop app does), so a denial here
    /// only means iOS silently drops the notifications.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("[NOTIFICATIONS] Authorization request failed: \(error.localizedDescription)")
            }
        }
    }

    private func show(id: String, title: String, body: String, tag: String, silent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.body = String(body.prefix(1000))
        content.sound = silent ? nil : .default
        // Group notifications from the same conversation together.
        if !tag.isEmpty {
            content.threadIdentifier = tag
        }
        content.userInfo = ["id": id]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                print("[NOTIFICATIONS] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    private func close(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func setBadge(_ count: Int) {
        center.setBadgeCount(max(0, count)) { error in
            if let error {
                print("[NOTIFICATIONS] Failed to set badge: \(error.localizedDescription)")
            }
        }
    }

    private func click(id: String) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: [id]),
              let argument = String(data: data, encoding: .utf8)
        else { return }
        // argument is a JSON array, so the id is passed as data, never as code.
        webView.evaluateJavaScript("window.__openTeamsNotifications?.click(...\(argument))")
    }
}

// MARK: - WKScriptMessageHandler

extension NotificationBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              TeamsConfig.isTrusted(URL(string: "\(origin.protocol)://\(origin.host)")),
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String
        else { return }

        switch type {
        case "show":
            guard let id = payload["id"] as? String else { return }
            show(
                id: id,
                title: payload["title"] as? String ?? "",
                body: payload["body"] as? String ?? "",
                tag: payload["tag"] as? String ?? "",
                silent: payload["silent"] as? Bool ?? false
            )
        case "close":
            if let id = payload["id"] as? String {
                close(id: id)
            }
        case "badge":
            if let count = payload["count"] as? Int {
                setBadge(count)
            }
        default:
            break
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationBridge: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Teams decides when a notification is warranted (for example, not for
        // the chat that is open), so show whatever it sends.
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["id"] as? String {
            click(id: id)
        }
        completionHandler()
    }
}

// MARK: - Page shim

extension NotificationBridge {
    /// Injected at document start in the main frame. Keep it self-contained:
    /// it runs before any Teams code and must not throw.
    static let shimSource = #"""
    (() => {
      const handler = window.webkit?.messageHandlers?.openTeamsNotifications;
      if (!handler || window.__openTeamsNotifications) return;

      const post = (message) => {
        try { handler.postMessage(message); } catch (e) { /* bridge unavailable */ }
      };

      // Notifications Teams may still click or close, oldest evicted first.
      const MAX_TRACKED = 50;
      const tracked = new Map();

      const dispatch = (stub, type) => {
        const event = new Event(type);
        // Teams' handlers read the notification from the event target.
        Object.defineProperty(event, "target", { value: stub });
        Object.defineProperty(event, "currentTarget", { value: stub });
        const handlers = [stub["on" + type], ...(stub._listeners[type] || [])];
        for (const fn of handlers) {
          if (typeof fn !== "function") continue;
          try { fn.call(stub, event); } catch (e) { /* third-party handler */ }
        }
      };

      // A factory used with `new`: returning an object replaces `this`.
      function OpenTeamsNotification(title, options) {
        options = options || {};
        const id = crypto.randomUUID();
        const stub = {
          title: String(title ?? ""),
          body: String(options.body ?? ""),
          tag: String(options.tag ?? ""),
          icon: options.icon ?? "",
          data: options.data ?? null,
          silent: Boolean(options.silent),
          onclick: null, onclose: null, onerror: null, onshow: null,
          _listeners: {},
          _closed: false,
          addEventListener(type, listener) {
            (this._listeners[type] ||= []).push(listener);
          },
          removeEventListener(type, listener) {
            this._listeners[type] = (this._listeners[type] || []).filter((l) => l !== listener);
          },
          dispatchEvent() { return true; },
          close() {
            if (this._closed) return;
            this._closed = true;
            post({ type: "close", id });
            dispatch(this, "close");
          },
        };

        tracked.set(id, stub);
        while (tracked.size > MAX_TRACKED) tracked.delete(tracked.keys().next().value);

        post({ type: "show", id, title: stub.title, body: stub.body, tag: stub.tag, silent: stub.silent });
        setTimeout(() => dispatch(stub, "show"), 0);
        return stub;
      }

      Object.defineProperty(OpenTeamsNotification, "permission", { get: () => "granted" });
      OpenTeamsNotification.requestPermission = (callback) => {
        if (typeof callback === "function") callback("granted");
        return Promise.resolve("granted");
      };
      OpenTeamsNotification.maxActions = 0;

      try {
        Object.defineProperty(window, "Notification", {
          value: OpenTeamsNotification, writable: true, configurable: true,
        });
      } catch (e) {
        window.Notification = OpenTeamsNotification;
      }

      Object.defineProperty(window, "__openTeamsNotifications", {
        value: Object.freeze({
          click(id) {
            const stub = tracked.get(id);
            if (stub) dispatch(stub, "click");
          },
        }),
      });

      // Unread count: Teams prefixes the title with "(N)", as the desktop
      // app's mutationTitle.js relies on.
      let lastCount = -1;
      const reportCount = () => {
        const match = /^\((\d+)\)/.exec(document.title || "");
        const count = match ? Number.parseInt(match[1], 10) : 0;
        if (count === lastCount) return;
        lastCount = count;
        post({ type: "badge", count });
      };
      const observeTitle = () => {
        reportCount();
        new MutationObserver(reportCount).observe(document.head || document.documentElement, {
          subtree: true, childList: true, characterData: true,
        });
      };
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", observeTitle, { once: true });
      } else {
        observeTitle();
      }
    })();
    """#
}
