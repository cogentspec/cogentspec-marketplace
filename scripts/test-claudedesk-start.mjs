import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const repository = resolve(import.meta.dirname, '..');
const session = '11111111-2222-4333-8444-555555555555';
const context = 'ctx-' + 'a'.repeat(64);
const powershell = process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const versions = { cogentspec: ['0.4.79', '0.4.80'], cogentstack: ['0.3.80', '0.3.81'] };

async function put(path, value) { await mkdir(resolve(path, '..'), { recursive: true }); await writeFile(path, value); }
async function run(file, args, env, cwd) {
  return new Promise((done, reject) => {
    const child = spawn(file, args, { env, cwd, windowsHide: true });
    let stdout = '', stderr = '';
    const limit = setTimeout(() => { child.kill(); reject(new Error('Fixture escaped its outer limit')); }, 35000);
    child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
    child.on('error', error => { clearTimeout(limit); reject(error); });
    child.on('close', code => { clearTimeout(limit); done({ code, stdout, stderr }); });
  });
}

const stub = String.raw`
$ErrorActionPreference = 'Stop'
if ((Get-Location).Path -cne $env:CLAUDEDESK_TEST_CWD) { throw 'Workspace changed' }
Add-Content -LiteralPath $env:CLAUDEDESK_TEST_TRACE -Value ($env:CLAUDEDESK_TEST_LABEL + ':' + [IO.Path]::GetFileName($PSCommandPath))
$scenario = $env:CLAUDEDESK_TEST_SCENARIO
$context = 'ctx-' + ('a' * 64)
switch ([IO.Path]::GetFileName($PSCommandPath)) {
 'check-claudedesk-update.ps1' {
  if ($args.Count) { throw 'Unexpected update arguments' }
  if ($scenario -eq 'stall') { [string]$PID | Set-Content -LiteralPath $env:CLAUDEDESK_TEST_PID; Start-Sleep -Seconds 40 }
  if ($scenario -eq 'malformed') { Write-Output 'PRIVATE_HANDOFF_DO_NOT_PRINT'; [Console]::Error.WriteLine('PRIVATE_HANDOFF_DO_NOT_PRINT'); exit 1 }
  $status = if ($scenario.StartsWith('update') -or $scenario -eq 'wrong-source') { 'update_available' }
    elseif ($scenario -eq 'offline') { 'check_unavailable' } elseif ($scenario -eq 'permission') { 'execution_permission_required' } else { 'current' }
  @{ status = $status; availableVersion = $env:CLAUDEDESK_TEST_VERSION; userMessage = 'Fixture permission required.' } | ConvertTo-Json -Compress
 }
 'project-context.ps1' { @{ isolated = ($scenario -ne 'unscoped'); contextKey = $context } | ConvertTo-Json -Compress }
 'start-claudedesk-bridge.ps1' {
  if ($args.Count -ne 4 -or $args[0] -ne '-ContextKey' -or $args[1] -cne $context -or $args[2] -ne '-SessionId' -or $args[3] -cne '11111111-2222-4333-8444-555555555555') { throw 'Wrong session/destination arguments' }
  if ($scenario -in @('licence_required','licence_verification_unavailable','connection_required')) {
   @{status=$scenario;userMessage='Fixture access check stopped safely.';workspaceUrl='PRIVATE_HANDOFF_DO_NOT_PRINT';recoveryUrl='PRIVATE_HANDOFF_DO_NOT_PRINT'} | ConvertTo-Json -Compress; return
  }
  $base = "https://cogentspec.app/stack?surface=claude-desktop&context=$context&experience=desktop-ui"
  if ($scenario -eq 'wrong-origin') { $base = $base.Replace('cogentspec.app','cogentspec.app.evil.invalid') }
  if ($scenario -eq 'wrong-mode') { $base = $base.Replace('desktop-ui','split-screen') }
  if ($scenario -eq 'wrong-provider') { $base = $base.Replace('claude-desktop','chatgpt') }
  if ($scenario -eq 'duplicate-mode') { $base += '&experience=desktop-ui' }
  if ($scenario -eq 'wrong-context') { $base = $base.Replace($context,'ctx-' + ('b' * 64)) }
  $native = $base + '&open=chatgpt&nav=' + ('b' * 32) + '#desktop-chatgpt=cgw_' + ('c' * 40)
  $web = $base + '&open=web&nav=' + ('b' * 32) + '#desktop-web=cgw_' + ('d' * 40)
  $result = @{ status='ready';bridge='already_running';presenceVerified=$true;contextIsolated=$true;threadId='11111111-2222-4333-8444-555555555555';accountState='signed_in';mcpState='not_required';projectDataConnection='authenticated_desktop_bridge';browserOpened=$false;contextKey=$context;workspaceUrl=$native;chatgptWorkspaceUrl=$native;webWorkspaceUrl=$web;currentConversationConnected=$true;conversationVerification='claude_desktop_session_presence';conversationConnectionReason='claude_desktop_session_presence_confirmed';conversationUserMessage='ClaudeDesk connected.' }
  switch ($scenario) {
   'wrong-alias' { $result.workspaceUrl=$web }
   'already-opened' { $result.browserOpened=$true }
   'no-presence' { $result.presenceVerified=$false }
   'wrong-session' { $result.threadId='99999999-2222-4333-8444-555555555555' }
   'unverified' { $result.currentConversationConnected=$false }
   'snap-proof' { $result.conversationVerification='authenticated_workspace' }
   'codex-proof' { $result.conversationVerification='desktop_thread_presence' }
   'popout-proof' { $result.conversationVerification='popout';$result.popoutConnectionConfirmed=$true }
  }
  $result | ConvertTo-Json -Compress
 }
 default { throw 'Unexpected helper' }
}
`;

async function exercise(plugin, scenario) {
  const root = await mkdtemp(join(tmpdir(), 'claudedesk fixture '));
  assert.equal(resolve(root, '..'), resolve(tmpdir()));
  const old = join(root, 'old package', plugin), fresh = join(root, 'fresh package', plugin);
  const marketplace = join(root, 'marketplace'), bin = join(root, 'bin'), trace = join(root, 'trace.txt');
  const env = { ...process.env, PATH: bin + ';' + process.env.PATH, CLAUDEDESK_TEST_CWD: root,
    CLAUDEDESK_TEST_SCENARIO: scenario, CLAUDEDESK_TEST_TRACE: trace, CLAUDEDESK_TEST_PID: join(root,'child.pid'),
    CLAUDEDESK_TEST_OLD: old, CLAUDEDESK_TEST_FRESH: fresh, CLAUDEDESK_TEST_MARKET: marketplace,
    CLAUDEDESK_TEST_PLUGIN: plugin, CLAUDEDESK_TEST_VERSION: versions[plugin][1], CLAUDEDESK_TEST_FLAG: join(root,'updated') };
  try {
    for (const [path, label, version] of [[old,'old',versions[plugin][0]],[fresh,'fresh',versions[plugin][1]]]) {
      await put(join(path,'.claude-plugin/plugin.json'),JSON.stringify({name:plugin,version}));
      for (const file of ['check-claudedesk-update.ps1','start-claudedesk-bridge.ps1'])
        await put(join(path,'skills/claudedesk/scripts',file),`$env:CLAUDEDESK_TEST_LABEL='${label}'\n`+stub);
      await put(join(path,'skills',plugin,'scripts/project-context.ps1'),`$env:CLAUDEDESK_TEST_LABEL='${label}'\n`+stub);
    }
    await put(join(marketplace,'claude-plugins',plugin,'.claude-plugin/plugin.json'),JSON.stringify({name:plugin,version:versions[plugin][1]}));
    const driver=join(old,'skills/claudedesk/scripts/start-claudedesk.ps1');
    await put(driver,await readFile(join(repository,'claude-plugins',plugin,'skills/claudedesk/scripts/start-claudedesk.ps1')));
    await put(join(bin,'claude.cmd'),`@echo off\r\n"${process.execPath}" "${join(bin,'claude.mjs')}" %*\r\n`);
    await put(join(bin,'claude.mjs'),String.raw`
import {appendFileSync,existsSync,writeFileSync} from 'node:fs';
const e=process.env,args=process.argv.slice(2),s=e.CLAUDEDESK_TEST_SCENARIO,updated=existsSync(e.CLAUDEDESK_TEST_FLAG);
appendFileSync(e.CLAUDEDESK_TEST_TRACE,'claude:'+args.join(' ')+'\n');
if(args.join(' ')==='plugin marketplace list --json') console.log(JSON.stringify([{name:'cogentstack',source:'github',repo:s==='wrong-source'?'somebody/other-marketplace':'cogentspec/cogentspec-marketplace',installLocation:e.CLAUDEDESK_TEST_MARKET}]));
else if(args.join(' ')==='plugin list --json') console.log(JSON.stringify([{id:e.CLAUDEDESK_TEST_PLUGIN+'@cogentstack',enabled:true,scope:updated&&s==='update-wrong-scope'?'local':'project',installPath:updated?e.CLAUDEDESK_TEST_FRESH:e.CLAUDEDESK_TEST_OLD,version:updated?e.CLAUDEDESK_TEST_VERSION:'0.0.1'}]));
else if(args.join(' ')==='plugin marketplace update cogentstack') {if(s==='update-refresh-failed')process.exit(1);console.log('Updated marketplace');}
else if(args[0]==='plugin'&&args[1]==='update'&&args[2]===e.CLAUDEDESK_TEST_PLUGIN+'@cogentstack'&&args[3]==='--scope'&&args[4]==='project') {writeFileSync(e.CLAUDEDESK_TEST_FLAG,'1');console.log('Updated plugin');}
else process.exit(1);
`);
    const resume=scenario.startsWith('resume-');
    const result=await run(powershell,['-NoProfile','-ExecutionPolicy','Bypass','-File',driver,'-SessionId',scenario==='missing-session'?'${CLAUDE_SESSION_ID}':session,
      ...(resume?['-UpdateAlreadyVerified','-VerifiedInstalledVersion',scenario==='resume-wrong-version'?'0.0.0':versions[plugin][0]]:[]),
      ...(scenario==='stall'?['-WorkflowTimeoutSeconds','6']:[])],env,root);
    assert.equal(result.code,0,result.stderr);
    const value=JSON.parse(result.stdout.trim());
    const lines=(await readFile(trace,'utf8').catch(e=>{if(e.code==='ENOENT')return '';throw e;})).trim().split(/\r?\n/);
    const ready=['current','offline','update','resume-update','unverified','snap-proof','codex-proof','popout-proof'].includes(scenario);
    assert.equal(value.protocol,'cogentspec-claudedesk-start-v1');
    assert.equal(value.status==='ready',ready,`${plugin}/${scenario}: ${JSON.stringify(value)}`);
    assert.equal(lines.filter(l=>l.endsWith('check-claudedesk-update.ps1')).length,resume||scenario==='missing-session'?0:1);
    if(ready){
      assert.equal(value.currentConversationConnected,!['unverified','snap-proof','codex-proof','popout-proof'].includes(scenario));
      assert.equal(value.browserOpened,false);
      assert.equal(lines.filter(l=>l.endsWith('project-context.ps1')).length,1);
      assert.equal(lines.filter(l=>l.endsWith('start-claudedesk-bridge.ps1')).length,1);
      if(scenario==='update') {
        assert.equal(value.pluginVersion,versions[plugin][1]);assert.equal(value.updateStatus,'updated');
        assert.equal(lines.filter(l=>l==='claude:plugin marketplace update cogentstack').length,1);
        assert.equal(lines.filter(l=>l===`claude:plugin update ${plugin}@cogentstack --scope project`).length,1);
        assert.ok(lines.includes('fresh:project-context.ps1'));assert.ok(lines.includes('fresh:start-claudedesk-bridge.ps1'));
        assert.ok(!lines.includes('old:project-context.ps1'));
      } else assert.ok(!lines.some(l=>l.startsWith('claude:')));
    }else{
      assert.equal(value.workspaceUrl,undefined);assert.equal(value.recoveryUrl,undefined);
      assert.ok(!result.stdout.includes('PRIVATE_HANDOFF_DO_NOT_PRINT'));
      if(['licence_required','licence_verification_unavailable','connection_required'].includes(scenario))assert.equal(value.userMessage,'Fixture access check stopped safely.');
      if(scenario==='stall') {
        assert.equal(value.workflowTimedOut,true);
        const pid=Number(await readFile(env.CLAUDEDESK_TEST_PID,'utf8'));
        assert.throws(()=>process.kill(pid,0),'Only the owned stalled child must be terminated');
      }
    }
    assert.ok(!lines.some(l=>/reset-|start-workspace-beacon|gptdesk|claudeweb|claudesnap|qwenlocal/.test(l)));
    return {plugin,scenario,status:value.status};
  } finally { await rm(root,{recursive:true,force:true}); }
}

const scenarios=['current','offline','update','update-refresh-failed','update-wrong-scope','wrong-source','resume-update','resume-wrong-version','permission','malformed','unscoped','missing-session','licence_required','licence_verification_unavailable','connection_required','wrong-origin','wrong-provider','wrong-mode','duplicate-mode','wrong-context','wrong-alias','wrong-session','already-opened','no-presence','unverified','snap-proof','codex-proof','popout-proof','stall'];
const outcomes=[];
for(const plugin of Object.keys(versions))for(const scenario of scenarios)outcomes.push(await exercise(plugin,scenario));
console.log(JSON.stringify({passed:outcomes.length,failed:0,packages:Object.keys(versions)}));
