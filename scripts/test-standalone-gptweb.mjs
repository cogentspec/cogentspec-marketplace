import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile,readdir,mkdir,mkdtemp,writeFile,cp,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const root=new URL('../',import.meta.url), runtime=new URL('bridge-runtime/gptweb/',root);
const manifestBytes=await readFile(new URL('runtime.json',runtime)),manifest=JSON.parse(manifestBytes);
const digest=createHash('sha256').update(manifestBytes).digest('hex');
const bootstrap=(await readFile(new URL('bridge-runtime/start-gptweb.ps1',root),'utf8')).replaceAll('\r\n','\n');
test('standalone runtime has no AI plugin or skill package and pins every public helper',async()=>{
 assert.equal(manifest.pluginRequired,false);assert.equal(manifest.codexRequired,false);
 const files=await readdir(runtime,{recursive:true});
 assert.ok(!files.some(name=>/SKILL\.md|\.codex-plugin|\.claude-plugin|openai\.yaml/.test(name)));
 for(const [path,sha] of Object.entries(manifest.files))assert.equal(createHash('sha256').update(await readFile(new URL(path,runtime))).digest('hex'),sha,path);
 const launcher=await readFile(new URL('scripts/start-cogentstack-bridge.ps1',runtime),'utf8');
 assert.ok(launcher.includes("'..\\runtime.json'"));assert.doesNotMatch(launcher,/\.codex-plugin|\.claude-plugin/);
 assert.doesNotMatch(bootstrap,/codex(?:\.cmd|\.exe)?\s+plugin|plugin\s+(?:add|install)|mcp\s+login|Start-Process|window\.open/);
 assert.ok(bootstrap.includes('core.autocrlf=false')&&bootstrap.includes('core.hooksPath='));
});

const mockRun=String.raw`
function Run([string]$File,[string[]]$Arguments,[string]$WorkingDirectory,[int]$LimitMilliseconds=30000){
 Add-Content -LiteralPath $env:WEB_FIXTURE_TRACE -Value ($Arguments -join '|')
 if($Arguments -contains 'clone'){
  if($Arguments[-2] -cne 'https://github.com/cogentspec/cogentspec-marketplace.git' -or $Arguments -notcontains '--no-checkout' -or $Arguments -notcontains 'core.autocrlf=false'){throw 'Unsafe clone'}
  $package=Join-Path $Arguments[-1] 'bridge-runtime\gptweb'
  New-Item -ItemType Directory -Path $package -Force|Out-Null
  Copy-Item -Path (Join-Path $env:WEB_FIXTURE_PACKAGE '*') -Destination $package -Recurse
  if($env:WEB_FIXTURE_CASE -eq 'modified'){Add-Content -LiteralPath (Join-Path $package 'scripts\connect-gptweb.ps1') -Value '# modified'}
  if($env:WEB_FIXTURE_CASE -eq 'unexpected'){Set-Content -LiteralPath (Join-Path $package 'extra.ps1') -Value 'throw 1'}
  return ''
 }
 if($Arguments -contains 'get-url'){if($env:WEB_FIXTURE_CASE -eq 'wrong-source'){return 'https://attacker.invalid/repo.git'};return 'https://github.com/cogentspec/cogentspec-marketplace.git'}
 if($Arguments -contains 'fetch' -or $Arguments -contains 'update-ref'){if($Arguments[-1] -cnotmatch '^[a-f0-9]{40}$'){throw 'Unpinned revision'};return ''}
 if($Arguments -contains 'sparse-checkout' -or $Arguments -contains 'checkout'){return ''}
 if($Arguments -contains '-File'){
  if($WorkingDirectory -cne $env:WEB_FIXTURE_CWD){throw 'Workspace changed'}
  if($Arguments[-1] -notlike '*\scripts\connect-gptweb.ps1'){throw 'Wrong entry'}
  $connected=$env:WEB_FIXTURE_CASE -ne 'no-ack'
  return (@{protocol='cogentspec-workspace-beacon-start-v1';status=$(if($connected){'connected'}else{'not_connected'});surface='chatgpt';experience='web';workspaceConnected=$connected;acknowledgementVerified=$connected;browserReused=$true;browserOpened=$false;browserHandoff='authenticated-workspace-reuse'}|ConvertTo-Json -Compress)
 }
 throw 'Unexpected process'
}
`;

test('quiet bootstrap installs or reuses only the verified runtime; bad source, bytes, metadata and missing ACK never connect',{skip:process.platform!=='win32'},async()=>{
 const directory=await mkdtemp(join(tmpdir(),'standalone-gptweb-'));
 try{
  const packageDirectory=join(directory,'fixture-package');await cp(runtime,packageDirectory,{recursive:true});
  const metadata={protocol:'cogentspec-standalone-web-release-v1',command:'$gptweb',version:manifest.version,
   manifestSha256:digest,repository:manifest.repository,sourceDirectory:'bridge-runtime/gptweb',revision:'a'.repeat(40),pluginRequired:false,codexRequired:false};
  await writeFile(join(directory,'metadata.json'),JSON.stringify(metadata));
  const driver=join(directory,'bootstrap.ps1'), trace=join(directory,'trace.txt');
  await writeFile(driver,bootstrap.replace("$root=Plain-Directory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\\standalone-web')","$root=Plain-Directory $env:WEB_FIXTURE_ROOT")
   .replace("try {\n    if($env:OS",()=>mockRun+"\ntry {\n    if($env:OS")
   .replaceAll('failureStage=$stage;runtimeInstalled=$installed;','failureStage=$stage;fixtureError=$_.Exception.Message;runtimeInstalled=$installed;'));
  const harness=join(directory,'harness.ps1');
  await writeFile(harness,String.raw`
function Invoke-RestMethod {
 param($Uri,$Method,$MaximumRedirection,$TimeoutSec)
 if($Uri -cne 'https://cogentspec.app/api/bridge/gptweb/runtime' -or $MaximumRedirection -ne 0){throw 'Wrong metadata request'}
 $value=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'metadata.json') -Raw|ConvertFrom-Json
 if($env:WEB_FIXTURE_CASE -eq 'bad-metadata'){$value.repository='https://attacker.invalid/repo.git'}
 return $value
}
function Get-Command { param($Name,$CommandType,$ErrorAction);if($Name -cne 'git.exe'){throw 'Unexpected tool'};return @{Source='fixture-git.exe'} }
& (Join-Path $PSScriptRoot 'bootstrap.ps1')
`);
  const fixtureRoot=join(directory,'installed');
  for(const scenario of ['install','reuse','modified','unexpected','wrong-source','bad-metadata','no-ack']){
   const installRoot=['install','reuse'].includes(scenario)?fixtureRoot:join(directory,scenario);
   await writeFile(trace,'');
   const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-File',harness],{encoding:'utf8',windowsHide:true,timeout:15000,cwd:directory,
    env:{...process.env,WEB_FIXTURE_ROOT:installRoot,WEB_FIXTURE_CWD:directory,WEB_FIXTURE_PACKAGE:packageDirectory,WEB_FIXTURE_TRACE:trace,WEB_FIXTURE_CASE:scenario}});
   assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout.trim());
   assert.equal(receipt.pluginInstalled,false);assert.equal(receipt.codexRequired,false);assert.equal(receipt.browserOpened,false);
   assert.equal(receipt.workspaceConnected,['install','reuse'].includes(scenario),scenario+':'+result.stdout);
   const calls=await readFile(trace,'utf8');assert.doesNotMatch(calls,/codex|plugin|mcp|activate|https:\/\/attacker/);
   if(scenario==='reuse'){assert.equal(receipt.runtimeInstalled,false);assert.doesNotMatch(calls,/clone/);}
   if(['modified','unexpected','wrong-source','bad-metadata'].includes(scenario))assert.doesNotMatch(calls,/connect-gptweb\.ps1/);
  }
 }finally{await rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
});

test('standalone scripts parse in Windows PowerShell without executing a worker',{skip:process.platform!=='win32'},()=>{
 const script=String.raw`$errors=@();Get-ChildItem -LiteralPath $env:WEB_PARSE_ROOT -Filter '*.ps1' -Recurse|ForEach-Object{$tokens=$null;$found=$null;[void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$found);$errors+=@($found)};if($errors.Count){$errors|ForEach-Object{Write-Output $_.Message};exit 1}`;
 const result=spawnSync('powershell.exe',['-NoProfile','-Command',script],{encoding:'utf8',windowsHide:true,env:{...process.env,WEB_PARSE_ROOT:new URL('bridge-runtime/',root).pathname.replace(/^\/([A-Z]:)/,'$1')}});
 assert.equal(result.status,0,result.stdout+result.stderr);
});

test('real bootstrap process adapter hides its child console, preserves workspace and terminates an owned timeout',{skip:process.platform!=='win32'},async()=>{
 const directory=await mkdtemp(join(tmpdir(),'gptweb-native-process-'));
 try{
  const definitions=bootstrap.slice(0,bootstrap.indexOf("try {\n    if($env:OS"));
  assert.ok(definitions.includes('function Run'));
  await writeFile(join(directory,'definitions.ps1'),definitions);
  await writeFile(join(directory,'child.ps1'),String.raw`
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class WebConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
@{directory=(Get-Location).ProviderPath;console=[WebConsole]::GetConsoleWindow().ToInt64();redirected=[Console]::IsOutputRedirected}|ConvertTo-Json -Compress
`);
  await writeFile(join(directory,'stall.ps1'),String.raw`[IO.File]::WriteAllText($env:WEB_NATIVE_PID,[string]$PID);Start-Sleep -Seconds 20`);
  const harness=join(directory,'harness.ps1');
  await writeFile(harness,String.raw`
. (Join-Path $PSScriptRoot 'definitions.ps1')
$power=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$result=(Run $power @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'child.ps1')) $PSScriptRoot 10000)|ConvertFrom-Json
if($result.directory -cne $PSScriptRoot -or $result.console -ne 0 -or -not $result.redirected){throw 'Child was visible or moved workspace'}
try{$null=Run $power @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'stall.ps1')) $PSScriptRoot 4000;throw 'Timeout was ignored'}catch{if($_.Exception.Message -cne 'runtime_timeout'){throw}}
$ownedId=[int][IO.File]::ReadAllText($env:WEB_NATIVE_PID)
if(Get-Process -Id $ownedId -ErrorAction SilentlyContinue){throw 'Owned child survived timeout'}
@{hidden=$true;workspacePreserved=$true;ownedTimeoutStopped=$true}|ConvertTo-Json -Compress
`);
  const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-File',harness],{encoding:'utf8',windowsHide:true,timeout:18000,cwd:directory,env:{...process.env,WEB_NATIVE_PID:join(directory,'child.pid')}});
  assert.equal(result.status,0,result.stdout+result.stderr);assert.deepEqual(JSON.parse(result.stdout.trim()),{hidden:true,workspacePreserved:true,ownedTimeoutStopped:true});
 }finally{await rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
});

test('real sparse Git preparation materializes only the pinned runtime, even when the default branch has changed',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'gptweb-pinned-source-'));
 const git=(args,cwd=directory)=>{
  const result=spawnSync('git',['-c','core.autocrlf=false','-c','commit.gpgsign=false',...args],{cwd,encoding:'utf8',windowsHide:true,timeout:20000});
  assert.equal(result.status,0,result.stderr);return result.stdout.trim();
 };
 try{
  const origin=join(directory,'origin'),checkout=join(directory,'checkout');await mkdir(origin);
  git(['init','--quiet'],origin);await cp(runtime,join(origin,'bridge-runtime','gptweb'),{recursive:true});
  await mkdir(join(origin,'plugins','unrelated'),{recursive:true});await writeFile(join(origin,'plugins','unrelated','SKILL.md'),'must not be checked out');
  git(['add','.'],origin);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','reviewed runtime'],origin);
  const approved=git(['rev-parse','HEAD'],origin);
  await writeFile(join(origin,'bridge-runtime','gptweb','scripts','connect-gptweb.ps1'),'unapproved later branch contents');
  git(['add','.'],origin);git(['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','later branch'],origin);
  git(['clone','--quiet','--filter=blob:none','--sparse','--no-checkout',origin,checkout]);
  git(['fetch','--quiet','--depth=1','origin',approved],checkout);
  git(['update-ref','--no-deref','HEAD',approved],checkout);
  git(['sparse-checkout','set','--no-cone','/bridge-runtime/gptweb/'],checkout);
  git(['checkout','--detach','--quiet',approved],checkout);
  assert.equal(await readFile(join(checkout,'bridge-runtime','gptweb','scripts','connect-gptweb.ps1'),'utf8'),await readFile(new URL('scripts/connect-gptweb.ps1',runtime),'utf8'));
  assert.ok(!(await readdir(checkout)).includes('plugins'));
  assert.equal(createHash('sha256').update(await readFile(join(checkout,'bridge-runtime','gptweb','runtime.json'))).digest('hex'),digest);
 }finally{await rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
});

test('standalone entry uses the existing encrypted credential and requires its exact live GPTWeb acknowledgement',{skip:process.platform!=='win32'},async()=>{
 const directory=await mkdtemp(join(tmpdir(),'gptweb-entry-'));
 try{
  const entry=(await readFile(new URL('scripts/connect-gptweb.ps1',runtime),'utf8')).replace(/\$credentialPath = Join-Path[^\r\n]+/,'$credentialPath = Join-Path $PSScriptRoot "credential.json"');
  await writeFile(join(directory,'connect-gptweb.ps1'),entry);
  await writeFile(join(directory,'start-cogentstack-bridge.ps1'),String.raw`
param($ContextKey,$Surface,$Experience,[switch]$ListenerOnly)
if($Surface -cne 'chatgpt' -or $Experience -cne 'web' -or -not $ListenerOnly){throw 'Wrong destination'}
$context='ctx-'+('a'*64)
$url='https://cogentspec.app/stack?surface=chatgpt&context='+$context+'&experience=web&open=web&nav='+('b'*32)+'#desktop-web=cgw_'+('c'*40)
@{status='ready';contextKey=$context;contextIsolated=$true;presenceVerified=$true;defaultDirectoryReady=$true;accountState='signed_in';projectDataConnection='authenticated_desktop_bridge';browserOpened=$false;webWorkspaceUrl=$url}|ConvertTo-Json -Compress
`);
  const harness=join(directory,'harness.ps1');
  await writeFile(harness,String.raw`
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName System.Security
$bytes=[Text.Encoding]::UTF8.GetBytes('fixture-private-token')
@{token=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'credential.json')
function Invoke-RestMethod {
 param($Method,$Uri,$TimeoutSec,$ContentType,$Headers,$Body)
 if($Uri -cne 'https://cogentspec.com/api/device-authorization/workspace-reuse' -or $Headers.Authorization -cne 'Bearer fixture-private-token'){throw 'Wrong protected request'}
 $binding=$Body|ConvertFrom-Json
 if($binding.surface -cne 'chatgpt' -or $binding.experience -cne 'web' -or $binding.contextKey -cne ('ctx-'+('a'*64))){throw 'Wrong task'}
 @{protocol='cogentspec-workspace-reuse-v1';contextKey=$binding.contextKey;surface=$(if($env:WEB_ENTRY_CASE -eq 'wrong-area'){'qwen-web'}else{'chatgpt'});experience='web';status=$(if($env:WEB_ENTRY_CASE -eq 'missing-ack'){'owner_unavailable'}else{'reused'});acknowledgementVerified=($env:WEB_ENTRY_CASE -ne 'missing-ack')}
}
& (Join-Path $PSScriptRoot 'connect-gptweb.ps1')
`);
  for(const scenario of ['connected','missing-ack','wrong-area']){
   const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-File',harness],{cwd:directory,encoding:'utf8',windowsHide:true,timeout:10000,env:{...process.env,WEB_ENTRY_CASE:scenario}});
   assert.equal(result.status,0,result.stderr);assert.doesNotMatch(result.stdout+result.stderr,/fixture-private-token|cgw_|ctx-[a-f0-9]{64}/);
   const receipt=JSON.parse(result.stdout.trim());assert.equal(receipt.workspaceConnected,scenario==='connected');assert.equal(receipt.acknowledgementVerified,scenario==='connected');assert.equal(receipt.browserOpened,false);
  }
 }finally{await rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
});
