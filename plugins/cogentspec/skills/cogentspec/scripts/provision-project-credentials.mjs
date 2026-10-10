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
    const integration = job.mode === 'configure_integration';
    if (job.mode && !['configure_integration','provision_initial'].includes(job.mode)) return 'failed';
    if (integration) {
      if (job.environment !== 'local' || !['auth','api','service'].includes(job.kind)) return 'failed';
      const bindingsPath = join(coge, 'integration-bindings.json');
      if (!existsSync(bindingsPath)) return 'setup_required';
      if (lstatSync(bindingsPath).isSymbolicLink() || !same(realpathSync(bindingsPath), bindingsPath)) return 'failed';
      const bindings = JSON.parse(readFileSync(bindingsPath, 'utf8'));
      if (bindings.protocol !== 2 || bindings.projectId !== job.projectId || bindings.runtimeId !== job.runtimeId) return 'failed';
      const matches = bindings.integrations.filter(item => item.id === job.integrationId);
      if (matches.length !== 1) return 'setup_required';
      const binding = matches[0];
      const permitted = job.kind === 'auth' ? ['user_accounts','backend_administration'] : job.kind === 'api' ? ['content_api_integration'] : ['forms_notifications','payments_checkout','content_api_integration'];
      if (binding.kind !== job.kind || !permitted.includes(binding.capabilityId) || !job.approvedCapabilities.includes(binding.capabilityId)) return 'failed';
      if (!Array.isArray(binding.fields) || !Array.isArray(job.configuration) || job.configuration.length > 10) return 'failed';
      const fields = new Map(job.configuration.map(field => [field.name, field.value]));
      if (fields.size !== job.configuration.length || job.configuration.some(field => typeof field.value !== 'string' || field.value.length > 4096 || !binding.fields.some(expected => expected.name === field.name))) return 'failed';
      if (binding.fields.some(field => field.required && !fields.get(field.name))) return 'failed';
    }
    const adapter = join(coge, integration ? 'integration-provisioner.mjs' : 'credential-provisioner.mjs');
    if (!existsSync(adapter)) return 'setup_required';
    if (lstatSync(adapter).isSymbolicLink() || !same(realpathSync(adapter), adapter)) return 'failed';
    const result = spawnSync(process.execPath, [adapter], {
      cwd: root, windowsHide: true, timeout: 60_000, maxBuffer: 64_000, encoding: 'utf8',
      env: Object.fromEntries(Object.entries(process.env).filter(([key]) => ['PATH','Path','SystemRoot','SYSTEMROOT','TEMP','TMP','HOME','USERPROFILE'].includes(key))),
      input: JSON.stringify(integration ? { protocol: 2, operation: 'configure_integration', jobId: job.id, projectId: job.projectId,
        runtimeId: job.runtimeId, entryId: job.entryId, kind: job.kind, integrationId: job.integrationId, environment: 'local', configuration: job.configuration }
        : { protocol: 1, operation: 'provision_initial', jobId: job.id, projectId: job.projectId,
        runtimeId: job.runtimeId, entryId: job.entryId, kind: job.kind, loginName: job.loginName, password: job.password }),
    });
    if (result.error || result.status !== 0) return 'failed';
    const output = JSON.parse(result.stdout);
    if (output.jobId !== job.id || output.projectId !== job.projectId) return 'failed';
    if (integration) {
      if (output.integrationId !== job.integrationId || output.environment !== 'local' || output.persisted !== true) return 'failed';
      if (output.status === 'verified' && output.connectionVerified === true && output.configurationApplied === true) return 'verified';
      return output.status === 'applied' && output.configurationApplied === true ? 'integration_applied' : 'failed';
    }
    if (output.status === 'existing_account') return 'existing_account';
    return output.status === 'applied' && output.loginVerified === true && output.unauthenticatedDenied === true
      && output.persisted === true ? 'applied' : 'failed';
  } catch { return 'failed'; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  let input = '';
  try {
    for await (const chunk of process.stdin) { input += chunk; if (Buffer.byteLength(input) > 256_000) throw Error(); }
    process.stdout.write(JSON.stringify({ state: provisionInitialCredentials(JSON.parse(input)) }));
  } catch { process.stdout.write('{"state":"failed"}'); }
}
