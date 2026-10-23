import { spawn } from 'node:child_process';
import { platform } from 'node:os';
import { isAbsolute, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Process adapter only. The installed PowerShell command owns browser opening;
// no browser object, tab discovery or URL-opening callback is used.
export async function connectGptSnap({ cwd, resumeApproval, spawnCommand = spawn,
  systemDirectory = 'C:\\Windows\\System32' } = {}) {
  if (!cwd || !isAbsolute(cwd)) return { status: 'failed', userMessage: 'GPTSnap needs the invoking workspace directory.' };
  const started = Date.now();
  const helper = join(dirname(fileURLToPath(import.meta.url)), 'start-gptsnap.ps1');
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helper];
  if (resumeApproval) args.push('-ResumeApproval', '-ContextKey', resumeApproval.contextKey);
  let child;
  try {
    child = spawnCommand(join(systemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      args, { cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch { return { status: 'failed', userMessage: 'GPTSnap could not start.' }; }
  return new Promise(resolve => {
    let buffer = '', bytes = 0, settled = false;
    const finish = value => {
      if (settled) return;
      settled = true; clearTimeout(timeout); resolve(value);
    };
    const fail = () => {
      if (settled) return;
      if (child.exitCode == null && !child.killed) {
        if (platform() === 'win32' && Number.isInteger(child.pid)) {
          const killer = spawn(join(systemDirectory, 'taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'],
            {windowsHide:true,stdio:'ignore'});
          killer.on('error', () => {try {child.kill();} catch {}});
        } else {try {child.kill();} catch {}}
      }
      finish({status:'not_connected',userMessage:'GPTSnap could not confirm the workspace connection. Nothing was retried.'});
    };
    const timeout = setTimeout(fail, 180000);
    child.stdout.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 65536) {fail();return;}
      buffer += chunk.toString();
    });
    child.stderr.on('data', () => {});
    child.on('error', fail);
    child.on('close', code => {
      if (settled) return;
      try {
        if (code !== 0) throw new Error('Command failed');
        const value = JSON.parse(buffer.trim());
        if (value.protocol !== 'cogentspec-gptsnap-start-v1') throw new Error('Invalid response');
        if (value.workspaceUrl || value.webWorkspaceUrl || value.approvalUrl || value.browserNavigationCode) {
          throw new Error('The installed command must own its private browser handoff');
        }
        if (value.status === 'connected') {
          if (!/^ctx-[a-f0-9]{64}$/.test(value.contextKey) || value.browserOpened !== true
            || value.browserHandoff !== 'windows-default-browser' || value.workspaceConnected !== true
            || value.acknowledgementVerified !== true) throw new Error('Unverified connection');
          finish({status:'connected',userMessage:'GPTSnap connected.',elapsedMs:Date.now()-started});
        } else if (value.status === 'approval_required') {
          if (value.approvalProtocol !== 'cogentspec-gptsnap-approval-v1' || value.browserOpened !== true
            || value.browserHandoff !== 'windows-default-browser' || value.approvalUrl || value.browserNavigationCode
            || !/^ctx-[a-f0-9]{64}$/.test(value.contextKey) || !(Date.parse(value.expiresAt)>Date.now())
            || value.pollAfterSeconds<5) throw new Error('Invalid approval');
          finish({status:'approval_required',userMessage:value.userMessage,contextKey:value.contextKey,
            expiresAt:value.expiresAt,pollAfterSeconds:value.pollAfterSeconds,refreshedPluginPath:value.refreshedPluginPath});
        } else {
          if (!['failed','not_connected','connection_required','execution_permission_required','licence_required',
            'licence_verification_unavailable','signed_out'].includes(value.status) || typeof value.userMessage !== 'string') {
            throw new Error('Unexpected result');
          }
          finish({status:value.status,userMessage:value.userMessage});
        }
      } catch {fail();}
    });
  });
}
