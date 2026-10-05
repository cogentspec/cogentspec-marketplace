import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

const watcher = resolve(import.meta.dirname, "../plugins/cogentspec/skills/cogentspec/scripts/watch-cogentspec-popout-bridge.ps1");
const threadId = "11111111-1111-1111-1111-111111111111";
for (const scenario of ["saved-thread", "no-thread", "switched-chat", "switched-before-claim", "dismissed-toast"]) {
  const root = await mkdtemp(join(tmpdir(), "cogentspec-retained-recovery-"));
  const helper = join(root, "helper.ps1");
  const outputPath = join(root, "dispatch.json");
  await writeFile(helper, `
param([string]$Mode, [string]$ThreadId, [switch]$PasteClipboard, [long]$PreferredWindowHandle)
if ($Mode -eq 'inspect') {
  if (-not (Get-Variable fixtureInspection -Scope Global -ErrorAction SilentlyContinue)) { $global:fixtureInspection = 0 }
  $global:fixtureInspection++
  $key = '${"a".repeat(64)}'
  if ('${scenario}' -eq 'switched-chat' -and $global:fixtureInspection -gt 1) { $key = '${"b".repeat(64)}' }
  if ('${scenario}' -eq 'switched-before-claim') { $key = '${"b".repeat(64)}' }
  $missing = -not ('${scenario}' -eq 'dismissed-toast' -and $global:fixtureInspection -gt 1)
  @{ status='ready'; publisherVerified=$true; popupVerified=$true; popupVisible=$true;
     popupWindowHandle=1234; popupProcessId=5678; conversationState='identified';
     currentConversationKey=$key; chatFingerprint=$key; clientUnavailable=$missing } | ConvertTo-Json -Compress
  return
}
@{ mode=$Mode; threadId=$ThreadId; pasteClipboard=[bool]$PasteClipboard } | ConvertTo-Json -Compress |
  Set-Content -LiteralPath '${outputPath.replaceAll("'", "''")}' -Encoding UTF8
@{ status='recovery_requested'; opened=$false; clientResumeConfirmed=$false;
   reason='Saved chat requested; connection not yet confirmed.' } | ConvertTo-Json -Compress
`, "utf8");
  let finish;
  const queries = [];
  const request = { id: "retained-fixture", targetRequestId: "chatgpt-desktop-popup:connect",
    recoveryThreadId: scenario === "no-thread" ? null : threadId, recoveryChatFingerprint: "a".repeat(64) };
  const server = createServer(async (incoming, response) => {
    response.setHeader("content-type", "application/json");
    if (incoming.method === "GET") {
      queries.push(new URL(incoming.url, "http://localhost").searchParams);
      response.end(JSON.stringify({ request, bridge: { ready: true } }));
      return;
    }
    let body = "";
    for await (const chunk of incoming) body += chunk;
    const payload = JSON.parse(body);
    if (payload.action !== "claim") finish = payload;
    response.end(JSON.stringify({ request }));
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  try {
    await new Promise((done, reject) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", watcher,
        "-PluginId", "cogentspec", "-PluginVersion", "0.6.82", "-ReadyPath", join(root, "ready.json"),
        "-MaxPolls", "1", "-ServiceUrl", `http://127.0.0.1:${server.address().port}`,
        "-TestToken", "fixture-token", "-TestHelperPath", helper], { windowsHide: true });
      let output = "";
      child.stdout.on("data", (chunk) => { output += chunk; });
      child.stderr.on("data", (chunk) => { output += chunk; });
      child.on("error", reject);
      child.on("exit", (code) => code === 0 ? done() : reject(new Error(output)));
    });
    assert.equal(queries[0].get("conversationState"), "unknown", scenario);
    assert.equal(finish.action, "fail", "Recovery dispatch must not confirm connection");
    if (["saved-thread", "dismissed-toast"].includes(scenario)) {
      const dispatch = JSON.parse((await readFile(outputPath, "utf8")).replace(/^\uFEFF/, ""));
      assert.deepEqual(dispatch, { mode: "recover", threadId, pasteClipboard: false });
    } else {
      await assert.rejects(readFile(outputPath), { code: "ENOENT" });
      assert.match(finish.statusMessage, /No verified thread/);
    }
    console.log(`PASS: ${scenario}; no paste, no send, no false green`);
  } finally {
    await new Promise((done) => server.close(done));
    await rm(root, { recursive: true, force: true });
  }
}
