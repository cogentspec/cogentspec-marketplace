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
test('versioned common worker helpers remain the reviewed immutable snapshot',()=>{
  for(const name of readdirSync(join(directory,'runtime')).filter(v=>!['connect-web.ps1','start-web-worker.ps1','watch-web-worker.ps1'].includes(v))){
    const original=execFileSync('git',['show',manifest.sourceSnapshot+':plugins/cogentspec/skills/cogentspec/scripts/'+name],{cwd:root,encoding:'utf8',windowsHide:true});
    assert.equal(readFileSync(join(directory,'runtime',name),'utf8').replaceAll('\r\n','\n'),original.replaceAll('\r\n','\n'),name);
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
