import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile,readdir,mkdtemp,cp,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync,execFileSync} from 'node:child_process';
const root=fileURLToPath(new URL('../bridge-gptweb-browser/',import.meta.url));
const files=async directory=>{const result=[];for(const entry of await readdir(directory,{withFileTypes:true})){
 const file=join(directory,entry.name);if(entry.isDirectory())result.push(...await files(file));else result.push(file);}return result;};
test('GPTWeb inventory pins every input and its frozen runtime; other connector files are unchanged',async()=>{
 const lines=(await readFile(join(root,'files.sha256'),'utf8')).trim().split('\n');
 const actual=(await files(root)).filter(file=>!file.endsWith('files.sha256')).map(file=>file.slice(root.length).replaceAll('\\','/')).sort();
 const declared=[];
 for(const line of lines){assert.match(line,/^[a-f0-9]{64}  [a-zA-Z0-9_./-]+$/);const relative=line.slice(66);declared.push(relative);
  assert.equal(createHash('sha256').update(await readFile(join(root,relative))).digest('hex'),line.slice(0,64),relative);}
 assert.deepEqual(declared.sort(),actual);
 const privateCore=await readFile(join(root,'runtime/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'),'utf8');
 const original=execFileSync('git',['show','e29ee568d816f7d4afb1b1436035e8b8783556d5:plugins/cogentspec/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'],{encoding:'utf8',windowsHide:true});
 const normalize=value=>value.replaceAll('\r\n','\n');
 assert.equal(normalize(privateCore).replace("$localStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\\gptweb-browser'",
  "$localStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'"),normalize(original));
 const account=await readFile(join(root,'runtime/skills/cogentspec/scripts/connect-cogentstack.ps1'),'utf8');
 assert.doesNotMatch(account,/Remove-Item|Set-Content|WriteAll|renewalToken|\/renew|\$gptsnap|\$gptdesk/);
 const connect=await readFile(join(root,'connect.ps1'),'utf8');
 assert.ok(connect.indexOf("'authorize' -Authenticated")<connect.indexOf('(& $launcher'));
 assert.match(connect,/workspaceConnected -cne \$false/);
 const changed=execFileSync('git',['diff','--name-status','e29ee568d816f7d4afb1b1436035e8b8783556d5'],{encoding:'utf8',windowsHide:true}).trim().split('\n').filter(Boolean);
 for(const line of changed){const [status,path]=line.split('\t');assert.equal(status,'A','Existing marketplace source must be unchanged');
  assert.ok(path.startsWith('bridge-gptweb-browser/')||path==='scripts/test-gptweb-browser-handler.mjs',path);}
});

test('Windows handler accepts only a GPTWeb request UUID and setup rejects altered source', {skip:process.platform!=='win32'},async()=>{
 const directory=await mkdtemp(join(tmpdir(),'gptweb-handler-contract-'));
 const executable=join(directory,'handler.exe'),compiler=join(process.env.WINDIR,'Microsoft.NET/Framework64/v4.0.30319/csc.exe');
 const compiled=spawnSync(compiler,['/nologo','/target:winexe','/out:'+executable,join(root,'GptWebBrowserHost.cs')],{windowsHide:true,encoding:'utf8'});
 assert.equal(compiled.status,0,compiled.stdout+compiled.stderr);
 const id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
 for(const [uri,expected] of [
  ['cogentspec-gptweb://connect?request='+id,0],['cogentspec-gptweb://connect/?request='+id,0],
  ['cogentspec://connect?request='+id,64],['cogentspec-gptweb://other?request='+id,64],
  ['cogentspec-gptweb://connect?request='+id+'&command=powershell',64],
  ['cogentspec-gptweb://connect:123?request='+id,64],['cogentspec-gptweb://user@connect?request='+id,64],
  ['cogentspec-gptweb://connect?request='+id+'#fragment',64],['cogentspec-gptweb://connect?request=bad',64],
  ['cogentspec-gptweb://connect?request='+id+'%22',64]])
  assert.equal(spawnSync(executable,['--check-uri',uri],{windowsHide:true}).status,expected,uri);
 const copy=join(directory,'artifact');await cp(root,copy,{recursive:true});
 const ps=join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe');
 const check=()=>spawnSync(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(copy,'install.ps1'),'-CheckOnly'],
  {windowsHide:true,encoding:'utf8',timeout:15000,env:{...process.env,PSModulePath:join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/Modules')}});
 const verified=check();assert.equal(verified.status,0,verified.stderr||verified.stdout);
 await writeFile(join(copy,'connect.ps1'),'throw "Altered fixture"');
 const rejected=check();assert.notEqual(rejected.status,0);assert.match(rejected.stderr,/source integrity check failed/);
 assert.equal(resolve(directory).startsWith(resolve(tmpdir())),true);
});
