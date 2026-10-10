import { readFileSync, realpathSync, lstatSync, existsSync } from 'node:fs';
import { isAbsolute, resolve, join, parse } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

// No passwords in argv, environment, files, logs or output. Only the registered local adapter receives stdin.
export function provisionInitialCredentials(job) {
  try {
    const same = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
    if (!isAbsolute(job.targetPath) || resolve(job.targetPath) === parse(job.targetPath).root) return 'failed';
    const root = realpathSync(job.targetPath);
    if (!same(root, resolve(job.targetPath))) return 'failed';
    const coge = join(root, '.coge'), manifestPath = join(coge, 'knowledge-manifest.json');
    for (const path of [coge, manifestPath]) if (lstatSync(path).isSymbolicLink() || !same(realpathSync(path), path)) return 'failed';
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    if (manifest.project?.requestId !== job.projectId || manifest.binding?.packRef !== job.packRef || manifest.binding?.releaseMode !== 'local') return 'failed';
    const adapter = join(coge, 'credential-provisioner.mjs');
    if (!existsSync(adapter)) return 'setup_required';
    if (lstatSync(adapter).isSymbolicLink() || !same(realpathSync(adapter), adapter)) return 'failed';
    const result = spawnSync(process.execPath, [adapter], {
      cwd: root, windowsHide: true, timeout: 60_000, maxBuffer: 64_000, encoding: 'utf8',
      env: Object.fromEntries(Object.entries(process.env).filter(([key]) => ['PATH','Path','SystemRoot','SYSTEMROOT','TEMP','TMP','HOME','USERPROFILE'].includes(key))),
      input: JSON.stringify({ protocol: 1, operation: 'provision_initial', jobId: job.id, projectId: job.projectId,
        runtimeId: job.runtimeId, entryId: job.entryId, kind: job.kind, loginName: job.loginName, password: job.password }),
    });
    if (result.error || result.status !== 0) return 'failed';
    const output = JSON.parse(result.stdout);
    if (output.jobId !== job.id || output.projectId !== job.projectId) return 'failed';
    if (output.status === 'existing_account') return 'existing_account';
    return output.status === 'applied' && output.loginVerified === true && output.unauthenticatedDenied === true
      && output.persisted === true ? 'applied' : 'failed';
  } catch { return 'failed'; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  let input = '';
  try {
    for await (const chunk of process.stdin) { input += chunk; if (Buffer.byteLength(input) > 16_000) throw Error(); }
    process.stdout.write(JSON.stringify({ state: provisionInitialCredentials(JSON.parse(input)) }));
  } catch { process.stdout.write('{"state":"failed"}'); }
}
