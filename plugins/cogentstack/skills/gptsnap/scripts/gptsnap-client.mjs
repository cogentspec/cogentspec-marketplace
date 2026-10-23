import { spawn } from 'node:child_process';
import { platform } from 'node:os';
import { isAbsolute, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Transport only: the only permitted browser capability is opening one exact URL.
// No DOM, page evaluation, selectors, screenshots, library queries or UI probes.
export async function connectGptSnap({ cwd, openWorkspace, resumeApproval, spawnCommand = spawn,
  systemDirectory = 'C:\\Windows\\System32' } = {}) {
  if (!cwd || !isAbsolute(cwd)) return { status: 'failed', userMessage: 'GPTSnap needs the invoking workspace directory.' };
  const started = Date.now();
  const helper = join(dirname(fileURLToPath(import.meta.url)), 'start-gptsnap.ps1');
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helper];
  if (!openWorkspace) args.push('-PrepareOnly');
  if (resumeApproval) args.push('-ResumeApproval', '-ContextKey', resumeApproval.contextKey);
  let child;
  try {
    // Browser hosts need not expose process/env. Use an absolute system binary,
    // never a workspace/PATH lookup; non-default Windows installs can supply theirs.
    child = spawnCommand(join(systemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      args, { cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch { return { status: 'failed', userMessage: 'GPTSnap could not start.' }; }
  return new Promise(resolve => {
    let buffer = '', bytes = 0, handoff = null, terminal = null, failed = false, opened = false;
    let chain = Promise.resolve(), settled = false;
    const abortOwned = () => {
      if (child.exitCode != null || child.killed) return;
      // Stop only this command's process tree, never a shared worker by name.
      if (platform() === 'win32' && Number.isInteger(child.pid)) {
        const killer = spawn(join(systemDirectory, 'taskkill.exe'),
          ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
        killer.on('error', () => { try { child.kill(); } catch {} });
      } else { try { child.kill(); } catch {} }
    };
    const finish = value => {
      if (settled) return;
      settled = true; clearTimeout(timeout);
      resolve(value);
    };
    const fail = () => {
      failed = true; abortOwned();
      finish({ status: 'not_connected', userMessage: 'GPTSnap could not confirm the workspace connection. Nothing was retried.' });
    };
    const timeout = setTimeout(fail, 180000);
    const frame = async value => {
      if (failed) return;
      if (value.protocol !== 'cogentspec-gptsnap-start-v1') throw new Error('Invalid command response');
      if (value.status === 'workspace_ready' || value.status === 'ready') {
        if (handoff || terminal) throw new Error('Repeated handoff');
        const url = new URL(value.workspaceUrl);
        const expected = '^https://cogentspec\\.app/stack\\?surface=chatgpt&context=' + value.contextKey
          + '&experience=split-screen&open=web&nav=[a-f0-9]{32}#desktop-web=cgw_[A-Za-z0-9_-]{32,}$';
        if (!/^ctx-[a-f0-9]{64}$/.test(value.contextKey) || !new RegExp(expected).test(value.workspaceUrl)
          || value.workspaceUrl !== value.webWorkspaceUrl || url.username || url.password
          || value.browserNavigationProtocol !== 'cogentspec-gptpop-navigation-v1'
          || value.presenceVerified !== true || value.defaultDirectoryReady !== true
          || value.accountState !== 'signed_in' || value.projectDataConnection !== 'authenticated_desktop_bridge'
          || value.mcpState !== 'not_required' || value.browserOpened !== false) throw new Error('Invalid handoff');
        handoff = value;
        if (openWorkspace) {
          if (value.status !== 'workspace_ready') throw new Error('Missing acknowledgement phase');
          await openWorkspace(value.workspaceUrl);
          opened = true;
        } else {
          terminal = { status: 'ready', workspaceUrl: value.workspaceUrl,
            userMessage: 'GPTSnap is ready. Open the workspace link to continue.' };
        }
      } else if (value.status === 'connected') {
        if (!opened || !handoff || terminal || value.contextKey !== handoff.contextKey
          || value.workspaceConnected !== true || value.acknowledgementVerified !== true) throw new Error('Unverified connection');
        terminal = { status: 'connected', userMessage: 'GPTSnap connected.', elapsedMs: Date.now() - started };
      } else if (value.status === 'approval_required') {
        if (handoff || terminal) throw new Error('Unexpected approval');
        const url = new URL(value.approvalUrl);
        if (url.origin !== 'https://cogentspec.com' || url.pathname !== '/activate' || url.hash
          || url.username || url.password || !url.searchParams.get('code')
          || url.searchParams.get('experience') !== 'split-screen'
          || value.approvalProtocol !== 'cogentspec-gptsnap-approval-v1'
          || !/^ctx-[a-f0-9]{64}$/.test(value.contextKey)
          || !(Date.parse(value.expiresAt) > Date.now()) || value.pollAfterSeconds < 5) throw new Error('Invalid approval');
        terminal = { status: 'approval_required', approvalUrl: value.approvalUrl,
          contextKey: value.contextKey, expiresAt: value.expiresAt, pollAfterSeconds: value.pollAfterSeconds,
          refreshedPluginPath: value.refreshedPluginPath, userMessage: value.userMessage };
      } else {
        if (terminal) throw new Error('Repeated result');
        terminal = { status: 'not_connected', userMessage: typeof value.userMessage === 'string'
          ? value.userMessage : 'GPTSnap could not confirm the workspace connection.' };
      }
    };
    child.stdout.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 65536) { fail(); return; }
      buffer += chunk.toString();
      let at;
      while ((at = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, at).trim(); buffer = buffer.slice(at + 1);
        if (!line) continue;
        chain = chain.then(() => frame(JSON.parse(line))).catch(fail);
      }
    });
    child.stderr.on('data', () => {}); // Never echo private helper diagnostics.
    child.on('error', fail);
    child.on('close', code => {
      chain.then(() => {
        if (buffer.trim()) return fail();
        if (failed || code !== 0 || !terminal) return fail();
        finish(terminal);
      }).catch(fail);
    });
  });
}
