import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";

test("packaged worker serializes native snapshots and reports disconnect without fake close", async () => {
  const previous = {chrome: globalThis.chrome, setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval};
  const events = [];
  const event = () => {const listeners = []; const e = {addListener: fn => listeners.push(fn), fire: (...args) => listeners.forEach(fn => fn(...args))}; events.push(e); return e;};
  const sent = [], saved = {}, badges = [], titles = [];
  const port = {postMessage: message => sent.push(message), onMessage: event(), onDisconnect: event()};
  let tabs = [{id: 7, windowId: 1, active: true, url: "https://cogentspec.com/stack?private=discarded"}];
  let focused = true;
  const onActivated = event(), onRemoved = event(), onFocusChanged = event();
  globalThis.chrome = {
    tabs: {query: async () => tabs.map(t => ({...t})), onActivated, onRemoved, onUpdated: event(), onCreated: event(), onAttached: event(), onDetached: event(), onReplaced: event()},
    windows: {getAll: async () => [{id: 1, focused}], onFocusChanged, onRemoved: event()},
    storage: {session: {get: async () => ({...saved}), set: async values => Object.assign(saved, values)}},
    runtime: {connectNative: name => {assert.equal(name, "com.cogentspec.popout_lifecycle"); return port;}, onStartup: event(), onInstalled: event(), lastError: undefined},
    alarms: {create: () => {}, onAlarm: event()},
    action: {setBadgeText: value => badges.push(value.text), setTitle: value => titles.push(value.title)}
  };
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  const flush = async () => {for(let i=0; i<10; i++) await new Promise(resolve => setImmediate(resolve));};
  try {
    await import("./worker.js?test=" + Date.now()); await flush();
    assert.equal(sent.at(-1).state, "active");
    tabs[0].active = false; onActivated.fire({tabId: 99}); await flush();
    assert.equal(sent.at(-1).state, "hidden");
    focused = false; onFocusChanged.fire(-1); await flush();
    assert.equal(sent.at(-1).state, "blurred");
    focused = true; tabs[0].active = true; onActivated.fire({tabId: 7}); await flush();
    assert.equal(sent.at(-1).state, "active");
    tabs = []; onRemoved.fire(7, {isWindowClosing: false}); await flush();
    assert.equal(sent.at(-1).state, "closed");
    const id = sent[0].sessionId;
    sent.forEach((message, index) => {assert.equal(message.sessionId, id); assert.equal(message.sequence, index+1); assert.equal(JSON.stringify(message).includes("private"), false);});
    port.onMessage.fire({accepted: true}); assert.equal(titles.at(-1), "CogentSpec lifecycle: local host connected");
    const before = sent.length; port.onDisconnect.fire(); onRemoved.fire(123); await flush();
    assert.equal(sent.length, before); assert.equal(badges.at(-1), "!");
  } finally {Object.assign(globalThis, previous);}
});

test("manifest permissions are scoped; no content script or external message bridge", async () => {
  const manifest = JSON.parse(await fs.readFile(new URL("./manifest.json", import.meta.url)));
  assert.deepEqual(manifest.permissions, ["nativeMessaging", "storage", "alarms"]);
  assert.deepEqual(manifest.host_permissions, ["https://cogentspec.com/*", "https://cogentspec.app/*"]);
  assert.equal(manifest.content_scripts, undefined);
  assert.equal(manifest.externally_connectable, undefined);
});
