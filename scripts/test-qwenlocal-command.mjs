import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../plugins/cogentspec/skills/qwenlocal/', import.meta.url));
const hash = data => createHash('sha256').update(data.replaceAll('\r\n', '\n')).digest('hex');
test('Qwen ships as a verified command in the existing Git marketplace, including its background runtime', async () => {
  const manifest = JSON.parse(await fs.readFile(path.join(root, 'command.json'), 'utf8'));
  assert.equal(manifest.source, 'https://github.com/cogentspec/cogentspec-marketplace.git'); assert.equal(manifest.command, '$qwenlocal');
  for (const [relative, digest] of Object.entries(manifest.files)) assert.equal(hash(await fs.readFile(path.join(root, relative), 'utf8')), digest, relative);
  const launch = await fs.readFile(path.join(root, 'scripts/start-qwenlocal.ps1'), 'utf8');
  assert.match(launch, /https:\/\/cogentspec\.app\/api\/qwen\/command\/claim/);
  assert.match(launch, /Start-CogentQwenRuntime/);
  assert.doesNotMatch(launch, /ExecutionPolicy Bypass|Set-ExecutionPolicy|schtasks|RunOnce|New-NetFirewall|cogentspec:\/\/desktop/);
  assert.match(launch, /-MaximumRedirection 0/);
  const installer = await fs.readFile(path.join(root, 'scripts/install-qwenlocal.ps1'), 'utf8');
  assert.match(installer, /HKCU:\\Software\\Classes\\cogentspec-browser/);
  assert.match(installer, /Assert-CogentQwenLauncher/);
  assert.doesNotMatch(installer, /\$command = .*powershell|\$command = .*-File/);
  assert.doesNotMatch(installer, /HKLM|RunOnce|schtasks|Set-ExecutionPolicy|New-NetFirewall/);
});
test('Codex/Claude canonical and compatibility packages contain the same Qwen command, not divergent provider copies', async () => {
  const files = ['command.json', 'SKILL.md', 'scripts/install-qwenlocal.ps1', 'scripts/prepare-qwen-runtime.ps1', 'scripts/start-qwenlocal.ps1', 'scripts/qwen-runtime.mjs', 'scripts/build-qwen-launcher.ps1', 'scripts/qwen-windowless-launcher.cs'];
  for (const packageRoot of ['../plugins/cogentstack/skills/qwenlocal/', '../claude-plugins/cogentspec/skills/qwenlocal/', '../claude-plugins/cogentstack/skills/qwenlocal/']) {
    const mirror = fileURLToPath(new URL(packageRoot, import.meta.url));
    for (const relative of files) assert.equal(hash(await fs.readFile(path.join(mirror, relative), 'utf8')), hash(await fs.readFile(path.join(root, relative), 'utf8')), packageRoot + relative);
  }
});
test('Windows command package validates before registration and rejects modified runtime bytes', { skip: process.platform !== 'win32' }, async () => {
  const script = path.join(root, 'scripts/install-qwenlocal.ps1');
  const result = JSON.parse(execFileSync('powershell.exe', ['-NoProfile', '-File', script, '-ValidateOnly'], { encoding: 'utf8', timeout: 20_000 }));
  assert.equal(result.status, 'validated'); assert.equal(result.command, '$qwenlocal');
  const fixture = await fs.mkdtemp(path.join(os.tmpdir(), 'qwen-git-command-'));
  try {
    await fs.cp(root, fixture, { recursive: true });
    await fs.appendFile(path.join(fixture, 'scripts/qwen-runtime.mjs'), '\n// modified fixture\n');
    assert.throws(() => execFileSync('powershell.exe', ['-NoProfile', '-File', path.join(fixture, 'scripts/install-qwenlocal.ps1'), '-ValidateOnly'], { encoding: 'utf8', timeout: 20_000, stdio: 'pipe' }));
  } finally { await fs.rm(fixture, { recursive: true, force: true, maxRetries: 15, retryDelay: 100 }); }
});
test('all Windows command scripts parse without running registration, a handler or a model', { skip: process.platform !== 'win32' }, async () => {
  for (const relative of ['install-qwenlocal.ps1', 'prepare-qwen-runtime.ps1', 'start-qwenlocal.ps1', 'build-qwen-launcher.ps1']) {
    const scriptPath = path.join(root, 'scripts', relative).replaceAll("'", "''");
    const check = `$e=$null;$t=$null;[Management.Automation.Language.Parser]::ParseFile('${scriptPath}',[ref]$t,[ref]$e)|Out-Null;if($e){$e|ForEach-Object{$_.Message};exit 1}`;
    execFileSync('powershell.exe', ['-NoProfile', '-EncodedCommand', Buffer.from(check, 'utf16le').toString('base64')], { encoding: 'utf8', timeout: 20_000 });
  }
});
test('actual Windows GUI launcher and supervised console worker have no console, reject URI injection and preserve both logs', { skip: process.platform !== 'win32' }, async () => {
  const fixture = await fs.mkdtemp(path.join(os.tmpdir(), 'qwen windowless command '));
  const ps = script => execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], { encoding: 'utf8', timeout: 30_000, windowsHide: true, stdio: 'pipe' });
  const quoted = value => "'" + value.replaceAll("'", "''") + "'";
  try {
    await fs.cp(root, fixture, { recursive: true });
    ps(path.join(fixture, 'scripts/build-qwen-launcher.ps1'));
    const executable = path.join(fixture, 'CogentSpec-Qwen-Launcher.exe');
    const bytes = await fs.readFile(executable), pe = bytes.readUInt32LE(60);
    assert.equal(bytes.readUInt16LE(pe + 92), 2, 'The executable must use the GUI subsystem, not a hidden console subsystem');
    const probe = path.join(fixture, 'console-probe.exe');
    const bootstrap = path.join(fixture, 'bootstrap.txt'), runtime = path.join(fixture, 'runtime.txt');
    const out = path.join(fixture, 'runtime.out'), error = path.join(fixture, 'runtime.err'), done = path.join(fixture, 'done.txt');
    const compile = path.join(fixture, 'compile-probe.ps1');
    await fs.writeFile(compile, `Add-Type -OutputType ConsoleApplication -OutputAssembly ${quoted(probe)} -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices;
public static class ConsoleProbe {
 [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
 public static void Main(string[] args) {
  File.WriteAllText(args[2], GetConsoleWindow() == IntPtr.Zero ? "no-console" : "console");
  Console.Out.Write(new string('o', 70000)); Console.Error.Write(new string('e', 70000));
 }
}
'@\n`);
    ps(compile);
    // Isolated native-launch acceptance only: replace the network/claim entry
    // with a harmless probe. No real ticket, registry write or runtime is used.
    await fs.writeFile(path.join(fixture, 'scripts/start-qwenlocal.ps1'), `param([string]$Uri)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
. ${quoted(path.join(fixture, 'scripts/prepare-qwen-runtime.ps1'))}
Add-Type -Name ConsoleProbeState -Namespace QwenTest -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CogentSpecBrowserRuntime/node-v22.23.4-win-x64/node.exe')) { $null = Get-CogentQwenNode }
[IO.File]::WriteAllText(${quoted(bootstrap)}, [string]([QwenTest.ConsoleProbeState]::GetConsoleWindow() -eq [IntPtr]::Zero))
Start-CogentQwenRuntime -Node ${quoted(probe)} -Module 'unused-fixture' -Config ${quoted(runtime)} -OutputPath ${quoted(out)} -ErrorPath ${quoted(error)}
[IO.File]::WriteAllText(${quoted(done)}, 'done')
`);
    const synthetic = 'cogentspec-browser://qwenlocal/' + '0'.repeat(64);
    for (const args of [[], ['https://untrusted.invalid/'], [synthetic + '" -Command anything'], [synthetic, 'extra']]) {
      assert.throws(() => execFileSync(executable, args, { timeout: 5000, windowsHide: true, stdio: 'pipe' }), failure => failure.status === 2);
    }
    await assert.rejects(fs.access(bootstrap), 'Invalid URI must not start PowerShell');
    execFileSync(executable, [synthetic], { timeout: 5000, windowsHide: true });
    for (let attempt = 0; attempt < 150; attempt++) {
      if (await fs.access(done).then(() => true, () => false)) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(await fs.readFile(bootstrap, 'utf8'), 'True', 'PowerShell has no attached console');
    assert.equal(await fs.readFile(runtime, 'utf8'), 'no-console', 'The runtime has no attached console');
    assert.equal((await fs.readFile(out)).length, 70000);
    assert.equal((await fs.readFile(error)).length, 70000, 'Both streams drain without deadlock');
    assert.equal(await fs.readFile(done, 'utf8'), 'done');
    await fs.appendFile(executable, 'tampered');
    const check = path.join(fixture, 'check-tamper.ps1');
    await fs.writeFile(check, `. ${quoted(path.join(fixture, 'scripts/prepare-qwen-runtime.ps1'))}\nAssert-CogentQwenLauncher ${quoted(fixture)}\n`);
    assert.throws(() => ps(check), 'A modified generated launcher must not be reused');
  } finally { await fs.rm(fixture, { recursive: true, force: true }); }
});
