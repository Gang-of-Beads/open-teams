/* global __otModules */
// Android counterpart of app/browser/preload.js. The Gradle task
// bundleOpenTeamsPreload wraps this file and the reused open-teams modules
// (`__otModules`) in one function, injected at document start on Teams origins
// only (see TeamsWebView.kt). `OpenTeamsNative` is the WebMessage listener the
// app registers for the same origins; nothing here is exposed to other sites.

if (globalThis.top !== globalThis || globalThis.__openTeams || !globalThis.OpenTeamsNative) {
  return;
}

const nativePort = globalThis.OpenTeamsNative;
const listeners = new Map();
const pendingInvokes = new Map();
let nextInvokeId = 1;
let frameHandler = null;

const post = (message) => nativePort.postMessage(JSON.stringify(message));

function emit(channel, args) {
  for (const listener of [...(listeners.get(channel) ?? [])]) {
    try {
      listener({}, ...args);
    } catch (err) {
      console.error(`[OpenTeams] listener for ${channel} failed`, err);
    }
  }
}

nativePort.onmessage = (event) => {
  // Screen-share frames arrive as raw JPEG bytes; everything else is JSON.
  if (event.data instanceof ArrayBuffer) {
    frameHandler?.(event.data);
    return;
  }
  const message = JSON.parse(event.data);
  if (message.type === "reply") {
    pendingInvokes.get(message.id)?.(message.result);
    pendingInvokes.delete(message.id);
  } else if (message.type === "event") {
    emit(message.channel, message.args ?? []);
  }
};

// The subset of Electron's ipcRenderer the reused modules call.
const ipcRenderer = {
  send: (channel, ...args) => post({ type: "send", channel, args }),
  invoke: (channel, ...args) =>
    new Promise((resolve) => {
      const id = nextInvokeId++;
      pendingInvokes.set(id, resolve);
      post({ type: "invoke", id, channel, args });
    }),
  on(channel, listener) {
    if (!listeners.has(channel)) {
      listeners.set(channel, []);
    }
    listeners.get(channel).push(listener);
    return ipcRenderer;
  },
  once(channel, listener) {
    const wrapped = (...args) => {
      ipcRenderer.removeListener(channel, wrapped);
      listener(...args);
    };
    return ipcRenderer.on(channel, wrapped);
  },
  removeListener(channel, listener) {
    const list = listeners.get(channel) ?? [];
    const index = list.indexOf(listener);
    if (index > -1) {
      list.splice(index, 1);
    }
    return ipcRenderer;
  },
};

// --- CommonJS loader for the bundled open-teams modules -------------------

const electronShim = {
  ipcRenderer,
  // tokenCache.js falls back to localStorage when encryption is unavailable.
  safeStorage: { isEncryptionAvailable: () => false },
};
const processShim = { platform: "android", env: {}, versions: {} };
const moduleCache = new Map();

function resolveModule(fromId, spec) {
  const parts = fromId.split("/").slice(0, -1);
  for (const segment of spec.split("/")) {
    if (segment === "..") {
      parts.pop();
    } else if (segment !== ".") {
      parts.push(segment);
    }
  }
  const id = parts.join("/");
  return id.endsWith(".js") ? id : `${id}.js`;
}

function load(id) {
  if (moduleCache.has(id)) {
    return moduleCache.get(id).exports;
  }
  const factory = __otModules[id];
  if (!factory) {
    throw new Error(`open-teams module not bundled: ${id}`);
  }
  const module = { exports: {} };
  moduleCache.set(id, module);
  const localRequire = (spec) => (spec === "electron" ? electronShim : load(resolveModule(id, spec)));
  factory(module, module.exports, localRequire, processShim);
  return module.exports;
}

// --- Notifications ---------------------------------------------------------
// WebView has no Notification API. Like preload.js's "electron" method, hand
// Teams a lifecycle stub and show the notification natively; clicks come back
// through open-teams' NotificationBridge so Teams opens the conversation.

const NotificationBridge = load("browser/notifications/notificationBridge.js");
const notificationBridge = new NotificationBridge(ipcRenderer);

function createNotificationStub() {
  const stub = {
    onclick: null,
    onclose: null,
    onerror: null,
    onshow: null,
    addEventListener(type, listener) {
      stub[`on${type}`] = listener;
    },
    removeEventListener(type, listener) {
      if (!listener || stub[`on${type}`] === listener) {
        stub[`on${type}`] = null;
      }
    },
    dispatchEvent: () => true,
  };
  setTimeout(() => stub.onshow?.(), 0);
  return stub;
}

function AndroidNotification(title, options = {}) {
  const notificationId = crypto.randomUUID();
  const stub = createNotificationStub();
  notificationBridge.register(notificationId, stub);
  stub.close = () => notificationBridge.close(notificationId);
  const icon = typeof options.icon === "string" && options.icon.startsWith("data:image/") ? options.icon : null;
  ipcRenderer.invoke("show-notification", {
    notificationId,
    title: String(title ?? ""),
    body: String(options.body ?? ""),
    tag: options.tag ? String(options.tag) : null,
    icon,
  });
  return stub;
}
AndroidNotification.requestPermission = async () => "granted";
Object.defineProperty(AndroidNotification, "permission", { get: () => "granted" });
globalThis.Notification = AndroidNotification;

// --- Screen sharing ----------------------------------------------------------
// WebView has no getDisplayMedia. The app captures the screen with
// MediaProjection and streams JPEG frames here; a canvas turns them into the
// MediaStream Teams asked for.

if (navigator.mediaDevices && !navigator.mediaDevices.getDisplayMedia) {
  navigator.mediaDevices.getDisplayMedia = async () => {
    const result = await ipcRenderer.invoke("screen-share-start");
    if (!result?.ok) {
      throw new DOMException("Screen capture was not allowed", "NotAllowedError");
    }
    const canvas = document.createElement("canvas");
    canvas.width = result.width;
    canvas.height = result.height;
    const context = canvas.getContext("2d");
    const stream = canvas.captureStream(result.fps);
    const [track] = stream.getVideoTracks();
    let ended = false;
    const end = () => {
      if (ended) {
        return;
      }
      ended = true;
      frameHandler = null;
      ipcRenderer.send("screen-share-stop");
    };
    const stopTrack = track.stop.bind(track);
    track.stop = () => {
      stopTrack();
      end();
    };
    ipcRenderer.once("screen-share-ended", () => {
      end();
      stopTrack();
      track.dispatchEvent(new Event("ended"));
    });
    let drawing = false;
    frameHandler = async (buffer) => {
      if (drawing) {
        return;
      }
      drawing = true;
      try {
        const bitmap = await createImageBitmap(new Blob([buffer], { type: "image/jpeg" }));
        if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
          canvas.width = bitmap.width;
          canvas.height = bitmap.height;
        }
        context.drawImage(bitmap, 0, 0);
        bitmap.close();
      } catch (err) {
        console.debug("[OpenTeams] dropped screen frame", err);
      } finally {
        drawing = false;
      }
    };
    return stream;
  };
}

// --- Native shell helpers ----------------------------------------------------

// Teams' built-in app ids, as used by the native bottom navigation.
const APP_IDS = {
  activity: "14d6962d-6eeb-4f48-8890-de55454bb136",
  chat: "86fcd49b-61a2-4701-b771-54728cd291fb",
  teams: "2a84919f-59d8-4441-a975-2a8c2643b741",
  calendar: "ef56c0de-36fc-4ef8-b417-3d82ba9d073c",
  calls: "20c3440d-c67e-4420-9f80-0e50c39693df",
  files: "5af6a76b-40fc-4ba1-af29-8f49b08e44fd",
};

function findAppButton(appId) {
  const element = document.querySelector(`[data-tid*="${appId}"], [id*="${appId}"]`);
  return element?.closest("button, [role='button'], [role='tab'], a") ?? element;
}

function navigateApp(app) {
  const appId = APP_IDS[app];
  if (!appId) {
    return false;
  }
  const button = findAppButton(appId);
  if (button) {
    button.click();
    return true;
  }
  // Teams' own deep link for an app; handled in-page like deepLinkRouter.js.
  location.hash = `#/l/app/${appId}`;
  return false;
}

// With the native bottom bar enabled, hide Teams' own app rail: the smallest
// narrow ancestor holding every app button found.
let hiddenRail = null;

function hideWebAppRail() {
  if (hiddenRail?.isConnected) {
    return true;
  }
  const buttons = Object.values(APP_IDS).map(findAppButton).filter(Boolean);
  if (buttons.length < 2) {
    return false;
  }
  let rail = buttons[0];
  while (rail && !buttons.every((button) => rail.contains(button))) {
    rail = rail.parentElement;
  }
  while (rail?.parentElement && rail.parentElement.offsetWidth > 0 && rail.parentElement.offsetWidth <= 120) {
    rail = rail.parentElement;
  }
  if (!rail || rail.offsetWidth > 120) {
    return false;
  }
  rail.style.setProperty("display", "none", "important");
  hiddenRail = rail;
  return true;
}

function activeApp() {
  for (const [app, appId] of Object.entries(APP_IDS)) {
    const button = findAppButton(appId);
    if (button?.matches("[aria-pressed='true'], [aria-selected='true'], [aria-current='page'], [aria-current='true']")) {
      return app;
    }
  }
  return null;
}

// In-call buttons, by the ids Teams gives its calling controls. The app falls
// back to the Teams keyboard shortcuts open-teams' control service uses.
const CALL_BUTTONS = {
  mute: "#microphone-button",
  video: "#video-button",
  hangup: "#hangup-button",
  raiseHand: "#raisehands-button, #raise-hand-button",
};

function applyViewportWidth(width) {
  const content = `width=${width}`;
  const apply = () => {
    let meta = document.querySelector("meta[name='viewport']");
    if (!meta) {
      if (!document.head) {
        return;
      }
      meta = document.createElement("meta");
      meta.name = "viewport";
      document.head.appendChild(meta);
    }
    if (meta.content !== content) {
      meta.content = content;
    }
  };
  apply();
  const watchHead = () => {
    apply();
    new MutationObserver(apply).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ["content"] });
  };
  if (document.head) {
    watchHead();
  } else {
    document.addEventListener("DOMContentLoaded", watchHead, { once: true });
  }
}

ipcRenderer.on("navigate-app", (_event, app) => {
  ipcRenderer.send("navigate-app-result", { app, handled: navigateApp(app) });
});

ipcRenderer.on("call-control", (_event, action) => {
  const button = document.querySelector(CALL_BUTTONS[action] ?? "#none");
  button?.click();
  ipcRenderer.send("call-control-result", { action, handled: !!button });
});

// Same in-page routing as app/mainAppWindow/deepLinkRouter.js: the SPA either
// rewrites the fragment or retitles the page; otherwise the app does a full load.
ipcRenderer.on("open-deep-link", (_event, route, url) => {
  const previousHash = location.hash;
  const previousTitle = document.title;
  location.hash = route;
  setTimeout(() => {
    if (location.hash === route && document.title === previousTitle) {
      location.hash = previousHash;
      ipcRenderer.send("deep-link-fallback", url);
    }
  }, 750);
});

ipcRenderer.on("download-blob", async (_event, url, name) => {
  try {
    const blob = await (await fetch(url)).blob();
    const reader = new FileReader();
    reader.onload = () => ipcRenderer.send("save-file", { name, dataUrl: reader.result });
    reader.readAsDataURL(blob);
  } catch (err) {
    console.error("[OpenTeams] blob download failed", err);
  }
});

globalThis.__openTeams = { version: 1 };

// --- open-teams modules ------------------------------------------------------

ipcRenderer.invoke("get-config").then((config) => {
  if (config.android?.viewportWidth > 0) {
    applyViewportWidth(config.android.viewportWidth);
  }
  // Before Teams reads navigator.platform (only active for the Windows identity).
  load("browser/tools/emulatePlatform.js").init(config);

  const init = () => {
    // Same modules and init signatures as preload.js uses on the desktop.
    const modules = [
      ["browser/tools/theme.js", true],
      ["browser/tools/disableAutogain.js", false],
      ["browser/tools/speakingIndicator.js", true],
    ];
    for (const [id, needsIpc] of modules) {
      try {
        const instance = load(id);
        if (needsIpc) {
          instance.init(config, ipcRenderer);
        } else {
          instance.init(config);
        }
      } catch (err) {
        console.error(`[OpenTeams] failed to init ${id}`, err);
      }
    }
    try {
      const ActivityManager = load("browser/notifications/activityManager.js");
      new ActivityManager(ipcRenderer, config).start();
    } catch (err) {
      console.error("[OpenTeams] ActivityManager failed to initialize", err);
    }
    ipcRenderer.on("config-changed", (_event, changes) => Object.assign(config, changes));

    // Report shell state (active app, rail hidden) until Teams has rendered,
    // then keep the bottom bar's selection in sync.
    let lastApp = null;
    setInterval(() => {
      if (document.hidden) {
        return;
      }
      if (config.android?.nativeNavigation) {
        hideWebAppRail();
      }
      const app = activeApp();
      if (app !== lastApp) {
        lastApp = app;
        ipcRenderer.send("active-app-changed", app);
      }
    }, 1000);
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
});

post({ type: "hello" });
