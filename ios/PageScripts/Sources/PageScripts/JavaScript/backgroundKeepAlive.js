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

  // Heartbeat for the native side: a gap between beats means the page was
  // suspended. Audio state only; no page content.
  const beat = () => {
    try {
      window.webkit?.messageHandlers?.openTeamsKeepAlive?.postMessage({
        context: context?.state || "none", paused: element ? element.paused : true,
        visibility: document.visibilityState,
      });
    } catch { /* bridge unavailable */ }
  };

  Object.defineProperty(window, "__openTeamsKeepAlive", { value: Object.freeze({ resume }) });
  document.addEventListener("visibilitychange", resume);
  // Watchdog for pauses that raise no event; a no-op while playing.
  setInterval(() => { resume(); beat(); }, 15000);
  resume();
  beat();
})();
