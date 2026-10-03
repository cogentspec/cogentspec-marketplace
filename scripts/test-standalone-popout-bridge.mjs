import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

const repositoryRoot = resolve(import.meta.dirname, "..");
const watcher = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "watch-cogentspec-popout-bridge.ps1");
const productionHelper = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "open-chatgpt-popup.ps1");
const fixtureRoot = await mkdtemp(join(tmpdir(), "cogentspec-popout-worker-test-"));
const helper = join(fixtureRoot, "open-chatgpt-popup.ps1");
const helperArguments = join(fixtureRoot, "helper-arguments.json");
const readyPath = join(fixtureRoot, "ready.json");

const productionHelperSource = await readFile(productionHelper, "utf8");
const popupWindowFinder = productionHelperSource.slice(
  productionHelperSource.indexOf("public static IntPtr[] FindPopupWindows"),
  productionHelperSource.indexOf("public static IntPtr[] FindMainWindows"),
);
assert.match(popupWindowFinder, /if \(!IsWindowVisible\(window\)\) return true;/);
assert.match(productionHelperSource, /'Dismiss Popout Window'/);
assert.match(productionHelperSource, /\[System\.Windows\.Automation\.ControlType\]::Document/);
assert.match(productionHelperSource, /Re-run ChatGPT's own popout hotkey so ChatGPT re-presents the\s+# retained chat and exposes its composer before CogentSpec tries to paste\./);
assert.match(productionHelperSource, /\$verifiedRetainedPopup = Find-VerifiedChatGptPopupWindow -ProcessIds \$chatGptProcessIds -AllowNativeRetainedFallback \$false/);
assert.match(productionHelperSource, /if \(-not \$UseRetainedChat -and -not \(Invoke-PopupActivation -PopupWindow \$popupWindow\)\)/);
assert.doesNotMatch(productionHelperSource, /found the retained ChatGPT popout but could not make it ready for reconnection/);
assert.doesNotMatch(popupWindowFinder, /className\.ToString\(\), "Chrome_WidgetWin_1"/);
assert.doesNotMatch(popupWindowFinder, /bool isPopupToolWindow/);

await writeFile(helper, `
param([string]$Mode, [switch]$UseRetainedChat, [switch]$PasteClipboard)
[ordered]@{ mode = $Mode; useRetainedChat = [bool]$UseRetainedChat; pasteClipboard = [bool]$PasteClipboard } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath '${helperArguments.replaceAll("'", "''")}' -Encoding UTF8
[ordered]@{ status = 'opened'; opened = $true; composerPopulated = [bool]$PasteClipboard } | ConvertTo-Json -Compress
`, "utf8");

const request = {
  id: "fixture-popout-action",
  action: "open_chatgpt_popup",
  targetRequestId: "chatgpt-desktop-popup:connect",
  status: "requested",
  statusMessage: "",
};
let lifecycle = "requested";
let transientFailuresRemaining = 2;
let getAttempts = 0;
const calls = [];
const server = createServer(async (incoming, response) => {
  if (incoming.method === "GET") {
    getAttempts += 1;
    if (transientFailuresRemaining > 0) {
      transientFailuresRemaining -= 1;
      incoming.socket.destroy();
      return;
    }
  }
  let body = "";
  for await (const chunk of incoming) body += chunk;
  calls.push({ method: incoming.method, url: incoming.url, authorization: incoming.headers.authorization, body });
  response.setHeader("content-type", "application/json");
  if (incoming.headers.authorization !== "Bearer fixture-token") {
    response.statusCode = 401;
    response.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }
  if (incoming.method === "GET") {
    response.end(JSON.stringify({ request: lifecycle === "requested" ? request : null, bridge: { ready: true } }));
    return;
  }
  const payload = JSON.parse(body);
  if (payload.action === "claim" && lifecycle === "requested") {
    lifecycle = "processing";
    response.end(JSON.stringify({ request: { ...request, status: lifecycle } }));
    return;
  }
  if (payload.action === "complete" && lifecycle === "processing") {
    lifecycle = "completed";
    response.end(JSON.stringify({ request: { ...request, status: lifecycle, statusMessage: payload.statusMessage } }));
    return;
  }
  response.statusCode = 409;
  response.end(JSON.stringify({ error: "invalid lifecycle" }));
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const address = server.address();
assert.equal(typeof address, "object");
const serviceUrl = `http://127.0.0.1:${address.port}`;

try {
  const markerStatuses = [];
  const markerObserver = setInterval(async () => {
    try {
      const marker = JSON.parse((await readFile(readyPath, "utf8")).replace(/^\uFEFF/, ""));
      markerStatuses.push(marker.status);
    } catch {
      // The worker may not have created the marker yet, or may be replacing it.
    }
  }, 25);
  let output;
  try {
    output = await new Promise((resolveProcess, rejectProcess) => {
    const child = spawn("powershell.exe", [
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", watcher,
      "-PluginId", "cogentspec", "-PluginVersion", "0.6.58",
      "-ReadyPath", readyPath, "-PollMilliseconds", "500", "-MaxPolls", "3",
      "-ServiceUrl", serviceUrl, "-TestToken", "fixture-token", "-TestHelperPath", helper,
    ], { windowsHide: true });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", rejectProcess);
    child.on("exit", (code) => code === 0
      ? resolveProcess({ stdout, stderr })
      : rejectProcess(new Error(`worker exited ${code}: ${stderr || stdout}`)));
    });
  } finally {
    clearInterval(markerObserver);
  }
  assert.equal(lifecycle, "completed");
  assert.equal(transientFailuresRemaining, 0);
  assert.equal(getAttempts >= 2, true);
  assert.equal(markerStatuses.includes("retrying"), true);
  assert.equal(calls.some((call) => call.method === "GET" && call.url.includes("/api/plugin/desktop-popout-actions?pluginId=cogentspec&pluginVersion=0.6.58")), true);
  assert.equal(calls.some((call) => call.method === "PATCH" && JSON.parse(call.body).action === "claim"), true);
  assert.equal(calls.some((call) => call.method === "PATCH" && JSON.parse(call.body).action === "complete"), true);
  const helperResult = JSON.parse((await readFile(helperArguments, "utf8")).replace(/^\uFEFF/, ""));
  assert.deepEqual(helperResult, { mode: "open", useRetainedChat: true, pasteClipboard: true });
  const ready = JSON.parse((await readFile(readyPath, "utf8")).replace(/^\uFEFF/, ""));
  assert.equal(ready.serverAcknowledged, true);
  assert.equal(ready.pluginId, "cogentspec");
  console.log(JSON.stringify({ status: "valid", lifecycle, transientRecovery: true, markerStatuses: [...new Set(markerStatuses)], getAttempts, calls: calls.length, helper: helperResult, workerOutput: output.stdout.trim() }));
} finally {
  await new Promise((resolveClose) => server.close(resolveClose));
  await rm(fixtureRoot, { recursive: true, force: true });
}
