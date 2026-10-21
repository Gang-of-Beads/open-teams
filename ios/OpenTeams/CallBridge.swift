import WebKit

/// Events the Teams page reports about calls.
enum CallEvent {
    /// A call is ringing. Sent again while ringing if Teams updates the caller
    /// (call-queue calls arrive twice).
    case incoming(name: String, number: String)
    /// The ringing toast went away: answered, declined, cancelled by the
    /// caller, or answered on another device.
    case incomingEnded
    /// The calling screen is up: an answered, placed or joined call.
    case connected
    /// The call or meeting ended.
    case disconnected
    /// The microphone was muted or unmuted in Teams.
    case muted(Bool)
}

protocol CallBridgeDelegate: AnyObject {
    func callBridge(_ bridge: CallBridge, didReceive event: CallEvent)
}

/// Connects Teams' calling UI to native code.
///
/// Events come from Teams' internal command stream
/// (`coreServices.commandChangeReportingService`), the same locale-independent
/// source the desktop app uses in `app/browser/tools/activityHub.js`:
/// incoming-call toasts carry `isIncomingCall` and a scenario name, and the
/// steps `calling-screen-rendered` / `render_disconected` mark a call starting
/// and ending. Actions click Teams' own buttons: the incoming-call toast's
/// accept/decline buttons (as the desktop app does), `#hangup-button` and
/// `#microphone-button`, whose `data-state` is `mic-off` while muted.
final class CallBridge: NSObject {
    static let handlerName = "openTeamsCalls"

    weak var webView: WKWebView?
    weak var delegate: CallBridgeDelegate?

    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        contentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
    }

    func answer() { run("answer()") }
    func decline() { run("decline()") }
    func hangUp() { run("hangUp()") }
    func setMuted(_ muted: Bool) { run("setMuted(\(muted))") }

    /// Silences Teams' own ringtone while iOS rings through CallKit.
    func setRingtoneSuppressed(_ suppressed: Bool) { run("setRingtoneSuppressed(\(suppressed))") }

    private func run(_ call: String) {
        webView?.evaluateJavaScript("window.__openTeamsCalls?.\(call); undefined")
    }
}

extension CallBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              TeamsConfig.isTrusted(URL(string: "\(origin.protocol)://\(origin.host)")),
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String
        else { return }

        let event: CallEvent
        switch type {
        case "incoming":
            event = .incoming(
                name: payload["name"] as? String ?? "",
                number: payload["number"] as? String ?? ""
            )
        case "incomingEnded":
            event = .incomingEnded
        case "connected":
            event = .connected
        case "disconnected":
            event = .disconnected
        case "muted":
            event = .muted(payload["muted"] as? Bool ?? false)
        default:
            return
        }
        delegate?.callBridge(self, didReceive: event)
    }
}

// MARK: - Page script

extension CallBridge {
    /// Injected at document end in the main frame. Must not throw.
    static let scriptSource = BundledScript.calls.source
}
