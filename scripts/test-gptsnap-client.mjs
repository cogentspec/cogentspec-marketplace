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
const confirmed = { protocol, status: 'connected', contextKey: context, workspaceConnected: true,
  acknowledgementVerified: true, browserOpened: false, browserReused: true, browserHandoff: 'authenticated-workspace-reuse' };

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

test('normal command needs no browser capability: only authenticated existing-workspace reuse connects', async () => {
  let invocations = 0;
  const calls = [];
  // No browser/DOM object is provided: any inspection, selector, screenshot,
  // project-list read or click would be unavailable and fail this path.
  const result = await connectGptSnap({ cwd: process.cwd(),
    ...fakeCommand([confirmed], (args, options) => {
      invocations++;
      assert.equal(options.windowsHide, true);
      assert.equal(options.cwd, process.cwd());
      assert.ok(!args.includes('-PrepareOnly'));
    }), openWorkspace: async target => {calls.push(target);throw new Error('Agent browser callback must never run');} });
  assert.equal(result.status, 'connected');
  assert.equal(result.userMessage, 'GPTSnap connected.');
  assert.equal(invocations, 1);
  assert.deepEqual(calls, []);
  assert.ok(!JSON.stringify(result).includes('cgw_'));
  assert.ok(!JSON.stringify(result).includes('PRIVATE_'));
});

test('readiness, browser-open acceptance and fabricated/absent ACK cannot report connected', async () => {
  for (const frames of [[ready], [{...confirmed,browserOpened:true}], [{ ...confirmed, acknowledgementVerified: false }],
    [{ ...confirmed, contextKey: 'default' }], [ready, ready, confirmed],
    [{ ...ready, workspaceUrl: url.replace('cogentspec.app', 'evil.invalid') }, confirmed],
    [{ ...ready, status: 'ready' }, confirmed], [{...confirmed,browserHandoff:'agent'}],
    [{...confirmed,browserOpened:true,browserReused:false,browserHandoff:'windows-default-browser'}]]) {
    let opens = 0;
    const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand(frames), openWorkspace: async () => { opens++; } });
    assert.notEqual(result.status, 'connected');
    assert.equal(opens, 0);
    assert.ok(!JSON.stringify(result).includes('cgw_'));
  }
});

test('authenticated reuse connects without opening, but contradictory or unverified reuse fails closed', async () => {
  const reused = {...confirmed,browserOpened:false,browserReused:true,browserHandoff:'authenticated-workspace-reuse'};
  assert.equal((await connectGptSnap({cwd:process.cwd(),...fakeCommand([reused])})).status,'connected');
  for (const patch of [{browserReused:false},{browserOpened:true},{acknowledgementVerified:false},{browserHandoff:'agent'}]) {
    assert.notEqual((await connectGptSnap({cwd:process.cwd(),...fakeCommand([{...reused,...patch}])})).status,'connected');
  }
});

test('failed native browser delivery stops without an agent navigation fallback', async () => {
  let opens = 0;
  const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand([{protocol,status:'failed',userMessage:'GPTSnap could not open your default browser. Nothing was retried.'}]), openWorkspace: async () => {
    opens++; throw new Error('PRIVATE_BROWSER_FAILURE');
  } });
  assert.equal(result.status, 'failed');
  assert.equal(opens, 0);
  assert.ok(!JSON.stringify(result).includes('PRIVATE_'));
});

test('absence of browser tools is the normal path, never PrepareOnly or a handoff link', async () => {
  const result = await connectGptSnap({ cwd: process.cwd(), ...fakeCommand([confirmed], args => {
    assert.ok(!args.includes('-PrepareOnly'));
  }) });
  assert.equal(result.status, 'connected');
  assert.equal(result.workspaceUrl, undefined);
});

test('approved host runtimes need no ambient process global', async () => {
  const ambient = globalThis.process;
  const cwd = ambient.cwd();
  let spawned = 0;
  try {
    delete globalThis.process;
    const result = await connectGptSnap({ cwd, ...fakeCommand([confirmed], () => spawned++) });
    assert.equal(spawned, 1);
    assert.equal(result.status, 'connected');
  } finally { globalThis.process = ambient; }
});
