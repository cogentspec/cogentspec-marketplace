import {snapshot} from "./policy.mjs";
const HOST = "com.cogentspec.popout_lifecycle";
const MATCHES = ["https://cogentspec.com/*", "https://cogentspec.app/*"];
let port = null;
let queue = Promise.resolve();
let epoch = 0;
let heartbeat;

async function publish() {
  if (!port) return;
  const currentPort = port;
  const currentEpoch = epoch;
  // WINDOW_ID_NONE is meaningful: lastFocused alone would incorrectly call an
  // unfocused browser active while the user is working in another application.
  const [tabs, windows, saved] = await Promise.all([
    chrome.tabs.query({url: MATCHES}), chrome.windows.getAll(), chrome.storage.session.get(["sessionId", "sequence"])
  ]);
  if (currentPort !== port || currentEpoch !== epoch) return;
  const sessionId = saved.sessionId || crypto.randomUUID();
  const sequence = (saved.sequence || 0) + 1;
  await chrome.storage.session.set({sessionId, sequence});
  const focused = windows.find(window => window.focused);
  currentPort.postMessage({protocol: "cogentspec-browser-lifecycle-v1", sessionId, sequence,
    ...snapshot(tabs, focused ? focused.id : -1)});
}
function changed() {
  // Serialize query + write so an old close snapshot cannot overtake a return.
  queue = queue.then(publish).catch(() => {
    chrome.action.setBadgeText({text: "!"});
    chrome.action.setTitle({title: "CogentSpec lifecycle: local host unavailable"});
  });
}
function connect() {
  if (port) return;
  const current = chrome.runtime.connectNative(HOST);
  port = current; epoch++;
  current.onMessage.addListener(message => {
    if (message.accepted === true) {
      chrome.action.setBadgeText({text: ""});
      chrome.action.setTitle({title: "CogentSpec lifecycle: local host connected"});
    }
  });
  current.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (port !== current) return;
    port = null; epoch++;
    clearInterval(heartbeat);
    chrome.action.setBadgeText({text: "!"});
    chrome.action.setTitle({title: "CogentSpec lifecycle: local host unavailable"});
    chrome.alarms.create("reconnect", {delayInMinutes: 0.5});
  });
  clearInterval(heartbeat);
  heartbeat = setInterval(changed, 3000);
  changed();
}
chrome.tabs.onActivated.addListener(changed);
chrome.tabs.onUpdated.addListener(changed);
chrome.tabs.onCreated.addListener(changed);
chrome.tabs.onRemoved.addListener(changed);
chrome.tabs.onAttached.addListener(changed);
chrome.tabs.onDetached.addListener(changed);
chrome.tabs.onReplaced.addListener(changed);
chrome.windows.onFocusChanged.addListener(changed);
chrome.windows.onRemoved.addListener(changed);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.onAlarm.addListener(alarm => {if (alarm.name === "reconnect") connect();});
connect();
