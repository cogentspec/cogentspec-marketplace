import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('gptweb verifies separately prepared setup while its legacy launcher stays isolated',async()=>{
 for(const plugin of ['cogentspec','cogentstack']) {
  const root=new URL('../plugins/'+plugin+'/skills/gptweb/',import.meta.url);
  const skill=await readFile(new URL('SKILL.md',root),'utf8');
  const script=await readFile(new URL('scripts/start-gptweb.ps1',root),'utf8');
  assert.ok(skill.includes('gptweb-setup/v1/PROCEDURE.md'));
  assert.match(script,/ManifestSha256/);assert.match(script,/Get-FileHash/);
  assert.ok(script.includes("-Command '$gptweb'"));
  assert.doesNotMatch(script,/start-cogentstack-bridge|browserNavigationCode|start-workspace-beacon|Start-Process|open_in_codex/);
 }
});
