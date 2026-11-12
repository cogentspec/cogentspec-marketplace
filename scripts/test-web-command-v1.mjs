import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url)),directory=join(root,'web-bridge/v1');
const manifest=JSON.parse(readFileSync(join(directory,'manifest.json'),'utf8'));
test('Web v1 pins its complete independent runtime and exactly two consumers',()=>{
  assert.equal(manifest.protocol,'cogentspec-web-runtime-v1');
  assert.deepEqual(manifest.commands,['$gptweb','$claudeweb']);
  assert.deepEqual(Object.keys(manifest.files).sort(),readdirSync(join(directory,'runtime')).map(v=>'runtime/'+v).sort());
  for(const [file,digest] of Object.entries(manifest.files))assert.equal(createHash('sha256').update(readFileSync(join(directory,file))).digest('hex'),digest,file);
  const start=readFileSync(join(directory,'runtime/start-web-worker.ps1'),'utf8');
  assert.match(start,/web-command-v1\\workers/);assert.match(start,/ShowWindow=\[UInt16\]0/);
  assert.doesNotMatch(start,/Stop-Process[\s\S]*?CogentSpec\\bridge/);
  const worker=readFileSync(join(directory,'runtime/watch-web-worker.ps1'),'utf8');
  assert.match(worker,/CogentSpecWebV1-\$WebCommand/);
  const dispatch=worker.slice(worker.indexOf('$scriptName = switch'),worker.indexOf('$scriptName = switch')+1100);
  assert.doesNotMatch(dispatch,/'(?:open_chatgpt_popup|set_chatgpt_popup_topmost|set_chatgpt_desktop_topmost|set_claude_desktop_topmost)'/);
});
test('versioned common worker helpers preserve the snapshot and exact reviewed credential environment patch',()=>{
  // Account-level manager/ERP additions are separately hashed and tested for
  // shared-package parity; the original Web connection snapshot stays frozen.
  for(const name of readdirSync(join(directory,'runtime')).filter(v=>!['connect-web.ps1','start-web-worker.ps1','watch-web-worker.ps1','bridge-manager.ps1','bridge-manager-core.ps1','erp-worker.ps1','erp-installation-worker.ps1','erp-docker-setup.ps1','install-erp-project.mjs','erp-customer-runtime.mjs','erp-customer-worker.mjs','erp-customer-release.ps1','erp-delete-project.ps1','remove-erp-project.mjs'].includes(v))){
    let original=execFileSync('git',['show',manifest.sourceSnapshot+':plugins/cogentspec/skills/cogentspec/scripts/'+name],{cwd:root,encoding:'utf8',windowsHide:true}).replaceAll('\r\n','\n');
    if(name==='provision-project-credentials.mjs'){
      // Only this reviewed environment repair may differ. Every other byte,
      // including account, manifest, adapter and credential guards, stays frozen.
      assert.equal(manifest.credentialEnvironmentPatch,'windows-compose-system-paths-v1');
      const marker='// No passwords in argv, environment, files, logs or output.';
      const helper=`// Docker discovers its Windows Compose plugin beneath Program Files. Preserve
// those system paths without passing application secrets to project adapters.
export function credentialAdapterEnvironment(environment = process.env) {
  const allowed = new Set(['path','systemroot','temp','tmp','home','userprofile','programfiles','programw6432']);
  return Object.fromEntries(Object.entries(environment).filter(([key]) => allowed.has(key.toLowerCase())));
}

`;
      const prior="env: Object.fromEntries(Object.entries(process.env).filter(([key]) => ['PATH','Path','SystemRoot','SYSTEMROOT','TEMP','TMP','HOME','USERPROFILE'].includes(key))),";
      assert.equal(original.split(marker).length,2);assert.equal(original.split(prior).length,2);
      original=original.replace(marker,helper+marker).replace(prior,'env: credentialAdapterEnvironment(),');
    }
    assert.equal(readFileSync(join(directory,'runtime',name),'utf8').replaceAll('\r\n','\n'),original,name);
  }
});
test('all shipped Web PowerShell scripts parse and a missing request never prompts', {skip:process.platform!=='win32'},()=>{
  const ps=join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe');
  for(const command of ['gptweb','claudeweb']){
    const host=command==='gptweb'?'plugins':'claude-plugins';
    const result=spawnSync(ps,['-NoProfile','-NonInteractive','-File',join(root,host,'cogentspec/skills',command,'scripts/start-'+command+'.ps1')],
      {windowsHide:true,encoding:'utf8',timeout:10000});
    assert.equal(result.status,0,result.stderr);const response=JSON.parse(result.stdout.trim());
    assert.equal(response.status,'not_connected');assert.equal(response.browserControlled,false);assert.equal(response.workspaceConnected,false);
  }
  const source=`$errors=@(); Get-ChildItem -LiteralPath '${directory.replaceAll("'","''")}' -Recurse -Filter *.ps1 | ForEach-Object { $tokens=$null; $parse=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parse); $errors += $parse }; if($errors.Count){$errors|ForEach-Object{$_.Message};exit 1}`;
  const parsed=spawnSync(ps,['-NoProfile','-NonInteractive','-Command',source],{windowsHide:true,encoding:'utf8',timeout:15000});
  assert.equal(parsed.status,0,parsed.stdout+parsed.stderr);
});
