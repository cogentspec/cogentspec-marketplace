import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('GPTWeb browser instructions are self-contained, work without a Windows executor, and match both packages',async()=>{
 const read=plugin=>readFile(new URL(`../plugins/${plugin}/skills/gptweb/SKILL.md`,import.meta.url),'utf8');
 const procedure=await read('cogentspec');assert.equal(await read('cogentstack'),procedure);
 const steps=procedure.split('\n').filter(line=>/^\d\. /.test(line));
 assert.equal(steps.length,6);
 assert.match(steps[0],/browser tools/);assert.match(steps[0],/wait/);
 assert.match(steps[1],/existing/);assert.match(steps[2],/Initiate Bridge/);
 assert.match(steps[3],/Ask the user to confirm/);assert.match(steps[3],/Only after confirmation/);
 assert.match(steps[4],/Bridge connected/);assert.match(steps[4],/My projects/);
 assert.doesNotMatch(steps.join('\n'),/Invoke.*ps1|sole GPTWeb entry point|start-gptweb\.ps1/);
 assert.match(procedure,/only its browser tools are required/);assert.match(procedure,/must already be running/);
 assert.match(procedure,/do not load a generic connection skill/);
 assert.match(procedure,/No ChatGPT plugin, skill installation, PowerShell execution or waiting listener is required/);
});
