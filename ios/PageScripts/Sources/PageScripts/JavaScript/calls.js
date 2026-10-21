(() => {
  const handler = window.webkit?.messageHandlers?.openTeamsCalls;
  if (!handler || window.__openTeamsCalls || window.opener) return;
  const post = (message) => {
    try { handler.postMessage(message); } catch { /* bridge unavailable */ }
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
      try { handleEvent(event); } catch { /* Teams internals changed */ }
    });
  };
  subscribe();
  setInterval(subscribe, 5000);

  // Microphone state, so the iOS call UI shows Teams' mute state. The
  // button's data-state is "mic-off" while muted; anything else starting
  // with "mic" is unmuted. Only a state that holds for a moment is
  // reported: a value seen mid-toggle, sent to CallKit and mirrored back,
  // would undo the user's change.
  const readMuted = () => {
    const state = document.getElementById("microphone-button")?.getAttribute("data-state") || "";
    if (state.includes("off")) return true;
    if (state.startsWith("mic")) return false;
    return null;
  };
  let lastMuted = null;
  let muteTimer = null;
  const reportMuted = () => {
    clearTimeout(muteTimer);
    muteTimer = setTimeout(() => {
      const muted = readMuted();
      if (muted === null || muted === lastMuted) return;
      lastMuted = muted;
      post({ type: "muted", muted });
    }, 500);
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
    const current = readMuted();
    if (current === null) return false;
    if (current !== muted) document.getElementById("microphone-button").click();
    return true;
  };

  Object.defineProperty(window, "__openTeamsCalls", {
    value: Object.freeze({ answer, decline, hangUp, setMuted, setRingtoneSuppressed }),
  });
})();
