import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('claudeweb installs only the verified Web runtime for the copied request',async()=>{
 for(const plugin of ['cogentspec','cogentstack']) {
  const root=new URL('../claude-plugins/'+plugin+'/skills/claudeweb/',import.meta.url);
  const skill=await readFile(new URL('SKILL.md',root),'utf8');
  const script=await readFile(new URL('scripts/start-claudeweb.ps1',root),'utf8');
  assert.ok(skill.includes('web-bridge/v1/PROCEDURE.md'));
  assert.match(script,/ManifestSha256/);assert.match(script,/Get-FileHash/);
  assert.ok(script.includes("-Command '$claudeweb'"));
  assert.doesNotMatch(script,/start-cogentstack-bridge|browserNavigationCode|start-workspace-beacon|Start-Process|open_in_codex/);
 }
});
