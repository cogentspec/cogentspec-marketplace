import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const repository = resolve(import.meta.dirname, '..');
const context = 'ctx-' + 'a'.repeat(64);
const url = `https://cogentspec.app/stack?surface=chatgpt&context=${context}&experience=split-screen&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'c'.repeat(40)}`;
for (const plugin of ['cogentspec', 'cogentstack']) {
  for (const scenario of ['connected', 'absent', 'wrong-context', 'unverified', 'failed-open']) {
    const root = await mkdtemp(join(tmpdir(), 'gptsnap handshake fixture '));
    assert.equal(resolve(root, '..'), resolve(tmpdir()));
    try {
      const skill = join(root, 'skills', 'gptsnap', 'scripts');
      const core = join(root, 'skills', plugin, 'scripts');
      await mkdir(skill, { recursive: true }); await mkdir(core, { recursive: true });
      await mkdir(join(root, '.codex-plugin'));
      await writeFile(join(root, '.codex-plugin', 'plugin.json'), JSON.stringify({ name: plugin, version: '0.6.166' }));
      for (const file of ['start-gptsnap.ps1', 'gptsnap-client.mjs']) await writeFile(join(skill, file),
        await readFile(join(repository, 'plugins', plugin, 'skills', 'gptsnap', 'scripts', file)));
      const trace = join(root, 'trace.txt');
      const prefix = `Add-Content -LiteralPath '${trace.replaceAll("'", "''")}' -Value ([IO.Path]::GetFileName($PSCommandPath))\n`;
      await writeFile(join(core, 'check-cogentspec-update.ps1'), prefix + `'${JSON.stringify({ status: 'current' })}'`);
      await writeFile(join(core, 'project-context.ps1'), prefix + `'${JSON.stringify({ isolated: true, contextKey: context })}'`);
      await writeFile(join(core, 'start-cogentstack-bridge.ps1'), prefix + `'${JSON.stringify({ status: 'ready', bridge: 'already_running',
        contextKey: context, contextIsolated: true, workspaceUrl: url, webWorkspaceUrl: url, presenceVerified: true,
        defaultDirectoryReady: true, accountState: 'signed_in', mcpState: 'not_required', projectDataConnection: 'authenticated_desktop_bridge', browserOpened: false })}'`);
      const ack = { protocol: 'cogentspec-workspace-connection-v1', status: scenario === 'absent' ? 'not_connected' : 'connected',
        contextKey: scenario === 'wrong-context' ? 'ctx-' + 'e'.repeat(64) : context, surface: 'chatgpt', experience: 'split-screen',
        acknowledgementVerified: scenario !== 'unverified' };
      await writeFile(join(core, 'connect-cogentstack.ps1'), `param($Mode,$ContextKey,$Surface,$WorkspaceCode,$RequestTimeoutSeconds)\n`
        + prefix + `if ($Mode -ne 'workspace-status' -or $ContextKey -ne '${context}' -or $Surface -ne 'chatgpt' -or $WorkspaceCode -ne 'cgw_${'c'.repeat(40)}') { throw 'Wrong receipt' }\n'${JSON.stringify(ack)}'`);
      const { connectGptSnap } = await import(pathToFileURL(join(skill, 'gptsnap-client.mjs')).href);
      const calls = [];
      const result = await connectGptSnap({ cwd: root, openWorkspace: async target => {
        calls.push(target); if (scenario === 'failed-open') throw new Error('UI unavailable');
      } });
      assert.equal(result.status, scenario === 'connected' ? 'connected' : 'not_connected', JSON.stringify(result));
      assert.deepEqual(calls, [url]);
      assert.ok(!JSON.stringify(result).includes('cgw_'));
      const invocations = (await readFile(trace, 'utf8')).trim().split(/\r?\n/);
      assert.deepEqual(invocations.slice(0, 3), ['check-cogentspec-update.ps1', 'project-context.ps1', 'start-cogentstack-bridge.ps1']);
      assert.ok(invocations.filter(name => name === 'connect-cogentstack.ps1').length <= 1);
      if (scenario !== 'failed-open') assert.equal(invocations[3], 'connect-cogentstack.ps1');
      console.log(`${plugin}: ${scenario} protected acknowledgement passed without UI inspection`);
    } finally {
      await rm(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    }
  }
}
