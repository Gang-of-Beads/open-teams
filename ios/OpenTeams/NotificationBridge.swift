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

    private struct PendingNotification {
        let id: String
        let title: String
        let body: String
        let tag: String
        let silent: Bool
        let icon: String
    }

    /// Teams raises a web notification for a ringing call at the same moment
    /// as the call itself. While CallKit shows the call, that banner is a
    /// duplicate, so notifications arriving shortly after a call starts
    /// ringing are held back, dropped if CallKit takes the call and shown if
    /// it does not.
    private var holdUntil: Date?
    private var held: [PendingNotification] = []

    func holdNotificationsForRingingCall() {
        holdUntil = Date().addingTimeInterval(3)
        held.removeAll()
    }

    /// CallKit is showing the call: drop what was held.
    func dropHeldNotifications() {
        holdUntil = nil
        held.removeAll()
    }

    /// CallKit did not take the call: show what was held after all.
    func releaseHeldNotifications() {
        holdUntil = nil
        let pending = held
        held.removeAll()
        for n in pending {
            show(id: n.id, title: n.title, body: n.body, tag: n.tag, silent: n.silent, icon: n.icon)
        }
    }

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

    private func show(id: String, title: String, body: String, tag: String, silent: Bool, icon: String) {
        let content = UNMutableNotificationContent()
        // The sender's picture as a thumbnail. Communication notifications
        // (avatar on the left) need an entitlement a free account cannot get.
        if let attachment = Self.attachment(fromDataURL: icon, id: id) {
            content.attachments = [attachment]
        }
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

    /// Writes a `data:image/...;base64,` URL from the page to a temporary file
    /// for UNNotificationAttachment, which takes ownership of the file.
    private static func attachment(fromDataURL dataURL: String, id: String) -> UNNotificationAttachment? {
        guard dataURL.hasPrefix("data:image/"),
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        let mime = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 11)..<comma]
        let ext = mime.hasPrefix("png") ? "png" : mime.hasPrefix("gif") ? "gif" : "jpg"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notification-\(id).\(ext)")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "icon", url: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
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
            let notification = PendingNotification(
                id: id,
                title: payload["title"] as? String ?? "",
                body: payload["body"] as? String ?? "",
                tag: payload["tag"] as? String ?? "",
                silent: payload["silent"] as? Bool ?? false,
                icon: payload["icon"] as? String ?? ""
            )
            if let holdUntil, holdUntil > Date() {
                held.append(notification)
                return
            }
            show(id: notification.id, title: notification.title, body: notification.body,
                 tag: notification.tag, silent: notification.silent, icon: notification.icon)
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
    static let shimSource = BundledScript.notifications.source
}
