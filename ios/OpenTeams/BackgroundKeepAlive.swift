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
final class BackgroundKeepAlive {
    private weak var webView: WKWebView?
    private var observers: [NSObjectProtocol] = []
    /// Do not reconfigure the host session during WebKit/CallKit capture.
    var callInProgress = false

    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    func start(webView: WKWebView) {
        self.webView = webView
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
                self?.resume()
            })
        }
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                self?.activateAudioSession()
                self?.resume()
            }
        })
        // The media server can restart (rare); the session must be set up again.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
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

    /// Injected at document end in the main frame of every page load.
    static let scriptSource = BundledScript.backgroundKeepAlive.source
}
