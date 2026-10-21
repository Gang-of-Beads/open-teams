// No Teams session or real caller: exercise only the DOM fallback with fake controls.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../app/src/main/js/android-preload.js", import.meta.url), "utf8");
const fn = source.slice(source.indexOf("function watchIncomingCalls()"), source.indexOf("// --- Camera and microphone"));
const events = [];
const handlers = {};
const hub = {
  on: (name, fn) => { handlers[name] = fn; },
  emit: (...args) => { events.push(args); handlers[args[0]]?.(); },
};
let scan;
let action;
let wrapper = false;
const buttons = [];
const context = {
  load: () => hub,
  ipcRenderer: { on: (_channel, handler) => { action = handler; } },
  document: {
    body: {},
    querySelector: (selector) => selector.includes("calling-actions") && wrapper ? {} : null,
    querySelectorAll: (selector) => buttons.filter((b) => selector.includes(`aria-label="${b.label}"`)),
  },
  MutationObserver: class { observe() {} },
  setTimeout: () => 1,
  setInterval: (callback) => { scan = callback; },
};
vm.runInNewContext(`${fn}\nwatchIncomingCalls();`, context);
const button = (label) => ({ label, visible: true, clicks: 0,
  getBoundingClientRect() { return { width: this.visible ? 32 : 0, height: 32 }; },
  click() { this.clicks++; },
});
const audio = button("Accept with audio");
const video = button("Accept with video");
const decline = button("Decline call");
buttons.push(audio);
scan();
assert.equal(events.length, 0, "accept alone is not an incoming call");
buttons.push(video, decline);
scan(); scan();
assert.equal(events.length, 1, "ring once, not once per mutation");
assert.equal(events[0][0], "incoming-call-created");
action({}, "ACCEPT_AUDIO");
assert.equal(audio.clicks, 1);
assert.equal(video.clicks, 0, "audio answer never enables video");
wrapper = true;
action({}, "ACCEPT_AUDIO");
assert.equal(audio.clicks, 1, "legacy handler owns its wrapper");
wrapper = false;
action({}, "toString");
action({}, "DECLINE");
assert.equal(decline.clicks, 1);
audio.visible = video.visible = false;
scan(); scan();
assert.equal(events.length, 2);
assert.equal(events[1][0], "incoming-call-ended");
handlers["incoming-call-created"](); // primary React detector got there first
const count = events.length;
audio.visible = video.visible = true;
scan();
assert.equal(events.length, count, "fallback does not overwrite primary caller details");
audio.visible = video.visible = false;
scan();
assert.equal(events.length, count, "primary detector owns its end event");
console.log("ok: incoming call detection, deduplication, audio/video actions, dismissal");
