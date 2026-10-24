import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';

const root = new URL('../', import.meta.url);
const source = await readFile(new URL('plugins/cogentspec/skills/cogentspec/scripts/start-workspace-beacon.ps1', root), 'utf8');
const launcher = String.raw`
param($ContextKey,$Surface,$Experience,[switch]$ListenerOnly)
if (-not $ListenerOnly) { throw 'Window control must be disabled' }
$context = 'ctx-' + ('a'*64)
$base = "https://cogentspec.app/stack?surface=$Surface&context=$context&experience=$Experience"
if ($env:BEACON_CASE -eq 'wrong-provider') { $base = $base.Replace("surface=$Surface",'surface=desktop') }
if ($env:BEACON_CASE -eq 'wrong-origin') { $base = $base.Replace('cogentspec.app','attacker.invalid') }
$nav = '&nav=' + ('b'*32)
$web = $base + '&open=web' + $nav + '#desktop-web=cgw_' + ('c'*40)
$embedded = $base + '&open=chatgpt' + $nav + '#desktop-chatgpt=cgw_' + ('d'*40)
@{status='ready';contextKey=$context;contextIsolated=$true;presenceVerified=($env:BEACON_CASE -ne 'missing-worker');
  accountState='signed_in';defaultDirectoryReady=$true;projectDataConnection='authenticated_desktop_bridge';browserOpened=$false;
  webWorkspaceUrl=$web;chatgptWorkspaceUrl=$embedded} | ConvertTo-Json -Compress
`;

for (const [surface, experience] of [['chatgpt','web'],['chatgpt','popout'],['chatgpt','desktop-ui'],
  ['claude-desktop','web'],['claude-desktop','split-screen'],['claude-desktop','desktop-ui'],['qwen-web','web']]) {
  test(`${surface}/${experience}: installed command connects its existing listener and fails closed`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'workspace-beacon-'));
    const driver = join(directory, 'start-workspace-beacon.ps1');
    await mkdir(directory, { recursive: true });
    // Replace only the credential file location in this isolated test copy. No
    // real user credential, service request, worker or browser is used.
    await writeFile(driver, source.replace(/\$credentialPath = Join-Path[^\r\n]+/, '$credentialPath = Join-Path $PSScriptRoot "fixture-credential.json"'));
    await writeFile(join(directory, 'start-cogentstack-bridge.ps1'), launcher);
    const harness = join(directory, 'fixture.ps1');
    await writeFile(harness, String.raw`
Add-Type -AssemblyName System.Security
$bytes = [Text.Encoding]::UTF8.GetBytes('cga_fixture_private')
$protected = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
@{token=[Convert]::ToBase64String($protected)} | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'fixture-credential.json')
function Invoke-RestMethod {
  param($Method,$Uri,$TimeoutSec,$ContentType,$Headers,$Body)
  if ($Uri -cne 'https://cogentspec.com/api/device-authorization/workspace-reuse' -or $Method -ne 'Post' -or $Headers.Authorization -cne 'Bearer cga_fixture_private') { throw 'Unexpected authenticated request' }
  $binding=$Body | ConvertFrom-Json
  if ($binding.surface -cne $env:BEACON_SURFACE -or $binding.experience -cne $env:BEACON_EXPERIENCE) { throw 'Wrong destination' }
  @{protocol='cogentspec-workspace-reuse-v1';status=$(if($env:BEACON_CASE -eq 'missing-owner'){'owner_unavailable'}else{'reused'});
    contextKey=$binding.contextKey;surface=$binding.surface;experience=$binding.experience;acknowledgementVerified=($env:BEACON_CASE -ne 'missing-owner')}
}
function Start-Process { throw 'Opening a window is forbidden' }
& (Join-Path $PSScriptRoot 'start-workspace-beacon.ps1') -Surface $env:BEACON_SURFACE -Experience $env:BEACON_EXPERIENCE
`);
    for (const scenario of ['connected','wrong-provider','wrong-origin','missing-worker','missing-owner']) {
      const result = spawnSync('powershell.exe', ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',harness], {
        encoding:'utf8', windowsHide:true, timeout:15000,
        env:{...process.env,BEACON_CASE:scenario,BEACON_SURFACE:surface,BEACON_EXPERIENCE:experience},
      });
      assert.equal(result.status,0,result.stderr);
      assert.doesNotMatch(result.stdout+result.stderr,/cgw_|cga_fixture_private|ctx-[a-f0-9]{64}|https:\/\/cogentspec.app/);
      const receipt = JSON.parse(result.stdout.trim());
      assert.equal(receipt.browserOpened,false);
      assert.equal(receipt.workspaceConnected,scenario==='connected',JSON.stringify(receipt));
      assert.equal(receipt.acknowledgementVerified,scenario==='connected');
    }
  });
}

test('canonical and compatibility hosts ship identical listener helpers and isolate Qwen Local', async () => {
  for(const host of ['plugins','claude-plugins']) for(const plugin of ['cogentspec','cogentstack']) {
    const base=`${host}/${plugin}/skills/`;
    assert.equal(await readFile(new URL(`${base}${plugin}/scripts/start-workspace-beacon.ps1`,root),'utf8'),source);
    const wrapper=await readFile(new URL(`${base}qwenweb/scripts/start-qwenweb.ps1`,root),'utf8');
    assert.match(wrapper,/-Surface qwen-web -Experience web/);
    assert.doesNotMatch(wrapper,/qwenlocal|Start-Process|http:\/\//);
  }
});
