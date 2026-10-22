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
  assert.match(launch, /-WindowStyle Hidden/);
  assert.doesNotMatch(launch, /ExecutionPolicy Bypass|Set-ExecutionPolicy|schtasks|RunOnce|New-NetFirewall|cogentspec:\/\/desktop/);
  assert.match(launch, /-MaximumRedirection 0/);
  const installer = await fs.readFile(path.join(root, 'scripts/install-qwenlocal.ps1'), 'utf8');
  assert.match(installer, /HKCU:\\Software\\Classes\\cogentspec-browser/);
  assert.doesNotMatch(installer, /HKLM|RunOnce|schtasks|Set-ExecutionPolicy|New-NetFirewall/);
});
test('Codex/Claude canonical and compatibility packages contain the same Qwen command, not divergent provider copies', async () => {
  const files = ['command.json', 'SKILL.md', 'scripts/install-qwenlocal.ps1', 'scripts/prepare-qwen-runtime.ps1', 'scripts/start-qwenlocal.ps1', 'scripts/qwen-runtime.mjs'];
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
  } finally { await fs.rm(fixture, { recursive: true, force: true }); }
});
test('all Windows command scripts parse without running registration, a handler or a model', { skip: process.platform !== 'win32' }, async () => {
  for (const relative of ['install-qwenlocal.ps1', 'prepare-qwen-runtime.ps1', 'start-qwenlocal.ps1']) {
    const scriptPath = path.join(root, 'scripts', relative).replaceAll("'", "''");
    const check = `$e=$null;$t=$null;[Management.Automation.Language.Parser]::ParseFile('${scriptPath}',[ref]$t,[ref]$e)|Out-Null;if($e){$e|ForEach-Object{$_.Message};exit 1}`;
    execFileSync('powershell.exe', ['-NoProfile', '-EncodedCommand', Buffer.from(check, 'utf16le').toString('base64')], { encoding: 'utf8', timeout: 20_000 });
  }
});
