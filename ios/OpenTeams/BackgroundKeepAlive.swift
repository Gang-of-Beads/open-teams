import AVFoundation
import UIKit
import WebKit

/// Keeps the Teams page running while the app is in the background so it can
/// keep receiving messages and raising notifications.
///
/// iOS suspends a WKWebView's web content process about a second after the
/// app leaves the foreground, which stops Teams' JavaScript and with it every
/// notification. WebKit keeps the process running while the page plays audio,
/// and the app declares the `audio` background mode (Config/Info.plist) so iOS
/// lets that playback, and the app, continue in the background. Playback has
/// to be running before the app is backgrounded; starting it afterwards is too
/// late.
///
/// The audio is a 30 Hz tone at -80 dBFS, inaudible but not digital silence,
/// which WebKit would detect and treat as "not playing". It is generated with
/// Web Audio and played through a MediaStream into an <audio> element:
/// - A plain <audio> clip registers with Now Playing, which puts a media player
///   on the lock screen and in Control Center.
/// - Plain Web Audio has no Now Playing entry, but WebKit interrupts its
///   AudioContext when the app goes to the background.
/// - MediaStream playback has neither problem: no Now Playing entry, and the
///   stream keeps playing in the background.
///
/// Anything that takes the audio session (a call, Siri, another app) can pause
/// the stream. If it stayed paused, iOS would suspend the page and
/// notifications would only arrive once the app was opened again, so playback
/// is resumed from several places: the page's own pause and state events, a
/// watchdog timer, visibility changes and, natively, app state and audio
/// session interruption notifications.
///
/// The audio session is mixable, so the tone never pauses music or podcasts
/// from other apps. The cost is battery: Teams keeps running.
final class BackgroundKeepAlive: NSObject {
    static let handlerName = "openTeamsKeepAlive"
    private weak var webView: WKWebView?
    private var observers: [NSObjectProtocol] = []
    /// Do not reconfigure the host session during WebKit/CallKit capture.
    var callInProgress = false
    private var lastBeat: Date?
    private static let lastBeatKey = "KeepAlive.lastBeat"
    private static let lastStateKey = "KeepAlive.lastAppState"

    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        contentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
    }

    /// Timestamped, content-free keep-alive evidence (state names only).
    static func log(_ message: String) {
        let time = Date().formatted(.iso8601.time(includingFractionalSeconds: false))
        print("[KEEPALIVE] \(time) \(message)")
    }

    private static func name(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    func start(webView: WKWebView) {
        self.webView = webView
        // Distinguishes a cold start after iOS killed the whole app from a
        // web process reload ([NAV] web content process terminated).
        let defaults = UserDefaults.standard
        if let previous = defaults.object(forKey: Self.lastBeatKey) as? Date {
            Self.log("launch; previous session's last heartbeat \(Int(Date().timeIntervalSince(previous)))s ago " +
                     "while \(defaults.string(forKey: Self.lastStateKey) ?? "unknown")")
        } else {
            Self.log("launch; no previous heartbeat")
        }
        activateAudioSession()

        let center = NotificationCenter.default
        let resumeOn: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            // Still running here; make sure playback is on before iOS decides
            // whether to suspend the app.
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        for name in resumeOn {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Self.log("\(name.rawValue.replacingOccurrences(of: "UIApplication", with: ""))")
                UserDefaults.standard.set(Self.name(UIApplication.shared.applicationState), forKey: Self.lastStateKey)
                self?.resume()
            })
        }
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let reason = (info?[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "-"
            Self.log("audio interruption \(rawType == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended") " +
                     "shouldResume=\(options.contains(.shouldResume)) reason=\(reason) call=\(self?.callInProgress ?? false)")
            if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                self?.activateAudioSession()
                self?.resume()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Self.log("audio route change reason=\(reason)")
        })
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            Self.log("memory warning app=\(Self.name(UIApplication.shared.applicationState))")
        })
        // The media server can restart (rare); the session must be set up again.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Self.log("media services reset")
            self?.activateAudioSession()
            self?.resume()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Puts the audio session back into mixable playback; CallManager calls
    /// this after a call, since CallKit may have interrupted it.
    func activateAudioSession() {
        guard !callInProgress else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[KEEPALIVE] Failed to configure the audio session: \(error.localizedDescription)")
        }
    }

    func resume() {
        webView?.evaluateJavaScript("window.__openTeamsKeepAlive?.resume(); undefined")
    }

    /// Records page heartbeats; logs gaps that indicate a suspended page.
    private func heartbeat(_ payload: [String: Any]) {
        let now = Date()
        let state = Self.name(UIApplication.shared.applicationState)
        if let lastBeat, now.timeIntervalSince(lastBeat) > 40 {
            Self.log("heartbeat gap \(Int(now.timeIntervalSince(lastBeat)))s app=\(state)")
        }
        let context = payload["context"] as? String ?? "?"
        let paused = payload["paused"] as? Bool ?? true
        if context != "running" || paused {
            Self.log("heartbeat audio context=\(context) paused=\(paused) app=\(state)")
        }
        lastBeat = now
        UserDefaults.standard.set(now, forKey: Self.lastBeatKey)
        UserDefaults.standard.set(state, forKey: Self.lastStateKey)
    }

    /// Injected at document end in the main frame of every page load.
    static let scriptSource = BundledScript.backgroundKeepAlive.source
}

extension BackgroundKeepAlive: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              TeamsConfig.isTrusted(URL(string: "\(origin.protocol)://\(origin.host)")),
              let payload = message.body as? [String: Any]
        else { return }
        heartbeat(payload)
    }
}
