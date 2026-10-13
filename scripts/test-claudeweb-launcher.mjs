import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,writeFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname,basename} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {runInNewContext} from 'node:vm';

const root=dirname(dirname(fileURLToPath(import.meta.url)));
const context='ctx-'+ 'a'.repeat(64);
const url=`https://cogentspec.app/stack?surface=claude-desktop&context=${context}&experience=web&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'C'.repeat(40)}`;
const ready=()=>({status:'ready',bridge:'already_running',workspaceUrl:url,webWorkspaceUrl:url,
  chatgptWorkspaceUrl:url.replace('open=web','open=chatgpt').replace('#desktop-web=','#desktop-chatgpt='),
  contextKey:context,contextIsolated:true,presenceVerified:true,defaultDirectoryReady:true,
  defaultDirectoryCreated:false,accountState:'signed_in',mcpState:'not_required',
  projectDataConnection:'authenticated_desktop_bridge',browserOpened:false});

test('Claude-only Web launcher validates and delivers one handoff, rejecting unsafe or unready contracts',async()=>{
  const fixture=await mkdtemp(join(tmpdir(),'cogentspec-claudeweb-test-'));
  try {
    for(const core of ['cogentspec','cogentstack']) {
      const scripts=join(fixture,core,'skills',core,'scripts');
      const commands=join(fixture,core,'skills','claudeweb','scripts');
      await mkdir(scripts,{recursive:true});await mkdir(commands,{recursive:true});
      await copyFile(join(root,'claude-plugins',core,'skills',core,'scripts','project-context.ps1'),join(scripts,'project-context.ps1'));
      const command=join(commands,'start-claudeweb.ps1');
      await copyFile(join(root,'claude-plugins',core,'skills','claudeweb','scripts','start-claudeweb.ps1'),command);
      await writeFile(join(scripts,'start-cogentstack-bridge.ps1'),`param([string]$ContextKey,[string]$Surface,[string]$Experience)
if ($Surface -cne 'claude-desktop' -or $Experience -cne 'web') {throw 'Wrong Claude destination'}
[Environment]::GetEnvironmentVariable('COGENTSPEC_CLAUDE_WEB_FIXTURE_RESULT') | Write-Output
`, 'utf8');
      const invoke=(result,requestedContext=context)=>{
        const code=`& '${command.replaceAll("'","''")}' -ContextKey '${requestedContext}'`;
        const run=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(code,'utf16le').toString('base64')],{
          encoding:'utf8',timeout:15000,cwd:fixture,env:{...process.env,COGENTSPEC_CLAUDE_WEB_FIXTURE_RESULT:JSON.stringify(result)}});
        assert.equal(run.status,0,run.stderr);
        return JSON.parse(run.stdout.trim().replace(/^\uFEFF/,''));
      };
      for(const bridge of ['already_running','started']) {
        const result=invoke({...ready(),bridge});
        assert.equal(result.status,'ready');
        assert.equal(result.browserNavigationProtocol,'cogentspec-claudeweb-navigation-v1');
        assert.equal(result.workspaceUrl,url);
        assert.equal(result.defaultDirectoryReady,true);
        assert.equal(result.webWorkspaceUrl,undefined,'expose only one destination');
        assert.equal(result.chatgptWorkspaceUrl,undefined,'never expose Desktop destination');
        let calls=0;
        await runInNewContext('(async()=>{'+result.browserNavigationCode+'})()',{
          claudeWebTab:{async goto(actual){calls++;assert.equal(actual,url);}},
          gptWebTab:{goto(){assert.fail('never use GPT tab handle');}},
        },{timeout:1000});
        assert.equal(calls,1);
      }
      const invalidUrls=[
        url.replace('surface=claude-desktop','surface=chatgpt'),
        url.replace('cogentspec.app','example.test'),
        url.replace('experience=web','experience=desktop-ui'),
        url.replace('#desktop-web=','#desktop='),
        url.replace(context,'ctx-'+ 'd'.repeat(64)),
        url.replace('&open=web','&surface=claude-desktop&open=web'),
        url.replace('https://','http://'),
        url.replace('https://','https://user@'),
        url.replace('cogentspec.app/','cogentspec.app:8443/'),
      ];
      for(const invalid of invalidUrls) {
        const result=invoke({...ready(),workspaceUrl:invalid,webWorkspaceUrl:invalid});
        assert.equal(result.status,'invalid_workspace_handoff');
        assert.equal(result.workspaceUrl,undefined);
        assert.equal(result.browserNavigationCode,undefined);
      }
      for(const patch of [{presenceVerified:false},{defaultDirectoryReady:false},{contextIsolated:false},
        {accountState:'signed_out'},{mcpState:'ready'},{browserOpened:true},{projectDataConnection:'codex_mcp'}]) {
        assert.equal(invoke({...ready(),...patch}).status,'invalid_workspace_handoff');
      }
      const failure=invoke({status:'default_directory_unavailable',userMessage:'The default projects folder is not writable.'});
      assert.equal(failure.status,'default_directory_unavailable');
      assert.equal(failure.userMessage,'The default projects folder is not writable.');
      assert.equal(failure.workspaceUrl,undefined);
      assert.equal(invoke(ready(),'default').status,'unscoped_context');
    }
  } finally {
    assert.equal(await realpath(fixture),resolve(fixture));
    assert.equal(dirname(fixture),resolve(tmpdir()));
    assert.ok(basename(fixture).startsWith('cogentspec-claudeweb-test-'));
    await rm(fixture,{recursive:true,force:true});
  }
});
