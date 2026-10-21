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

  const visible = (element) => {
    if (!element || element.hidden || getComputedStyle(element).visibility === "hidden") return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.left < innerWidth;
  };
  const onScreen = (element) => {
    if (!visible(element)) return false;
    const rect = element.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < innerHeight;
  };
  const selectedApp = () => Object.entries(OPEN_TEAMS_APPS)
    .find(([, id]) => document.getElementById(id)?.getAttribute("aria-pressed") === "true")?.[0] || "more";
  const currentPage = () => {
    const root = document.querySelector('[role="main"]') || document.getElementById("app") || document;
    if ([...root.querySelectorAll('#hangup-button')].some(onScreen)) return "calls";
    // Activity can open a conversation without changing the app bar's
    // aria-pressed tile. Select the destination tab visually without issuing
    // another navigation or losing the conversation opened from the feed.
    if (selectedApp() === "activity" && [...root.querySelectorAll(
      '[data-tid^="chat-title-name"], [data-tid="chat-pane-list"], ' +
      '[data-tid="ckeditor"], [data-testid="chat-header"]'
    )].some(onScreen)) return "chat";
    return selectedApp();
  };

  let lastState = "";
  const report = () => {
    const entries = Object.entries(OPEN_TEAMS_APPS);
    const ready = entries.some(([, id]) => document.getElementById(id));
    const active = currentPage();
    const badges = Object.fromEntries(entries.map(([tab, id]) => [tab, unread(id)]));
    const back = Boolean(document.querySelector('[data-tid="layout-navigation-controls"]'));
    const theme = document.querySelector('meta[name="theme-color"]')?.content || "";
    const state = JSON.stringify({ ready, active, badges, back, theme });
    if (state === lastState) return;
    lastState = state;
    post({ type: "state", ready, active, badges, back, theme });
  };

  let lastContentChange = performance.now();
  let navigationGeneration = 0;

  // Coalesce Teams' frequent DOM changes into one report.
  let scheduled = false;
  const schedule = () => {
    lastContentChange = performance.now();
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; report(); }, 250);
  };
  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true,
    attributes: true, attributeFilter: ["aria-pressed", "aria-busy", "hidden", "style", "content"],
  });
  report();

  const click = (element) => {
    element?.click();
    return Boolean(element);
  };

  const select = (id, token = 0) => {
    const generation = ++navigationGeneration;
    const button = document.getElementById(id);
    // Leaving an Activity-owned conversation for the Activity feed is an
    // actual destination change (the native selected tab is Chat now), not
    // a generic 'reselect means back' rule for every tab.
    if (id === OPEN_TEAMS_APPS.activity && selectedApp() === "activity" && currentPage() === "chat") {
      click(document.querySelector('[data-tid="layout-navigation-controls"]'));
    }
    if (!click(button)) return false;
    const started = performance.now();
    const settle = () => {
      if (generation !== navigationGeneration) return;
      const now = performance.now();
      const root = document.querySelector('[role="main"]') || document.getElementById("app");
      const busy = root && [...root.querySelectorAll('[aria-busy="true"]')].some(visible);
      // Wait for transform-based slides, not perpetual spinners or opacity
      // animations. No Teams CSS or transition callbacks are modified.
      const sliding = root?.getAnimations?.({ subtree: true }).some((animation) =>
        animation.playState === "running" && animation.effect?.getKeyframes?.().some((frame) =>
          (frame.transform && frame.transform !== "none") || frame.translate
        )
      );
      if (now - started >= 180 && now - lastContentChange >= 120 &&
          OPEN_TEAMS_APPS[currentPage()] === id && !busy && !sliding) {
        post({ type: "navigationSettled", token });
      } else if (now - started < 1200) {
        setTimeout(settle, 50);
      }
    };
    setTimeout(settle, 180);
    return true;
  };

  let lastUnread = null;
  let focusGeneration = 0;
  const unreadMarker = (row) => row.matches('[data-is-unread="true"], [data-unread="true"]') ||
    Boolean(row.querySelector('[data-is-unread="true"], [data-unread="true"], ' +
      '[data-testid="unread-indicator"], [data-testid="unread-icon"], ' +
      '[data-tid="unread-indicator"], [data-tid="unread-badge"]'));
  const scrollContainer = (element) => {
    for (let parent = element; parent && parent !== document.body; parent = parent.parentElement) {
      if (/(auto|scroll|overlay)/.test(getComputedStyle(parent).overflowY) &&
          parent.scrollHeight > parent.clientHeight + 1) return parent;
    }
    return null;
  };
  const nextUnreadOrTop = (tree) => {
    const rows = [...tree.querySelectorAll('[role="treeitem"]')].filter((row) =>
      visible(row) && !row.querySelector('[role="treeitem"]') &&
      !row.hasAttribute("aria-expanded") && !row.matches('[data-testid^="sc-channel-list-item-"]')
    );
    const scroller = scrollContainer(rows[0] || tree);
    if (!scroller) return false;
    const candidates = rows.filter(unreadMarker);
    const key = (row) => row.getAttribute("data-chat-id") || row.getAttribute("data-itemid") || row.id || row;
    const previous = candidates.findIndex((row) => key(row) === lastUnread);
    const row = candidates.length ? candidates[(previous + 1) % candidates.length] : null;
    if (!row) {
      lastUnread = null;
      scroller.scrollTo({ top: 0, behavior: "auto" });
      return true;
    }
    lastUnread = key(row);
    const offset = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    scroller.scrollTo({ top: Math.max(0, scroller.scrollTop + offset - 12), behavior: "auto" });
    // A temporary outline, not focus/click: never opens a chat or marks it read.
    const previousOutline = row.style.outline;
    row.style.outline = "2px solid Highlight";
    setTimeout(() => { row.style.outline = previousOutline; }, 900);
    return true;
  };
  const focusNextUnread = () => {
    const generation = ++focusGeneration;
    if (currentPage() !== "chat") return;
    // A conversation opened from Activity still belongs to Activity's route;
    // explicitly enter Chat only for this list-navigation gesture.
    if (selectedApp() !== "chat") select(OPEN_TEAMS_APPS.chat);
    const started = performance.now();
    let returned = false;
    const locate = () => {
      if (generation !== focusGeneration) return;
      if (selectedApp() === "chat") {
        const back = document.querySelector('[data-tid="layout-navigation-controls"]');
        if (!returned && visible(back)) {
          returned = true;
          click(back);
        } else {
          const tree = [...document.querySelectorAll('[role="tree"]')].find(visible);
          if (tree && nextUnreadOrTop(tree)) return;
        }
      }
      if (performance.now() - started < 1400) setTimeout(locate, 100);
    };
    // Return-to-list is asynchronous; do not target a hidden detail pane.
    setTimeout(locate, 200);
  };

  Object.defineProperty(window, "__openTeamsShell", {
    value: Object.freeze({
      select: (id, token) => { focusGeneration++; return select(id, token); },
      focusNextUnread,
      openMore: () => click(document.querySelector('[data-tid="hamburger-button"]')),
      goBack: () => click(document.querySelector('[data-tid="layout-navigation-controls"]')),
      setNativeTabs: (shown) => { tabsStyle.disabled = !shown; },
    }),
  });
})();
