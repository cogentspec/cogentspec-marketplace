import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('claudeweb restores its provider-specific marketplace Web handoff',async()=>{
  for(const plugin of ['cogentspec','cogentstack']) {
    const root=new URL('../claude-plugins/'+plugin+'/skills/claudeweb/',import.meta.url);
    const skill=await readFile(new URL('SKILL.md',root),'utf8');
    const script=await readFile(new URL('scripts/start-claudeweb.ps1',root),'utf8');
    assert.ok(skill.includes('status: ready'));
    assert.ok(skill.includes('My projects'));
    assert.ok(skill.includes('browserNavigationCode'));
    assert.match(script,/-Surface claude-desktop -Experience web/);
    assert.match(script,/browserNavigationCode/);
    assert.doesNotMatch(script,/start-workspace-beacon|ListenerOnly|Start-Process|open_in_codex/);
  }
});
