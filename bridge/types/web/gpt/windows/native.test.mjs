import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdtemp, mkdir, cp, rm } from 'node:fs/promises';
import { join, resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

const root = fileURLToPath(new URL('../../../../../', import.meta.url));
const runtime = join(root, 'bridge-runtime', 'gptweb');
const windows = fileURLToPath(new URL('./', import.meta.url));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
async function clean(path) {
  assert.equal(dirname(resolve(path)), resolve(tmpdir()));
  assert.ok(basename(path).startsWith('gptweb-native-test-'));
  await rm(path, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}

test('the compiled GPTWeb Bridge has no console or setup window and accepts only its bound URI or installer filename', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'gptweb-native-test-'));
  try {
    const executable = join(directory, 'setup.exe');
    const compiler = join(process.env.WINDIR, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
    const build = spawnSync(compiler, ['/nologo', '/target:winexe', '/platform:anycpu', '/reference:System.Windows.Forms.dll',
      '/reference:System.Web.Extensions.dll', '/out:' + executable, join(windows, 'GptWebLauncher.cs')], { windowsHide: true, encoding: 'utf8', timeout: 30000 });
    assert.equal(build.status, 0, build.stdout + build.stderr);
    const bytes = await readFile(executable), pe = bytes.readUInt32LE(0x3c);
    assert.equal(bytes.readUInt32LE(pe), 0x4550); assert.equal(bytes.readUInt16LE(pe + 24 + 68), 2, 'Windows GUI subsystem cannot create a console');
    const id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    for (const [uri, valid] of [
      ['cogentspec-gptweb://connect?request=' + id, true],
      ['cogentspec://connect?request=' + id, false], ['cogentspec-gptweb://other?request=' + id, false],
      ['cogentspec-gptweb://connect:123?request=' + id, false], ['cogentspec-gptweb://user@connect?request=' + id, false],
      ['cogentspec-gptweb://connect?request=' + id + '&command=anything', false],
      ['cogentspec-gptweb://connect?request=' + id + '#fragment', false],
      ['cogentspec-gptweb://connect?request=' + id + '%22', false],
    ]) {
      const result = spawnSync(executable, ['--validate-uri', uri], { windowsHide: true, timeout: 5000 });
      assert.equal(result.status, valid ? 0 : 64, uri);
    }
    for (const [filename, valid] of [
      ['CogentSpec-GPTWeb-Bridge-' + id + '.exe', true],
      ['CogentSpec-GPTWeb-Bridge-' + id + ' (1).exe', true],
      ['CogentSpec-GPTWeb-Bridge.exe', false], ['CogentSpec-GPTWeb-Setup-' + id + '.exe', false],
      ['CogentSpec-GPTWeb-Bridge-' + id + '.exe.cmd', false],
      ['CogentSpec-GPTWeb-Bridge-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.exe', false],
      ['CogentSpec-GPTWeb-Bridge-' + id + '-other.exe', false],
    ]) assert.equal(spawnSync(executable, ['--validate-filename', filename], { windowsHide: true, timeout: 5000 }).status, valid ? 0 : 64, filename);
    assert.equal(spawnSync(executable, [], { windowsHide: true, timeout: 5000 }).status, 64, 'An unbound download cannot start setup or select a workspace');
    const source = await readFile(join(windows, 'GptWebLauncher.cs'), 'utf8');
    assert.match(source, /CreateNoWindow = true/); assert.match(source, /WindowStyle = ProcessWindowStyle.Hidden/);
    assert.doesNotMatch(source, /Verb\s*=\s*"runas"|cmd\.exe|nativeMessaging|cogentspec:\/\/|new Form|Application\.Run|Windows\.Forms|MessageBox/);
  } finally { await clean(directory); }
});

test('native startup uses no listener, and its private runtime cannot terminate another connector worker', async () => {
  const entry = await readFile(join(runtime, 'scripts', 'start-gptweb-native.ps1'), 'utf8');
  const worker = await readFile(join(runtime, 'scripts', 'start-cogentstack-bridge.ps1'), 'utf8');
  const credential = await readFile(join(runtime, 'scripts', 'connect-cogentstack.ps1'), 'utf8');
  assert.doesNotMatch(entry, /workspace-reuse|workspace-presence|Start-Process|gptsnap-authorization/);
  assert.match(entry, /operation='authorize'/); assert.match(entry, /operation='ready'/);
  assert.ok(entry.indexOf("operation='authorize'") < entry.indexOf("$output = @(&"), 'Account/device preflight must precede worker startup');
  assert.doesNotMatch(worker, /Stop-Process -Id \$existingProcessId/);
  assert.match(worker, /ProcessStartupInformation = \$startup/); assert.match(worker, /ShowWindow = \[UInt16\]0/);
  assert.match(credential, /'gptweb-authorization\.json'/); assert.doesNotMatch(credential, /'gptsnap-authorization\.json'/);
});

test('the actual launcher process adapter runs its verified script without a console under a restricted inherited policy', { skip: process.platform !== 'win32' }, async () => {
  const directory=await mkdtemp(join(tmpdir(),'gptweb-native-test-'));
  try {
    await writeFile(join(directory,'fixture.ps1'), "param($ContextKey,[switch]$PrepareOnly)\nStart-Sleep -Milliseconds 400\nWrite-Output 'fixture-ready'\n");
    await writeFile(join(directory,'Probe.cs'), String.raw`
using System;using System.Diagnostics;using System.IO;using System.Threading;
internal static class GuiProcessProbe {
 [STAThread] static int Main(string[] args) {
  var info=GptWebLauncher.VerifiedPowerShell(args[0],"ctx-"+new string('a',64),"",true,false,false);
  if(info.UseShellExecute||!info.CreateNoWindow||info.WindowStyle!=ProcessWindowStyle.Hidden)return 20;
  using(var child=Process.Start(info)){
   bool visible=false;while(!child.WaitForExit(25)){try{child.Refresh();visible|=child.MainWindowHandle!=IntPtr.Zero;}catch(InvalidOperationException){if(!child.HasExited)throw;}}
   var stdout=child.StandardOutput.ReadToEnd();var stderr=child.StandardError.ReadToEnd();
   File.WriteAllText(args[1],visible?"visible":stdout.Trim()+"\nSTDERR:"+stderr+"\nEXIT:"+child.ExitCode);return visible||child.ExitCode!=0||stdout.Trim()!="fixture-ready"||stderr!=""?21:0;
  }
 }
}
`);
    const executable=join(directory,'ProcessProbe.exe');
    const built=spawnSync('C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe',['/nologo','/target:winexe','/main:GuiProcessProbe',
      '/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll','/out:'+executable,join(windows,'GptWebLauncher.cs'),join(directory,'Probe.cs')],
      {windowsHide:true,encoding:'utf8',timeout:30000});
    assert.equal(built.status,0,built.stdout+built.stderr);
    const result=spawnSync(executable,[join(directory,'fixture.ps1'),join(directory,'result.txt')],{
      windowsHide:true,encoding:'utf8',timeout:15000,env:{...process.env,PSExecutionPolicyPreference:'Restricted'}});
    const trace=await readFile(join(directory,'result.txt'),'utf8');
    assert.equal(result.status,0,trace+result.stderr);assert.equal(trace,'fixture-ready\nSTDERR:\nEXIT:0');
  } finally {await clean(directory);}
});

test('one-time setup installs SHA-verified files without Git, reuses them, and refuses a modified cache', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'gptweb-native-test-'));
  try {
    const source = (await readFile(join(windows, 'bootstrap.ps1'), 'utf8')).replaceAll('\r\n', '\n');
    assert.doesNotMatch(source, /git\.exe|git clone|codex.*install|mcp.*login/);
    const fixture = join(directory, 'package'); await mkdir(fixture);
    // Materialize the shipped manifest inventory, not untracked working folders.
    const manifest = JSON.parse(await readFile(join(runtime, 'runtime.json'), 'utf8'));
    await mkdir(join(fixture, 'scripts'));
    for (const path of Object.keys(manifest.files)) await cp(join(runtime, path), join(fixture, path));
    await cp(join(runtime, 'runtime.json'), join(fixture, 'runtime.json'));
    const nodeBytes = Buffer.from('isolated-node-fixture-never-executed');
    await writeFile(join(directory, 'node.bin'), nodeBytes);
    const metadata = { protocol: 'cogentspec-gptweb-native-release-v1', command: '$gptweb', runtimeRevision: 'a'.repeat(40),
      runtimeManifestSha256: sha(await readFile(join(fixture, 'runtime.json'))) };
    await writeFile(join(directory, 'release.json'), JSON.stringify(metadata));
    const mock = String.raw`
function Download([string]$Url,[string]$Path,[string]$Hash) {
 Add-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'trace.txt') -Value $Url
 if($Url -ceq 'https://nodejs.org/dist/v22.23.2/win-x64/node.exe'){$input=Join-Path $env:GPTWEB_FIXTURE 'node.bin'}else{
  $base='https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+('a'*40)+'/bridge-runtime/gptweb/'
  if(-not $Url.StartsWith($base,[StringComparison]::Ordinal)){throw 'wrong source'}
  $relative=$Url.Substring($base.Length)
  if($relative -cne 'runtime.json' -and $relative -cnotmatch '^scripts/[a-z0-9-]+\.(ps1|mjs)$'){throw 'wrong file'}
  $input=Join-Path (Join-Path $env:GPTWEB_FIXTURE 'package') $relative.Replace('/','\')
 }
 [IO.File]::WriteAllBytes($Path,[IO.File]::ReadAllBytes($input))
 if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash){throw 'hash mismatch'}
}
function Invoke-RestMethod { param($Uri,$MaximumRedirection,$TimeoutSec)
 if($Uri -cne 'https://cogentspec.app/api/bridge/gptweb/native-release' -or $MaximumRedirection -ne 0){throw 'wrong metadata'}
 return (Get-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'release.json') -Raw|ConvertFrom-Json)
}
`;
    const fixtureSource = source.replace("$root=Safe-Directory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\\gptweb-native')", '$root=Safe-Directory $env:GPTWEB_FIXTURE_ROOT')
      .replace("\ntry {\n    if($env:OS", () => '\n' + mock + '\ntry {\n    if($env:OS')
      .replaceAll('0d0f5e39f9f3d9587bc19f73eab3c2c9c4903fd02d6dbf9c853dd81b3d95fad4', sha(nodeBytes));
    await writeFile(join(directory, 'bootstrap.ps1'), fixtureSource);
    const installed = join(directory, 'installed');
    const run = () => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', join(directory, 'bootstrap.ps1'),
      '-ContextKey', 'ctx-' + 'a'.repeat(64), '-PrepareOnly'], { windowsHide: true, timeout: 30000, encoding: 'utf8',
      env: { ...process.env, GPTWEB_FIXTURE: directory, GPTWEB_FIXTURE_ROOT: installed } });
    let result = run(); assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout.trim()).status, 'prepared', result.stdout + result.stderr);
    const downloads = await readFile(join(directory, 'trace.txt'), 'utf8');
    result = run(); assert.equal(JSON.parse(result.stdout.trim()).status, 'prepared', result.stdout + result.stderr);
    assert.equal(await readFile(join(directory, 'trace.txt'), 'utf8'), downloads, 'Reuse must verify cache without downloading another package');
    const entry = join(installed, 'packages', metadata.runtimeManifestSha256, 'scripts', 'start-gptweb-native.ps1');
    await writeFile(entry, 'throw "fixture tampering"');
    result = run(); assert.equal(JSON.parse(result.stdout.trim()).status, 'not_ready');
    assert.equal(await readFile(entry, 'utf8'), 'throw "fixture tampering"', 'Do not silently overwrite a modified installation');
  } finally { await clean(directory); }
});

test('a scoped loopback proxy reaches the actual hidden PowerShell child without changing Windows proxy settings', { skip: process.platform !== 'win32' }, async () => {
  const directory=await mkdtemp(join(tmpdir(),'gptweb-native-test-'));
  let connections=0;
  const proxy=createServer();
  proxy.on('connect',(request,socket)=>{
    assert.equal(request.url,'cogentspec.app:443');connections++;
    socket.end('HTTP/1.1 502 Candidate transport probe\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
  });
  await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
  try {
    await writeFile(join(directory,'fixture.ps1'),String.raw`
param($ContextKey,[switch]$PrepareOnly)
if($env:COGENTSPEC_GPTWEB_LOOPBACK_PROXY -notmatch '^http://127\.0\.0\.1:[0-9]+$'){throw 'missing scoped transport'}
$request=[Net.HttpWebRequest]::Create('https://cogentspec.app/api/health');$request.Timeout=5000
try{$response=$request.GetResponse();$response.Dispose();throw 'unexpected upstream response'}catch{
 if($_.Exception.Message -eq 'unexpected upstream response'){throw}
 Write-Output 'proxy-reached'
}
`);
    await writeFile(join(directory,'Probe.cs'),String.raw`
using System;using System.Diagnostics;using System.IO;
internal static class ProxyProbe {
 [STAThread] static int Main(string[] args){
  var info=GptWebLauncher.VerifiedPowerShell(args[0],"ctx-"+new string('a',64),"",true,false,false);
  if(info.UseShellExecute||!info.CreateNoWindow||info.WindowStyle!=ProcessWindowStyle.Hidden)return 20;
  using(var child=Process.Start(info)){
   var text=child.StandardOutput.ReadToEnd();var error=child.StandardError.ReadToEnd();child.WaitForExit();
   File.WriteAllText(args[1],"EXIT:"+child.ExitCode+"\nSTDOUT:"+text+"\nSTDERR:"+error);
   return child.ExitCode==0&&text.Trim()=="proxy-reached"&&error==""?0:21;
  }
 }
}
`);
    const executable=join(directory,'ProxyProbe.exe');
    const built=spawnSync('C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe',['/nologo','/target:winexe','/main:ProxyProbe',
      '/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll','/out:'+executable,join(windows,'GptWebLauncher.cs'),join(directory,'Probe.cs')],
      {windowsHide:true,encoding:'utf8',timeout:30000});
    assert.equal(built.status,0,built.stdout+built.stderr);
    await writeFile(executable+'.config','<configuration><system.net><defaultProxy enabled="true"><proxy proxyaddress="http://127.0.0.1:'+proxy.address().port+'" bypassonlocal="false" usesystemdefault="false" /></defaultProxy></system.net></configuration>');
    const result=await new Promise((resolve,reject)=>{
      const child=spawn(executable,[join(directory,'fixture.ps1'),join(directory,'trace.txt')],{windowsHide:true,timeout:15000,env:{...process.env,PSExecutionPolicyPreference:'Restricted'}});
      child.on('error',reject);child.on('exit',(code,signal)=>resolve({code,signal}));
    });
    assert.equal(result.code,0,await readFile(join(directory,'trace.txt'),'utf8'));assert.equal(connections,1);
  } finally {await new Promise(resolve=>proxy.close(resolve));await clean(directory);}
});

test('native startup proves the browser account before worker creation and never treats readiness as connection', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'gptweb-native-test-'));
  try {
    let source = (await readFile(join(runtime, 'scripts/start-gptweb-native.ps1'), 'utf8')).replaceAll('\r\n', '\n');
    source = source.replace("Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\\desktop-credential.json'", "Join-Path $env:GPTWEB_FIXTURE 'credential.json'");
    const adapter = String.raw`
function Invoke-RestMethod { param($Method,$Uri,$TimeoutSec,$ContentType,$Headers,$Body)
 if($Uri -cne 'https://cogentspec.app/api/bridge/gptweb/startup' -or $Headers.Authorization -cne 'Bearer cga_isolated_fixture'){throw 'invalid_request'}
 $value=$Body|ConvertFrom-Json
 Add-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'trace.txt') -Value $value.operation
 if($env:GPTWEB_FIXTURE_MODE -eq 'wrong-account'){throw 'forbidden'}
 return @{protocol='cogentspec-gptweb-startup-v1';status=$(if($value.operation -eq 'authorize'){'authorized'}else{'ready'});workspaceConnected=$false}
}
`;
    source = source.replace('\ntry {\n', () => '\n' + adapter + '\ntry {\n');
    await writeFile(join(directory, 'start.ps1'), source);
    await writeFile(join(directory, 'start-cogentstack-bridge.ps1'), String.raw`
param($ContextKey,$Surface,$Experience,[switch]$ListenerOnly,[switch]$ResumeApproval)
Add-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'trace.txt') -Value 'worker'
@{status='ready';contextKey=$ContextKey;contextIsolated=$true;presenceVerified=$true;accountState='signed_in';projectDataConnection='authenticated_desktop_bridge';defaultDirectoryReady=$true;browserOpened=$false}|ConvertTo-Json -Compress
`);
    await writeFile(join(directory, 'run.ps1'), String.raw`
Add-Type -AssemblyName System.Security
$bytes=[Text.Encoding]::UTF8.GetBytes('cga_isolated_fixture')
$protected=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
@{token=[Convert]::ToBase64String($protected)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'credential.json')
& (Join-Path $env:GPTWEB_FIXTURE 'start.ps1') -ContextKey ('ctx-'+('a'*64)) -StartupRequest 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
`);
    const run = mode => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', join(directory, 'run.ps1')], {
      windowsHide: true, encoding: 'utf8', timeout: 15000, env: { ...process.env, GPTWEB_FIXTURE: directory, GPTWEB_FIXTURE_MODE: mode } });
    let result = run('wrong-account');assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout.trim()).status, 'not_ready');
    assert.equal((await readFile(join(directory, 'trace.txt'), 'utf8')).trim(), 'authorize');
    await writeFile(join(directory, 'trace.txt'), '');
    result = run('approved');assert.equal(result.status, 0, result.stderr);
    const ready = JSON.parse(result.stdout.trim());assert.equal(ready.status, 'ready');
    assert.equal(ready.workspaceConnected, false);assert.equal(ready.acknowledgementVerified, false);
    assert.deepEqual((await readFile(join(directory, 'trace.txt'), 'utf8')).trim().split(/\r?\n/), ['authorize', 'worker', 'ready']);
    assert.doesNotMatch(result.stdout + result.stderr, /cga_isolated_fixture|protected|Bearer/);
    await rm(join(directory,'credential.json'));
    await writeFile(join(directory,'trace.txt'),'');
    await writeFile(join(directory,'setup-gptweb-device.ps1'),String.raw`
param($ContextKey,$StartupRequest,[switch]$ResumeApproval)
if($StartupRequest -cne 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'){throw 'wrong startup'}
Add-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'trace.txt') -Value 'enroll'
if(-not $ResumeApproval){@{protocol='cogentspec-gptweb-native-v1';status='approval_required';approvalUrl='https://cogentspec.com/activate?code=ABCD-EFGH&experience=web'}|ConvertTo-Json -Compress;return}
Add-Type -AssemblyName System.Security
$bytes=[Text.Encoding]::UTF8.GetBytes('cga_isolated_fixture')
$protected=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
@{token=[Convert]::ToBase64String($protected)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'credential.json')
@{protocol='cogentspec-gptweb-native-v1';status='enrolled'}|ConvertTo-Json -Compress
`);
    const cold=resume=>spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-File',join(directory,'start.ps1'),
      '-ContextKey','ctx-'+'a'.repeat(64),'-StartupRequest','aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',...(resume?['-ResumeApproval']:[])],{
      windowsHide:true,encoding:'utf8',timeout:15000,env:{...process.env,GPTWEB_FIXTURE:directory,GPTWEB_FIXTURE_MODE:'approved'}});
    result=cold(false);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'approval_required');
    assert.deepEqual((await readFile(join(directory,'trace.txt'),'utf8')).trim().split(/\r?\n/),['enroll'],'No worker before genuine first-use permission');
    result=cold(true);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'ready');
    assert.deepEqual((await readFile(join(directory,'trace.txt'),'utf8')).trim().split(/\r?\n/),['enroll','enroll','authorize','worker','ready']);
  } finally { await clean(directory); }
});

test('one-time enrollment finishes after account approval without a browser job or worker startup', { skip: process.platform !== 'win32' }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'gptweb-native-test-'));
  try {
    await cp(join(runtime, 'scripts/setup-gptweb-device.ps1'), join(directory, 'setup.ps1'));
    await writeFile(join(directory, 'connect-cogentstack.ps1'), String.raw`
param($Mode,$Surface,$ContextKey,$Experience,$RequestTimeoutSeconds,[switch]$BrowserApproval)
if($Surface -cne 'chatgpt' -or $Experience -cne 'web'){throw 'wrong connector'}
Add-Content -LiteralPath (Join-Path $env:GPTWEB_FIXTURE 'trace.txt') -Value $Mode
switch($Mode){
 'status' {@{status='signed_out'}|ConvertTo-Json -Compress}
 'start' {if(-not $BrowserApproval){throw 'browser consent missing'};@{status='approval_required';approvalUrl='https://cogentspec.com/activate?user_code=fixture'}|ConvertTo-Json -Compress}
 'complete' {if(-not $BrowserApproval){throw 'wrong pending approval'};@{status=$env:GPTWEB_ENROLLMENT_RESULT}|ConvertTo-Json -Compress}
 default {throw 'unexpected operation'}
}
`);
    const run = (resume, status = 'authorized') => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', join(directory, 'setup.ps1'),
      '-ContextKey', 'ctx-' + 'a'.repeat(64), ...(resume ? ['-ResumeApproval'] : [])], {
      windowsHide: true, encoding: 'utf8', timeout: 10000, env: { ...process.env, GPTWEB_FIXTURE: directory, GPTWEB_ENROLLMENT_RESULT: status } });
    let result = run(false);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'approval_required');
    result = run(true);assert.equal(result.status,0,result.stderr);const enrolled=JSON.parse(result.stdout.trim());
    assert.equal(enrolled.status,'enrolled');assert.equal(enrolled.workspaceConnected,false);assert.equal(enrolled.browserOpened,false);
    assert.deepEqual((await readFile(join(directory,'trace.txt'),'utf8')).trim().split(/\r?\n/),['status','start','complete']);
    result = run(true, 'approval_pending');assert.equal(result.status,0,result.stderr);
    assert.equal(JSON.parse(result.stdout.trim()).status,'approval_required','Waiting for consent must reuse the same approval instead of reporting failure');
  } finally { await clean(directory); }
});
