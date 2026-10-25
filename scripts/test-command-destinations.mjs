import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { runInNewContext } from 'node:vm';

const repository=fileURLToPath(new URL('../',import.meta.url));
const context='ctx-'+'a'.repeat(64);
const cases=[
 ['plugins','gptdesk','chatgpt','desktop-ui',false],
 ['claude-plugins','claudedesk','claude-desktop','desktop-ui',false],
 ['claude-plugins','claudesnap','claude-desktop','split-screen',false],
 ['claude-plugins','claudeweb','claude-desktop','web',true],
 ['plugins','qwenweb','qwen-web','web',true],
];
for(const [host,command,surface,experience,web] of cases)for(const plugin of ['cogentspec','cogentstack']){
 test(`${plugin}/${command} executes only its exact provider/type entrypoint with no browser opened`,async()=>{
  const root=mkdtempSync(join(tmpdir(),'bridge-destination-fixture-'));
  try{
   const core=join(root,'skills',plugin,'scripts'),entry=join(root,'skills',command,'scripts',`start-${command}.ps1`);
   mkdirSync(core,{recursive:true});mkdirSync(dirname(entry),{recursive:true});
   writeFileSync(entry,readFileSync(join(repository,host,plugin,'skills',command,'scripts',`start-${command}.ps1`)));
   writeFileSync(join(core,'project-context.ps1'),`function Get-CogentSpecProjectContext { param([string]$ExplicitContextKey) return [pscustomobject]@{ ContextKey='${context}'; Isolated=$true } }\n`);
   const helper=web?'start-cogentstack-bridge.ps1':'start-workspace-beacon.ps1';
   writeFileSync(join(core,helper),web?`
param([string]$ContextKey,[string]$Surface,[string]$Experience)
$url='https://cogentspec.app/stack?surface='+$Surface+'&context='+$ContextKey+'&experience='+$Experience+'&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'c'.repeat(40)}'
@{status='ready';contextKey=$ContextKey;contextIsolated=$true;presenceVerified=$true;defaultDirectoryReady=$true;accountState='signed_in';projectDataConnection='authenticated_desktop_bridge';mcpState='not_required';browserOpened=$false;workspaceUrl=$url;webWorkspaceUrl=$url;chatgptWorkspaceUrl='https://invalid.example/';pluginId='${plugin}';pluginVersion='0.0.1';launcherElapsedMs=1}|ConvertTo-Json -Compress
`:`param([string]$ContextKey,[string]$Surface,[string]$Experience)
@{status='fixture';contextKey=$ContextKey;surface=$Surface;experience=$Experience;browserOpened=$false}|ConvertTo-Json -Compress\n`);
   const run=spawnSync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',entry,'-ContextKey',context],{cwd:root,encoding:'utf8',windowsHide:true,timeout:20_000});
   assert.equal(run.status,0,run.stderr);const value=JSON.parse(run.stdout.trim());
   assert.equal(value.contextKey,context);assert.equal(value.browserOpened,false);
   if(web){
    assert.equal(value.status,'ready');assert.equal(value.browserNavigationProtocol,`cogentspec-${command}-navigation-v1`);
    const target=new URL(value.workspaceUrl);assert.equal(target.searchParams.get('surface'),surface);assert.equal(target.searchParams.get('experience'),experience);
    const calls=[];const browser=command==='qwenweb'?'qwenWebTab':'claudeWebTab';
    await runInNewContext('(async()=>{'+value.browserNavigationCode+'})()',{[browser]:{goto:target=>calls.push(target)}},{timeout:1000});
    assert.deepEqual(calls,[value.workspaceUrl]);
   }else{assert.equal(value.surface,surface);assert.equal(value.experience,experience);}
  }finally{
   assert.equal(dirname(resolve(root)),resolve(tmpdir()));assert.ok(basename(root).startsWith('bridge-destination-fixture-'));
   rmSync(root,{recursive:true,force:true});
  }
 });
}
