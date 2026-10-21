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
    static let scriptSource = #"""
    (() => {
      const handler = window.webkit?.messageHandlers?.openTeamsCalls;
      if (!handler || window.__openTeamsCalls || window.opener) return;
      const post = (message) => {
        try { handler.postMessage(message); } catch (e) { /* bridge unavailable */ }
      };

      // crossClientScenarioName values of a ringing call (see activityHub.js).
      const RINGING_SCENARIOS = new Set([
        "incoming_call",
        "incoming_pstn_call",
        "incoming_call_queue_call",
        "conference_incoming_call_queue_call",
      ]);
      const isPhoneNumber = (value) => typeof value === "string" && /^\+?\d[\d\s().-]*$/.test(value.trim());

      let ringing = false;

      const handleEvent = (event) => {
        if (!["CommandStart", "ScenarioMarked"].includes(event?.type)) return;
        const context = event.context || {};
        if (!["internal-command-handler", "use-command-reporting-callbacks"].includes(context.target)) return;

        const options = context.entityCommand?.entityOptions;
        if (context.entityCommand) {
          if (!options?.isIncomingCall) return;
          if (RINGING_SCENARIOS.has(options.crossClientScenarioName)) {
            // A phone caller's title is the number and text their name, if
            // known; anyone else's title is their name.
            const number = isPhoneNumber(options.title) ? options.title.trim() : "";
            const name = number ? (options.text && !isPhoneNumber(options.text) ? options.text : "") : (options.title || "");
            ringing = true;
            setRingtoneSuppressed(true);
            post({ type: "incoming", name, number });
          } else if (ringing) {
            ringing = false;
            setRingtoneSuppressed(false);
            post({ type: "incomingEnded" });
          }
          return;
        }

        if (context.step === "calling-screen-rendered") {
          post({ type: "connected" });
          lastMuted = null;
          reportMuted();
        } else if (context.step === "render_disconected") {
          post({ type: "disconnected" });
        }
      };

      // Teams builds its services after the page loads and may rebuild them,
      // so keep looking and resubscribe when the service object changes.
      let subscribedTo = null;
      const subscribe = () => {
        const app = document.getElementById("app");
        const root = app?._reactRootContainer?._internalRoot || app?._reactRootContainer;
        const props = root?.current?.updateQueue?.baseState?.element?.props;
        const service = (props?.coreServices || props?.children?.props?.coreServices)?.commandChangeReportingService;
        if (!service || service === subscribedTo || typeof service.observeChanges !== "function") return;
        subscribedTo = service;
        service.observeChanges().subscribe((event) => {
          try { handleEvent(event); } catch (e) { /* Teams internals changed */ }
        });
      };
      subscribe();
      setInterval(subscribe, 5000);

      // Microphone state, so the iOS call UI shows Teams' mute state.
      let lastMuted = null;
      const reportMuted = () => {
        const mic = document.getElementById("microphone-button");
        if (!mic) return;
        const muted = mic.getAttribute("data-state") === "mic-off";
        if (muted === lastMuted) return;
        lastMuted = muted;
        post({ type: "muted", muted });
      };
      new MutationObserver(reportMuted).observe(document.documentElement, {
        subtree: true, attributes: true, attributeFilter: ["data-state"],
      });

      // Teams' ringtone. Ringtones play from a URL; call audio and the
      // keep-alive play MediaStreams (srcObject) and are never touched.
      let suppressRingtone = false;
      const mutedByUs = new Set();
      const recentlyPlayed = new Set();
      const silence = (element) => {
        if (element.srcObject || element.muted) return;
        element.muted = true;
        mutedByUs.add(element);
      };
      const originalPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function (...args) {
        if (!this.srcObject) {
          recentlyPlayed.add(this);
          if (recentlyPlayed.size > 20) recentlyPlayed.delete(recentlyPlayed.values().next().value);
          if (suppressRingtone) silence(this);
        }
        return originalPlay.apply(this, args);
      };
      function setRingtoneSuppressed(suppressed) {
        suppressRingtone = suppressed;
        if (suppressed) {
          for (const element of recentlyPlayed) if (!element.paused) silence(element);
        } else {
          for (const element of mutedByUs) element.muted = false;
          mutedByUs.clear();
        }
      }

      // Actions, run by native code.
      const incomingCallButtons = () => {
        const actions = document.querySelector('[data-testid="calling-actions"],[data-testid="msn-actions"]');
        return actions ? [...actions.querySelectorAll("button")] : [];
      };
      const answer = () => {
        // [video, audio, decline], or [accept, decline]; answer with audio.
        const buttons = incomingCallButtons();
        const button = buttons.length >= 3 ? buttons[1] : buttons.length === 2 ? buttons[0] : null;
        button?.click();
        return Boolean(button);
      };
      const decline = () => {
        const button = incomingCallButtons().at(-1);
        button?.click();
        return Boolean(button);
      };
      const hangUp = () => {
        const button = document.getElementById("hangup-button");
        button?.click();
        return Boolean(button);
      };
      const setMuted = (muted) => {
        const mic = document.getElementById("microphone-button");
        if (!mic) return false;
        if ((mic.getAttribute("data-state") === "mic-off") !== muted) mic.click();
        return true;
      };

      Object.defineProperty(window, "__openTeamsCalls", {
        value: Object.freeze({ answer, decline, hangUp, setMuted, setRingtoneSuppressed }),
      });
    })();
    """#
}
