import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,existsSync,rmSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname,resolve} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'..'),scripts=join(root,'plugins/cogentspec/skills/cogentspec/scripts');
test('actual ERP PowerShell launcher sends a credential object over private stdin to the customer worker',{skip:process.platform!=='win32',timeout:30000},()=>{
 const temp=mkdtempSync(join(tmpdir(),'cogent-customer-launch-'));
 try{
  const manager=join(temp,'CogentSpec/bridge-manager/v1'),version='0123456789abcdef01234567',directory=join(manager,'packages',version),marker=join(temp,'claim-verified.json');mkdirSync(directory,{recursive:true});
  const hashes={};for(const name of ['erp-customer-worker.mjs','erp-customer-runtime.mjs']){const bytes=readFileSync(join(scripts,name));writeFileSync(join(directory,name),bytes);hashes[name]=createHash('sha256').update(bytes).digest('hex');}
  writeFileSync(join(manager,'current.json'),JSON.stringify({version,hashes}));
  const token='synthetic-'+randomUUID(),preload='data:text/javascript,'+encodeURIComponent(`import{writeFileSync}from'node:fs';globalThis.fetch=async(url,options)=>{if(url!=='https://cogentspec.com/api/plugin/erp-customer-releases'||options.headers.authorization!==${JSON.stringify('Bearer '+token)})throw Error('Credential wire format is invalid');if(process.argv.some(v=>v.includes(${JSON.stringify(token)})))throw Error('Credential appeared in argv');if(JSON.parse(options.body).action!=='claim')throw Error('Unexpected operation');writeFileSync(${JSON.stringify(marker)},JSON.stringify({credentialObjectReceived:true,privateStdin:true}));return Response.json({job:null});};`);
  const source=readFileSync(join(scripts,'erp-worker.ps1'),'utf8'),start=source.indexOf('                $node = (Get-Command node.exe'),end=source.indexOf('                } finally { $process.Dispose() }',start);
  assert.ok(start>0&&end>start);const block=source.slice(start,end+'                } finally { $process.Dispose() }'.length);
  const entry=join(directory,'launcher-fixture.ps1');writeFileSync(entry,`$ErrorActionPreference='Stop'\n$token='${token}'\n${block}\n`);
  const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',entry],{encoding:'utf8',windowsHide:true,timeout:25000,env:{...process.env,LOCALAPPDATA:temp,NODE_OPTIONS:'--import='+preload}});
  assert.equal(result.status,0,result.stderr);assert.doesNotMatch(result.stdout+result.stderr,new RegExp(token));assert.ok(existsSync(marker),'Actual wrapper never delivered a valid credential object');assert.deepEqual(JSON.parse(readFileSync(marker,'utf8')),{credentialObjectReceived:true,privateStdin:true});
 }finally{assert.equal(dirname(realpathSync(temp)).toLowerCase(),realpathSync(tmpdir()).toLowerCase());rmSync(temp,{recursive:true});}
});
