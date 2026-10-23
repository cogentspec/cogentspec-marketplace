import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const repository = resolve(import.meta.dirname, '..');
const context = 'ctx-' + 'a'.repeat(64);
const url = `https://cogentspec.app/stack?surface=chatgpt&context=${context}&experience=split-screen&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'c'.repeat(40)}`;
for (const plugin of ['cogentspec', 'cogentstack']) {
  for (const scenario of ['connected', 'absent', 'wrong-context', 'unverified', 'failed-open', 'unsafe-destination', 'approval', 'unsafe-approval', 'resume']) {
    const root = await mkdtemp(join(tmpdir(), 'gptsnap handshake fixture '));
    assert.equal(resolve(root, '..'), resolve(tmpdir()));
    try {
      const skill = join(root, 'skills', 'gptsnap', 'scripts');
      const core = join(root, 'skills', plugin, 'scripts');
      await mkdir(skill, { recursive: true }); await mkdir(core, { recursive: true });
      await mkdir(join(root, '.codex-plugin'));
      await writeFile(join(root, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version: '0.6.166' }));
      const trace = join(root, 'trace.txt');
      const prefix = `Add-Content -LiteralPath '${trace.replaceAll("'", "''")}' -Value ([IO.Path]::GetFileName($PSCommandPath))\n`;
      const approvalUrl = 'https://cogentspec.com/activate?code=TEST-CODE&experience=split-screen';
      const expectedUrl = scenario === 'approval' ? approvalUrl : url;
      for (const file of ['start-gptsnap.ps1', 'gptsnap-client.mjs']) {
        let source = await readFile(join(repository, 'plugins', plugin, 'skills', 'gptsnap', 'scripts', file), 'utf8');
        if (file === 'start-gptsnap.ps1') {
          assert.ok(source.includes('function Open-GptSnapBrowser('));
          // Only the private fixture replaces the OS boundary; the real source
          // still validates the complete destination before this function runs.
          source = source.replace('function Open-GptSnapBrowser(', 'function FixtureUnusedNativeBrowser(');
          source = source.replace('function Value(', `function Open-GptSnapBrowser([Uri]$Destination) {
            Add-Content -LiteralPath '${trace.replaceAll("'", "''")}' -Value 'native-browser'
            if ($Destination.AbsoluteUri -cne '${expectedUrl}') {throw 'Wrong native destination'}
            ${scenario === 'failed-open' ? "throw 'Browser unavailable'" : ''}
          }\nfunction Value(`);
        }
        await writeFile(join(skill, file), source);
      }
      await writeFile(join(core, 'check-cogentspec-update.ps1'), prefix + `'${JSON.stringify({ status: 'current' })}'`);
      await writeFile(join(core, 'project-context.ps1'), prefix + `'${JSON.stringify({ isolated: true, contextKey: context })}'`);
      const destination = scenario === 'unsafe-destination' ? url.replace('cogentspec.app','attacker.invalid') : url;
      const launch = scenario === 'approval' || scenario === 'unsafe-approval'
        ? {status:'approval_required',contextKey:context,approvalProtocol:'cogentspec-gptsnap-approval-v1',
          approvalUrl:scenario === 'unsafe-approval' ? approvalUrl.replace('cogentspec.com','attacker.invalid') : approvalUrl,
          expiresAt:new Date(Date.now()+600000).toISOString(),pollAfterSeconds:5,browserOpened:false}
        : { status: 'ready', bridge: 'already_running',
          contextKey: context, contextIsolated: true, workspaceUrl: destination, webWorkspaceUrl: destination, presenceVerified: true,
          defaultDirectoryReady: true, accountState: 'signed_in', mcpState: 'not_required', projectDataConnection: 'authenticated_desktop_bridge', browserOpened: false };
      await writeFile(join(core, 'start-cogentstack-bridge.ps1'), prefix + `'${JSON.stringify(launch)}'`);
      const ack = { protocol: 'cogentspec-workspace-connection-v1', status: scenario === 'absent' ? 'not_connected' : 'connected',
        contextKey: scenario === 'wrong-context' ? 'ctx-' + 'e'.repeat(64) : context, surface: 'chatgpt', experience: 'split-screen',
        acknowledgementVerified: scenario !== 'unverified' };
      await writeFile(join(core, 'connect-cogentstack.ps1'), `param($Mode,$ContextKey,$Surface,$WorkspaceCode,$RequestTimeoutSeconds)\n`
        + prefix + `if ($Mode -ne 'workspace-status' -or $ContextKey -ne '${context}' -or $Surface -ne 'chatgpt' -or $WorkspaceCode -ne 'cgw_${'c'.repeat(40)}') { throw 'Wrong receipt' }\n'${JSON.stringify(ack)}'`);
      const { connectGptSnap } = await import(pathToFileURL(join(skill, 'gptsnap-client.mjs')).href);
      const calls = [];
      let rawProtocol='';
      const result = await connectGptSnap({ cwd: root,
        spawnCommand:(exe,args,options)=>{
          const child=spawn(exe,args,options);
          child.stdout.on('data',chunk=>{rawProtocol+=chunk.toString();});
          return child;
        },
        ...(scenario === 'resume' ? {resumeApproval:{contextKey:context}} : {}),
        openWorkspace: async target => {calls.push(target);throw new Error('Agent callback forbidden');} });
      const expectedStatus = ['connected','resume'].includes(scenario) ? 'connected'
        : scenario === 'approval' ? 'approval_required'
        : ['failed-open','unsafe-destination','unsafe-approval'].includes(scenario) ? 'failed' : 'not_connected';
      assert.equal(result.status, expectedStatus, JSON.stringify(result));
      assert.deepEqual(calls, []);
      assert.ok(!JSON.stringify(result).includes('cgw_'));
      assert.ok(!/cgw_|https:\/\/|gptPopTab/.test(rawProtocol), 'Normal stdout must not export a browser handoff');
      const invocations = (await readFile(trace, 'utf8')).trim().split(/\r?\n/);
      const preparation = scenario === 'resume' ? ['start-cogentstack-bridge.ps1']
        : ['check-cogentspec-update.ps1', 'project-context.ps1', 'start-cogentstack-bridge.ps1'];
      assert.deepEqual(invocations.slice(0, preparation.length), preparation);
      const nativeCount = invocations.filter(name=>name==='native-browser').length;
      assert.equal(nativeCount, ['unsafe-destination','unsafe-approval'].includes(scenario) ? 0 : 1);
      assert.ok(invocations.filter(name => name === 'connect-cogentstack.ps1').length <= 1);
      const expectsAck = !['failed-open','unsafe-destination','approval','unsafe-approval'].includes(scenario);
      assert.equal(invocations.filter(name=>name==='connect-cogentstack.ps1').length, expectsAck ? 1 : 0);
      if (expectsAck) assert.deepEqual(invocations.slice(preparation.length), ['native-browser','connect-cogentstack.ps1']);
      assert.equal(result.approvalUrl, undefined);
      console.log(`${plugin}: ${scenario} installed native handoff passed without agent browser capabilities`);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    }
  }
}
