import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { cp, mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const root=await mkdtemp(join(tmpdir(),'claudedesk topdown '));
assert.equal(resolve(root,'..'),resolve(tmpdir()));
const repository=resolve(import.meta.dirname,'..');
const powershell=process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const quote=s=>"'"+s.replaceAll("'","''")+"'";
const children=new Set();
const heartbeats=[];
const mutations=[];
let queued=null;
const server=createServer((request,response)=>{
  assert.equal(request.headers.authorization,'Bearer claudedesk-fixture-token');
  const url=new URL(request.url,'http://localhost');
  assert.equal(url.pathname,'/api/plugin/desktop-actions');
  heartbeats.push(Object.fromEntries(url.searchParams));
  if(request.method!=='GET')mutations.push(request.method);
  response.writeHead(200,{'content-type':'application/json'});response.end(JSON.stringify({request:queued,taskPaused:false}));
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
async function run(args){
  return new Promise((done,reject)=>{
    const env={...process.env};delete env.PSModulePath;
    const p=spawn(powershell,['-NoProfile','-ExecutionPolicy','Bypass',...args],{cwd:root,env,windowsHide:true});
    children.add(p);let stdout='',stderr='';
    const timer=setTimeout(()=>{p.kill();reject(new Error('Top-down fixture exceeded 30 seconds'));},30000);
    p.stdout.on('data',d=>stdout+=d);p.stderr.on('data',d=>stderr+=d);
    p.on('error',reject);p.on('close',code=>{clearTimeout(timer);children.delete(p);code===0?done(stdout.trim()):reject(new Error(stderr||stdout));});
  });
}
const workerIds=new Set();
try{
  const plugin=join(root,'package'),desk=join(plugin,'skills/claudedesk/scripts'),core=join(plugin,'skills/cogentspec/scripts');
  await cp(join(repository,'claude-plugins/cogentspec'),plugin,{recursive:true});
  const state=join(root,'state');await mkdir(state);
  const encrypted=await run(['-Command',`Add-Type -AssemblyName System.Security; [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('claudedesk-fixture-token'),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))`]);
  await writeFile(join(state,'desktop-credential.json'),JSON.stringify({token:encrypted}));
  // Relocate only fixture I/O and HTTP. All command, process, mutex, presence,
  // reuse and exact-session verification logic below is the production code.
  for(const name of ['start-claudedesk-bridge.ps1','watch-claudedesk-bridge.ps1']){
    let source=await readFile(join(desk,name),'utf8');
    source=source.replaceAll("Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'",quote(state));
    source=source.replace("$serviceUrl = 'https://cogentspec.com'",`$serviceUrl = 'http://127.0.0.1:${server.address().port}'`);
    await writeFile(join(desk,name),source);
  }
  await writeFile(join(core,'connect-cogentstack.ps1'),String.raw`
param($Mode,$Surface,$ContextKey,$Experience,[switch]$WorkspaceGrant,$RequestTimeoutSeconds)
if($Mode -cne 'status' -or $Surface -cne 'claude-desktop' -or $Experience -cne 'desktop-ui' -or -not $WorkspaceGrant -or $RequestTimeoutSeconds -ne 6){throw 'Wrong account gate'}
@{status='connected';webWorkspaceCode='cgw_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';chatgptWorkspaceCode='cgw_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'} | ConvertTo-Json -Compress
`);
  await writeFile(join(core,'ensure-default-project-directory.ps1'),`function Initialize-CogentSpecDefaultProjectDirectory { return @{status='ready';created=$false} }`);
  await writeFile(join(core,'project-credential-worker.ps1'),`function Invoke-InitialCredentialSetup { param($Token) }`);
  await writeFile(join(desk,'check-claudedesk-update.ps1'),`@{status='current'} | ConvertTo-Json -Compress`);
  const context='ctx-'+randomUUID().replaceAll('-','').repeat(2);
  const foreignState=join(state,'bridge/snap-sentinel.json');await mkdir(resolve(foreignState,'..'),{recursive:true});
  await writeFile(foreignState,'Other connector state must remain unchanged');
  const hash=createHash('sha256').update(context).digest('hex').slice(0,24);
  const locked=join(root,'foreign.lock'),lockScript=join(root,'foreign.ps1');
  await writeFile(lockScript,`$m=New-Object Threading.Mutex($false,'Local\\CogentSpecBridge-${hash}');try{if(-not $m.WaitOne(0)){throw 'Foreign mutex unavailable'};[IO.File]::WriteAllText(${quote(locked)},[string]$PID);Start-Sleep -Seconds 60}finally{$m.ReleaseMutex();$m.Dispose()}`);
  const env={...process.env};delete env.PSModulePath;
  const foreign=spawn(powershell,['-NoProfile','-ExecutionPolicy','Bypass','-File',lockScript],{env,cwd:root,windowsHide:true,stdio:'ignore'});
  children.add(foreign);
  let foreignReady=false;for(let i=0;i<60;i++){try{await readFile(locked);foreignReady=true;break;}catch{}await new Promise(done=>setTimeout(done,50));}
  assert.equal(foreignReady,true,'The existing generic worker mutex must be held during ClaudeDesk startup');
  await writeFile(join(core,'project-context.ps1'),`function Get-CogentSpecProjectContext {param($ExplicitContextKey) return [pscustomobject]@{ContextKey=$ExplicitContextKey;Isolated=$true} }\nif($MyInvocation.InvocationName -ne '.') { @{contextKey='${context}';isolated=$true}|ConvertTo-Json -Compress }`);
  const session=randomUUID();
  const invoke=async id=>JSON.parse(await run(['-File',join(desk,'start-claudedesk.ps1'),'-SessionId',id]));
  const first=await invoke(session);
  if(first.status!=='ready') await run(['-File',join(desk,'start-claudedesk-bridge.ps1'),'-ContextKey',context,'-SessionId',session]);
  assert.equal(first.status,'ready',JSON.stringify(first));assert.equal(first.bridge,'started');
  assert.equal(first.currentConversationConnected,true);assert.equal(first.conversationVerification,'claude_desktop_session_presence');
  assert.equal(first.browserOpened,false);assert.equal(first.updateStatus,'current');
  assert.ok(first.workspaceUrl.includes('surface=claude-desktop')&&first.workspaceUrl.includes('experience=desktop-ui'));
  const files=JSON.parse(await run(['-Command',`@(Get-ChildItem -LiteralPath ${quote(join(state,'claudedesk-v1'))} -Filter '*.json' | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json}) | ConvertTo-Json -Compress`]));
  const records=Array.isArray(files)?files:[files];const firstPid=records.find(v=>v.watcherScript)?.processId;
  assert.ok(firstPid);workerIds.add(firstPid);
  const second=await invoke(session);assert.equal(second.bridge,'already_running');assert.equal(second.currentConversationConnected,true);
  queued={id:randomUUID(),action:'set_claude_desktop_topmost',targetRequestId:'claude-desktop-main:pinned'};
  const third=await invoke(randomUUID());assert.equal(third.status,'ready');assert.equal(third.bridge,'started');
  assert.equal(third.currentConversationConnected,true);
  const stateFiles=await run(['-Command',`Get-ChildItem -LiteralPath ${quote(join(state,'claudedesk-v1'))} -Filter '*.json' | ForEach-Object {$v=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json;if($v.PSObject.Properties['watcherScript']){$v.processId}}`]);
  for(const pid of stateFiles.split(/\s+/).map(Number).filter(Boolean))workerIds.add(pid);
  assert.ok(heartbeats.length>=3);
  assert.ok(heartbeats.every(h=>h.context===context&&h.pluginId==='cogentspec'));
  assert.equal(await readFile(foreignState,'utf8'),'Other connector state must remain unchanged');
  assert.equal(foreign.exitCode,null,'ClaudeDesk must not stop the other connector worker');
  assert.deepEqual(mutations,[],'ClaudeDesk must not claim or mutate Snap visibility actions');
  console.log(JSON.stringify({passed:5,failed:0,started:true,reused:true,sessionReplacement:true,realWorkerHeartbeat:true,foreignWorkerPreserved:true,foreignActionsIgnored:true,browserOpened:false}));
} finally{
  for(const p of children)p.kill();
  // Only PIDs read from this temporary fixture's own state files are stopped.
  const stateDir=join(root,'state/claudedesk-v1');
  try{
    const ids=await run(['-Command',`if(Test-Path -LiteralPath ${quote(stateDir)}){Get-ChildItem -LiteralPath ${quote(stateDir)} -Filter '*.json'|ForEach-Object {$v=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json;if($v.PSObject.Properties['watcherScript']){$v.processId}}}`]);
    for(const pid of ids.split(/\s+/).map(Number).filter(Boolean))workerIds.add(pid);
  }catch{}
  for(const pid of workerIds)try{process.kill(pid);}catch{}
  await new Promise(done=>server.close(done));
  await rm(root,{recursive:true,force:true});
}
