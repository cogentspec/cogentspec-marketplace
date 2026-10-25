import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, lstatSync, mkdirSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, resolve, relative, extname, posix } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const compilerRequire = createRequire(existsSync(new URL('../app/package.json', import.meta.url)) ? new URL('../app/package.json', import.meta.url) : import.meta.url);
const ts = compilerRequire('typescript');

// This verifier intentionally has no automatic refresh or "accept all" mode.
// The checked-in locks are reviewed inputs, never build outputs.
export const commandIds = Object.freeze(['snap/gpt', 'snap/claude', 'web/gpt', 'web/claude', 'web/qwen', 'desk/gpt', 'desk/claude', 'local/qwen']);
const schema = 'cogentspec-bridge-firewall-v1';
const textExtensions = new Set(['.ps1', '.mjs', '.cjs', '.js', '.ts', '.tsx', '.jsx', '.json', '.md', '.yaml', '.yml', '.css', '.py', '.cs', '.sh', '.toml', '.txt', '.html', '.svg']);
const digest = value => createHash('sha256').update(value).digest('hex');
const stable = value => JSON.stringify(value);
const equalSet = (a, b) => stable([...a].sort()) === stable([...b].sort());
const fail = message => { throw new Error(`Bridge firewall: ${message}`); };
const json = path => JSON.parse(readFileSync(path, 'utf8'));
const save = (path, value) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, JSON.stringify(value, null, 2) + '\n'); };

function safePath(root, name) {
  if (typeof name !== 'string' || !name || name.includes('\\') || name.includes('\0') || name.startsWith('/')
    || name.split('/').some(part => !part || part === '.' || part === '..') || /^[A-Za-z]:/.test(name)) fail(`unsafe path ${name}`);
  const path = resolve(root, name);
  let parent = path;
  while (parent !== resolve(root)) {
    if (existsSync(parent) && lstatSync(parent).isSymbolicLink()) fail(`linked input ${name}`);
    const next = dirname(parent);
    if (next === parent) fail(`path escapes root: ${name}`);
    parent = next;
  }
  if (existsSync(path) && !realpathSync(path).startsWith(realpathSync(root) + (process.platform === 'win32' ? '\\' : '/'))) fail(`input escapes root: ${name}`);
  return path;
}

function filesAt(root, name) {
  const path = safePath(root, name);
  if (!existsSync(path)) fail(`missing inventory root ${name}`);
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) fail(`linked input ${name}`);
  if (stat.isFile()) return [name];
  if (!stat.isDirectory()) fail(`non-regular input ${name}`);
  return readdirSync(path).sort().flatMap(child => filesAt(root, `${name}/${child}`));
}

export function sourceHash(root, name) {
  const bytes = readFileSync(safePath(root, name));
  // Git text checkout line endings are not semantic changes. Binary files and
  // the final release/log bytes use unnormalised SHA-256.
  return digest(textExtensions.has(extname(name)) ? bytes.toString('utf8').replaceAll('\r\n', '\n') : bytes);
}

export function readPolicy(root) {
  const policy = json(resolve(root, 'bridge/firewall.json'));
  if (policy.protocol !== schema || policy.sourceHash !== 'sha256-git-text-lf-v1') fail('unknown policy or hash protocol');
  if (!Array.isArray(policy.commands) || !equalSet(policy.commands.map(item => item.id), commandIds)
    || new Set(policy.commands.map(item => item.id)).size !== 8) fail('the supported eight-cell command matrix changed');
  const names = new Set();
  for (const command of policy.commands) {
    const [type, provider] = command.id.split('/');
    const expected = '$' + (provider === 'gpt' ? 'gpt' : provider) + type;
    if (command.type !== type || command.provider !== provider || command.command !== expected || names.has(command.command)) fail(`wrong command identity ${command.id}`);
    names.add(command.command);
    if (!Array.isArray(command.suites) || !command.suites.length) fail(`no contract suites for ${command.id}`);
  }
  if (!Array.isArray(policy.groups) || new Set(policy.groups.map(item => item.id)).size !== policy.groups.length) fail('duplicate inventory group');
  for (const group of policy.groups) {
    if (!/^[a-z0-9-]+$/.test(group.id) || !['command', 'shared-runtime', 'packaging', 'presentation', 'firewall'].includes(group.kind)) fail('invalid dependency group');
    if (!group.roots?.length || !group.consumers?.length || group.consumers.some(id => !commandIds.includes(id))) fail(`invalid consumers for ${group.id}`);
    if (group.kind === 'command' && (group.consumers.length !== 1 || group.command !== group.consumers[0])) fail(`unscoped command group ${group.id}`);
    if (group.kind === 'firewall' && !equalSet(group.consumers, commandIds)) fail('firewall changes must affect every command');
  }
  // There is deliberately no generic "primitive" category: existing legacy
  // shared orchestration is classified as a shared runtime, not blessed as safe.
  return policy;
}

function inventory(root, policy) {
  const groups = new Map(), owners = new Map();
  for (const group of policy.groups) {
    const files = [...new Set(group.roots.flatMap(name => filesAt(root, name)))].filter(name => !(group.exclude || []).some(prefix => name === prefix || name.startsWith(prefix + '/'))).sort();
    const entries = Object.fromEntries(files.map(name => [name, sourceHash(root, name)]));
    groups.set(group.id, { kind: group.kind, consumers: [...group.consumers].sort(), files: entries });
    for (const name of files) {
      if (owners.has(name)) fail(`overlapping ownership for ${name}`);
      owners.set(name, group);
    }
  }
  return { groups, owners };
}

export function moduleTarget(root, source, specifier, aliases = {}) {
  const alias = Object.keys(aliases).find(prefix => specifier.startsWith(prefix));
  const normalized = posix.normalize(alias ? posix.join(aliases[alias], specifier.slice(alias.length)) : posix.join(posix.dirname(source), specifier));
  if (normalized.startsWith('../')) fail(`import escapes repository: ${source}`);
  const candidates = [normalized, ...['.mjs', '.cjs', '.js', '.ts', '.tsx', '.json', '.css'].map(extension => normalized + extension),
    ...['index.mjs', 'index.js', 'index.ts', 'index.tsx'].map(index => `${normalized}/${index}`)];
  return candidates.find(name => existsSync(safePath(root, name)) && lstatSync(safePath(root, name)).isFile());
}

export function moduleDependencies(source, name) {
  const tree = ts.createSourceFile(name, source, ts.ScriptTarget.Latest, true);
  const imports = [], edges = []; let computed = false;
  const add = (specifier, symbols) => { imports.push(specifier); edges.push({ specifier, symbols }); };
  const visit = node => {
    if (ts.isImportDeclaration(node) && ts.isStringLiteralLike(node.moduleSpecifier)) {
      const symbols = [];
      if (node.importClause?.name) symbols.push('default');
      const bindings = node.importClause?.namedBindings;
      if (bindings && ts.isNamedImports(bindings)) for (const element of bindings.elements) symbols.push((element.propertyName || element.name).text);
      else if (bindings) symbols.push('*');
      add(node.moduleSpecifier.text, symbols.length ? symbols : ['*']);
    }
    if (ts.isExportDeclaration(node) && node.moduleSpecifier && ts.isStringLiteralLike(node.moduleSpecifier)) {
      add(node.moduleSpecifier.text, node.exportClause && ts.isNamedExports(node.exportClause)
        ? node.exportClause.elements.map(element => (element.propertyName || element.name).text) : ['*']);
    }
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword
      || (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
      if (node.arguments.length === 1 && ts.isStringLiteralLike(node.arguments[0])) add(node.arguments[0].text, ['*']);
      else computed = true;
    }
    if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)
      && node.moduleReference.expression && ts.isStringLiteralLike(node.moduleReference.expression)) add(node.moduleReference.expression.text, ['*']);
    ts.forEachChild(node, visit);
  };
  visit(tree);
  return { imports, edges, computed };
}

function checkEdges(root, policy, state) {
  // Framework layouts/middleware are loaded by convention rather than imports.
  // New files there must not bypass the dependency graph.
  for (const directory of policy.implicitRoots || []) {
    for (const name of readdirSync(safePath(root, directory))) {
      if (/^(?:layout|template|error|global-error|loading|not-found|middleware|instrumentation|proxy)\.(?:ts|tsx|js|jsx|mjs)$/.test(name)
        && !state.owners.has(`${directory}/${name}`)) fail(`uninventoried framework dependency ${directory}/${name}`);
    }
  }
  for (const packageRoot of policy.packageRoots || []) {
    for (const name of filesAt(root, packageRoot)) if (!state.owners.has(name)) fail(`uninventoried package file ${name}`);
  }
  for (const [name, owner] of state.owners) {
    if (!['.mjs', '.cjs', '.js', '.ts', '.tsx', '.jsx', '.ps1'].includes(extname(name))) continue;
    const source = readFileSync(safePath(root, name), 'utf8');
    // Even a string/dynamic PowerShell path cannot reach another command's
    // skill folder. Whole directory inventories cover computed helper paths.
    if (owner.kind === 'command') {
      const own = policy.commands.find(command => command.id === owner.command);
      for (const command of policy.commands) {
        if (command.id !== own.id && (source.includes(`start-${command.command.slice(1)}.ps1`)
          || new RegExp(`(?:skills[/\\\\]|types[/\\\\]${command.type}[/\\\\])${command.command.slice(1)}(?:[/\\\\]|['"])`).test(source))) {
          fail(`cross-command dependency ${name} -> ${command.id}`);
        }
      }
    }
    if (extname(name) === '.ps1') continue;
    const { imports, edges, computed } = moduleDependencies(source, name);
    if (owner.kind === 'command' && computed) fail(`computed command import ${name}`);
    for (const specifier of imports.filter(value => value.startsWith('.') || Object.keys(policy.importAliases || {}).some(prefix => value.startsWith(prefix)))) {
      const target = moduleTarget(root, name, specifier, policy.importAliases);
      if (!target) fail(`unresolved dependency ${name} -> ${specifier}`);
      const targetOwner = state.owners.get(target);
      if (!targetOwner) fail(`uninventoried dependency ${name} -> ${target}`);
      if (owner.kind === 'command' && targetOwner.kind === 'command' && owner.command !== targetOwner.command) fail(`cross-command import ${name} -> ${target}`);
      if (owner.kind === 'command' && targetOwner.kind !== 'command') {
        const symbols = edges.filter(edge => edge.specifier === specifier).flatMap(edge => edge.symbols);
        const allowed = policy.sharedImports?.[owner.command]?.[target] || [];
        if (symbols.some(symbol => !allowed.includes(symbol) || (symbol === '*' && ['.mjs','.cjs','.js','.ts','.tsx','.jsx'].includes(extname(target))))) {
          fail(`undeclared shared export ${name} -> ${target}; type/provider boundary expansion requires an explicit policy change`);
        }
      }
      if (owner.kind !== 'command' && targetOwner.kind === 'command' && !owner.consumers.includes(targetOwner.command)) fail(`undeclared shared consumer ${name} -> ${target}`);
    }
  }
}

function desiredLock(policy, state, command) {
  const groups = Object.fromEntries([...state.groups].filter(([, group]) => group.consumers.includes(command.id)));
  const payload = { protocol: schema, command: command.command, id: command.id, type: command.type, provider: command.provider,
    sourceHash: policy.sourceHash, groups };
  return { ...payload, artifactDigest: digest(stable(payload)) };
}

const lockPath = (root, id) => resolve(root, 'bridge/locks', `${id}.json`);

export function verify(root) {
  const policy = readPolicy(root), state = inventory(root, policy);
  checkEdges(root, policy, state);
  const commands = [];
  for (const command of policy.commands) {
    const expected = desiredLock(policy, state, command), path = lockPath(root, command.id);
    if (!existsSync(path)) fail(`missing dependency lock ${command.id}`);
    const actual = json(path);
    if (stable(actual) !== stable(expected)) fail(`dependency drift in ${command.id}; explicit adoption and affected-command verification required`);
    commands.push({ id: command.id, command: command.command, artifactDigest: expected.artifactDigest });
  }
  const expectedLocks = commandIds.map(id => `bridge/locks/${id}.json`);
  if (!equalSet(filesAt(root, 'bridge/locks'), expectedLocks)) fail('unexpected dependency lock');
  const fingerprint = digest(stable({ policy, commands }));
  return { protocol: schema, status: 'verified', component: policy.component, fingerprint, commands, policy, state };
}

export function adopt(root, ids, reason) {
  if (!ids?.length || new Set(ids).size !== ids.length || ids.some(id => !commandIds.includes(id)) || typeof reason !== 'string' || reason.trim().length < 12) fail('adoption requires explicit command IDs and a reason');
  const policy = readPolicy(root), state = inventory(root, policy);
  checkEdges(root, policy, state);
  const affected = policy.commands.filter(command => !existsSync(lockPath(root, command.id))
    || stable(json(lockPath(root, command.id))) !== stable(desiredLock(policy, state, command))).map(command => command.id);
  if (!equalSet(ids, affected)) fail(`adoption scope must be exactly: ${affected.join(', ') || '(no changes)'}`);
  const changes = [];
  for (const id of ids) {
    const command = policy.commands.find(candidate => candidate.id === id), path = lockPath(root, id);
    const before = existsSync(path) ? json(path).artifactDigest : null;
    const lock = desiredLock(policy, state, command);
    save(path, lock);
    changes.push({ id, before, after: lock.artifactDigest });
  }
  save(resolve(root, 'bridge/adoption.json'), { protocol: schema, reason: reason.trim(), changes });
  return verify(root);
}

function git(root, args) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', windowsHide: true, maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) fail('could not resolve explicit comparison revision');
  return result.stdout.trim();
}

export function affectedCommands(root, baseRef) {
  const checked = verify(root);
  if (typeof baseRef !== 'string' || !baseRef || baseRef.startsWith('-')) fail('an explicit base revision is required');
  const base = git(root, ['rev-parse', '--verify', `${baseRef}^{commit}`]);
  const affected = [];
  for (const command of checked.commands) {
    const previous = spawnSync('git', ['show', `${base}:bridge/locks/${command.id}.json`], { cwd: root, encoding: 'utf8', windowsHide: true });
    if (previous.status !== 0 || JSON.parse(previous.stdout).artifactDigest !== command.artifactDigest) affected.push(command.id);
  }
  // A verifier, registry, test runner, or required contract test can change
  // without touching a runtime module. These inputs are themselves locked.
  return { checked, base, affected };
}

export function runContracts(root, ids, output) {
  const checked = verify(root);
  if (!ids?.length || ids.some(id => !commandIds.includes(id))) fail('explicit contract command scope required');
  mkdirSync(output, { recursive: true });
  const suites = new Map();
  for (const command of checked.policy.commands.filter(command => ids.includes(command.id))) {
    for (const suite of command.suites) suites.set(stable(suite), suite);
  }
  const results = [];
  for (const [index, suite] of [...suites.values()].entries()) {
    if (suite.executable !== 'node' || !Array.isArray(suite.args) || !suite.args.length || suite.args.some(arg => typeof arg !== 'string')) fail('unsupported contract runner');
    const childEnvironment = { ...process.env };
    delete childEnvironment.NODE_TEST_CONTEXT;
    const runnerArguments = suite.args.includes('--test') ? ['--test-reporter=tap', ...suite.args] : suite.args;
    const result = spawnSync(process.execPath, runnerArguments, { cwd: resolve(root, suite.cwd || '.'), env: childEnvironment, encoding: 'utf8', windowsHide: true,
      timeout: 600_000, maxBuffer: 24 * 1024 * 1024 });
    const log = (result.stdout || '') + (result.stderr || '');
    const file = `suite-${index + 1}.log`;
    writeFileSync(resolve(output, file), log);
    const pass = /# pass\s+(\d+)/.exec(log), total = /# tests\s+(\d+)/.exec(log), skipped = /# skipped\s+(\d+)/.exec(log);
    const success = result.status === 0 && !result.signal && !result.error && (pass ? Number(pass[1]) > 0 : /"status"\s*:\s*"valid"/.test(log));
    results.push({ suite, status: success ? 'passed' : 'failed', exitCode: result.status, signal: result.signal || null,
      tests: total ? Number(total[1]) : null, passed: pass ? Number(pass[1]) : null, skipped: skipped ? Number(skipped[1]) : null,
      log: file, logSha256: digest(Buffer.from(log)) });
    process.stdout.write(`Bridge contracts ${index + 1}/${suites.size}: ${success ? 'passed' : 'FAILED'}\n`);
    if (!success) break;
  }
  const report = { protocol: schema, kind: 'integration', component: checked.component, fingerprint: checked.fingerprint,
    completedAt: new Date().toISOString(), commands: [...new Set(ids)].sort(), results };
  save(resolve(output, 'integration.json'), report);
  if (results.length !== suites.size || results.some(result => result.status !== 'passed')) fail('contract suite failed; see private local test logs');
  return report;
}

export function validateEvidence(checked, ids, evidencePath, now = Date.now()) {
  const path = resolve(evidencePath), evidence = json(path), evidenceRoot = dirname(path);
  if (evidence.protocol !== schema || evidence.kind !== 'integration' || evidence.component !== checked.component
    || evidence.fingerprint !== checked.fingerprint) fail('missing or stale source-bound integration evidence');
  const age = now - Date.parse(evidence.completedAt);
  if (!Number.isFinite(age) || age < 0 || age > 24 * 60 * 60 * 1000) fail('integration evidence is expired');
  for (const id of ids) {
    const command = checked.policy.commands.find(candidate => candidate.id === id);
    if (!evidence.commands?.includes(id)) fail(`missing integration evidence ${id}`);
    for (const suite of command.suites) {
      const result = evidence.results?.find(candidate => stable(candidate.suite) === stable(suite));
      if (!result || result.status !== 'passed' || result.exitCode !== 0 || result.signal || result.passed === 0
        || (result.tests !== null && result.tests <= (result.skipped || 0))) fail(`missing, failed, or skipped-only suite ${id}`);
      if (digest(readFileSync(safePath(evidenceRoot, result.log))) !== result.logSha256) fail(`modified test evidence ${id}`);
    }
  }
}

export function recordLive(root, id, resultPath, output) {
  const checked = verify(root), command = checked.commands.find(candidate => candidate.id === id);
  if (!command) fail('unknown live command');
  const result = json(resultPath);
  // Only explicit observations are accepted. A launcher's "ready" result is
  // not a connection and integration fixtures are never promoted to live proof.
  if (result.testedSourceFingerprint !== checked.fingerprint || result.testedArtifactDigest !== command.artifactDigest
    || result.command !== command.command || result.environment !== 'live' || result.status !== 'connected'
    || result.workspaceConnected !== true || result.acknowledgementVerified !== true || result.browserOpened !== false
    || result.visibleBridgeConnected !== true || result.projectLibraryVerified !== true
    || result.duplicateApproval !== false || result.unexpectedWindow !== false) fail(`incomplete live observation ${id}`);
  const age = Date.now() - Date.parse(result.observedAt);
  if (!Number.isFinite(age) || age < 0 || age > 30 * 60 * 1000) fail('live observation must be fresh');
  // Whitelist the retained fields. Never copy context, credentials or handoffs.
  const observation = { protocol: schema, kind: 'live', id, command: command.command, component: checked.component,
    fingerprint: checked.fingerprint, artifactDigest: command.artifactDigest, observedAt: result.observedAt,
    status: 'connected', workspaceConnected: true, acknowledgementVerified: true, browserOpened: false,
    visibleBridgeConnected: true, projectLibraryVerified: true, duplicateApproval: false, unexpectedWindow: false };
  save(resolve(output, `${id}.json`), observation);
  return observation;
}

export function releaseGate(root, baseRef, evidencePath, liveDirectory, now = Date.now()) {
  const { checked, base, affected } = affectedCommands(root, baseRef);
  if (affected.length) {
    if (!evidencePath || !existsSync(resolve(evidencePath))) fail('integration verification NOT RUN for the candidate source');
    if (!liveDirectory || !existsSync(resolve(liveDirectory))) fail('live verification NOT RUN for the candidate source');
    validateEvidence(checked, affected, evidencePath, now);
    for (const id of affected) {
      const file = safePath(resolve(liveDirectory), `${id}.json`);
      if (!existsSync(file)) fail(`live verification NOT RUN: ${id}`);
      const value = json(file), command = checked.commands.find(candidate => candidate.id === id), age = now - Date.parse(value.observedAt);
      if (value.protocol !== schema || value.kind !== 'live' || value.id !== id || value.command !== command.command
        || value.component !== checked.component || value.fingerprint !== checked.fingerprint || value.artifactDigest !== command.artifactDigest
        || !Number.isFinite(age) || age < 0 || age > 24 * 60 * 60 * 1000 || value.status !== 'connected'
        || value.workspaceConnected !== true || value.acknowledgementVerified !== true || value.browserOpened !== false
        || value.visibleBridgeConnected !== true || value.projectLibraryVerified !== true
        || value.duplicateApproval !== false || value.unexpectedWindow !== false) fail(`incomplete or stale live verification ${id}`);
    }
  }
  return { protocol: schema, status: 'release-verified', component: checked.component, base, fingerprint: checked.fingerprint, affected };
}

async function main() {
  const [mode = 'check', ...args] = process.argv.slice(2);
  const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
  const root = resolve(option('--root') || dirname(dirname(fileURLToPath(import.meta.url))));
  let result;
  if (mode === 'check') result = verify(root);
  else if (mode === 'adopt') result = adopt(root, option('--commands')?.split(','), option('--reason'));
  else if (mode === 'affected') { const value = affectedCommands(root, option('--base-ref')); result = { base: value.base, affected: value.affected }; }
  else if (mode === 'test') result = runContracts(root, option('--commands')?.split(','), resolve(option('--output') || fail('test output directory required')));
  else if (mode === 'record-live') result = recordLive(root, option('--command'), option('--result'), option('--output') || fail('live output directory required'));
  else if (mode === 'release') result = releaseGate(root, option('--base-ref'), option('--evidence'), option('--live-directory'));
  else fail(`unknown mode ${mode}`);
  // Inventory contents stay in files; ordinary output is a bounded receipt.
  console.log(JSON.stringify({ protocol: schema, status: result.status || 'passed', component: result.component,
    fingerprint: result.fingerprint, base: result.base, affected: result.affected,
    commands: result.commands?.map(command => typeof command === 'string' ? command : command.id) }));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error.message); process.exitCode = 1; });
