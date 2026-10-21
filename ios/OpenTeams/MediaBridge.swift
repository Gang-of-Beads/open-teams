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

    static let scriptSource = #"""
    (() => {
      const host = location.hostname;
      if (!(host === "teams.cloud.microsoft" || host === "teams.microsoft.com" ||
            host.endsWith(".teams.microsoft.com")) || window.__openTeamsMedia) return;
      Object.defineProperty(window, "__openTeamsMedia", { value: true });
      const patched = new WeakSet();
      const patchTrack = (track) => {
        if (track.kind !== "audio" || patched.has(track)) return;
        patched.add(track);
        // Desktop ignoreSystemMute.js: do not let OS capture interruptions
        // toggle Teams' own mute button. This does not unmute any audio.
        try {
          Object.defineProperty(track, "muted", { configurable: true, get: () => false });
          for (const prop of ["onmute", "onunmute"]) {
            Object.defineProperty(track, prop, { configurable: true, get: () => null, set: () => {} });
          }
          const add = track.addEventListener;
          track.addEventListener = function (type, listener, options) {
            if (type !== "mute" && type !== "unmute") return add.call(this, type, listener, options);
          };
          // Cloned local capture tracks must have the same protection.
          const clone = track.clone;
          track.clone = function () { const copy = clone.call(this); patchTrack(copy); return copy; };
        } catch (_) { console.warn("[MEDIA] Local mute protection unavailable"); }
      };
      const patchStream = (stream) => { stream.getAudioTracks().forEach(patchTrack); return stream; };
      const devices = navigator.mediaDevices;
      if (devices?.getUserMedia) {
        const capture = devices.getUserMedia;
        devices.getUserMedia = function (...args) { return capture.apply(this, args).then(patchStream); };
      }
      for (const key of ["getUserMedia", "webkitGetUserMedia"]) {
        const capture = navigator[key];
        if (!capture) continue;
        navigator[key] = function (constraints, success, failure) {
          return capture.call(this, constraints, (stream) => success(patchStream(stream)), failure);
        };
      }

      // Native screen wakefulness uses actual WebRTC connections, not merely
      // the presence of Teams' calling screen. Failed/closed connections are
      // removed immediately; disconnected is given a reconnection grace period.
      const peers = new Set();
      const disconnectedAt = new WeakMap();
      let last = false;
      const report = () => {
        const now = Date.now();
        let active = false;
        for (const pc of peers) {
          if (["closed", "failed"].includes(pc.connectionState) || pc.signalingState === "closed") {
            peers.delete(pc);
            continue;
          }
          if (pc.connectionState === "disconnected") {
            if (!disconnectedAt.has(pc)) disconnectedAt.set(pc, now);
          } else {
            disconnectedAt.delete(pc);
          }
          const live = pc.connectionState === "connected" ||
            (pc.connectionState === "disconnected" && now - disconnectedAt.get(pc) < 15000);
          const audio = [...pc.getSenders(), ...pc.getReceivers()]
            .some((s) => s.track?.kind === "audio" && s.track.readyState === "live");
          if (live && audio) active = true;
        }
        if (last === active) return;
        last = active;
        try { window.webkit.messageHandlers.openTeamsMedia.postMessage({ active }); } catch (_) {}
      };
      const Original = window.RTCPeerConnection;
      if (Original) {
        window.RTCPeerConnection = new Proxy(Original, {
          construct(target, args) {
            const pc = Reflect.construct(target, args);
            peers.add(pc);
            for (const event of ["connectionstatechange", "signalingstatechange", "track"]) pc.addEventListener(event, report);
            return pc;
          },
        });
        setInterval(report, 2000);
      }
    })();
    """#
}
