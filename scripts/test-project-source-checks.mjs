import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=new URL('../',import.meta.url),canonical=new URL('plugins/cogentspec/skills/cogentspec/scripts/',root);
const {fingerprintProjectSource,projectSourceFingerprintProgram}=await import(new URL('project-source-fingerprint.mjs',canonical));
test('all native source workers share their trusted fingerprint without changing startup or destination dispatch',async()=>{
 for(const host of ['plugins','claude-plugins'])for(const plugin of ['cogentspec','cogentstack']){
  const folder=new URL(`${host}/${plugin}/skills/${plugin}/scripts/`,root);
  for(const file of ['project-source-worker.ps1','project-source-fingerprint.mjs','project-review.ps1'])assert.equal((await readFile(new URL(file,folder),'utf8')).replaceAll('\r\n','\n'),(await readFile(new URL(file,canonical),'utf8')).replaceAll('\r\n','\n'));
  const worker=await readFile(new URL('watch-cogentstack-bridge.ps1',folder),'utf8'),start=await readFile(new URL('start-cogentstack-bridge.ps1',folder),'utf8');
  assert.match(worker,/Invoke-ProjectSourceChecks -Token \$token/);assert.match(worker,/\[string\]\$ReadyPath/);
  assert.match(start,/'project-source-worker.ps1'/);assert.match(start,/'project-source-fingerprint.mjs'/);
  const runtime=await readFile(new URL(`${host}/${plugin}/skills/qwenlocal/scripts/qwen-runtime.mjs`,root),'utf8');assert.ok(runtime.replaceAll('\r\n','\n').includes(projectSourceFingerprintProgram.replaceAll('\r\n','\n')));assert.match(runtime,/request.url === '\/source-check'/);
 }
});
test('native source helper checks real uncommitted files, rejects a different project and ignores generated identity',async t=>{
 const folder=await mkdtemp(join(tmpdir(),'coge-native-source-'));t.after(()=>rm(folder,{recursive:true,force:true}));
 await mkdir(join(folder,'.coge'));await writeFile(join(folder,'.coge','knowledge-manifest.json'),JSON.stringify({project:{requestId:'synthetic-project'}}));
 await writeFile(join(folder,'index.html'),'reviewed');const passed=await fingerprintProjectSource(folder);assert.equal(passed.files,1);
 const helper=new URL('project-source-fingerprint.mjs',canonical);
 const run=id=>spawnSync(process.execPath,[fileURLToPath(helper)],{input:JSON.stringify({targetPath:folder,projectId:id}),encoding:'utf8',windowsHide:true});
 const result=run('synthetic-project');assert.equal(result.status,0,result.stderr);assert.deepEqual(JSON.parse(result.stdout),passed);
 await writeFile(join(folder,'index.html'),'uncommitted edit');assert.notEqual(JSON.parse(run('synthetic-project').stdout).sourceDigest,passed.sourceDigest);
 assert.equal(run('other-project').status,1);
});
