/* global OPEN_TEAMS_APPS, OPEN_TEAMS_OPTIONS */

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
    /* Measured on device: on an app switch Teams' narrow layout slides the
       list panes in from the left (Activity's sub-nav from x=-470 over
       ~430 ms, Chat's mid-nav from x=-2600), dropping frames while the new
       app renders. Only during a native tab switch, show them in place. The
       panes' state classes are hashed, so this is scoped by time instead;
       Teams' in-app list/detail transitions are left untouched. */
    html.open-teams-switching :is([data-tid="app-layout-area--sub-nav"],
                                  [data-tid="app-layout-area--mid-nav"]) {
      transition: none !important;
      transform: none !important;
    }
  `;
  (document.head || document.documentElement).appendChild(style);

  // One tap, one action. On touch, WebKit first sends synthetic hover events
  // (mouseover/mouseenter/mousemove); Teams' desktop layout reacts by adding
  // the row's "..." menu button, and WebKit then treats any hover-triggered
  // page change as "show hover content" and drops the click (verified on
  // device: no mousedown/mouseup/click on the first tap). Finger-generated
  // hover events are not delivered to Teams; clicks, focus and pointer
  // events are. A real mouse or trackpad (iPad) still gets hover.
  //
  // A message's action bar (quick reactions, Reply/quote, "...") opens when a
  // tap focuses the message, as a popover on <body>. Inside it hover is
  // delivered as on desktop. iOS does not focus a tapped button, so mousedown
  // there moved focus from the message to <body>; Teams closed the bar on
  // that focusout and the click never came (verified on device). Preventing
  // that mousedown keeps focus on the message; the click still follows.
  const inActionBar = (target) => Boolean(target?.closest?.('[data-tid="message-actions-container"]'));
  let touchPointer = false;
  for (const type of ["pointerover", "pointerdown"]) {
    addEventListener(type, (event) => { touchPointer = event.pointerType === "touch"; }, true);
  }
  addEventListener("mousedown", (event) => {
    if (touchPointer && inActionBar(event.target)) event.preventDefault();
  }, true);
  for (const type of ["mouseover", "mouseenter", "mousemove", "mouseout", "mouseleave"]) {
    addEventListener(type, (event) => {
      if (touchPointer && !inActionBar(event.target)) event.stopImmediatePropagation();
    }, true);
  }

  // WebKit can still hold the click for its "hover first" heuristic when
  // CSS hover/focus styles change the row (verified on device: touchend,
  // then no mousedown/click; a second tap on the same row clicks). For a
  // clean single tap that WebKit did not click within 90 ms (its own click
  // arrives 35-60 ms after touchend), click the tapped element. A late
  // native click for the same tap is swallowed, so nothing activates twice.
  // Excluded: moves, long presses, text fields, prevented touches, and taps
  // that stop a list still coasting from a vertical fling (iOS does not
  // click those either). A horizontal swipe back is not a fling.
  let tap = null;
  let flingTarget = null;
  let flingScrolledAt = 0;
  let flingTop = 0;
  const scrollTop = (target) => (target === document ? document.scrollingElement?.scrollTop : target.scrollTop) || 0;
  addEventListener("scroll", (event) => {
    if (tap?.vertical) flingTarget = event.target;
    if (event.target !== flingTarget) return;
    const top = scrollTop(event.target);
    if (Math.abs(top - flingTop) > 0.5) flingScrolledAt = performance.now();
    flingTop = top;
  }, { capture: true, passive: true });
  addEventListener("touchstart", (event) => {
    if (event.touches.length !== 1) { tap = null; return; }
    const touch = event.touches[0];
    tap = {
      x: touch.clientX, y: touch.clientY, started: performance.now(), target: event.target,
      moved: false, vertical: false, clicked: false, synthesized: false,
      coasting: performance.now() - flingScrolledAt < 80,
    };
  }, { capture: true, passive: true });
  addEventListener("touchmove", (event) => {
    if (!tap) return;
    const touch = event.touches[0];
    const dx = touch.clientX - tap.x;
    const dy = touch.clientY - tap.y;
    if (Math.hypot(dx, dy) <= 10) return;
    tap.moved = true;
    if (Math.abs(dy) > Math.abs(dx)) tap.vertical = true;
  }, { capture: true, passive: true });
  addEventListener("touchcancel", () => { tap = null; }, true);
  for (const type of ["mousedown", "mouseup", "click"]) {
    addEventListener(type, (event) => {
      if (!tap || !event.isTrusted) return;
      if (tap.synthesized) {
        event.stopImmediatePropagation();
        event.preventDefault();
      } else {
        tap.clicked = true;
      }
    }, true);
  }
  addEventListener("touchend", (event) => {
    const current = tap;
    if (!current || event.defaultPrevented || current.moved || current.coasting ||
        performance.now() - current.started > 500 ||
        current.target.closest?.("input, textarea, select, [contenteditable]")) return;
    setTimeout(() => {
      // Only the element that was actually tapped. If Teams re-rendered it
      // meanwhile, do nothing: whatever is at that point now (another row, a
      // banner that just appeared) is not what the user touched.
      if (current.clicked || tap !== current || !current.target.isConnected) return;
      current.synthesized = true;
      // SVG icons have no click(); a bubbling click reaches Teams' handlers.
      current.target.dispatchEvent(new MouseEvent("click", {
        bubbles: true, cancelable: true, composed: true, view: window,
        clientX: current.x, clientY: current.y, detail: 1,
      }));
    }, 90);
  }, true);

  let switchTimer = 0;
  const markSwitching = () => {
    document.documentElement.classList.add("open-teams-switching");
    clearTimeout(switchTimer);
    switchTimer = setTimeout(() => document.documentElement.classList.remove("open-teams-switching"), 1200);
  };

  // Teams' app bar button duplicates the native More tab, so it is hidden
  // while the native tab bar is shown. Clicking it still works when hidden.
  const tabsStyle = document.createElement("style");
  tabsStyle.textContent = `[data-tid="hamburger-button"] { display: none !important; }`;
  tabsStyle.disabled = true;
  (document.head || document.documentElement).appendChild(tabsStyle);
  const appBarButton = () => document.querySelector(
    '[data-tid="hamburger-button"], [data-testid="hamburger-button"]'
  );
  let lastApp = "chat";
  let shellReady = false;
  let pendingDestination = null;
  const lastBadges = {};

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
  // Activity keeps the last item's conversation mounted under its list, so
  // geometry alone reports it on screen. Require it to be topmost.
  const uncovered = (element) => {
    if (!onScreen(element)) return false;
    const rect = element.getBoundingClientRect();
    const x = Math.min(Math.max(rect.left + rect.width / 2, 0), innerWidth - 1);
    const y = Math.min(Math.max(rect.top + rect.height / 2, 0), innerHeight - 1);
    const top = document.elementFromPoint(x, y);
    return Boolean(top && (element.contains(top) || top.contains(element)));
  };
  const selectedApp = () => {
    const selected = Object.entries(OPEN_TEAMS_APPS)
      .find(([, id]) => document.getElementById(id)?.getAttribute("aria-pressed") === "true")?.[0];
    // A closed/collapsed app bar can unmount all its tiles. Absence is not
    // evidence that the user navigated to More.
    if (pendingDestination && performance.now() < pendingDestination.until) return pendingDestination.tab;
    pendingDestination = null;
    if (selected) lastApp = selected;
    return lastApp;
  };
  document.addEventListener("click", (event) => {
    const tile = event.target?.closest?.('[data-is-launch-tile="true"]');
    if (!tile) return;
    const tab = Object.entries(OPEN_TEAMS_APPS).find(([, id]) =>
      tile.id === id || tile.getAttribute("data-tid") === id
    )?.[0] || "more";
    lastApp = tab;
    pendingDestination = { tab, until: performance.now() + 1200 };
  }, true);
  const currentPage = () => {
    const root = document.querySelector('[role="main"]') || document.getElementById("app") || document;
    if ([...root.querySelectorAll('#hangup-button')].some(uncovered)) return "calls";
    // Activity can open a conversation without changing the app bar's
    // aria-pressed tile. Select the destination tab visually without issuing
    // another navigation or losing the conversation opened from the feed.
    if (selectedApp() === "activity" && [...root.querySelectorAll(
      '[data-tid^="chat-title-name"], [data-tid="chat-pane-list"], ' +
      '[data-tid="ckeditor"], [data-testid="chat-header"]'
    )].some(uncovered)) return "chat";
    return selectedApp();
  };

  let lastState = "";
  // After a cold load Teams' narrow layout reopens the last conversation
  // instead of the list. Return to the list once, unless the conversation
  // was opened on purpose: a notification tap, or any touch before it.
  const loadedAt = performance.now();
  let startListPending = true;
  document.addEventListener("openteams:notification-open", () => { startListPending = false; });
  addEventListener("pointerdown", (event) => { if (event.isTrusted) startListPending = false; }, true);
  const returnToListAfterLoad = () => {
    if (!startListPending) return;
    if (performance.now() - loadedAt > 20000) { startListPending = false; return; }
    const back = document.querySelector('[data-tid="layout-navigation-controls"]');
    if (selectedApp() === "chat" && back && visible(back)) {
      startListPending = false;
      back.click();
    }
  };

  // Teams' "We need you to sign in again" banner (verified data-tid). Its
  // Sign in button retries silent renewal in a hidden login frame, which
  // fails while WebKit blocks that frame's cookies; the native side
  // explains how to allow it.
  let authReported = false;
  const reportAuthBanner = () => {
    if (authReported || !document.querySelector('[data-tid^="banner-notification-action-auth-banner"]')) return;
    authReported = true;
    post({ type: "authRequired" });
  };

  const report = () => {
    returnToListAfterLoad();
    reportAuthBanner();
    const entries = Object.entries(OPEN_TEAMS_APPS);
    shellReady ||= entries.some(([, id]) => document.getElementById(id)) ||
      Boolean(document.querySelector('[data-tid="me-control-avatar-trigger"], [data-testid="me-control-avatar-trigger"]'));
    const ready = shellReady;
    const active = pendingDestination && performance.now() < pendingDestination.until
      ? pendingDestination.tab : currentPage();
    const badges = Object.fromEntries(entries.map(([tab, id]) => {
      // A mounted tile without a count element has no unread items: Teams
      // can remove readerBox-<id> when the count drops to 0. Only a tile
      // that is absent entirely (app bar unmounted) keeps the last count.
      if (document.getElementById(id)) lastBadges[tab] = unread(id);
      return [tab, lastBadges[tab] || 0];
    }));
    const back = Boolean(document.querySelector('[data-tid="layout-navigation-controls"]'));
    const theme = document.querySelector('meta[name="theme-color"]')?.content || "";
    const state = JSON.stringify({ ready, active, badges, back, theme });
    if (state === lastState) return;
    lastState = state;
    post({ type: "state", ready, active, badges, back, theme });
  };

  let navigationGeneration = 0;

  // Measured on device (WebContent physical footprint): observing the whole
  // document (subtree, childList, characterData) cost ~370 MB, because Teams
  // mutates the DOM constantly and every burst ran a layout-reading report.
  // The reported state changes rarely, so poll a few elements instead while
  // the page is visible, and report at once on visibility changes and
  // native actions. Nothing runs while the page is hidden.
  if ((typeof OPEN_TEAMS_OPTIONS === "object" && OPEN_TEAMS_OPTIONS.legacyShell)) {
    let scheduled = false;
    new MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      setTimeout(() => { scheduled = false; report(); }, 250);
    }).observe(document.documentElement, {
      subtree: true, childList: true, characterData: true,
      attributes: true, attributeFilter: ["aria-pressed", "content"],
    });
  } else {
    setInterval(() => { if (document.visibilityState === "visible") report(); }, 500);
    document.addEventListener("visibilitychange", report);
    // A tap inside Teams (opening a chat, going back) shows up promptly.
    document.addEventListener("click", () => setTimeout(report, 150), true);
  }
  report();

  const click = (element) => {
    element?.click();
    return Boolean(element);
  };

  const select = (id) => {
    const generation = ++navigationGeneration;
    const tab = Object.entries(OPEN_TEAMS_APPS).find(([, value]) => value === id)?.[0];
    if (!tab) return false;
    const started = performance.now();
    let expanded = false;
    const attempt = () => {
      if (generation !== navigationGeneration) return;
      const button = document.getElementById(id) || document.querySelector('[data-tid="' + id + '"]');
      if (button) {
        if (tab === "activity" && selectedApp() === "activity" && currentPage() === "chat") {
          click(document.querySelector('[data-tid="layout-navigation-controls"]'));
        }
        markSwitching();
        click(button);
        lastApp = tab;
        pendingDestination = { tab, until: performance.now() + 1200 };
        report();
        post({ type: "navigationResult", tab, dispatched: true });
        setTimeout(report, 1250);
        return;
      }
      if (!expanded) {
        expanded = true;
        click(appBarButton());
      }
      if (performance.now() - started < 900) {
        setTimeout(attempt, 50);
      } else {
        // Do not silently select a tab whose command was never dispatched,
        // and close the app bar this attempt opened (the button toggles it)
        // instead of leaving it over the page.
        if (expanded) click(appBarButton());
        post({ type: "navigationResult", tab, dispatched: false });
        lastState = "";
        report();
      }
    };
    attempt();
    return true;
  };

  let lastUnread = null;
  let focusGeneration = 0;
  // Verified on device: Teams marks an unread chat/channel row only for
  // screen readers. Its aria-labelledby references a shared hidden label
  // (chat_list_unread_text, simple_collab_voiceover_unread_message,
  // channel-list-unread-text). The ids are locale-independent; no text,
  // bold styling or hashed class names are used.
  const unreadMarker = (row) => (row.getAttribute("aria-labelledby") || "").split(/\s+/)
    .some((id) => id && /unread/i.test(id) && document.getElementById(id));
  const scrollContainer = (element) => {
    for (let parent = element; parent && parent !== document.body; parent = parent.parentElement) {
      if (/(auto|scroll|overlay)/.test(getComputedStyle(parent).overflowY) &&
          parent.scrollHeight > parent.clientHeight + 1) return parent;
    }
    return null;
  };
  const nextUnreadOrTop = (tree) => {
    // Conversations only (chats and channels): not section headers, Quick
    // views (data-item-type=slice) or Copilot.
    const rows = [...tree.querySelectorAll('[role="treeitem"]')].filter((row) =>
      visible(row) && !row.querySelector('[role="treeitem"]') && !row.hasAttribute("aria-expanded") &&
      row.getAttribute("data-item-type") !== "slice" && !row.matches('[data-testid^="list-item-metaos"]')
    );
    const scroller = scrollContainer(rows[0] || tree);
    if (!scroller) return false;
    const candidates = rows.filter(unreadMarker);
    // Stable conversation key; element ids are regenerated on re-render.
    const key = (row) => row.getAttribute("data-fui-tree-item-value") || row.id || row;
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
          // The chat list lives in the mid-nav pane; never pick a tree from
          // another app that is still mounted (Activity's list).
          const pane = document.querySelector('[data-tid="app-layout-area--mid-nav"]') || document;
          const tree = [...pane.querySelectorAll('[role="tree"]')].find(visible);
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
      select: (id) => { focusGeneration++; return select(id); },
      focusNextUnread,
      openMore: () => { navigationGeneration++; focusGeneration++; return click(appBarButton()); },
      goBack: () => click(document.querySelector('[data-tid="layout-navigation-controls"]')),
      setNativeTabs: (shown) => { tabsStyle.disabled = !shown; },
    }),
  });
})();
