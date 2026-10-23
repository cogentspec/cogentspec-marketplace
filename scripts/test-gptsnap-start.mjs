import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { runInNewContext } from 'node:vm';
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
Add-Content -LiteralPath $env:SNAP_FIXTURE_TRACE -Value ($env:SNAP_FIXTURE_LABEL + ':' + [IO.Path]::GetFileName($PSCommandPath))
$scenario = $env:SNAP_FIXTURE_SCENARIO
$context = 'ctx-' + ('a' * 64)
switch ([IO.Path]::GetFileName($PSCommandPath)) {
 'check-cogentspec-update.ps1' {
  if ($scenario -eq 'stall') { [string]$PID | Set-Content -LiteralPath $env:SNAP_FIXTURE_PID; Start-Sleep -Seconds 20 }
  if ($scenario -eq 'malformed') { Write-Output 'PRIVATE_HANDOFF_DO_NOT_PRINT'; [Console]::Error.WriteLine('PRIVATE_HANDOFF_DO_NOT_PRINT'); exit 1 }
  $status = if ($scenario.StartsWith('update') -or $scenario -in @('wrong-source', 'upgrade-failed')) { 'update_available' }
    elseif ($scenario -eq 'offline') { 'check_unavailable' } elseif ($scenario -eq 'permission') { 'execution_permission_required' } else { 'current' }
  @{ status = $status; userMessage = 'Fixture permission required.' } | ConvertTo-Json -Compress
 }
 'project-context.ps1' { @{ isolated = ($scenario -ne 'unscoped'); contextKey = $context } | ConvertTo-Json -Compress }
 'start-cogentstack-bridge.ps1' {
  $resuming = $scenario.StartsWith('resume-')
  if ($args.Count -ne $(if ($resuming) { 7 } else { 6 }) -or $args[0] -ne '-ContextKey' -or $args[1] -ne $context -or $args[2] -ne '-Surface' -or $args[3] -ne 'chatgpt' -or $args[4] -ne '-Experience' -or $args[5] -ne 'split-screen' -or ($resuming -and $args[6] -ne '-ResumeApproval')) { throw 'Wrong destination arguments' }
  if ($scenario -eq 'connection-required') { @{ status = 'connection_required'; userMessage = 'Fixture connection needs permission.' } | ConvertTo-Json -Compress; return }
  if ($scenario -in @('licence_required', 'licence_verification_unavailable')) {
    @{ status = $scenario; userMessage = 'Fixture access check stopped safely.'; workspaceUrl = 'PRIVATE_HANDOFF_DO_NOT_PRINT'; recoveryUrl = 'PRIVATE_HANDOFF_DO_NOT_PRINT' } | ConvertTo-Json -Compress; return
  }
  if ($scenario.StartsWith('approval') -or $scenario -eq 'resume-approval-loop') {
    $approval = @{ status = 'approval_required'; contextKey = $context; approvalProtocol = 'cogentspec-gptsnap-approval-v1'; approvalUrl = 'https://cogentspec.com/activate?code=TEST-CODE&experience=split-screen'; expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o'); pollAfterSeconds = 5; browserOpened = $false; browserNavigationCode = 'PRIVATE_HANDOFF_DO_NOT_PRINT' }
    if ($scenario -eq 'approval-origin') { $approval.approvalUrl = $approval.approvalUrl.Replace('cogentspec.com','evil.invalid') }
    if ($scenario -eq 'approval-context') { $approval.contextKey = 'ctx-' + ('e' * 64) }
    if ($scenario -eq 'approval-expired') { $approval.expiresAt = '2000-01-01T00:00:00Z' }
    if ($scenario -eq 'approval-poll') { $approval.pollAfterSeconds = 1 }
    $approval | ConvertTo-Json -Compress; return
  }
  $url = "https://cogentspec.app/stack?surface=chatgpt&context=$context&experience=split-screen&open=web&nav=" + ('b' * 32) + '#desktop-web=cgw_' + ('c' * 40)
  if ($scenario -eq 'wrong-origin') { $url = $url.Replace('cogentspec.app','cogentspec.app.evil.invalid') }
  if ($scenario -eq 'wrong-mode') { $url = $url.Replace('split-screen','desktop-ui') }
  if ($scenario -eq 'duplicate-mode') { $url = $url.Replace('&open=web','&experience=split-screen&open=web') }
  if ($scenario -eq 'wrong-context') { $url = $url.Replace($context, 'ctx-' + ('b' * 64)) }
  if ($scenario -eq 'missing-handoff') { $url = $url.Split('#')[0] }
  if ($scenario -eq 'wrong-port') { $url = $url.Replace('cogentspec.app','cogentspec.app:444') }
  if ($scenario -eq 'userinfo') { $url = $url.Replace('https://','https://user@') }
  $result = @{ status = 'ready'; bridge = 'already_running'; accountState = 'signed_in'; mcpState = 'not_required'; browserOpened = ($scenario -eq 'already-opened'); contextKey = $context; contextIsolated = $true; presenceVerified = ($scenario -ne 'unverified'); workspaceUrl = $url; webWorkspaceUrl = $url; projectDataConnection = 'authenticated_desktop_bridge'; defaultDirectoryReady = ($scenario -ne 'missing-directory'); currentConversationConnected = $false; browserNavigationCode = 'throw "PRIVATE_HANDOFF_DO_NOT_PRINT"' }
  if ($scenario -eq 'wrong-alias') { $result.webWorkspaceUrl = $url + 'wrong' }
  if ($scenario -eq 'signed-out-ready') { $result.accountState = 'signed_out' }
  $result | ConvertTo-Json -Compress
 }
 default { throw 'Unexpected helper' }
}
`;

async function exercise(plugin, scenario) {
  const root = await mkdtemp(join(tmpdir(), 'gptsnap fast fixture '));
  assert.equal(resolve(root, '..'), resolve(tmpdir()));
  const pluginRoot = join(root, 'old package', plugin);
  const refreshed = join(root, 'refreshed package', plugin);
  const marketplace = join(root, 'marketplace');
  const trace = join(root, 'trace.txt');
  const pidFile = join(root, 'child.pid');
  const bin = join(root, 'bin');
  const env = { ...process.env, PATH: bin + ';' + process.env.PATH, SNAP_FIXTURE_SCENARIO: scenario, SNAP_FIXTURE_TRACE: trace, SNAP_FIXTURE_PID: pidFile, SNAP_FIXTURE_MARKETPLACE: marketplace, SNAP_FIXTURE_REFRESHED: refreshed, SNAP_FIXTURE_VERSION: versions[plugin][1] };
  try {
    for (const [packageRoot, label, version] of [[pluginRoot, 'old', versions[plugin][0]], [refreshed, 'new', versions[plugin][1]]]) {
      await put(join(packageRoot, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version }));
      for (const name of ['check-cogentspec-update.ps1', 'project-context.ps1', 'start-cogentstack-bridge.ps1']) {
        await put(join(packageRoot, 'skills', plugin, 'scripts', name), `$env:SNAP_FIXTURE_LABEL = '${label}'\n` + stub);
      }
    }
    const driver = join(pluginRoot, 'skills', 'gptsnap', 'scripts', 'start-gptsnap.ps1');
    await put(driver, await readFile(join(repository, 'plugins', plugin, 'skills', 'gptsnap', 'scripts', 'start-gptsnap.ps1'), 'utf8'));
    await put(join(bin, 'codex.cmd'), `@echo off\r\n"${process.execPath}" "${join(bin, 'codex.mjs')}" %*\r\n`);
    await put(join(bin, 'codex.mjs'), `
import { appendFileSync } from 'node:fs';
const args=process.argv.slice(2), scenario=process.env.SNAP_FIXTURE_SCENARIO;
appendFileSync(process.env.SNAP_FIXTURE_TRACE,'codex:'+args.join(' ')+'\\n');
if(args.join(' ')==='plugin marketplace list --json') console.log(JSON.stringify({marketplaces:[{name:'cogentstack', root:process.env.SNAP_FIXTURE_MARKETPLACE,marketplaceSource:{source:scenario==='wrong-source'?'https://evil.invalid/repo.git':'https://github.com/cogentspec/cogentspec-marketplace.git'}}]},null,2));
else if(args.join(' ')==='plugin marketplace upgrade cogentstack --json') console.log(JSON.stringify({errors:scenario==='upgrade-failed'?['failed']:[]},null,2));
else process.exit(1);
`);
    await put(join(marketplace, '.agents', 'plugins', `install-${plugin}.ps1`), String.raw`
param([switch]$UpdateOnly,[switch]$MarketplacePrepared,[int]$InstallerTimeoutSeconds,[switch]$DeferConnectionStartup)
if (-not $UpdateOnly -or -not $MarketplacePrepared -or $InstallerTimeoutSeconds -ne 120 -or -not $DeferConnectionStartup -or $args.Count) { throw 'Unsafe update arguments' }
Add-Content -LiteralPath $env:SNAP_FIXTURE_TRACE -Value 'installer:update-only'
if ($env:SNAP_FIXTURE_SCENARIO -eq 'update-stall') { [string]$PID | Set-Content -LiteralPath $env:SNAP_FIXTURE_PID; Start-Sleep -Seconds 20 }
$result = @{ protocol = 'trusted-marketplace-update-v1'; status = 'updated'; credentialPreserved = ($env:SNAP_FIXTURE_SCENARIO -ne 'update-bad-contract'); previousPackageReplaced = $true; packageRuntimeCleared = $true; workerStateCleared = $true; popoutBridgeReady = $false; desktopUiBridgeReady = $false; projectDataConnectionReady = $false; connectionStartupDeferred = $true; continueCurrentTask = $true; fastUpdatePath = $true; workspaceReadinessSkipped = $true; claimAttempted = $false; accountRequestConsumed = $false; refreshedPluginPath = $env:SNAP_FIXTURE_REFRESHED; version = $env:SNAP_FIXTURE_VERSION; installerElapsedMs = 1; installerBudgetSeconds = 110 }
if ($env:SNAP_FIXTURE_SCENARIO -eq 'update-missing-contract') { $result = @{ status = 'updated' } }
$result | ConvertTo-Json -Compress
`);
    const began = performance.now();
    const resume = scenario.startsWith('resume-');
    const runResult = await run(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', driver,
      '-PrepareOnly',
      ...(resume ? ['-ResumeApproval', '-ContextKey', context] : []),
      ...(scenario === 'stall' ? ['-WorkflowTimeoutSeconds', '2'] : scenario === 'update-stall' ? ['-WorkflowTimeoutSeconds', '3', '-UpdateTimeoutSeconds', '1'] : [])], env, root);
    assert.equal(runResult.code, 0, runResult.stderr);
    const result = JSON.parse(runResult.stdout.trim());
    const lines = (await readFile(trace, 'utf8').catch(error => { if (error.code === 'ENOENT') return ''; throw error; })).trim().split(/\r?\n/);
    assert.equal(result.protocol, 'cogentspec-gptsnap-start-v1');
    assert.equal(lines.filter(line => line.endsWith('check-cogentspec-update.ps1')).length, resume ? 0 : 1);
    assert.ok(!runResult.stdout.includes('PRIVATE_HANDOFF_DO_NOT_PRINT'), 'Leaked helper diagnostics/code');
    const ready = ['current', 'offline', 'update', 'resume-approved'].includes(scenario);
    if (ready) {
      assert.equal(result.status, 'ready', JSON.stringify(result));
      assert.equal(result.contextKey, context);
      assert.equal(result.presenceVerified, true);
      assert.equal(lines.filter(line => line.endsWith('project-context.ps1')).length, resume ? 0 : 1);
      assert.equal(lines.filter(line => line.endsWith('start-cogentstack-bridge.ps1')).length, 1);
      assert.equal(result.workflowBudgetSeconds, scenario === 'update' ? 170 : 50);
      const calls = [];
      await runInNewContext('(async () => {' + result.browserNavigationCode + '})()', {
        gptPopTab: { goto: async url => calls.push(url) }
      }, { timeout: 1000 });
      assert.deepEqual(calls, [result.workspaceUrl]);
      const destination = new URL(result.workspaceUrl);
      assert.equal(destination.searchParams.get('context'), context);
      assert.equal(destination.searchParams.get('experience'), 'split-screen');
      if (resume) assert.equal(result.updateStatus, 'not_repeated_after_approval');
      if (scenario === 'update') {
        assert.equal(result.pluginVersion, versions[plugin][1]);
        assert.equal(lines.filter(line => line === 'codex:plugin marketplace list --json').length, 2);
        assert.equal(lines.filter(line => line === 'codex:plugin marketplace upgrade cogentstack --json').length, 1);
        assert.equal(lines.filter(line => line === 'installer:update-only').length, 1);
        assert.ok(lines.includes('new:project-context.ps1'));
        assert.ok(lines.includes('new:start-cogentstack-bridge.ps1'));
        assert.ok(!lines.includes('old:project-context.ps1'));
      } else assert.ok(!lines.some(line => line.startsWith('codex:') || line.startsWith('installer:')));
      if (scenario === 'current') assert.deepEqual(lines, [
        'old:check-cogentspec-update.ps1', 'old:project-context.ps1', 'old:start-cogentstack-bridge.ps1'
      ], 'The ordinary user command must own exactly one startup sequence');
    } else if (scenario === 'approval') {
      assert.equal(result.status, 'approval_required');
      assert.equal(result.contextKey, context);
      assert.equal(result.pollAfterSeconds, 5);
      assert.equal(result.workspaceUrl, undefined);
      const calls = [];
      await runInNewContext('(async () => {' + result.browserNavigationCode + '})()', {
        gptPopTab: { goto: async url => calls.push(url) }
      }, { timeout: 1000 });
      assert.deepEqual(calls, [result.approvalUrl]);
      assert.equal(lines.filter(line => line.endsWith('start-cogentstack-bridge.ps1')).length, 1);
    } else {
      assert.notEqual(result.status, 'ready');
      assert.notEqual(result.status, 'approval_required');
      assert.equal(result.workspaceUrl, undefined);
      assert.equal(result.approvalUrl, undefined);
      assert.ok(lines.filter(line => line.endsWith('start-cogentstack-bridge.ps1')).length <= 1);
      if (['licence_required', 'licence_verification_unavailable'].includes(scenario)) {
        assert.equal(result.status, scenario);
        assert.equal(result.userMessage, 'Fixture access check stopped safely.');
        assert.equal(result.recoveryUrl, undefined);
      }
      if (['permission', 'malformed', 'wrong-source', 'upgrade-failed', 'update-bad-contract', 'update-missing-contract', 'stall', 'update-stall'].includes(scenario)) {
        assert.ok(!lines.some(line => line.endsWith('project-context.ps1') || line.endsWith('start-cogentstack-bridge.ps1')));
      }
      if (['stall', 'update-stall'].includes(scenario)) {
        assert.equal(result.workflowTimedOut, true);
        assert.ok(performance.now() - began < 10000);
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
  const scenarios = ['current', 'offline', 'update', 'permission', 'unscoped', 'wrong-source', 'upgrade-failed', 'update-bad-contract', 'update-missing-contract', 'wrong-origin', 'wrong-mode', 'duplicate-mode', 'wrong-context', 'wrong-alias', 'missing-handoff', 'wrong-port', 'userinfo', 'unverified', 'missing-directory', 'signed-out-ready', 'already-opened', 'connection-required', 'malformed', 'stall', 'update-stall', 'approval', 'approval-origin', 'approval-context', 'approval-expired', 'approval-poll', 'resume-approved', 'resume-approval-loop'];
  scenarios.push('licence_required', 'licence_verification_unavailable');
  const selected = process.argv.slice(2);
  assert.ok(selected.every(scenario => scenarios.includes(scenario)), 'Unknown fixture scenario');
  for (const scenario of selected.length ? selected : scenarios) {
    results.push(await exercise(plugin, scenario));
    console.log(`${plugin}: ${scenario} passed`);
  }
  console.log(JSON.stringify({ status: 'valid', plugin, cases: results.length, results }));
}
