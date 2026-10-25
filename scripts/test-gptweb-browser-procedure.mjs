import assert from 'node:assert/strict';
import test from 'node:test';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const baseline='2fe075a1b10e000a573cc0fbc808d9f3cbc2bf7f';
test('Web v1 changes no common helper, installer, manifest or other connector package',()=>{
 const changed=execFileSync('git',['diff','--name-only',baseline,'--','plugins/','claude-plugins/','.agents/','bridge-runtime/','bridge-gptweb-browser/','qwen-web-extension/'],{cwd:new URL('../',import.meta.url),encoding:'utf8',windowsHide:true}).trim().split('\n').filter(Boolean);
 const allowed=new Set(['plugins','claude-plugins'].flatMap(host=>['cogentspec','cogentstack'].flatMap(plugin=>{const command=host==='plugins'?'gptweb':'claudeweb';return [host+'/'+plugin+'/skills/'+command+'/SKILL.md',host+'/'+plugin+'/skills/'+command+'/scripts/start-'+command+'.ps1'];})));
 for(const file of changed)assert.ok(allowed.has(file),'Out-of-scope connector change: '+file);
});
test('Web v1 instructions require the actual local execution capability and exact request, without browser takeover',()=>{
 const text=readFileSync(new URL('../web-bridge/v1/PROCEDURE.md',import.meta.url),'utf8');
 assert.match(text,/local Windows execution tool/);assert.match(text,/UUID/);assert.match(text,/fresh acknowledgement/);
 assert.match(text,/does not use browser control/);assert.match(text,/does not install an AI plugin/);
});
