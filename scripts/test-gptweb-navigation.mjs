import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('gptweb dispatches only its existing owning listener; shared handshake cases cover unsafe handoffs',async()=>{
  for(const plugin of ['cogentspec','cogentstack']) {
    const root=new URL('../plugins/'+plugin+'/skills/gptweb/',import.meta.url);
    const skill=await readFile(new URL('SKILL.md',root),'utf8');
    const script=await readFile(new URL('scripts/start-gptweb.ps1',root),'utf8');
    assert.ok(skill.includes('acknowledgementVerified: true'));
    assert.ok(skill.includes('browserOpened: false'));
    assert.ok(skill.includes('Initiate Bridge'));
    assert.match(script,/-Surface chatgpt -Experience web/);
    assert.doesNotMatch(script,/goto\(|Start-Process|open_in_codex|browserNavigationCode/);
  }
});
