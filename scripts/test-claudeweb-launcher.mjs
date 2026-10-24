import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('claudeweb dispatches only its existing owning listener; shared handshake cases cover unsafe handoffs',async()=>{
  for(const plugin of ['cogentspec','cogentstack']) {
    const root=new URL('../claude-plugins/'+plugin+'/skills/claudeweb/',import.meta.url);
    const skill=await readFile(new URL('SKILL.md',root),'utf8');
    const script=await readFile(new URL('scripts/start-claudeweb.ps1',root),'utf8');
    assert.ok(skill.includes('acknowledgementVerified: true'));
    assert.ok(skill.includes('browserOpened: false'));
    assert.ok(skill.includes('Initiate Bridge'));
    assert.match(script,/-Surface claude-desktop -Experience web/);
    assert.doesNotMatch(script,/goto\(|Start-Process|open_in_codex|browserNavigationCode/);
  }
});
