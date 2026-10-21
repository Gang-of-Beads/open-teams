(() => {
  const handler = window.webkit?.messageHandlers?.openTeamsNotifications;
  if (!handler || window.__openTeamsNotifications) return;

  const post = (message) => {
    try { handler.postMessage(message); } catch { /* bridge unavailable */ }
  };

  // Notifications Teams may still click or close, oldest evicted first.
  const MAX_TRACKED = 50;
  const tracked = new Map();

  const dispatch = (stub, type) => {
    const event = new Event(type);
    // Teams' handlers read the notification from the event target.
    Object.defineProperty(event, "target", { value: stub });
    Object.defineProperty(event, "currentTarget", { value: stub });
    const handlers = [stub["on" + type], ...(stub._listeners[type] || [])];
    for (const fn of handlers) {
      if (typeof fn !== "function") continue;
      try { fn.call(stub, event); } catch { /* third-party handler */ }
    }
  };

  const MAX_ICON_BYTES = 300000;
  const iconDataURL = (src) => new Promise((resolve) => {
    if (typeof src !== "string" || !src) return resolve("");
    if (src.startsWith("data:")) return resolve(src.startsWith("data:image/") && src.length < MAX_ICON_BYTES * 1.4 ? src : "");
    const timer = setTimeout(() => resolve(""), 1500);
    const done = (value) => { clearTimeout(timer); resolve(value); };
    fetch(src, { credentials: "include" })
      .then((response) => (response.ok ? response.blob() : null))
      .then((blob) => {
        if (!blob || !blob.type.startsWith("image/") || blob.size > MAX_ICON_BYTES) return done("");
        const reader = new FileReader();
        reader.onload = () => done(String(reader.result));
        reader.onerror = () => done("");
        reader.readAsDataURL(blob);
      })
      .catch(() => done(""));
  });

  // A factory used with `new`: returning an object replaces `this`.
  function OpenTeamsNotification(title, options) {
    options = options || {};
    const id = crypto.randomUUID();
    const stub = {
      title: String(title ?? ""),
      body: String(options.body ?? ""),
      tag: String(options.tag ?? ""),
      icon: options.icon ?? "",
      data: options.data ?? null,
      silent: Boolean(options.silent),
      onclick: null, onclose: null, onerror: null, onshow: null,
      _listeners: {},
      _closed: false,
      addEventListener(type, listener) {
        (this._listeners[type] ||= []).push(listener);
      },
      removeEventListener(type, listener) {
        this._listeners[type] = (this._listeners[type] || []).filter((l) => l !== listener);
      },
      dispatchEvent() { return true; },
      close() {
        if (this._closed) return;
        this._closed = true;
        post({ type: "close", id });
        dispatch(this, "close");
      },
    };

    tracked.set(id, stub);
    while (tracked.size > MAX_TRACKED) tracked.delete(tracked.keys().next().value);

    // The picture is fetched here, where Teams' cookies and blob: URLs
    // work, and handed over as a data URL. Never hold the notification up
    // for more than a moment.
    iconDataURL(options.icon).then((icon) => {
      if (stub._closed) return;
      post({ type: "show", id, title: stub.title, body: stub.body, tag: stub.tag, silent: stub.silent, icon });
    });
    setTimeout(() => dispatch(stub, "show"), 0);
    return stub;
  }

  Object.defineProperty(OpenTeamsNotification, "permission", { get: () => "granted" });
  OpenTeamsNotification.requestPermission = (callback) => {
    if (typeof callback === "function") callback("granted");
    return Promise.resolve("granted");
  };
  OpenTeamsNotification.maxActions = 0;

  try {
    Object.defineProperty(window, "Notification", {
      value: OpenTeamsNotification, writable: true, configurable: true,
    });
  } catch {
    window.Notification = OpenTeamsNotification;
  }

  Object.defineProperty(window, "__openTeamsNotifications", {
    value: Object.freeze({
      click(id) {
        const stub = tracked.get(id);
        if (stub) dispatch(stub, "click");
      },
    }),
  });

  // Unread count: Teams prefixes the title with "(N)", as the desktop
  // app's mutationTitle.js relies on.
  let lastCount = -1;
  const reportCount = () => {
    const match = /^\((\d+)\)/.exec(document.title || "");
    const count = match ? Number.parseInt(match[1], 10) : 0;
    if (count === lastCount) return;
    lastCount = count;
    post({ type: "badge", count });
  };
  const observeTitle = () => {
    reportCount();
    new MutationObserver(reportCount).observe(document.head || document.documentElement, {
      subtree: true, childList: true, characterData: true,
    });
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", observeTitle, { once: true });
  } else {
    observeTitle();
  }
})();
