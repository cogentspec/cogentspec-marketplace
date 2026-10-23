import assert from 'node:assert/strict';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { connectGptSnap } from '../plugins/cogentspec/skills/gptsnap/scripts/gptsnap-client.mjs';

const context = 'ctx-' + 'a'.repeat(64);
const url = `https://cogentspec.app/stack?surface=chatgpt&context=${context}&experience=split-screen&open=web&nav=${'b'.repeat(32)}#desktop-web=cgw_${'c'.repeat(40)}`;
const protocol = 'cogentspec-gptsnap-start-v1';
const ready = { protocol, status: 'workspace_ready', contextKey: context, workspaceUrl: url, webWorkspaceUrl: url,
  browserNavigationProtocol: 'cogentspec-gptpop-navigation-v1', presenceVerified: true, defaultDirectoryReady: true,
  accountState: 'signed_in', projectDataConnection: 'authenticated_desktop_bridge', mcpState: 'not_required', browserOpened: false };
const confirmed = { protocol, status: 'connected', contextKey: context, workspaceConnected: true, acknowledgementVerified: true };

function fakeCommand(frames, onSpawn = () => {}) {
  let child;
  return { spawnCommand(_exe, args, options) {
    onSpawn(args, options);
    child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.exitCode = null; child.killed = false;
    child.kill = () => { child.killed = true; child.exitCode = 1; child.emit('close', 1); };
    queueMicrotask(() => {
      for (const frame of frames) child.stdout.write(JSON.stringify(frame) + '\n');
      child.stderr.write('PRIVATE_DIAGNOSTIC_MUST_NOT_ESCAPE');
      child.exitCode = 0; child.emit('close', 0);
    });
    return child;
  } };
}

test('normal command uses only one URL-open capability and server acknowledgement, never UI inspection', async () => {
  let invocations = 0;
  const calls = [];
  // No browser/DOM object is provided: any inspection, selector, screenshot,
  // project-list read or click would be unavailable and fail this path.
  const result = await connectGptSnap({ cwd: process.cwd(),
    ...fakeCommand([ready, confirmed], (args, options) => {
      invocations++;
      assert.equal(options.windowsHide, true);
      assert.equal(options.cwd, process.cwd());
      assert.ok(!args.includes('-PrepareOnly'));
    }), openWorkspace: async target => calls.push(target) });
  assert.equal(result.status, 'connected');
  assert.equal(result.userMessage, 'GPTSnap connected.');
  assert.equal(invocations, 1);
  assert.deepEqual(calls, [url]);
  assert.ok(!JSON.stringify(result).includes('cgw_'));
  assert.ok(!JSON.stringify(result).includes('PRIVATE_'));
});

test('readiness, browser-open acceptance and fabricated/absent ACK cannot report connected', async () => {
  for (const frames of [[ready], [confirmed], [ready, { ...confirmed, acknowledgementVerified: false }],
    [ready, { ...confirmed, contextKey: 'ctx-' + 'd'.repeat(64) }], [ready, ready, confirmed],
    [{ ...ready, workspaceUrl: url.replace('cogentspec.app', 'evil.invalid') }, confirmed],
    [{ ...ready, status: 'ready' }, confirmed]]) {
    let opens = 0;
    const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand(frames), openWorkspace: async () => { opens++; } });
    assert.notEqual(result.status, 'connected');
    assert.ok(opens <= 1);
    assert.ok(!JSON.stringify(result).includes('cgw_'));
  }
});

test('failed browser delivery stops without another navigation or connection attempt', async () => {
  let opens = 0;
  const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand([ready, confirmed]), openWorkspace: async () => {
    opens++; throw new Error('PRIVATE_BROWSER_FAILURE');
  } });
  assert.equal(result.status, 'not_connected');
  assert.equal(opens, 1);
  assert.ok(!JSON.stringify(result).includes('PRIVATE_'));
});

test('without an opening capability, return an unconsumed recovery link, never claim connected', async () => {
  const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand([{ ...ready, status: 'ready' }], args => {
    assert.ok(args.includes('-PrepareOnly'));
  }) });
  assert.equal(result.status, 'ready');
  assert.equal(result.workspaceUrl, url);
});
