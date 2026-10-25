import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';

test('GPTWeb restores the Wednesday marketplace launcher and handoff without a listener',async()=>{
 const read=plugin=>readFile(new URL(`../plugins/${plugin}/skills/gptweb/SKILL.md`,import.meta.url),'utf8');
 const procedure=await read('cogentspec');assert.equal(await read('cogentstack'),procedure);
 const steps=procedure.split('\n').filter(line=>/^\d\. /.test(line));
 assert.equal(steps.length,5);
 assert.match(steps[0],/start-gptweb\.ps1.*exactly once/);
 assert.match(steps[1],/authenticated_desktop_bridge/);
 assert.match(steps[2],/browserNavigationCode.*verbatim/);
 assert.match(steps[3],/Bridge connected.*My projects/);
 assert.match(procedure,/self-contained browser procedure plus a Windows launcher/);
 assert.match(procedure,/browser access alone cannot run the launcher/);
 assert.match(procedure,/host's actual execution permission/);
 assert.match(procedure,/No ChatGPT plugin is required/);
 assert.match(procedure,/copy button only copies/);
 assert.match(procedure,/Do not use another command's listener, Initiate Bridge/);
 assert.match(procedure,/UpdateOnly -MarketplacePrepared/);
 assert.equal(await readFile(new URL('../bridge/types/web/gpt/procedure.md',import.meta.url),'utf8'),procedure);
 for(const plugin of ['cogentspec','cogentstack']) {
  const path=`plugins/${plugin}/skills/gptweb/scripts/start-gptweb.ps1`;
  // Canonical text hashes from 8a8011d, so shallow CI checkouts can verify
  // exact restoration without downloading historical code during a test.
  const expected=plugin==='cogentspec'?'9bda24127e7681b67d73a0e1c77f598c281548ac60989542b34f4b58de9a67fb':'f935828116e3156086b21bdef7a6e8bd31e6ee6f9cf92045556821a03208afd6';
  const source=(await readFile(new URL('../'+path,import.meta.url),'utf8')).replaceAll('\r\n','\n');
  assert.equal(createHash('sha256').update(source).digest('hex'),expected);
 }
});

// Execute the shipped PowerShell launcher, including rejection of invalid
// origins, contexts, destinations, stale workers and denied authorization.
await import('./test-web-handoff.mjs');
