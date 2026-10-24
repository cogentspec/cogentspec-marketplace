import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('gptweb restores the marketplace launcher and browser handoff without a listener prerequisite',async()=>{
  for(const plugin of ['cogentspec','cogentstack']) {
    const root=new URL('../plugins/'+plugin+'/skills/gptweb/',import.meta.url);
    const skill=await readFile(new URL('SKILL.md',root),'utf8');
    const script=await readFile(new URL('scripts/start-gptweb.ps1',root),'utf8');
    assert.ok(skill.includes('status: ready'));
    assert.ok(skill.includes('browserOpened: false'));
    assert.ok(skill.includes('browserNavigationCode'));
    assert.match(script,/-Surface chatgpt -Experience web/);
    assert.match(script,/browserNavigationCode/);
    assert.doesNotMatch(script,/start-workspace-beacon|ListenerOnly|Start-Process|open_in_codex/);
  }
});
