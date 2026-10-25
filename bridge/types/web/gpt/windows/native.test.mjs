import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdtemp, mkdir, cp, rm } from 'node:fs/promises';
import { join, resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
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

test('the compiled GPTWeb launcher is a GUI executable and accepts only its exact startup URI', { skip: process.platform !== 'win32' }, async () => {
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
    const source = await readFile(join(windows, 'GptWebLauncher.cs'), 'utf8');
    assert.match(source, /CreateNoWindow = true/); assert.match(source, /WindowStyle = ProcessWindowStyle.Hidden/);
    assert.doesNotMatch(source, /Verb\s*=\s*"runas"|cmd\.exe|nativeMessaging|cogentspec:\/\//);
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
 'complete' {if(-not $BrowserApproval){throw 'wrong pending approval'};@{status='connected'}|ConvertTo-Json -Compress}
 default {throw 'unexpected operation'}
}
`);
    const run = resume => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', join(directory, 'setup.ps1'),
      '-ContextKey', 'ctx-' + 'a'.repeat(64), ...(resume ? ['-ResumeApproval'] : [])], {
      windowsHide: true, encoding: 'utf8', timeout: 10000, env: { ...process.env, GPTWEB_FIXTURE: directory } });
    let result = run(false);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout.trim()).status,'approval_required');
    result = run(true);assert.equal(result.status,0,result.stderr);const enrolled=JSON.parse(result.stdout.trim());
    assert.equal(enrolled.status,'enrolled');assert.equal(enrolled.workspaceConnected,false);assert.equal(enrolled.browserOpened,false);
    assert.deepEqual((await readFile(join(directory,'trace.txt'),'utf8')).trim().split(/\r?\n/),['status','start','complete']);
  } finally { await clean(directory); }
});
