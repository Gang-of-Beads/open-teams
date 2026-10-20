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

// Teams passes the sender's avatar as a URL on its own origin; Android needs the bytes.
async function iconData(src) {
  if (typeof src !== "string" || !src) {
    return null;
  }
  if (src.startsWith("data:image/")) {
    return src;
  }
  try {
    const response = await fetch(src, { credentials: "include" });
    if (!response.ok) {
      return null;
    }
    const bitmap = await createImageBitmap(await response.blob());
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 96;
    canvas.getContext("2d").drawImage(bitmap, 0, 0, 96, 96);
    bitmap.close();
    return canvas.toDataURL("image/png");
  } catch {
    return null; // cross-origin or not an image: show the notification without it
  }
}

function AndroidNotification(title, options = {}) {
  const notificationId = crypto.randomUUID();
  const stub = createNotificationStub();
  notificationBridge.register(notificationId, stub);
  stub.close = () => notificationBridge.close(notificationId);
  iconData(options.icon).then((icon) =>
    ipcRenderer.invoke("show-notification", {
      notificationId,
      title: String(title ?? ""),
      body: String(options.body ?? ""),
      tag: options.tag ? String(options.tag) : null,
      icon,
    }),
  );
  return stub;
}
AndroidNotification.requestPermission = async () => "granted";
Object.defineProperty(AndroidNotification, "permission", { get: () => "granted" });
globalThis.Notification = AndroidNotification;

// --- Camera and microphone permission state ------------------------------------
// WebView keeps no per-site permission state, so permissions.query() answers
// "prompt" even once Android has granted the app the camera and microphone,
// and Teams then treats them as not yet allowed. Report Android's state.

let androidMedia = { microphone: false, camera: false };
const mediaStatuses = [];

if (navigator.permissions?.query) {
  const query = navigator.permissions.query.bind(navigator.permissions);
  navigator.permissions.query = async (descriptor) => {
    const status = await query(descriptor);
    const name = descriptor?.name;
    if (name === "microphone" || name === "camera") {
      Object.defineProperty(status, "state", { configurable: true, get: () => (androidMedia[name] ? "granted" : "prompt") });
      mediaStatuses.push({ name, status });
      if (mediaStatuses.length > 50) {
        mediaStatuses.shift();
      }
    }
    return status;
  };
}

function setAndroidMedia(state) {
  const before = androidMedia;
  androidMedia = { microphone: Boolean(state?.microphone), camera: Boolean(state?.camera) };
  for (const { name, status } of mediaStatuses) {
    if (before[name] !== androidMedia[name]) {
      status.dispatchEvent(new Event("change"));
    }
  }
}

ipcRenderer.on("media-permissions", (_event, state) => setAndroidMedia(state));

// --- Default microphone --------------------------------------------------------
// Teams selects the microphone whose groupId matches the "default" entry, and in
// a meeting disables its mic button when none does. WebView gives "default" its
// own groupId and no label, so point it at the device Chromium's
// AudioManagerAndroid opens for "default": wired, USB, Bluetooth, else speakerphone.
const DEFAULT_MIC_ORDER = ["Wired headset", "USB audio", "Bluetooth headset", "Speakerphone"];

function withDefaultMicrophone(devices) {
  const mics = devices.filter((d) => d.kind === "audioinput" && d.deviceId !== "default" && d.label);
  const target = DEFAULT_MIC_ORDER.map((label) => mics.find((d) => d.label === label)).find(Boolean) ?? mics[0];
  if (!target) {
    return devices;
  }
  return devices.map((d) => {
    if (d.kind !== "audioinput" || d.deviceId !== "default") {
      return d;
    }
    const fields = { deviceId: d.deviceId, kind: d.kind, label: `Default - ${target.label}`, groupId: target.groupId };
    const alias = Object.create(Object.getPrototypeOf(d));
    for (const [key, value] of Object.entries(fields)) {
      Object.defineProperty(alias, key, { value, enumerable: true });
    }
    alias.toJSON = () => fields;
    alias.getCapabilities = () => d.getCapabilities?.();
    return alias;
  });
}

if (globalThis.MediaDevices?.prototype.enumerateDevices) {
  const enumerate = MediaDevices.prototype.enumerateDevices;
  MediaDevices.prototype.enumerateDevices = async function () {
    return withDefaultMicrophone(await enumerate.call(this));
  };
}

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

// Teams' DOM as observed on teams.cloud.microsoft (2026-10) in this WebView's
// narrow layout. The native top bar, drawer and bottom bar stand in for Teams'
// title bar and app rail; the web ones stay in the DOM and are driven from here.
const SHELL = {
  titleBar: '[data-tid="app-layout-area--title-bar"]',
  appButtons: '[data-tid="app-bar-wrapper"] button[data-pinned="true"]',
  back: '[data-tid="layout-navigation-controls"]', // "Return to list" when a conversation is open
  meTrigger: '[data-tid="me-control-avatar-trigger"]',
  meAvatar: '[data-tid="me-control-avatar"]',
  presence: '[data-tid="me-control-avatar-presence"]',
  search: '[data-tid="title-bar-toggle-search-btn"]',
  searchInput: "#ms-searchux-input",
  searchPopup: '[data-tid="ms-searchux-popup"]',
  settings: '[data-tid="more-options-header"]',
  hamburger: '[data-tid="hamburger-button"]',
};

// Hide Teams' title bar (the native top bar replaces it) unless one of its
// menus is in use, and the list titles the native top bar already shows.
const SHELL_CSS = `
html.ot-native:not(.ot-header) ${SHELL.titleBar} { display: none !important; }
html.ot-native:not(.ot-header) [data-tid="app-layout-area--nav"] { visibility: hidden; } /* the native bars replace it */
html.ot-native [data-tid="app-layout-area--mid-nav"] h1,
html.ot-native [data-tid="app-layout-area--sub-nav"] h1 { visibility: hidden; }
html.ot-native [role="tooltip"] { display: none !important; } /* hover tooltips on a touch screen */
`;

function visible(element) {
  if (!element) {
    return false;
  }
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.left < innerWidth;
}

// Visible and not covered: in the list view Teams keeps the conversation
// header (and its "Return to list" button) in place underneath the list.
function onTop(element) {
  if (!visible(element)) {
    return false;
  }
  const rect = element.getBoundingClientRect();
  const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
  return Boolean(hit) && (hit === element || element.contains(hit));
}

const appLabel = (button) => (button.getAttribute("aria-label") || "").replace(/\s*\([^)]*\)\s*$/, "").trim();

// "Header mode": the web title bar is shown while its search box, profile
// menu, settings menu or expanded app rail is in use, then hidden again.
let headerMode = false;
let headerSince = 0;
let headerIdlePolls = 0;

// Teams remembers an expanded app rail across reloads; outside header mode it
// would cover the list, so fold it back.
function appRailExpanded() {
  return document.querySelector(SHELL.hamburger)?.dataset.appbarExpanded === "true";
}

function collapseAppRail() {
  if (appRailExpanded()) {
    document.querySelector(SHELL.hamburger).click();
  }
}

function setHeaderMode(on) {
  if (!on) {
    collapseAppRail();
  }
  headerMode = on;
  headerSince = Date.now();
  headerIdlePolls = 0;
  document.documentElement.classList.toggle("ot-header", on);
}

function headerInUse() {
  const titleBar = document.querySelector(SHELL.titleBar);
  return Boolean(titleBar?.contains(document.activeElement)) ||
    visible(document.querySelector(SHELL.searchPopup)) ||
    appRailExpanded() ||
    [...document.querySelectorAll('[role="menu"], [role="dialog"]')].some(visible);
}

function shellAction(action) {
  const selector = { search: SHELL.search, status: SHELL.meTrigger, settings: SHELL.settings, apps: SHELL.hamburger }[action];
  const button = selector && document.querySelector(selector);
  if (!button) {
    return;
  }
  setHeaderMode(true);
  requestAnimationFrame(() => {
    button.click();
    if (action === "search") {
      setTimeout(() => document.querySelector(SHELL.searchInput)?.focus(), 150);
    }
  });
}

function shellBack() {
  if (headerMode) {
    document.activeElement?.blur?.();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }));
    setHeaderMode(false);
    return;
  }
  document.querySelector(SHELL.back)?.click();
}

function navigateApp(id) {
  const button = document.getElementById(id);
  if (!button) {
    return;
  }
  button.click();
  // Like the native app, a tab opens on its list rather than the last conversation.
  setTimeout(() => {
    const back = document.querySelector(SHELL.back);
    if (onTop(back)) {
      back.click();
    }
  }, 700);
}

// The first opaque background at a point, for native bars that match Teams' theme.
function backgroundAt(x, y) {
  let element = document.elementFromPoint(x, y);
  while (element) {
    const color = getComputedStyle(element).backgroundColor;
    if (color && color !== "transparent" && !/rgba\(.*,\s*0\)$/.test(color)) {
      return color;
    }
    element = element.parentElement;
  }
  return getComputedStyle(document.body).backgroundColor;
}

function profile() {
  const triggerLabel = document.querySelector(SHELL.meTrigger)?.getAttribute("aria-label") || "";
  const avatarLabel = document.querySelector(SHELL.meAvatar)?.getAttribute("aria-label") || "";
  const presence = document.querySelector(SHELL.presence);
  const email = /[^\s,;()]+@[^\s,;()]+\.[a-z]{2,}/i.exec(triggerLabel)?.[0] ?? "";
  return {
    name: (/ of (.+?)\.?$/.exec(avatarLabel)?.[1] ?? avatarLabel) || email,
    email,
    presence: presence?.getAttribute("aria-label") || "",
    presenceColor: presence ? getComputedStyle(presence.querySelector("svg") || presence).color : "",
  };
}

let lastAvatarSrc = null;

function sendAvatar() {
  const image = document.querySelector(`${SHELL.meAvatar} img`);
  if (!image?.complete || !image.naturalWidth || image.src === lastAvatarSrc) {
    return;
  }
  lastAvatarSrc = image.src;
  try {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 96;
    canvas.getContext("2d").drawImage(image, 0, 0, 96, 96);
    ipcRenderer.send("profile-avatar", canvas.toDataURL("image/png"));
  } catch (err) {
    console.debug("[OpenTeams] avatar not readable", err);
  }
}

let lastShellState = "";
let shellReadyAt = 0;
let userTouched = false;
globalThis.addEventListener("pointerdown", () => { userTouched = true; }, { capture: true, passive: true });

function reportShell() {
  document.documentElement.classList.add("ot-native");
  document.documentElement.classList.toggle("ot-header", headerMode);
  if (headerMode) {
    headerIdlePolls = headerInUse() ? 0 : headerIdlePolls + 1;
    if (headerIdlePolls >= 2 && Date.now() - headerSince > 1500) {
      setHeaderMode(false);
    }
  } else {
    collapseAppRail();
  }
  // Like the native app, start on the list rather than Teams' last open
  // conversation, which Teams restores a little after its app bar renders.
  const back = document.querySelector(SHELL.back);
  if (!shellReadyAt && document.querySelector(SHELL.appButtons)) {
    shellReadyAt = Date.now();
  }
  if (shellReadyAt && !userTouched && Date.now() - shellReadyAt < 20000 && onTop(back)) {
    back.click();
  }
  const state = {
    apps: [...document.querySelectorAll(SHELL.appButtons)].map((button) => ({
      id: button.dataset.tid,
      label: appLabel(button),
      selected: button.getAttribute("aria-pressed") === "true",
    })),
    detail: onTop(back),
    header: headerMode,
    profile: profile(),
    colors: { top: backgroundAt(innerWidth / 2, 2), bottom: backgroundAt(innerWidth / 2, innerHeight - 2) },
  };
  const json = JSON.stringify(state);
  if (json !== lastShellState) {
    lastShellState = json;
    ipcRenderer.send("shell-state", state);
  }
  sendAvatar();
  watchPrejoin();
  watchCallButtons();
}

// Teams' own call buttons carry the mute and camera state (data-state is not
// localised). speakingIndicator's WebRTC audio level rarely arrives in WebView,
// so without this the native call bar would always show the mic as on.
let callButtonState = "";

function watchCallButtons() {
  const mic = document.querySelector(CALL_BUTTONS.mute)?.dataset.state;
  const video = document.querySelector(CALL_BUTTONS.video)?.dataset.state;
  const state = mic ? `${mic}|${video}` : "";
  if (state === callButtonState) {
    return;
  }
  callButtonState = state;
  if (mic) {
    ipcRenderer.send("microphone-state-changed", mic === "mic-off" ? "muted" : "silent");
    ipcRenderer.send("camera-state-changed", video === "call-video");
  }
}

// Teams reports "calling-screen-rendered" (call-connected) for its pre-join
// screen too, but nothing when that screen is cancelled, which would leave the
// native call running. End it when the screen goes without the call starting.
let prejoinShown = false;
let prejoinLeftAt = 0;

function watchPrejoin() {
  if (document.querySelector('[data-tid="calling-prejoin-screen"]')) {
    prejoinShown = true;
    prejoinLeftAt = 0;
  } else if (prejoinShown && document.querySelector(CALL_BUTTONS.hangup)) {
    prejoinShown = false; // joined
  } else if (prejoinShown) {
    prejoinLeftAt ||= Date.now();
    if (Date.now() - prejoinLeftAt > 3000) {
      prejoinShown = false;
      ipcRenderer.invoke("call-disconnected");
    }
  }
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

ipcRenderer.on("navigate-app", (_event, id) => navigateApp(id));
ipcRenderer.on("shell-action", (_event, action) => shellAction(action));
ipcRenderer.on("shell-back", () => shellBack());

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
  setAndroidMedia(config.android?.mediaPermissions);
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

    if (config.android?.nativeNavigation) {
      const style = document.createElement("style");
      style.id = "open-teams-shell";
      style.textContent = SHELL_CSS;
      document.head.appendChild(style);
      document.documentElement.classList.add("ot-native");
      setInterval(() => {
        if (!document.hidden) {
          reportShell();
        }
      }, 500);
    }
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
});

post({ type: "hello" });
