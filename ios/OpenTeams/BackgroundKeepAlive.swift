import AVFoundation
import UIKit
import WebKit

/// Keeps the Teams page running while the app is in the background so it can
/// keep receiving messages and raising notifications.
///
/// iOS suspends a WKWebView's web content process about a second after the
/// app leaves the foreground, which stops Teams' JavaScript and with it every
/// notification. WebKit keeps the process running while the page plays media,
/// so the page loops a generated, silent WAV clip, and the app declares the
/// `audio` background mode (Config/Info.plist) so iOS lets that playback, and
/// the app, continue in the background. Playback has to be running before the
/// app is backgrounded; starting it afterwards is too late.
///
/// The audio session is mixable, so the silent clip does not pause music or
/// podcasts from other apps. The cost is battery: Teams keeps running.
final class BackgroundKeepAlive {
    private weak var webView: WKWebView?
    private var observers: [NSObjectProtocol] = []

    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    func start(webView: WKWebView) {
        self.webView = webView
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        } catch {
            print("[KEEPALIVE] Failed to configure the audio session: \(error.localizedDescription)")
        }

        let center = NotificationCenter.default
        // Playback can be paused by the system, for example by a phone call or
        // another app taking the audio session; resume when we get it back.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resume() })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                self?.resume()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func resume() {
        webView?.evaluateJavaScript("window.__openTeamsKeepAlive?.resume(); undefined")
    }

    /// Injected at document end in the main frame of every page load.
    static let scriptSource = #"""
    (() => {
      // Popups (sign-in, consent) share the scripts but do not need it.
      if (window.__openTeamsKeepAlive || window.opener) return;

      // One second of 8 kHz, 8-bit mono silence (128 is the zero level).
      const rate = 8000;
      const buffer = new ArrayBuffer(44 + rate);
      const view = new DataView(buffer);
      const ascii = (offset, text) => {
        for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
      };
      ascii(0, "RIFF"); view.setUint32(4, 36 + rate, true); ascii(8, "WAVE");
      ascii(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
      view.setUint16(22, 1, true); view.setUint32(24, rate, true); view.setUint32(28, rate, true);
      view.setUint16(32, 1, true); view.setUint16(34, 8, true);
      ascii(36, "data"); view.setUint32(40, rate, true);
      for (let i = 0; i < rate; i++) view.setUint8(44 + i, 128);

      const audio = new Audio(URL.createObjectURL(new Blob([buffer], { type: "audio/wav" })));
      audio.loop = true;

      const resume = () => {
        if (!audio.paused) return;
        audio.play().catch(() => { /* retried on the next resume */ });
      };

      Object.defineProperty(window, "__openTeamsKeepAlive", { value: Object.freeze({ resume }) });
      resume();
    })();
    """#
}
