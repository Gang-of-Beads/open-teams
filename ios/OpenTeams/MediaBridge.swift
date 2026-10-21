import UIKit
import WebKit

/// Browser-side media observations, independent of Teams' React internals.
/// Only local capture tracks are patched; remote tracks and track.enabled
/// (the user's actual mute) are never changed.
final class MediaBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "openTeamsMedia"
    var onCallActivity: ((Bool) -> Void)?

    func install(in controller: WKUserContentController) {
        controller.add(WeakScriptMessageHandler(self), name: Self.handlerName)
        controller.addUserScript(WKUserScript(
            source: Self.scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              origin.protocol == "https",
              TeamsConfig.isTrusted(URL(string: "https://\(origin.host)")),
              let payload = message.body as? [String: Any],
              let active = payload["active"] as? Bool else { return }
        onCallActivity?(active)
    }

    static let scriptSource = BundledScript.media.source
}
