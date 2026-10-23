import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const repository=resolve(import.meta.dirname,'..'),context='ctx-'+'a'.repeat(64);
const url=`https://cogentspec.app/stack?surface=chatgpt&context=${context}&experience=split-screen&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'c'.repeat(40)}`;
for(const plugin of ['cogentspec','cogentstack']) {
  for(const scenario of ['reused','owner_unavailable','owner_changed','busy','offline','wrong-context','unverified','open_required','unsafe-destination','approval','unsafe-approval','resume']) {
    const root=await mkdtemp(join(tmpdir(),'gptsnap existing workspace fixture '));
    try {
      const skill=join(root,'skills','gptsnap','scripts'),core=join(root,'skills',plugin,'scripts');
      await mkdir(skill,{recursive:true});await mkdir(core,{recursive:true});await mkdir(join(root,'.codex-plugin'));
      await writeFile(join(root,'.codex-plugin','plugin.json'),JSON.stringify({name:plugin,version:'0.6.169'}));
      const trace=join(root,'trace.txt'),quotedTrace=trace.replaceAll("'","''");
      const prefix=`Add-Content -LiteralPath '${quotedTrace}' -Value ([IO.Path]::GetFileName($PSCommandPath))\n`;
      for(const file of ['start-gptsnap.ps1','gptsnap-client.mjs']) {
        let source=await readFile(join(repository,'plugins',plugin,'skills','gptsnap','scripts',file),'utf8');
        if(file==='start-gptsnap.ps1') {
          assert.ok(!/Open-GptSnapBrowser|UseShellExecute\s*=\s*\$true|Start-Process/.test(source),'No OS browser-opening boundary is permitted');
          source=source.replace('function Request-GptSnapReuse(','function FixtureUnusedReuse(');
          source=source.replace('function Value(',`function Request-GptSnapReuse([string]$Code,[string]$Context) {
            Add-Content -LiteralPath '${quotedTrace}' -Value 'workspace-reuse'
            if ($Code -cne 'cgw_${'c'.repeat(40)}' -or $Context -cne '${context}') { throw 'Wrong reuse binding' }
            ${scenario==='offline'?"throw 'Offline'":''}
            return ('${JSON.stringify({protocol:'cogentspec-workspace-reuse-v1',
              status:['reused','resume','unverified'].includes(scenario)?'reused':scenario,
              contextKey:scenario==='wrong-context'?'ctx-'+'d'.repeat(64):context,surface:'chatgpt',experience:'split-screen',
              acknowledgementVerified:['reused','resume'].includes(scenario)})}' | ConvertFrom-Json)
          }\nfunction Value(`);
        }
        await writeFile(join(skill,file),source);
      }
      await writeFile(join(core,'check-cogentspec-update.ps1'),prefix+`'{"status":"current"}'`);
      await writeFile(join(core,'project-context.ps1'),prefix+`'${JSON.stringify({isolated:true,contextKey:context})}'`);
      const approval=scenario==='approval'||scenario==='unsafe-approval';
      const destination=scenario==='unsafe-destination'?url.replace('cogentspec.app','attacker.invalid'):url;
      const launch=approval?{status:'approval_required',contextKey:context,approvalProtocol:'cogentspec-gptsnap-approval-v1',
        approvalUrl:`https://${scenario==='unsafe-approval'?'attacker.invalid':'cogentspec.com'}/activate?code=TEST&experience=split-screen`,
        expiresAt:new Date(Date.now()+600000).toISOString(),pollAfterSeconds:5,browserOpened:false}:
        {status:'ready',bridge:'already_running',contextKey:context,contextIsolated:true,workspaceUrl:destination,webWorkspaceUrl:destination,
          presenceVerified:true,defaultDirectoryReady:true,accountState:'signed_in',mcpState:'not_required',projectDataConnection:'authenticated_desktop_bridge',browserOpened:false};
      await writeFile(join(core,'start-cogentstack-bridge.ps1'),prefix+`'${JSON.stringify(launch)}'`);
      await writeFile(join(core,'connect-cogentstack.ps1'),prefix+`throw 'An extra receipt helper is forbidden'`);
      const {connectGptSnap}=await import(pathToFileURL(join(skill,'gptsnap-client.mjs')).href);
      let output='';const callbacks=[];
      const result=await connectGptSnap({cwd:root,spawnCommand:(exe,args,options)=>{
        const child=spawn(exe,args,options);child.stdout.on('data',chunk=>{output+=chunk;});return child;
      },...(scenario==='resume'?{resumeApproval:{contextKey:context}}:{}),openWorkspace:async target=>{callbacks.push(target);throw Error('Agent callback forbidden');}});
      const expected=['reused','resume'].includes(scenario)?'connected':scenario==='approval'?'approval_required':
        ['owner_unavailable','owner_changed','busy','open_required'].includes(scenario)?'not_connected':'failed';
      assert.equal(result.status,expected,JSON.stringify(result));assert.deepEqual(callbacks,[]);
      assert.ok(!/cgw_|https:\/\/|gptPopTab/.test(output),'No browser handoff in normal stdout');
      const invocations=(await readFile(trace,'utf8')).trim().split(/\r?\n/);
      const expectedCalls=scenario==='resume'?['start-cogentstack-bridge.ps1']:
        ['check-cogentspec-update.ps1','project-context.ps1','start-cogentstack-bridge.ps1'];
      if(!approval&&scenario!=='unsafe-destination')expectedCalls.push('workspace-reuse');
      assert.deepEqual(invocations,expectedCalls,'One preparation/reuse only, no open or receipt fallback');
      console.log(`${plugin}: ${scenario} existing-workspace-only handshake passed`);
    } finally {await rm(root,{recursive:true,force:true,maxRetries:10,retryDelay:100});}
  }
}
