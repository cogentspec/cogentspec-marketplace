import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { join, dirname, basename, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { commandIds, adopt, verify, affectedCommands, runContracts, validateEvidence, recordLive, releaseGate } from './bridge-firewall.mjs';

const protocol = 'cogentspec-bridge-firewall-v1';
const write = (root, path, value) => { const target = join(root, path); mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n'); };
const read = (root, path) => JSON.parse(readFileSync(join(root, path), 'utf8'));
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'bridge-firewall-test-'));
  const commands = commandIds.map(id => { const [type, provider] = id.split('/'); return { id, type, provider,
    command: '$' + provider + type, suites: [{ executable: 'node', args: ['--test', 'contract.test.mjs'] }] }; });
  const groups = commands.map(command => ({ id: command.id.replace('/', '-'), kind: 'command', command: command.id,
    consumers: [command.id], roots: [`types/${command.id}`] }));
  groups.push({ id: 'worker', kind: 'shared-runtime', consumers: commandIds, roots: ['shared'] });
  groups.push({ id: 'test-contract', kind: 'firewall', consumers: commandIds, roots: ['contract.test.mjs'] });
  for (const command of commands) write(root, `types/${command.id}/entry.mjs`, 'export const run = () => "connected";\n');
  write(root, 'shared/worker.mjs', 'export const start = () => "ready";\n');
  write(root, 'contract.test.mjs', "import test from 'node:test'; import assert from 'node:assert/strict'; test('contract executed',()=>assert.equal(1,1));\n");
  write(root, 'bridge/firewall.json', { protocol, sourceHash: 'sha256-git-text-lf-v1', component: 'fixture', commands, groups });
  adopt(root, commandIds, 'Initial explicit fixture dependency adoption');
  return { root, dispose() {
    assert.equal(dirname(resolve(root)), resolve(tmpdir()));
    assert.ok(basename(root).startsWith('bridge-firewall-test-'));
    rmSync(root, { recursive: true, force: true });
  } };
}
function using(fn) { const value = fixture(); try { return fn(value.root); } finally { value.dispose(); } }
const runGit = (root, ...args) => { const result = spawnSync('git', args, { cwd: root, windowsHide: true, encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr); return result.stdout.trim(); };
function commitBase(root) {
  runGit(root, 'init', '--quiet'); runGit(root, 'config', 'user.name', 'Firewall fixture'); runGit(root, 'config', 'user.email', 'fixture@example.invalid');
  runGit(root, 'add', '.'); runGit(root, 'commit', '--quiet', '-m', 'Fixture baseline'); return runGit(root, 'rev-parse', 'HEAD');
}

test('eight independent locks; unsupported cells and command identities fail closed', () => using(root => {
  assert.equal(verify(root).commands.length, 8);
  const policy = read(root, 'bridge/firewall.json');
  policy.commands.push({ id: 'snap/qwen', type: 'snap', provider: 'qwen', command: '$qwensnap', suites: [] });
  write(root, 'bridge/firewall.json', policy);
  assert.throws(() => verify(root), /eight-cell/);
}));

test('private GPTWeb edit cannot be adopted as a GPTSnap edit; other seven locks retain their bytes', () => using(root => {
  const before = Object.fromEntries(commandIds.map(id => [id, readFileSync(join(root, `bridge/locks/${id}.json`), 'utf8')]));
  write(root, 'types/web/gpt/entry.mjs', 'export const run = () => "repaired web";\n');
  assert.throws(() => verify(root), /dependency drift in web\/gpt/);
  assert.throws(() => adopt(root, ['snap/gpt'], 'Wrong command repair scope'), /scope must be exactly: web\/gpt/);
  adopt(root, ['web/gpt'], 'Explicit GPTWeb-only repair adoption');
  for (const id of commandIds.filter(id => id !== 'web/gpt')) assert.equal(readFileSync(join(root, `bridge/locks/${id}.json`), 'utf8'), before[id]);
}));

test('shared worker edit requires every consumer, not only the command being repaired', () => using(root => {
  write(root, 'shared/worker.mjs', 'export const start = () => "new worker";\n');
  assert.throws(() => adopt(root, ['web/gpt'], 'Shared change disguised as Web fix'), /scope must be exactly: snap\/gpt/);
  const changed = adopt(root, commandIds, 'Explicit all-consumer worker compatibility change');
  assert.equal(changed.status, 'verified');
}));

test('cross-type and cross-provider imports are rejected even during explicit adoption', () => using(root => {
  for (const target of ['../../snap/gpt/entry.mjs', '../claude/entry.mjs']) {
    write(root, 'types/web/gpt/entry.mjs', `export { run } from '${target}';\n`);
    assert.throws(() => adopt(root, ['web/gpt'], 'Attempt cross-command reuse'), /cross-command import/);
  }
}));

test('compiler aliases cannot hide cross-command orchestration imports', () => using(root => {
  const policy=read(root,'bridge/firewall.json');policy.importAliases={'@/':'types/'};write(root,'bridge/firewall.json',policy);
  write(root,'types/web/gpt/entry.mjs',"export {run} from '@/snap/gpt/entry.mjs';\n");
  assert.throws(()=>adopt(root,['web/gpt'],'Attempt alias dependency bypass'),/cross-command import/);
}));

test('an existing shared module cannot supply a new listener export to a different command', () => using(root => {
  write(root,'shared/worker.mjs','export const start=()=>"ready"; export const documentId=()=>"id";\n');
  const policy=read(root,'bridge/firewall.json');policy.sharedImports={'web/gpt':{'shared/worker.mjs':['documentId']}};
  write(root,'bridge/firewall.json',policy);
  write(root,'types/web/gpt/entry.mjs',"import {documentId} from '../../../shared/worker.mjs'; export const run=documentId;\n");
  adopt(root,commandIds,'Explicit safe shared export fixture enrollment');
  for(const code of ["import {start} from '../../../shared/worker.mjs';", "import * as worker from '../../../shared/worker.mjs';",
    "export * from '../../../shared/worker.mjs';", "const worker=import('../../../shared/worker.mjs');"]){
    write(root,'types/web/gpt/entry.mjs',code+'\n');
    assert.throws(()=>adopt(root,['web/gpt'],'Attempt shared listener import drift'),/undeclared shared export/);
  }
}));

test('PowerShell entrypoints cannot call another matrix command by filename', () => using(root => {
  write(root,'types/web/gpt/entry.ps1',"& 'start-gptsnap.ps1'\n");
  assert.throws(()=>adopt(root,['web/gpt'],'Attempt cross-type PowerShell dispatch'),/cross-command dependency/);
}));

test('implicit framework layouts and middleware cannot bypass the import inventory', () => using(root => {
  write(root,'framework/layout.tsx','export default function Layout(){return null;}\n');
  const policy=read(root,'bridge/firewall.json');policy.implicitRoots=['framework'];policy.groups.find(group=>group.id==='worker').roots.push('framework/layout.tsx');
  write(root,'bridge/firewall.json',policy);adopt(root,commandIds,'Explicit initial framework dependency coverage');
  write(root,'framework/middleware.ts','export const middleware=()=>{};\n');
  assert.throws(()=>verify(root),/uninventoried framework dependency/);
}));

test('a new helper is inventoried; moving it outside the boundary cannot hide the dependency', () => using(root => {
  write(root, 'types/web/gpt/new-helper.mjs', 'export const helper = true;\n');
  assert.throws(() => verify(root), /dependency drift in web\/gpt/);
  write(root, 'hidden/helper.mjs', 'export const helper = true;\n');
  write(root, 'types/web/gpt/entry.mjs', "import '../../../hidden/helper.mjs';\n");
  assert.throws(() => adopt(root, ['web/gpt'], 'Attempt hidden helper dependency'), /uninventoried dependency/);
}));

test('an extra file at a shipped package root is rejected even if no command imports it', () => using(root => {
  const policy=read(root,'bridge/firewall.json');policy.packageRoots=['types'];write(root,'bridge/firewall.json',policy);
  write(root,'types/unowned.mjs','export const hidden=true;\n');
  assert.throws(()=>verify(root),/uninventoried package file/);
}));

test('computed command imports and dependency paths outside the repository are refused', () => using(root => {
  write(root, 'types/web/gpt/entry.mjs', 'export const run = target => import(target);\n');
  assert.throws(() => adopt(root, ['web/gpt'], 'Attempt computed dependency'), /computed command import/);
  const policy = read(root, 'bridge/firewall.json'); policy.groups[0].roots = ['../outside']; write(root, 'bridge/firewall.json', policy);
  assert.throws(() => verify(root), /unsafe path/);
}));

test('symlinks and junctions cannot substitute a locked runtime', () => using(root => {
  const target = join(root, 'other'); mkdirSync(target); write(root, 'other/entry.mjs', 'export const run = true;\n');
  symlinkSync(target, join(root, 'types/web/gpt/linked'), process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => verify(root), /linked input/);
}));

test('source-bound contract evidence rejects edits, missing commands, and tampered logs', () => using(root => {
  const output = join(root, 'evidence'); runContracts(root, ['web/gpt'], output);
  const checked = verify(root), evidence = join(output, 'integration.json');
  validateEvidence(checked, ['web/gpt'], evidence);
  assert.throws(() => validateEvidence(checked, ['snap/gpt'], evidence), /missing integration/);
  write(root, 'types/web/gpt/entry.mjs', 'export const run = () => "changed after test";\n');
  adopt(root, ['web/gpt'], 'Explicit post-test private change');
  assert.throws(() => validateEvidence(verify(root), ['web/gpt'], evidence), /stale source-bound/);
  write(root, 'evidence/suite-1.log', 'forged pass');
  assert.throws(() => validateEvidence(checked, ['web/gpt'], evidence), /modified test evidence/);
}));

test('an all-skipped suite cannot provide passing command evidence', () => using(root => {
  write(root, 'contract.test.mjs', "import test from 'node:test'; test.skip('not available',()=>{});\n");
  adopt(root, commandIds, 'Explicit skipped fixture suite setup');
  assert.throws(() => runContracts(root, ['web/gpt'], join(root, 'evidence')), /contract suite failed/);
}));

test('ready, unacknowledged, duplicate-approval and stale observations never become live success', () => using(root => {
  const checked=verify(root);
  const value = { command: '$gptweb', environment: 'live', status: 'connected', observedAt: new Date().toISOString(), workspaceConnected: true,
    testedSourceFingerprint: checked.fingerprint, testedArtifactDigest: checked.commands.find(command=>command.id==='web/gpt').artifactDigest,
    acknowledgementVerified: true, browserOpened: false, visibleBridgeConnected: true, projectLibraryVerified: true, duplicateApproval: false, unexpectedWindow: false };
  write(root,'observation.json',value);
  assert.equal(recordLive(root,'web/gpt',join(root,'observation.json'),join(root,'live')).status,'connected');
  for (const patch of [{ status: 'ready' }, { acknowledgementVerified: false }, { duplicateApproval: true }, { unexpectedWindow: true },
    { environment: 'integration' }, { command: '$gptsnap' }, { testedSourceFingerprint:'wrong-source' }, { testedArtifactDigest:'wrong-artifact' },
    { observedAt: new Date(Date.now() - 31 * 60_000).toISOString() }]) {
    write(root, 'observation.json', { ...value, ...patch });
    assert.throws(() => recordLive(root, 'web/gpt', join(root, 'observation.json'), join(root, 'live')), /incomplete live|must be fresh/);
  }
}));

test('release is blocked without live evidence even when integration passes; only the exact changed cell is required', () => using(root => {
  const base = commitBase(root);
  write(root, 'types/web/gpt/entry.mjs', 'export const run = () => "new web release";\n');
  adopt(root, ['web/gpt'], 'Explicit Web-only release fixture');
  assert.deepEqual(affectedCommands(root, base).affected, ['web/gpt']);
  const output = join(root, 'evidence'); runContracts(root, ['web/gpt'], output);
  const live = join(root, 'live'); mkdirSync(live);
  assert.throws(() => releaseGate(root, base, join(output, 'integration.json'), live), /live verification NOT RUN/);
  write(root, 'observation.json', { command: '$gptweb', environment: 'live', status: 'connected', observedAt: new Date().toISOString(), workspaceConnected: true,
    testedSourceFingerprint: verify(root).fingerprint, testedArtifactDigest: verify(root).commands.find(command=>command.id==='web/gpt').artifactDigest,
    acknowledgementVerified: true, browserOpened: false, visibleBridgeConnected: true, projectLibraryVerified: true, duplicateApproval: false, unexpectedWindow: false,
    contextKey: 'must-not-be-retained', token: 'must-not-be-retained' });
  recordLive(root, 'web/gpt', join(root, 'observation.json'), live);
  assert.doesNotMatch(readFileSync(join(live, 'web/gpt.json'), 'utf8'), /must-not-be-retained|contextKey|token/);
  assert.equal(releaseGate(root, base, join(output, 'integration.json'), live).status, 'release-verified');
  const observation = read(root, 'live/web/gpt.json'); observation.duplicateApproval = true; write(root, 'live/web/gpt.json', observation);
  assert.throws(() => releaseGate(root, base, join(output, 'integration.json'), live), /incomplete or stale live/);
}));

test('expired evidence and future timestamps are rejected', () => using(root => {
  const output = join(root, 'evidence'); runContracts(root, ['web/gpt'], output);
  const path = join(output, 'integration.json'), evidence = read(root, 'evidence/integration.json');
  for (const completedAt of [new Date(Date.now() + 60_000).toISOString(), new Date(Date.now() - 25 * 60 * 60_000).toISOString(), 'invalid']) {
    write(root, 'evidence/integration.json', { ...evidence, completedAt });
    assert.throws(() => validateEvidence(verify(root), ['web/gpt'], path), /expired/);
  }
}));
