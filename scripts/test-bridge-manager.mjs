import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, readFileSync, rmSync, realpathSync } from 'node:fs';
import { join, resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
const root=resolve(import.meta.dirname,'..');
const source=path=>readFileSync(join(root,path),'utf8').replaceAll('\r\n','\n');
const core='plugins/cogentspec/skills/cogentspec/scripts/bridge-manager-core.ps1';
test('all four provider packages ship identical shared manager code',()=>{
 for(const file of ['bridge-manager.ps1','bridge-manager-core.ps1'])for(const base of [
  'plugins/cogentstack/skills/cogentstack/scripts','claude-plugins/cogentspec/skills/cogentspec/scripts','claude-plugins/cogentstack/skills/cogentstack/scripts']){
   assert.equal(source(base+'/'+file),source('plugins/cogentspec/skills/cogentspec/scripts/'+file));
 }
});
test('native model rejects changed runtimes and PID reuse; cancellation fences worker recovery',{skip:process.platform!=='win32'},()=>{
 const folder=mkdtempSync(join(tmpdir(),'cogentspec-manager-test-'));
 try{
  const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(root,'scripts/test-bridge-manager-core.ps1'),'-CorePath',join(root,core),'-TestRoot',folder],
   {encoding:'utf8',timeout:30000,windowsHide:true});
  assert.equal(result.status,0,result.stderr);const report=JSON.parse(result.stdout.trim());assert.equal(report.status,'passed');assert.ok(report.checks>=15);assert.equal(report.realWorkersStarted,false);
 }finally{
  const actual=realpathSync(folder),parent=realpathSync(tmpdir());
  assert.equal(dirname(actual).toLowerCase(),parent.toLowerCase());assert.match(basename(actual),/^cogentspec-manager-test-[a-zA-Z0-9]+$/);
  rmSync(actual,{recursive:true});
 }
});
test('native manager parses under Windows PowerShell and the URI cannot select an executable or context',{skip:process.platform!=='win32'},()=>{
 for(const file of ['bridge-manager-core.ps1','bridge-manager.ps1']){
  const p=join(root,'plugins/cogentspec/skills/cogentspec/scripts',file).replaceAll("'","''");
  const command=`$tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('${p}',[ref]$tokens,[ref]$errors);if($errors.Count){$errors|ForEach-Object{$_.Message};exit 1}`;
  const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],{encoding:'utf8',windowsHide:true,timeout:15000});assert.equal(result.status,0,result.stdout+result.stderr);
 }
 const manager=source('plugins/cogentspec/skills/cogentspec/scripts/bridge-manager.ps1');
 assert.match(manager,/cogentspec-bridge:\/\//);assert.match(manager,/RestartCount 3/);assert.match(manager,/RunLevel Limited/);assert.match(manager,/CurrentUser|GetCurrent/);
 assert.doesNotMatch(manager,/Invoke-Expression|iex |Start-Process\s+\$Uri/);
});
