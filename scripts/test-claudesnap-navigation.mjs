import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { runInNewContext } from "node:vm";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const context = "ctx-" + "a".repeat(64);
const url = "https://cogentspec.app/stack?surface=claude-desktop&context=" + context
  + "&experience=split-screen&open=web&nav=" + "b".repeat(32)
  + "#desktop-web=cgw_" + "c".repeat(40);

async function verifyDelivery(result) {
  assert.equal(result.status, "ready");
  assert.equal(result.browserOpened, false);
  assert.equal(result.browserNavigationProtocol, "cogentspec-claudesnap-navigation-v1");
  const exactCall = /^await claudeSnapTab\.goto\(("(?:[^"\\]|\\.)*")\);$/.exec(result.browserNavigationCode);
  assert.ok(exactCall, "Navigation must be one JSON-quoted call on the claimed external tab");
  assert.equal(JSON.parse(exactCall[1]), result.workspaceUrl);
  const destination = new URL(result.workspaceUrl);
  assert.equal(destination.origin, "https://cogentspec.app");
  assert.equal(destination.pathname, "/stack");
  assert.equal(destination.searchParams.get("context"), result.contextKey);
  assert.equal(destination.searchParams.get("experience"), "split-screen");
  assert.match(destination.hash, /^#desktop-web=cgw_[A-Za-z0-9_-]{32,}$/);
  const calls = [];
  await runInNewContext("(async () => { " + result.browserNavigationCode + " })()", {
    claudeSnapTab: { goto: async target => calls.push(target) },
    open_in_codex: () => { throw Error("Embedded browser must not be opened"); },
    gptWebTab: { goto: () => { throw Error("GPTWeb must not replace ClaudeSnap"); } },
  }, { timeout: 1000 });
  assert.deepEqual(calls, [result.workspaceUrl]);
}

if (process.argv.includes("--launcher-result")) {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  await verifyDelivery(JSON.parse(input.replace(/^\uFEFF/, "")));
  console.log(JSON.stringify({ status: "valid", externalTabOnly: true, exactHandoff: true, navigationCalls: 1 }));
} else {
  test("real PowerShell navigation function preserves the handoff and rejects wrong destinations", {
    skip: process.platform !== "win32" ? "Windows PowerShell fixture" : false,
  }, async () => {
    const script = String.raw`
$source = Join-Path (Get-Location) 'plugins/cogentspec/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Launcher syntax failed' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ClaudeSnapBrowserNavigation' }, $true)
if (-not $definition) { throw 'Navigation function missing' }
. ([ScriptBlock]::Create($definition.Extent.Text))
$key = 'ctx-' + ('a' * 64)
$url = 'https://cogentspec.app/stack?surface=claude-desktop&context=' + $key + '&experience=split-screen&open=web&nav=' + ('b' * 32) + '#desktop-web=cgw_' + ('c' * 40)
$nav = Get-ClaudeSnapBrowserNavigation $url $key 'claude-desktop'
$badUrls = @(
    $url.Replace('cogentspec.app', 'untrusted.example'),
    $url.Replace('/stack?', '/popout-launch?'),
    $url.Replace('experience=split-screen', 'experience=desktop-ui'),
    $url.Replace('experience=split-screen', 'experience=popout'),
    $url.Replace('experience=split-screen', 'experience=web'),
    $url.Replace('open=web', 'open=chatgpt'),
    $url.Replace('#desktop-web=', '#desktop-chatgpt='),
    $url.Replace('#desktop-web=', '#desktop='),
    $url.Replace('context=' + $key, 'context=ctx-' + ('d' * 64)),
    $url.Replace('&open=web', '&experience=split-screen&open=web'),
    $url.Replace('#desktop-web=cgw_' + ('c' * 40), '')
)
$rejected = 0
foreach ($bad in $badUrls) {
    try { [void](Get-ClaudeSnapBrowserNavigation $bad $key 'claude-desktop') }
    catch { $rejected += 1 }
}
foreach ($pair in @(@($url, 'unscoped', 'claude-desktop'), @($url, $key, 'chatgpt'))) {
    try { [void](Get-ClaudeSnapBrowserNavigation $pair[0] $pair[1] $pair[2]) }
    catch { $rejected += 1 }
}
[ordered]@{
 status='ready'; browserOpened=$false; contextKey=$key; workspaceUrl=$url
 browserNavigationProtocol=$nav.protocol; browserNavigationCode=$nav.code
 rejected=$rejected; expectedRejected=$badUrls.Count + 2
} | ConvertTo-Json -Compress
`;
    const executed = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
      cwd: root, encoding: "utf8", timeout: 15000,
    });
    assert.equal(executed.status, 0, executed.stderr);
    const result = JSON.parse(executed.stdout.trim().replace(/^\uFEFF/, ""));
    assert.equal(result.rejected, result.expectedRejected);
    assert.equal(result.rejected, 13);
    await verifyDelivery(result);
  });

  test("delivery regression fails if an embedded or different destination is substituted", async () => {
    const good = { status: "ready", browserOpened: false, contextKey: context, workspaceUrl: url,
      browserNavigationProtocol: "cogentspec-claudesnap-navigation-v1",
      browserNavigationCode: "await claudeSnapTab.goto(" + JSON.stringify(url) + ");" };
    await verifyDelivery(good);
    for (const code of [
      "await open_in_codex(" + JSON.stringify(url) + ");",
      good.browserNavigationCode.replace("claudeSnapTab", "gptWebTab"),
      good.browserNavigationCode.replace("split-screen", "desktop-ui"),
      good.browserNavigationCode + good.browserNavigationCode,
    ]) await assert.rejects(verifyDelivery({ ...good, browserNavigationCode: code }));
  });

  test("both ClaudeSnap instructions connect the explicitly listening Claude split work area", () => {
  for(const plugin of ['cogentspec','cogentstack']) {
    const skill=readFileSync(resolve(root,'claude-plugins',plugin,'skills/claudesnap/SKILL.md'),'utf8');
    for(const marker of ['Initiate Bridge','claude-desktop / split-screen','acknowledgementVerified: true','browserOpened: false','Never open']) assert.ok(skill.includes(marker),marker);
    assert.doesNotMatch(skill,/claudeSnapTab\.goto|open_in_codex/);
  }
});
}
