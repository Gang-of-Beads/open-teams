/* global OPEN_TEAMS_APPS */

// Debug builds only. Reports timing and structural metadata (element tag,
// data-tid/testid, role, class prefix, animation names/durations). It never
// reports text, names, URLs, titles or message content.
(() => {
  const handler = window.webkit?.messageHandlers?.openTeamsShell;
  if (!handler || window.opener || window.__openTeamsDiagnostics) return;
  const post = (event, data) => {
    try { handler.postMessage({ type: "diagnostic", event, data: JSON.stringify(data) }); } catch { /* bridge unavailable */ }
  };

  const navigation = performance.getEntriesByType?.("navigation")?.[0];
  post("document", { type: navigation?.type || "unknown", visibility: document.visibilityState });
  addEventListener("beforeunload", () => post("beforeunload", { visibility: document.visibilityState }));
  addEventListener("pagehide", (event) => post("pagehide", { persisted: event.persisted }));

  const describe = (element) => {
    if (!element?.tagName) return "";
    const id = element.getAttribute("data-tid") || element.getAttribute("data-testid") || "";
    const className = String(element.className?.baseVal ?? element.className ?? "").split(/\s+/).slice(0, 2).join(".");
    return [element.tagName.toLowerCase(), id, element.getAttribute("role") || "", className].join("|");
  };

  let traceGeneration = 0;
  const trace = (tab, nativeTapMs) => {
    const generation = ++traceGeneration;
    const start = performance.now();
    const dispatchDelayMs = Math.round(Date.now() - nativeTapMs);
    const id = OPEN_TEAMS_APPS[tab];
    let last = start;
    let worstFrameMs = 0;
    let slowFrames = 0;
    let frames = 0;
    let selectedMs = null;
    let lastMutationMs = 0;
    let mutations = 0;
    const animations = new Map();

    // Light: childList and aria-pressed only. Observing style/class during
    // Teams' rendering would itself slow the switch being measured.
    const observer = new MutationObserver((records) => {
      lastMutationMs = performance.now() - start;
      mutations += records.length;
    });
    observer.observe(document.documentElement, {
      subtree: true, childList: true, attributes: true, attributeFilter: ["aria-pressed"],
    });

    let lastSample = -Infinity;
    const frame = (now) => {
      if (generation !== traceGeneration) { observer.disconnect(); return; }
      const gap = now - last;
      last = now;
      frames++;
      worstFrameMs = Math.max(worstFrameMs, gap);
      if (gap > 34) slowFrames++;
      if (selectedMs === null && document.getElementById(id)?.getAttribute("aria-pressed") === "true") {
        selectedMs = Math.round(now - start);
      }
      if (now - lastSample >= 250) {
        lastSample = now;
        for (const animation of document.getAnimations?.() || []) {
          const target = animation.effect?.target;
          const name = animation.animationName || animation.transitionProperty || animation.id || animation.constructor.name;
          const key = describe(target) + "#" + name;
          if (animations.has(key)) continue;
          const timing = animation.effect?.getTiming?.() || {};
          animations.set(key, {
            target: describe(target), name,
            durationMs: typeof timing.duration === "number" ? Math.round(timing.duration) : String(timing.duration),
            delayMs: Math.round(timing.delay || 0),
            seenAtMs: Math.round(now - start),
          });
        }
      }
      if (now - start < 2500) {
        requestAnimationFrame(frame);
        return;
      }
      observer.disconnect();
      post("tab", {
        tab, dispatchDelayMs, selectedMs, frames, worstFrameMs: Math.round(worstFrameMs), slowFrames,
        mutations, lastMutationMs: Math.round(lastMutationMs),
        animations: [...animations.values()].slice(0, 20),
      });
    };
    requestAnimationFrame(frame);
  };

  Object.defineProperty(window, "__openTeamsDiagnostics", { value: Object.freeze({ trace }) });
})();
