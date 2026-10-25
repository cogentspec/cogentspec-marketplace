import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const tuesday='8a8011d5d48f53636bf5dabe7d4a5a07ad0f9710';
const git=(...args)=>execFileSync('git',args,{cwd:root,windowsHide:true,encoding:'utf8'});
const normalize=value=>value.replaceAll('\r\n','\n');

test('GPTWeb and ClaudeWeb restore Tuesday instructions and retain their exact launchers in both packages',async()=>{
 for(const [host,command] of [['plugins','gptweb'],['claude-plugins','claudeweb']]) {
  for(const plugin of ['cogentspec','cogentstack']) {
   for(const relative of ['SKILL.md',`scripts/start-${command}.ps1`]) {
    const path=`${host}/${plugin}/skills/${command}/${relative}`;
    assert.equal(normalize(await readFile(new URL('../'+path,import.meta.url),'utf8')),normalize(git('show',tuesday+':'+path)),path);
   }
  }
 }
});

test('the restore cannot edit Qwen, Snap, Desk, shared runtime, manifests or installer behavior',()=>{
 const allowed=new Set([
  ...['cogentspec','cogentstack'].flatMap(plugin=>[
   `plugins/${plugin}/skills/gptweb/SKILL.md`,
   `claude-plugins/${plugin}/skills/claudeweb/SKILL.md`,
  ]),
  'scripts/test-gptweb-navigation.mjs','scripts/test-claudeweb-launcher.mjs',
  'scripts/test-gptweb-browser-procedure.mjs','scripts/test-gptweb-browser-handler.mjs',
 ]);
 const changed=git('diff','--name-only','5366ee2a8fbd704f2630b8196085f4234b5b69f5').trim().split('\n').filter(Boolean);
 for(const path of changed)assert.ok(allowed.has(path),'Out-of-scope marketplace change: '+path);
});
