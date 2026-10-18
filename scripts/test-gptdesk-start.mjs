import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const repository = resolve(import.meta.dirname, '..');
const context = 'ctx-' + 'a'.repeat(64);
const versions = { cogentspec: ['0.6.145', '0.6.146'], cogentstack: ['0.5.134', '0.5.135'] };
const powershell = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

async function put(path, text) {
  await mkdir(resolve(path, '..'), { recursive: true });
  await writeFile(path, text, 'utf8');
}
async function run(file, args, env, cwd) {
  return await new Promise((resolveRun, reject) => {
    const child = spawn(file, args, { env, cwd, windowsHide: true });
    let stdout = '', stderr = '';
    const timeout = setTimeout(() => { child.kill(); reject(new Error('Fixture escaped its outer safety limit')); }, 25000);
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', error => { clearTimeout(timeout); reject(error); });
    child.on('close', code => { clearTimeout(timeout); resolveRun({ code, stdout, stderr }); });
  });
}

const stub = String.raw`
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:DESK_FIXTURE_TRACE -Value ($env:DESK_FIXTURE_LABEL + ':' + [IO.Path]::GetFileName($PSCommandPath))
$scenario = $env:DESK_FIXTURE_SCENARIO
$context = 'ctx-' + ('a' * 64)
switch ([IO.Path]::GetFileName($PSCommandPath)) {
 'check-cogentspec-update.ps1' {
  if ($scenario -eq 'stall') { [string]$PID | Set-Content -LiteralPath $env:DESK_FIXTURE_PID; Start-Sleep -Seconds 20 }
  if ($scenario -eq 'malformed') { Write-Output 'PRIVATE_HANDOFF_DO_NOT_PRINT'; [Console]::Error.WriteLine('PRIVATE_HANDOFF_DO_NOT_PRINT'); exit 1 }
  $status = if ($scenario.StartsWith('update') -or $scenario -in @('wrong-source', 'upgrade-failed')) { 'update_available' }
    elseif ($scenario -eq 'offline') { 'check_unavailable' } elseif ($scenario -eq 'permission') { 'execution_permission_required' } else { 'current' }
  @{ status = $status; userMessage = 'Fixture permission required.' } | ConvertTo-Json -Compress
 }
 'project-context.ps1' { @{ isolated = ($scenario -ne 'unscoped'); contextKey = $context } | ConvertTo-Json -Compress }
 'start-cogentstack-bridge.ps1' {
  if ($args.Count -ne 6 -or $args[0] -ne '-ContextKey' -or $args[1] -ne $context -or $args[2] -ne '-Surface' -or $args[3] -ne 'chatgpt' -or $args[4] -ne '-Experience' -or $args[5] -ne 'desktop-ui') { throw 'Wrong destination arguments' }
  if ($scenario -eq 'connection-required') { @{ status = 'connection_required'; userMessage = 'Fixture connection needs permission.' } | ConvertTo-Json -Compress; return }
  if ($scenario -in @('preview', 'preview-wrong-origin', 'preview-wrong-context')) {
    $previewContext = if ($scenario -eq 'preview-wrong-context') { 'ctx-' + ('b' * 64) } else { $context }
    $url = "https://cogentspec.app/stack?surface=chatgpt&context=$previewContext&experience=desktop-ui&preview=1"
    if ($scenario -eq 'preview-wrong-origin') { $url = $url.Replace('cogentspec.app','attacker.invalid') }
    @{ status = 'preview'; contextKey = $previewContext; previewUrl = $url; userMessage = 'No active licence. Preview only.' } | ConvertTo-Json -Compress
    return
  }
  $base = "https://cogentspec.app/stack?surface=chatgpt&context=$context&experience=desktop-ui"
  if ($scenario -eq 'wrong-origin') { $base = $base.Replace('cogentspec.app','cogentspec.app.evil.invalid') }
  if ($scenario -eq 'wrong-mode') { $base = $base.Replace('desktop-ui','popout') }
  if ($scenario -eq 'duplicate-mode') { $base += '&experience=desktop-ui' }
  if ($scenario -eq 'wrong-context') { $base = $base.Replace($context, 'ctx-' + ('b' * 64)) }
  $native = $base + '&open=chatgpt&nav=' + ('b' * 32) + '#desktop-chatgpt=' + ('c' * 40)
  $web = $base + '&open=web&nav=' + ('b' * 32) + '#desktop-web=' + ('d' * 40)
  $selected = if ($scenario -eq 'wrong-alias') { $web } else { $native }
  $verified = $scenario -ne 'unverified'
  $result = @{ status = 'ready'; bridge = 'already_running'; accountState = 'signed_in'; mcpState = 'ready'; browserOpened = ($scenario -eq 'already-opened'); contextKey = $context; workspaceUrl = $selected; chatgptWorkspaceUrl = $native; webWorkspaceUrl = $web; currentConversationConnected = $verified; conversationVerification = 'desktop_thread_presence'; conversationConnectionReason = if ($verified) { 'desktop_thread_presence_confirmed' } else { 'current_desktop_conversation_not_verified' }; conversationUserMessage = if ($verified) { 'The current GPT Desk conversation is connected.' } else { 'Fixture conversation remains unverified.' }; popoutConnectionConfirmed = $false; launcherElapsedMs = 1; popoutConnectionReason = 'not_applicable'; popoutUserMessage = 'Legacy fallback.' }
  if ($scenario -eq 'legacy-confirmed') { $result.Remove('currentConversationConnected'); $result.popoutConnectionConfirmed = $true }
  $result | ConvertTo-Json -Compress
 }
 default { throw 'Unexpected helper' }
}
`;

async function exercise(plugin, scenario) {
  const root = await mkdtemp(join(tmpdir(), 'gptdesk fast fixture '));
  assert.equal(resolve(root, '..'), resolve(tmpdir()));
  const pluginRoot = join(root, 'old package', plugin);
  const refreshed = join(root, 'refreshed package', plugin);
  const marketplace = join(root, 'marketplace');
  const trace = join(root, 'trace.txt');
  const pidFile = join(root, 'child.pid');
  const bin = join(root, 'bin');
  const env = { ...process.env, PATH: bin + ';' + process.env.PATH, DESK_FIXTURE_SCENARIO: scenario, DESK_FIXTURE_TRACE: trace, DESK_FIXTURE_PID: pidFile, DESK_FIXTURE_MARKETPLACE: marketplace, DESK_FIXTURE_REFRESHED: refreshed, DESK_FIXTURE_VERSION: versions[plugin][1] };
  try {
    for (const [packageRoot, label, version] of [[pluginRoot, 'old', versions[plugin][0]], [refreshed, 'new', versions[plugin][1]]]) {
      await put(join(packageRoot, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version }));
      for (const name of ['check-cogentspec-update.ps1', 'project-context.ps1', 'start-cogentstack-bridge.ps1']) {
        await put(join(packageRoot, 'skills', plugin, 'scripts', name), `$env:DESK_FIXTURE_LABEL = '${label}'\n` + stub);
      }
    }
    const driver = join(pluginRoot, 'skills', 'gptdesk', 'scripts', 'start-gptdesk.ps1');
    await put(driver, await readFile(join(repository, 'plugins', plugin, 'skills', 'gptdesk', 'scripts', 'start-gptdesk.ps1'), 'utf8'));
    await put(join(bin, 'codex.cmd'), `@echo off\r\n"${process.execPath}" "${join(bin, 'codex.mjs')}" %*\r\n`);
    await put(join(bin, 'codex.mjs'), `
import { appendFileSync } from 'node:fs';
const args=process.argv.slice(2), scenario=process.env.DESK_FIXTURE_SCENARIO;
appendFileSync(process.env.DESK_FIXTURE_TRACE,'codex:'+args.join(' ')+'\\n');
if(args.join(' ')==='plugin marketplace list --json') console.log(JSON.stringify({marketplaces:[{name:'cogentstack', root:process.env.DESK_FIXTURE_MARKETPLACE,marketplaceSource:{source:scenario==='wrong-source'?'https://evil.invalid/repo.git':'https://github.com/cogentspec/cogentspec-marketplace.git'}}]},null,2));
else if(args.join(' ')==='plugin marketplace upgrade cogentstack --json') console.log(JSON.stringify({errors:scenario==='upgrade-failed'?['failed']:[]},null,2));
else process.exit(1);
`);
    await put(join(marketplace, '.agents', 'plugins', `install-${plugin}.ps1`), String.raw`
param([switch]$UpdateOnly,[switch]$MarketplacePrepared,[int]$InstallerTimeoutSeconds)
if (-not $UpdateOnly -or -not $MarketplacePrepared -or $InstallerTimeoutSeconds -ne 120 -or $args.Count) { throw 'Unsafe update arguments' }
Add-Content -LiteralPath $env:DESK_FIXTURE_TRACE -Value 'installer:update-only'
if ($env:DESK_FIXTURE_SCENARIO -eq 'update-stall') { [string]$PID | Set-Content -LiteralPath $env:DESK_FIXTURE_PID; Start-Sleep -Seconds 20 }
$result = @{ protocol = 'trusted-marketplace-update-v1'; status = 'updated'; credentialPreserved = ($env:DESK_FIXTURE_SCENARIO -ne 'update-bad-contract'); previousPackageReplaced = $true; packageRuntimeCleared = $true; workerStateCleared = $true; popoutBridgeReady = $true; desktopUiBridgeReady = $true; projectDataConnectionReady = $true; continueCurrentTask = $true; fastUpdatePath = $true; workspaceReadinessSkipped = $true; claimAttempted = $false; accountRequestConsumed = $false; refreshedPluginPath = $env:DESK_FIXTURE_REFRESHED; version = $env:DESK_FIXTURE_VERSION; installerElapsedMs = 1; installerBudgetSeconds = 110 }
if ($env:DESK_FIXTURE_SCENARIO -eq 'update-missing-contract') { $result = @{ status = 'updated' } }
$result | ConvertTo-Json -Compress
`);
    const began = performance.now();
    const resume = ['resume-update', 'resume-wrong-version'].includes(scenario);
    const runResult = await run(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', driver,
      ...(resume ? ['-UpdateAlreadyVerified', '-VerifiedInstalledVersion', scenario === 'resume-wrong-version' ? '0.0.1' : versions[plugin][0]] : []),
      ...(scenario === 'stall' ? ['-WorkflowTimeoutSeconds', '2'] : scenario === 'update-stall' ? ['-WorkflowTimeoutSeconds', '5'] : [])], env, root);
    assert.equal(runResult.code, 0, runResult.stderr);
    const result = JSON.parse(runResult.stdout.trim());
    const lines = (await readFile(trace, 'utf8').catch(error => { if (error.code === 'ENOENT') return ''; throw error; })).trim().split(/\r?\n/);
    assert.equal(result.protocol, 'cogentspec-gptdesk-start-v1');
    assert.equal(lines.filter(line => line.endsWith('check-cogentspec-update.ps1')).length, resume ? 0 : 1);
    const ready = ['current', 'confirmed', 'legacy-confirmed', 'unverified', 'offline', 'update', 'resume-update'].includes(scenario);
    if (ready) {
      assert.equal(result.status, 'ready');
      assert.equal(result.currentConversationConnected, scenario !== 'unverified');
      if (scenario !== 'legacy-confirmed') {
        assert.equal(result.conversationVerification, 'desktop_thread_presence');
        assert.equal(result.conversationConnectionReason, scenario === 'unverified'
          ? 'current_desktop_conversation_not_verified' : 'desktop_thread_presence_confirmed');
      }
      assert.equal(lines.filter(line => line.endsWith('project-context.ps1')).length, 1);
      assert.equal(lines.filter(line => line.endsWith('start-cogentstack-bridge.ps1')).length, 1);
      assert.equal(result.workflowBudgetSeconds, 100);
      if (resume) assert.equal(result.updateStatus, 'verified_update');
      if (scenario === 'update') {
        assert.equal(result.pluginVersion, versions[plugin][1]);
        assert.equal(lines.filter(line => line === 'codex:plugin marketplace list --json').length, 2);
        assert.equal(lines.filter(line => line === 'codex:plugin marketplace upgrade cogentstack --json').length, 1);
        assert.equal(lines.filter(line => line === 'installer:update-only').length, 1);
        assert.ok(lines.includes('new:project-context.ps1'));
        assert.ok(lines.includes('new:start-cogentstack-bridge.ps1'));
        assert.ok(!lines.includes('old:project-context.ps1'));
        assert.equal(result.installedVersion, versions[plugin][1]);
      } else {
        assert.ok(!lines.some(line => line.startsWith('codex:') || line.startsWith('installer:')));
      }
    } else if (scenario === 'preview') {
      assert.equal(result.status, 'preview');
      assert.equal(result.contextKey, context);
      assert.equal(result.currentConversationConnected, false);
      assert.equal(result.canUsePaidWorkspace, false);
      assert.match(result.previewUrl, /^https:\/\/cogentspec\.app\/stack\?/);
      assert.ok(result.previewUrl.endsWith('&experience=desktop-ui&preview=1'));
      assert.equal(result.previewUrl.includes('#'), false);
    } else {
      assert.notEqual(result.status, 'ready');
      assert.equal(result.workspaceUrl, undefined);
      assert.ok(!runResult.stdout.includes('PRIVATE_HANDOFF_DO_NOT_PRINT'));
      assert.ok(lines.filter(line => line.endsWith('start-cogentstack-bridge.ps1')).length <= 1);
      if (['permission', 'malformed', 'wrong-source', 'upgrade-failed', 'update-bad-contract', 'update-missing-contract', 'stall', 'update-stall', 'resume-wrong-version'].includes(scenario)) {
        assert.ok(!lines.some(line => line.endsWith('project-context.ps1') || line.endsWith('start-cogentstack-bridge.ps1')));
      }
      if (['stall', 'update-stall'].includes(scenario)) {
        assert.equal(result.workflowTimedOut, true);
        assert.ok(performance.now() - began < 10000);
        if (scenario === 'update-stall') assert.equal(result.failureStage, 'package_update');
        const childId = (await readFile(pidFile, 'utf8')).trim();
        const probe = await run(powershell, ['-NoProfile', '-Command', `if (Get-Process -Id ${childId} -ErrorAction SilentlyContinue) { exit 1 }`], env, root);
        assert.equal(probe.code, 0, 'Owned stalled helper survived');
      }
    }
    assert.ok(!lines.some(line => /sidebar|popout|gptweb|account-bound-claim/.test(line)));
    return { scenario, status: result.status, workflowElapsedMs: result.workflowElapsedMs };
  } finally {
    assert.equal(resolve(root, '..'), resolve(tmpdir()));
    await rm(root, { recursive: true, force: true });
  }
}

for (const plugin of Object.keys(versions)) {
  const results = [];
  const scenarios = ['current', 'confirmed', 'legacy-confirmed', 'unverified', 'offline', 'update', 'permission', 'unscoped', 'wrong-source', 'upgrade-failed', 'update-bad-contract', 'update-missing-contract', 'wrong-origin', 'wrong-mode', 'duplicate-mode', 'wrong-context', 'wrong-alias', 'already-opened', 'connection-required', 'malformed', 'stall', 'update-stall', 'resume-update', 'resume-wrong-version', 'preview', 'preview-wrong-origin', 'preview-wrong-context'];
  const selected = process.argv.slice(2);
  assert.ok(selected.every(scenario => scenarios.includes(scenario)), 'Unknown fixture scenario');
  for (const scenario of selected.length ? selected : scenarios) {
    results.push(await exercise(plugin, scenario));
    console.log(`${plugin}: ${scenario} passed`);
  }
  console.log(JSON.stringify({ status: 'valid', plugin, cases: results.length, results }));
}
