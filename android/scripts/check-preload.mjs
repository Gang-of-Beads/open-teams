// Smoke test for the generated open-teams-preload.js (run after a Gradle build):
// loads it in node:vm with a fake native bridge and checks that the bundled
// open-teams modules initialise and the bridge speaks the expected protocol.
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import { webcrypto } from "node:crypto";

function find(dir, name) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) {
      const hit = find(path, name);
      if (hit) return hit;
    } else if (entry === name) {
      return path;
    }
  }
  return null;
}

const bundlePath = find(new URL("../app/build/generated", import.meta.url).pathname, "open-teams-preload.js");
assert.ok(bundlePath, "build the app first: ./gradlew assembleDebug");

const posted = [];
const errors = [];
const listeners = {};
const bridge = { postMessage: (message) => posted.push(JSON.parse(message)), onmessage: null };
const element = () => ({ style: { setProperty() {} }, appendChild() {}, closest: () => null });
const context = {
  OpenTeamsNative: bridge,
  console: { ...console, debug() {}, info() {}, warn() {}, error: (...args) => errors.push(args.join(" ")) },
  crypto: webcrypto,
  navigator: { mediaDevices: {} },
  location: { hash: "", hostname: "teams.cloud.microsoft" },
  document: {
    readyState: "complete",
    hidden: true,
    title: "Teams",
    head: element(),
    documentElement: element(),
    addEventListener: (type, fn) => (listeners[type] = fn),
    querySelector: () => null,
    createElement: element,
  },
  setTimeout: () => 0,
  setInterval: () => 0,
  clearInterval() {},
  Blob,
  Event,
  DOMException,
  structuredClone,
};
vm.createContext(context);
vm.runInContext("globalThis.top = globalThis;", context);
vm.runInContext(readFileSync(bundlePath, "utf8"), context, { filename: bundlePath });

assert.deepEqual(posted.map((m) => m.type), ["invoke", "hello"], "asks for the config, then says hello");
assert.equal(posted[0].channel, "get-config");
assert.equal(typeof context.navigator.mediaDevices.getDisplayMedia, "function", "getDisplayMedia shim installed");
assert.equal(context.Notification.permission, "granted", "Notification shim installed");

const config = {
  followSystemTheme: true,
  emulateWinChromiumPlatform: false,
  appActiveCheckInterval: 2,
  appIdleTimeoutCheckInterval: 10,
  media: { microphone: { disableAutogain: false, speakingIndicator: false } },
  android: { viewportWidth: 0, nativeNavigation: true },
};
bridge.onmessage({ data: JSON.stringify({ type: "reply", id: posted[0].id, result: config }) });
await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(errors, [], "every bundled open-teams module initialises");
assert.ok(posted.some((m) => m.channel === "get-system-idle-state"), "activityManager started");

new context.Notification("Alice", { body: "Hi" });
const shown = posted.find((m) => m.channel === "show-notification");
assert.equal(shown.args[0].title, "Alice");
assert.equal(shown.args[0].body, "Hi");

bridge.onmessage({ data: JSON.stringify({ type: "event", channel: "call-control", args: ["mute"] }) });
assert.deepEqual(posted.at(-1), { type: "send", channel: "call-control-result", args: [{ action: "mute", handled: false }] });

console.log(`ok: ${bundlePath}`);
