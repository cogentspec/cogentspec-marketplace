import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp,mkdir,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {runInNewContext} from 'node:vm';

const root=new URL('../',import.meta.url);
// GPTWeb/ClaudeWeb now use the independent request-bound Web runtime, covered
// by test-web-command-v1.mjs. Qwen retains the direct browser handoff protocol.
for(const [host,command,surface,handle] of [['plugins','qwenweb','qwen-web','qwenWebTab']]) {
 test(`${command}: launcher starts before any tab listener, returns one exact Web handoff and rejects unsafe results`,async()=>{
  const dir=await mkdtemp(join(tmpdir(),'web-handoff-')),core=join(dir,'skills','cogentspec','scripts'),dest=join(dir,'skills',command,'scripts');
  await mkdir(core,{recursive:true});await mkdir(dest,{recursive:true});
  const source=await readFile(new URL(`${host}/cogentspec/skills/${command}/scripts/start-${command}.ps1`,root),'utf8');
  await writeFile(join(dest,`start-${command}.ps1`),source);
  await writeFile(join(core,'project-context.ps1'),`function Get-CogentSpecProjectContext { param($ExplicitContextKey) @{ContextKey=('ctx-'+('a'*64));Isolated=($env:WEB_CASE -ne 'unscoped')} }`);
  await writeFile(join(core,'start-cogentstack-bridge.ps1'),String.raw`
param($ContextKey,$Surface,$Experience,[switch]$ListenerOnly)
if ($ListenerOnly -or $Surface -cne $env:WEB_SURFACE -or $Experience -cne 'web') { throw 'Wrong destination or listener dependency' }
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.txt') -Value 'once'
if ($env:WEB_CASE -eq 'denied') { @{status='connection_required';userMessage='Execution permission required.';workspaceUrl='PRIVATE_DO_NOT_FORWARD'} | ConvertTo-Json -Compress;return }
$url="https://cogentspec.app/stack?surface=$Surface&context=$ContextKey&experience=web&open=web&nav="+('b'*32)+'#desktop-web=cgw_'+('c'*40)
switch($env:WEB_CASE) {
 'origin' {$url=$url.Replace('cogentspec.app','attacker.invalid')}
 'surface' {$url=$url.Replace("surface=$Surface",'surface=desktop')}
 'context' {$url=$url.Replace($ContextKey,('ctx-'+('d'*64)))}
 'duplicate' {$url=$url.Replace('&open=web','&experience=web&open=web')}
 'fragment' {$url=$url.Split('#')[0]}
 'mode' {$url=$url.Replace('experience=web','experience=split-screen')}
}
@{status='ready';contextKey=$ContextKey;contextIsolated=$true;presenceVerified=($env:WEB_CASE -ne 'worker');defaultDirectoryReady=$true;
 accountState=$(if($env:WEB_CASE -eq 'account'){'signed_out'}else{'signed_in'});projectDataConnection='authenticated_desktop_bridge';mcpState='not_required';
 browserOpened=($env:WEB_CASE -eq 'opened');workspaceUrl=$url;webWorkspaceUrl=$url;chatgptWorkspaceUrl='https://example.invalid/desktop'} | ConvertTo-Json -Compress
`);
  for(const scenario of ['ready','origin','surface','context','duplicate','fragment','mode','worker','account','opened','denied','unscoped']) {
   const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(dest,`start-${command}.ps1`)],{encoding:'utf8',windowsHide:true,timeout:15000,env:{...process.env,WEB_CASE:scenario,WEB_SURFACE:surface}});
   assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout.trim());
   if(scenario==='ready') {
    assert.equal(receipt.status,'ready');assert.equal(receipt.browserOpened,false);
    assert.equal(receipt.browserNavigationProtocol,`cogentspec-${command}-navigation-v1`);
    let calls=0;await runInNewContext(`(async()=>{${receipt.browserNavigationCode}})()`,{[handle]:{async goto(url){calls++;assert.equal(url,receipt.workspaceUrl);}}});assert.equal(calls,1);
   } else {assert.notEqual(receipt.status,'ready');assert.doesNotMatch(result.stdout,/cgw_|PRIVATE_DO_NOT_FORWARD|browserNavigationCode|workspaceUrl/);}
  }
  assert.equal((await readFile(join(core,'calls.txt'),'utf8')).trim().split(/\r?\n/).length,11,'Each scoped call must invoke the worker once');
 });
}

test('Qwen Web launcher and instructions are identical across all four marketplace packages',async()=>{
 const canonical=await readFile(new URL('plugins/cogentspec/skills/qwenweb/scripts/start-qwenweb.ps1',root),'utf8');
 const skill=await readFile(new URL('plugins/cogentspec/skills/qwenweb/SKILL.md',root),'utf8');
 for(const host of ['plugins','claude-plugins'])for(const plugin of ['cogentspec','cogentstack']) {
  const path=`${host}/${plugin}/skills/qwenweb/`;
  assert.equal((await readFile(new URL(path+'scripts/start-qwenweb.ps1',root),'utf8')).replaceAll('..\\..\\cogentstack\\scripts','..\\..\\cogentspec\\scripts'),canonical);
  assert.equal(await readFile(new URL(path+'SKILL.md',root),'utf8'),skill);
 }
});
