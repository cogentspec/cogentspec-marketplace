import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

const repositoryRoot = resolve(import.meta.dirname, "..");
const watcher = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "watch-cogentspec-popout-bridge.ps1");
const projectWatcher = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "watch-cogentstack-bridge.ps1");
const productionHelper = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "open-chatgpt-popup.ps1");
const fixtureRoot = await mkdtemp(join(tmpdir(), "cogentspec-popout-worker-test-"));
await new Promise((resolveProcess, rejectProcess) => {
  const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    join(repositoryRoot, "scripts", "test-popout-turn-identity.ps1")], { windowsHide: true });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  child.on("error", rejectProcess);
  child.on("exit", (code) => code === 0 ? resolveProcess() : rejectProcess(new Error(output)));
});
const helper = join(fixtureRoot, "open-chatgpt-popup.ps1");
const helperArguments = join(fixtureRoot, "helper-arguments.json");
const readyPath = join(fixtureRoot, "ready.json");

const productionHelperSource = await readFile(productionHelper, "utf8");
const watcherSource = await readFile(watcher, "utf8");
const projectWatcherSource = await readFile(projectWatcher, "utf8");
const popupWindowFinder = productionHelperSource.slice(
  productionHelperSource.indexOf("public static IntPtr[] FindPopupWindows"),
  productionHelperSource.indexOf("public static IntPtr[] FindMainWindows"),
);
assert.doesNotMatch(popupWindowFinder, /if \(!IsWindowVisible\(window\)\) return true;/);
assert.match(popupWindowFinder, /className\.ToString\(\), "Chrome_WidgetWin_1"/);
assert.match(productionHelperSource, /'Dismiss Popout Window'/);
assert.match(productionHelperSource, /function Find-ChatGptPopupWindowMatch/);
assert.match(productionHelperSource, /function Select-ChatGptPopupWindowMatch/);
assert.match(productionHelperSource, /\$visibleMatches\.Count -eq 1/);
assert.match(productionHelperSource, /\$PreferredWindowHandle -ne 0/);
assert.match(productionHelperSource, /verification = 'ambiguous_hidden_candidates'/);
assert.match(productionHelperSource, /'Work with ChatGPT', 'Ask ChatGPT anything locally'/);
assert.match(productionHelperSource, /\$MainWindowHandles -contains \$window\.ToInt64\(\)/);
const mainWindowBoundarySource = productionHelperSource.slice(
  productionHelperSource.indexOf("$chatGptMainWindowHandles ="),
  productionHelperSource.indexOf("$popupMatch =", productionHelperSource.indexOf("$chatGptMainWindowHandles =")),
);
assert.match(mainWindowBoundarySource, /FindMainWindows\(\$chatGptProcessIds\)/);
assert.doesNotMatch(mainWindowBoundarySource, /\.MainWindowHandle\b/);
assert.match(productionHelperSource, /'popup_specific_composer'/);
assert.match(productionHelperSource, /popup_detected_not_verified/);
assert.match(productionHelperSource, /ChatGPT Popout opened, but Desktop Bridge could not verify one safe composer window/);
assert.match(productionHelperSource, /return \[System\.Windows\.Automation\.Condition\]::TrueCondition/);
assert.match(productionHelperSource, /\$Element\.Current\.IsEnabled -and \$Element\.Current\.IsKeyboardFocusable/);
assert.match(productionHelperSource, /'Do anything'/);
const composerConditionSource = productionHelperSource.slice(
  productionHelperSource.indexOf("function Get-ChatGptComposerCondition"),
  productionHelperSource.indexOf("function Set-ChatGptComposerFocus"),
);
assert.doesNotMatch(composerConditionSource, /ControlTypeProperty/);
assert.match(productionHelperSource, /Working-screen[\s\S]*?Popout requests keep that pin/);
assert.match(productionHelperSource, /\$temporaryTopmostRestored = Restore-ChatGptPopupTopmost/);
assert.match(productionHelperSource, /\[switch\]\$KeepPinned/);
assert.match(productionHelperSource, /if \(-not \$KeepPinned\) \{[\s\S]*?\$temporaryTopmost = \$true/);
assert.match(productionHelperSource, /pinRequested = \[bool\]\$KeepPinned/);
assert.match(productionHelperSource, /pinned = \$popupPinned/);
assert.match(productionHelperSource, /\$popupPinned -ne \$shouldPin/);
assert.match(productionHelperSource, /the ChatGPT popout remained pinned/);
assert.match(productionHelperSource, /Ctrl\+Shift\+Space is a toggle/);
assert.match(productionHelperSource, /if \(-not \$activatedExisting -and -not \$popupCandidateDetected\)/);
assert.match(productionHelperSource, /-or \[bool\]\$popupMatch\.candidateDetected\) \{ break \}/);
assert.match(productionHelperSource, /A newly exposed Popout may omit its dismiss control while unpinned/);
assert.match(productionHelperSource, /CogentSpec opened the ChatGPT Popout but Windows could not pin it for composer input/);
assert.match(productionHelperSource, /popupVerification = \$popupVerification/);
assert.doesNotMatch(productionHelperSource, /AllowNativeRetainedFallback/);
assert.match(productionHelperSource, /if \(\$UseRetainedChat -and -not \$activatedExisting -and -not \$OpenWithShortcut\)/);
const retainedSafetyStart = productionHelperSource.indexOf("if ($UseRetainedChat -and -not $activatedExisting -and -not $OpenWithShortcut)");
const retainedSafetySource = productionHelperSource.slice(
  retainedSafetyStart,
  productionHelperSource.indexOf("$taskOwner =", retainedSafetyStart),
);
assert.match(retainedSafetySource, /retained_popup_not_visible/);
assert.match(retainedSafetySource, /Open ChatGPT Popout manually/);
assert.doesNotMatch(retainedSafetySource, /SendControlShiftSpace/);
assert.match(watcherSource, /\$target -eq 'chatgpt-desktop-popup:connect'[\s\S]*?-UseRetainedChat -OpenWithShortcut -KeepPinned -PasteClipboard/);
assert.match(watcherSource, /\$target -eq 'chatgpt-desktop-popup:update'[\s\S]*?-UseRetainedChat -KeepPinned -PasteClipboard/);
assert.match(watcherSource, /-Mode open -UseRetainedChat -KeepPinned/);
assert.match(productionHelperSource, /popupWindowHandle = \$popupWindow\.ToInt64\(\)/);
assert.match(productionHelperSource, /popupProcessId = \[CogentSpec\.ChatGptPopupNative\]::GetProcessId\(\$popupWindow\)/);
assert.match(productionHelperSource, /pinShortcut = 'Ctrl\+Shift\+Y'/);
assert.match(productionHelperSource, /function Get-ChatGptConversationFingerprint/);
assert.match(productionHelperSource, /function Get-ChatGptConversationObservation/);
assert.match(productionHelperSource, /\$speaker -cne 'You said:'/);
assert.match(productionHelperSource, /\$messageParts = \[Collections\.Generic\.List\[string\]\]::new\(\)/);
assert.match(productionHelperSource, /\$messageParts\.Add\(\$part\)/);
assert.match(productionHelperSource, /\$message = \(\(\$messageParts -join ''\) -replace '\\s\+', ''\)\.Trim\(\)/);
assert.doesNotMatch(productionHelperSource, /\$message = \(\(\[string\]\$textElements\.Item\(\$index \+ 1\)\.Current\.Name\)/);
assert.match(productionHelperSource, /\$message -ceq '\$cogentspec'/);
assert.match(productionHelperSource, /conversationState = \[string\]\$conversation\.state/);
assert.match(productionHelperSource, /currentConversationKey = \[string\]\$conversation\.currentConversationKey/);
assert.match(productionHelperSource, /chatFingerprint = \$chatFingerprint/);
assert.match(watcherSource, /class ChatGptPopupPinHotkey/);
assert.match(watcherSource, /WH_KEYBOARD_LL/);
assert.doesNotMatch(watcherSource, /RegisterHotKey/);
assert.match(watcherSource, /IsVerifiedForegroundPopup\(foreground\)/);
assert.match(watcherSource, /window\.ToInt64\(\) != expectedWindow/);
assert.match(watcherSource, /processId == \(uint\)expectedProcess/);
assert.match(watcherSource, /\[int\]\$inspection\.popupProcessId/);
assert.match(watcherSource, /private const int VK_Y = 0x59/);
assert.match(watcherSource, /Interlocked\.Exchange\(ref capturedY, 1\)/);
assert.match(watcherSource, /SWP_NOMOVE \| SWP_NOSIZE \| SWP_NOACTIVATE/);
assert.match(watcherSource, /SetVerifiedPopup\(0, 0\)/);
assert.match(watcherSource, /if \(\$TestToken\) \{ return \}/);
assert.match(watcherSource, /\$script:ActiveChatFingerprint/);
assert.match(watcherSource, /\$script:CurrentConversationState/);
assert.match(watcherSource, /\$script:CurrentConversationKey/);
assert.match(watcherSource, /\$script:CurrentPopupWindowHandle/);
assert.match(watcherSource, /\$inspectionArguments\.PreferredWindowHandle = \[long\]\$script:CurrentPopupWindowHandle/);
assert.match(watcherSource, /popupVisible=' \+ \$script:VerifiedPopupVisible/);
assert.match(watcherSource, /conversationState=' \+ \[Uri\]::EscapeDataString/);
assert.match(watcherSource, /currentConversationKey=' \+ \[Uri\]::EscapeDataString/);
assert.match(watcherSource, /chatFingerprint=' \+ \[Uri\]::EscapeDataString/);
assert.match(projectWatcherSource, /targetRequestId -eq 'chatgpt-desktop-popup:connect'[\s\S]*?'-UseRetainedChat', '-OpenWithShortcut'/);
assert.match(projectWatcherSource, /targetRequestId -eq 'chatgpt-desktop-popup:update'[\s\S]*?\$arguments \+= '-UseRetainedChat'/);
assert.match(projectWatcherSource, /if \(-not \$desktopUiRequest\) \{[\s\S]*?\$arguments \+= '-KeepPinned'/);
assert.doesNotMatch(productionHelperSource, /\$verifiedRetainedPopup = Find-VerifiedChatGptPopupWindow -ProcessIds \$chatGptProcessIds -AllowNativeRetainedFallback \$false/);
assert.match(productionHelperSource, /if \(-not \$activatedExisting -and -not \(Invoke-PopupActivation -PopupWindow \$popupWindow\)\)/);
const composerFailureSource = productionHelperSource.slice(
  productionHelperSource.lastIndexOf("if ($PasteClipboard)"),
  productionHelperSource.lastIndexOf("$temporaryTopmostRestored ="),
);
assert.doesNotMatch(composerFailureSource, /SendControlShiftSpace|RequestClosePopup|restoreDeadline/);
assert.match(composerFailureSource, /A Popout connection failure must fail in the Popout/);
assert.doesNotMatch(productionHelperSource, /found the retained ChatGPT popout but could not make it ready for reconnection/);
assert.doesNotMatch(popupWindowFinder, /bool isPopupToolWindow/);

await writeFile(helper, `
param([string]$Mode, [switch]$UseRetainedChat, [switch]$OpenWithShortcut, [switch]$KeepPinned, [switch]$PasteClipboard, [long]$PreferredWindowHandle = 0)
if ($Mode -eq 'inspect') {
  [ordered]@{ status = 'ready'; publisherVerified = $true; popupVerified = $true; popupVisible = $false; popupWindowHandle = 1234; popupProcessId = 5678; conversationState = 'identified'; currentConversationKey = '${"a".repeat(64)}'; chatFingerprint = '${"a".repeat(64)}' } | ConvertTo-Json -Compress
  return
}
[ordered]@{ mode = $Mode; useRetainedChat = [bool]$UseRetainedChat; openWithShortcut = [bool]$OpenWithShortcut; keepPinned = [bool]$KeepPinned; pasteClipboard = [bool]$PasteClipboard } |
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
  assert.equal(calls.some((call) => call.method === "GET" && call.url.includes("popupVisible=false")
    && call.url.includes("conversationState=identified")
    && call.url.includes(`currentConversationKey=${"a".repeat(64)}`)
    && call.url.includes(`chatFingerprint=${"a".repeat(64)}`)), true, JSON.stringify(calls));
  assert.equal(calls.some((call) => call.method === "PATCH" && JSON.parse(call.body).action === "claim"), true);
  assert.equal(calls.some((call) => call.method === "PATCH" && JSON.parse(call.body).action === "complete"), true);
  const helperResult = JSON.parse((await readFile(helperArguments, "utf8")).replace(/^\uFEFF/, ""));
  assert.deepEqual(helperResult, { mode: "open", useRetainedChat: true, openWithShortcut: true, keepPinned: true, pasteClipboard: true });
  const ready = JSON.parse((await readFile(readyPath, "utf8")).replace(/^\uFEFF/, ""));
  assert.equal(ready.serverAcknowledged, true);
  assert.equal(ready.pluginId, "cogentspec");
  assert.equal(ready.pinHotkey, "Ctrl+Shift+Y");
  assert.equal(ready.pinHotkeyReady, false);
  assert.equal(ready.pinHotkeyScope, "verified_foreground_chatgpt_popout");
  assert.equal(ready.popupVisible, false);
  assert.equal(ready.conversationState, "identified");
  assert.equal(ready.currentConversationKey, "a".repeat(64));
  assert.equal(ready.connectedChatMarkerFound, true);
  console.log(JSON.stringify({ status: "valid", lifecycle, transientRecovery: true, markerStatuses: [...new Set(markerStatuses)], getAttempts, calls: calls.length, helper: helperResult, workerOutput: output.stdout.trim() }));
} finally {
  await new Promise((resolveClose) => server.close(resolveClose));
  await rm(fixtureRoot, { recursive: true, force: true });
}
