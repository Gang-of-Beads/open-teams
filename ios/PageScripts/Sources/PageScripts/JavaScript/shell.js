/* global OPEN_TEAMS_APPS */

(() => {
  const handler = window.webkit?.messageHandlers?.openTeamsShell;
  if (!handler || window.__openTeamsShell || window.opener) return;
  const post = (message) => {
    try { handler.postMessage(message); } catch { /* bridge unavailable */ }
  };

  // Web-only touch behaviour that native apps do not have.
  const style = document.createElement("style");
  style.textContent = `
    html { -webkit-tap-highlight-color: transparent; }
    button, [role="button"], [role="tab"], [role="treeitem"], [role="menuitem"], img {
      -webkit-touch-callout: none;
    }
  `;
  (document.head || document.documentElement).appendChild(style);

  // Teams' app bar button, hidden while the native tab bar replaces it.
  const tabsStyle = document.createElement("style");
  tabsStyle.textContent = `[data-tid="hamburger-button"] { display: none !important; }`;
  tabsStyle.disabled = true;
  (document.head || document.documentElement).appendChild(tabsStyle);

  const unread = (id) => {
    const match = /\d+/.exec(document.getElementById("readerBox-" + id)?.textContent || "");
    return match ? Number.parseInt(match[0], 10) : 0;
  };

  let lastState = "";
  const report = () => {
    const entries = Object.entries(OPEN_TEAMS_APPS);
    const ready = entries.some(([, id]) => document.getElementById(id));
    const active = entries.find(([, id]) => document.getElementById(id)?.getAttribute("aria-pressed") === "true")?.[0] || "more";
    const badges = Object.fromEntries(entries.map(([tab, id]) => [tab, unread(id)]));
    const back = Boolean(document.querySelector('[data-tid="layout-navigation-controls"]'));
    const theme = document.querySelector('meta[name="theme-color"]')?.content || "";
    const state = JSON.stringify({ ready, active, badges, back, theme });
    if (state === lastState) return;
    lastState = state;
    post({ type: "state", ready, active, badges, back, theme });
  };

  // Coalesce Teams' frequent DOM changes into one report.
  let scheduled = false;
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; report(); }, 250);
  };
  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true,
    attributes: true, attributeFilter: ["aria-pressed", "content"],
  });
  report();

  const click = (element) => {
    element?.click();
    return Boolean(element);
  };

  Object.defineProperty(window, "__openTeamsShell", {
    value: Object.freeze({
      select: (id) => click(document.getElementById(id)),
      openMore: () => click(document.querySelector('[data-tid="hamburger-button"]')),
      goBack: () => click(document.querySelector('[data-tid="layout-navigation-controls"]')),
      setNativeTabs: (shown) => { tabsStyle.disabled = !shown; },
    }),
  });
})();
