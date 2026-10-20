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
  // The list pane: Chat and most apps use mid-nav, Activity uses sub-nav.
  listPane: ':is([data-tid="app-layout-area--mid-nav"], [data-tid="app-layout-area--sub-nav"])',
};

// Hide Teams' title bar (the native top bar replaces it) unless one of its
// menus is in use, and the list titles the native top bar already shows.
const SHELL_CSS = `
html.ot-native:not(.ot-header) ${SHELL.titleBar} { display: none !important; }
html.ot-native:not(.ot-header) [data-tid="app-layout-area--nav"] { visibility: hidden; } /* the native bars replace it */
html.ot-native [data-tid="app-layout-area--mid-nav"] h1,
html.ot-native [data-tid="app-layout-area--sub-nav"] h1 { visibility: hidden; }
html.ot-native [role="tooltip"] { display: none !important; } /* hover tooltips on a touch screen */
html.ot-native, html.ot-native * { -webkit-tap-highlight-color: transparent; }
/* The list's own header row: its buttons live in the native top bar. */
html.ot-native:not(.ot-list) ${SHELL.listPane} :has(> h1) { display: none !important; }
/* Collapsed rather than display: none, so appHeader() can still tell it is on screen. */
html.ot-native:not(.ot-list):not(.ot-detail) [data-tid="app-layout-area--header"]:has(.ot-app-header) {
  height: 0 !important; min-height: 0 !important; overflow: hidden !important; transition: none !important;
}
/* For its menus it stays invisible and out of the flow: the menu drops down at the top right, under the native button. */
html.ot-native.ot-list-menu :is(${SHELL.listPane} :has(> h1), [data-tid="app-layout-area--header"]:has(.ot-app-header)) {
  position: absolute !important; top: 0; left: 0; right: 0; opacity: 0; pointer-events: none;
}
/* Phone-sized list rows (Teams' desktop rows are 28-32px). */
html.ot-native ${SHELL.listPane} [role="treeitem"]:not([aria-expanded]) { height: auto !important; }
html.ot-native ${SHELL.listPane} [role="treeitem"]:not([aria-expanded]) > .fui-TreeItemLayout { min-height: 44px; font-size: 15px; }
html.ot-native ${SHELL.listPane} [role="treeitem"]:not([aria-expanded]) > .fui-TreeItemLayout:has(.fui-Avatar) { min-height: 56px; }
html.ot-native ${SHELL.listPane} [role="treeitem"][aria-expanded] > .fui-TreeItemLayout { min-height: 40px; }
html.ot-native ${SHELL.listPane} .fui-TreeItemLayout .fui-Avatar,
html.ot-native ${SHELL.listPane} .fui-TreeItemLayout .fui-Avatar img { width: 36px; height: 36px; }
html.ot-native ${SHELL.listPane} .fui-TreeItemLayout { transition: background-color 120ms; }
html.ot-native ${SHELL.listPane} .fui-TreeItemLayout:active { background-color: rgba(128, 128, 128, 0.18); }
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

// "Header mode": a hidden part of Teams' chrome is shown while it is in use,
// then hidden again: "title" for the title bar (search box, profile and
// settings menus, app rail), "list" for the list's header row (its menus and
// filter box, opened from the native top bar's actions).
let headerMode = "";
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

function setHeaderMode(mode) {
  if (!mode) {
    collapseAppRail();
  }
  headerMode = mode;
  headerSince = Date.now();
  headerIdlePolls = 0;
  document.documentElement.classList.toggle("ot-header", mode === "title");
  document.documentElement.classList.toggle("ot-list", mode === "list");
  document.documentElement.classList.remove("ot-list-menu");
}

// Opening a chat or activity item (or going back to the list) changes the
// native bars at the tap, like a native screen transition, instead of once
// Teams has rendered the new view a few hundred milliseconds later.
const OPENS_ITEM = `${SHELL.listPane} :is([role="treeitem"]:not([aria-expanded]), [role="option"])`;
let expectedView = null; // { detail, until, hold }
let itemOpenedAt = 0;

// hold: keep reporting it until the time is up, even if Teams briefly shows otherwise.
function expectView(detail, ms, hold = false) {
  expectedView = { detail, until: Date.now() + ms, hold };
  reportShell();
}

function shownDetail(actual) {
  if (expectedView && ((!expectedView.hold && actual === expectedView.detail) || Date.now() > expectedView.until)) {
    expectedView = null;
  }
  return expectedView ? expectedView.detail : actual;
}

// A Teams menu or dialog is open: Back closes it, like a native popup.
function overlayOpen() {
  return [...document.querySelectorAll('[role="menu"], [role="dialog"]')].some(visible);
}

// The list's filter box (Chat's "Filter by person, chat or channel name").
function listFilter() {
  return [...document.querySelectorAll(`${SHELL.listPane} input`)].find(
    (input) => visible(input) && !input.closest(".ot-list-header"),
  );
}

// A native tap does not move Android's focus into the WebView, so the
// keyboard would not come up for the box Teams just focused.
function keyboardForFocus() {
  setTimeout(() => {
    const focused = document.activeElement;
    if (focused?.matches?.("input, textarea, [contenteditable='true']")) {
      ipcRenderer.send("show-keyboard");
    }
  }, 200);
}

// The list pane on screen; Teams keeps the panes of apps visited before mounted with no size.
function visiblePane() {
  return [...document.querySelectorAll(SHELL.listPane)].find((p) => p.getBoundingClientRect().width > 0);
}

// The header row (title, then buttons) of that list pane.
function listHeader() {
  return visiblePane()?.querySelector("h1")?.parentElement ?? null;
}

// Apps without a list pane (Calls) show their icon, title, tabs and buttons
// in an entity header instead; on their top level the native bar replaces it.
function appHeader() {
  if (visiblePane()) {
    return null;
  }
  return [...document.querySelectorAll('[data-tid="entity-header"]')].find(
    (header) => header.parentElement.getBoundingClientRect().width > 0 && header.querySelector('[data-tid="entity-header-toolbar"]'),
  ) ?? null;
}

// The header whose buttons the native top bar shows (see reportShell).
let shellHeader = null;

// The list header's buttons (new chat, filter, more...) with the icon Teams
// draws for them, so the native top bar can show the same icons.
function listActions(header) {
  return [...(header?.querySelectorAll("button") ?? [])].slice(0, 4).map((button, index) => {
    const svg = [...button.querySelectorAll("svg")].find((icon) => getComputedStyle(icon).display !== "none");
    const path = [...(svg?.querySelectorAll("path") ?? [])].map((p) => p.getAttribute("d")).join(" ");
    return {
      index,
      id: button.dataset.testid || button.dataset.tid || "",
      label: button.getAttribute("aria-label") ?? "",
      viewBox: svg?.getAttribute("viewBox") ?? "",
      path,
    };
  }).filter((action) => action.path && action.viewBox);
}

function headerInUse() {
  const header = shellHeader;
  if (headerMode === "list") {
    return Boolean(header?.contains(document.activeElement)) ||
      [...(header?.querySelectorAll("input") ?? [])].some((input) => input.value) ||
      overlayOpen();
  }
  const titleBar = document.querySelector(SHELL.titleBar);
  return Boolean(titleBar?.contains(document.activeElement)) ||
    visible(document.querySelector(SHELL.searchPopup)) ||
    appRailExpanded() ||
    [...document.querySelectorAll('[role="menu"], [role="dialog"]')].some(visible);
}

function shellAction(action) {
  if (action.startsWith("list:")) {
    const button = shellHeader?.querySelectorAll("button")[Number(action.slice(5))];
    if (button?.getAttribute("aria-haspopup") === "menu") {
      setHeaderMode("list");
      document.documentElement.classList.add("ot-list-menu");
      requestAnimationFrame(() => button.click());
    } else if (button) {
      button.click(); // new chat, filter: nothing to anchor in the header
      keyboardForFocus();
    }
    return;
  }
  const selector = { search: SHELL.search, status: SHELL.meTrigger, settings: SHELL.settings, apps: SHELL.hamburger }[action];
  const button = selector && document.querySelector(selector);
  if (!button) {
    return;
  }
  setHeaderMode("title");
  requestAnimationFrame(() => {
    button.click();
    if (action === "search") {
      setTimeout(() => {
        document.querySelector(SHELL.searchInput)?.focus();
        keyboardForFocus();
      }, 150);
    }
  });
}

function shellBack() {
  const filter = listFilter();
  if (filter && !headerMode && !overlayOpen()) {
    filter.focus();
    filter.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }));
    return;
  }
  if (headerMode || overlayOpen()) {
    (document.activeElement ?? document).dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }),
    );
    document.activeElement?.blur?.();
    if (headerMode) {
      setHeaderMode("");
    }
    return;
  }
  const back = document.querySelector(SHELL.back);
  if (back) {
    back.click();
    expectView(false, 1000);
  }
}

// Rows of whatever list or view is on screen (chats, activity, calls...).
function visibleRows() {
  return [...document.querySelectorAll('[data-tid^="app-layout-area--"] :is([role="treeitem"], [role="option"], [role="row"], [role="listitem"])')]
    .filter((row) => {
      const rect = row.getBoundingClientRect();
      return rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight && rect.left >= 0 && rect.left < innerWidth;
    })
    .slice(0, 5);
}

// Apps where Teams reopened an item right after showing the list.
const reopeningApps = new Set();

function navigateApp(id) {
  const button = document.getElementById(id);
  if (!button) {
    return;
  }
  // Teams unmounts an app's view when another opens and rebuilds it on the way
  // back. The app shows its last look meanwhile and asks for "app-ready" once
  // new rows (or an app's frame) are on screen.
  const before = new Set(visibleRows());
  const start = performance.now();
  let leftAt = 0;
  let ready = false;
  button.click();
  expectView(false, 2000, true);
  const check = () => {
    const elapsed = performance.now() - start;
    if (itemOpenedAt > start || elapsed > 4000) {
      if (!ready) {
        ipcRenderer.send("app-ready", id); // the user moved on, or Teams is slow: show the page as it is
      }
      return;
    }
    const back = document.querySelector(SHELL.back);
    // Like the native app, a tab opens on its list rather than the last
    // conversation, which Teams may also reopen just after showing the list
    // (a race in its narrow layout). That happens under the snapshot.
    if (onTop(back)) {
      if (!leftAt && elapsed < 2000 && itemOpenedAt < start) {
        leftAt = performance.now();
        reopeningApps.add(id);
        if (ready) {
          ready = false;
          ipcRenderer.send("app-busy", id);
        }
        back.click();
      }
    } else if (!ready) {
      const rows = visibleRows();
      const fresh = rows.length >= 3 && rows.every((row) => !before.has(row));
      const frame = [...document.querySelectorAll('[data-tid="app-layout-area--main"] iframe')].some(visible) &&
        ![...before].some((row) => row.isConnected && visible(row));
      const settled = leftAt ? performance.now() - leftAt > 350 : !reopeningApps.has(id) || elapsed > 1200;
      if (button.getAttribute("aria-pressed") === "true" && (fresh || frame) && settled) {
        ready = true;
        requestAnimationFrame(() => ipcRenderer.send("app-ready", id)); // after a paint with the content
      }
    }
    if (!ready || elapsed < 1500) {
      requestAnimationFrame(check);
    }
  };
  requestAnimationFrame(check);
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
  document.documentElement.classList.toggle("ot-header", headerMode === "title");
  document.documentElement.classList.toggle("ot-list", headerMode === "list");
  for (const title of document.querySelectorAll(`${SHELL.listPane} h1`)) {
    title.parentElement.classList.add("ot-list-header");
  }
  if (headerMode) {
    headerIdlePolls = headerInUse() ? 0 : headerIdlePolls + 1;
    if (headerIdlePolls >= 2 && Date.now() - headerSince > 1500) {
      setHeaderMode("");
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
  const detail = shownDetail(onTop(back));
  document.documentElement.classList.toggle("ot-detail", detail);
  shellHeader = listHeader() ?? (detail ? null : appHeader());
  shellHeader?.classList.add(shellHeader.matches(`${SHELL.listPane} *`) ? "ot-list-header" : "ot-app-header");
  const state = {
    apps: [...document.querySelectorAll(SHELL.appButtons)].map((button) => ({
      id: button.dataset.tid,
      label: appLabel(button),
      selected: button.getAttribute("aria-pressed") === "true",
    })),
    detail,
    header: headerMode === "title",
    overlay: Boolean(headerMode) || overlayOpen() || Boolean(listFilter()),
    actions: listActions(shellHeader),
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
      // Follow Teams' DOM closely. Before the next paint an app's own header is
      // hidden, so it never shows; the full report (native bars) runs at most
      // every 50ms during bursts of changes.
      let shellFrame = 0;
      let shellTimer = 0;
      let shellRanAt = 0;
      const runShell = () => {
        shellTimer = 0;
        shellRanAt = performance.now();
        reportShell();
      };
      const scheduleShell = () => {
        if (shellFrame || document.hidden) {
          return;
        }
        shellFrame = requestAnimationFrame(() => {
          shellFrame = 0;
          if (!document.documentElement.classList.contains("ot-detail")) {
            appHeader()?.classList.add("ot-app-header");
          }
          const wait = 50 - (performance.now() - shellRanAt);
          if (wait <= 0) {
            runShell();
          } else if (!shellTimer) {
            shellTimer = setTimeout(runShell, wait);
          }
        });
      };
      new MutationObserver(scheduleShell).observe(document.body, { childList: true, subtree: true });
      globalThis.addEventListener("pointerup", scheduleShell, true);
      globalThis.addEventListener(
        "click",
        (event) => {
          if (event.target.closest?.(OPENS_ITEM) && !event.target.closest("button")) {
            itemOpenedAt = performance.now();
            expectView(true, 1500);
          }
        },
        true,
      );
      setInterval(scheduleShell, 1000);
    }
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
});

post({ type: "hello" });
