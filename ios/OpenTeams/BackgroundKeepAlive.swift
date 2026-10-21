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

    /// Set by CallManager while a call owns the audio session, so the
    /// keep-alive does not switch it back to mixable playback mid-call.
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
    /// this when a call releases it.
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
    static let scriptSource = #"""
    (() => {
      // Popups (sign-in, consent) share the scripts but do not need it.
      if (window.__openTeamsKeepAlive || window.opener) return;
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) return;

      let context = null;
      let element = null;

      const build = () => {
        context = new AudioContextClass();
        const oscillator = context.createOscillator();
        oscillator.frequency.value = 30;
        const gain = context.createGain();
        gain.gain.value = 0.0001; // -80 dBFS
        const destination = context.createMediaStreamDestination();
        oscillator.connect(gain);
        gain.connect(destination);
        oscillator.start();

        element = new Audio();
        element.srcObject = destination.stream;

        // Resume after anything that stops playback, without spinning: each
        // event schedules at most one retry.
        context.addEventListener("statechange", () => {
          if (context.state !== "running" && context.state !== "closed") setTimeout(resume, 1000);
        });
        element.addEventListener("pause", () => setTimeout(resume, 1000));
      };

      const resume = () => {
        if (!context) build();
        if (context.state !== "running") context.resume().catch(() => { /* retried later */ });
        if (element.paused) element.play().catch(() => { /* retried later */ });
      };

      Object.defineProperty(window, "__openTeamsKeepAlive", { value: Object.freeze({ resume }) });
      document.addEventListener("visibilitychange", resume);
      // Watchdog for pauses that raise no event; a no-op while playing.
      setInterval(resume, 15000);
      resume();
    })();
    """#
}
