// Standalone browser project connector. No Desktop UI, account token or model runtime.
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs/promises';
import { randomBytes, createHash, generateKeyPairSync, sign, timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const connectorVersion = '1.0.0';
const origins = new Set(['https://cogentspec.app', 'https://cogentspec.com']);
const verifier = 'https://cogentspec.app/api/qwen/project-bridge/verify';
const hash = data => createHash('sha256').update(data).digest('hex');
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length
  && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const fail = message => { throw new Error(message); };
const markerPath = '.coge/browser-project.json';
const ignored = new Set(['node_modules', '.git', '.coge', 'dist', 'build', '.next', '.venv', 'vendor']);
const protectedFile = name => name.split('/').some(part => ignored.has(part.toLowerCase()) || /^\.env(?:\.|$)/i.test(part)
  || /^(?:\.npmrc|\.yarnrc.*|.*\.(?:pem|key|pfx|p12)|id_rsa|id_ed25519)$/i.test(part))
  || /^(?:AGENTS\.md|PROJECT_KNOWLEDGE\.md|CURRENT_STATE\.md|HANDOFF\.md)$/i.test(name);
const approvedReadMetadata = new Set(['.coge/project-profile.json', '.coge/technical-choices.json', '.coge/capability-profile.json', '.coge/domain-decisions.json',
  'AGENTS.md', 'PROJECT_KNOWLEDGE.md', 'CURRENT_STATE.md', 'HANDOFF.md']);

export function safeRelative(name) {
  if (typeof name !== 'string' || name.length > 220 || name.includes('\\') || name.includes(':')
    || name.split('/').some(p => !p || p === '.' || p === '..' || /[<>"|?*]/.test(p) || Array.from(p).some(c => c.charCodeAt(0) < 32)
      || /[. ]$/.test(p) || /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(p))) fail('Unsafe project-relative path.');
  return name;
}

async function noLinks(target, allowMissing = false) {
  const parsed = path.parse(target);
  let current = parsed.root;
  for (const segment of target.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    try { if ((await fs.lstat(current)).isSymbolicLink()) fail('Linked project paths are not allowed.'); }
    catch (error) { if (allowMissing && error.code === 'ENOENT') continue; throw error; }
  }
}

export async function validateProjectRoot(input) {
  if (!path.isAbsolute(input) || input.startsWith('\\\\')) fail('Choose a dedicated absolute local project folder.');
  const root = path.resolve(input);
  const normalized = value => path.resolve(value).toLowerCase();
  const excluded = [path.parse(root).root, os.homedir(), os.tmpdir(), process.env.SystemRoot,
    process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.ProgramData].filter(Boolean);
  if (excluded.some(item => normalized(item) === normalized(root))
    || /(?:^|[\\/])(?:windows|program files(?: \(x86\))?|programdata|\.ssh|\.aws|\.codex|appdata)(?:[\\/]|$)/i.test(root)) fail('A system, credential, home, temporary or drive root is not a project folder.');
  await noLinks(root, true);
  const parent = await fs.stat(path.dirname(root));
  if (!parent.isDirectory()) fail('The parent project directory must already exist.');
  try { if (!(await fs.stat(root)).isDirectory()) fail('The project path is not a directory.'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return root;
}

function decodeFiles(files, foundation) {
  if (!Array.isArray(files) || !files.length || files.length > (foundation ? 200 : 20)) fail('Invalid file batch.');
  let total = 0;
  const names = new Set();
  return files.map(file => {
    const name = safeRelative(file.path);
    if (names.has(name.toLowerCase()) || name.toLowerCase() === markerPath || !foundation && protectedFile(name)) fail('Duplicate or protected file path.');
    names.add(name.toLowerCase());
    if (typeof file.contentBase64 !== 'string' || file.contentBase64.length > 2_000_000) fail('File too large.');
    const content = Buffer.from(file.contentBase64, 'base64');
    total += content.length;
    if (content.toString('base64') !== file.contentBase64 || hash(content) !== file.sha256
      || content.length > (foundation ? 1_500_000 : 128_000) || total > (foundation ? 6_000_000 : 512_000)) fail('File hash or size verification failed.');
    return { ...file, path: name, content };
  });
}

async function ownedRoot(root, plan) {
  await noLinks(root);
  await noLinks(path.join(root, markerPath));
  const stat = await fs.lstat(path.join(root, markerPath));
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > 4096) fail('Invalid project ownership marker.');
  const binding = JSON.parse(await fs.readFile(path.join(root, markerPath), 'utf8'));
  if (binding.ownerId !== plan.ownerId || binding.context !== plan.context || binding.bindingId !== plan.bindingId) fail('This folder belongs to a different project or account.');
  return binding;
}

// Preflight the whole batch. Back up replaced files before applying; roll back a
// failed batch. This is not an OS sandbox against another local process/user.
export async function applyFiles(root, files, { foundation = false } = {}) {
  const decoded = decodeFiles(files, foundation);
  await noLinks(root);
  const originals = [];
  for (const file of decoded) {
    const target = path.join(root, file.path);
    await noLinks(target, true);
    let previous = null;
    try {
      const info = await fs.lstat(target);
      if (!info.isFile() || info.nlink !== 1 || info.size > 1_500_000) fail('Only ordinary single-link files can be replaced.');
      previous = await fs.readFile(target);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (foundation ? previous !== null && hash(previous) !== file.sha256
      : (previous === null ? null : hash(previous)) !== file.beforeHash) fail(`File changed or already exists: ${file.path}`);
    originals.push({ target, previous, file });
  }
  const written = [];
  try {
    for (const item of originals) {
      await noLinks(item.target, true);
      await fs.mkdir(path.dirname(item.target), { recursive: true });
      // Recheck immediately before writing; an external edit requires a new review.
      let current = null;
      try { current = await fs.readFile(item.target); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if ((current === null ? null : hash(current)) !== (item.previous === null ? null : hash(item.previous))) fail('A project file changed during the operation.');
      const temp = `${item.target}.cogent-${randomBytes(12).toString('hex')}`;
      try {
        await fs.writeFile(temp, item.file.content, { flag: 'wx', mode: 0o600 });
        await fs.rename(temp, item.target);
      } finally { await fs.rm(temp, { force: true }); }
      written.push(item);
    }
  } catch (error) {
    for (const item of written.reverse()) {
      await noLinks(item.target);
      if (hash(await fs.readFile(item.target)) !== item.file.sha256) fail('Rollback stopped: a file changed externally. Preserve the folder for recovery.');
      if (item.previous === null) await fs.unlink(item.target);
      else await fs.writeFile(item.target, item.previous);
    }
    throw error;
  }
  return decoded.map(file => ({ path: file.path, sha256: file.sha256 }));
}

async function inventory(root) {
  const files = [];
  async function walk(folder, prefix = '') {
    for (const item of await fs.readdir(folder, { withFileTypes: true })) {
      if (files.length >= 500) fail('Project inventory exceeds 500 files.');
      const name = prefix + item.name;
      if (item.isSymbolicLink() || protectedFile(name) && name !== '.coge' && !approvedReadMetadata.has(name)) continue;
      safeRelative(name);
      const full = path.join(folder, item.name);
      await noLinks(full);
      if (item.isDirectory()) await walk(full, name + '/');
      else if (item.isFile()) {
        const stat = await fs.stat(full);
        if (stat.nlink === 1 && stat.size <= 128_000) files.push({ path: name, size: stat.size });
      }
    }
  }
  await walk(root);
  return files;
}

async function npmCli() {
  const candidates = [path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js'),
    path.resolve(path.dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js')];
  for (const candidate of candidates) { try { if ((await fs.stat(candidate)).isFile()) return candidate; } catch { /* Try the other official Node layout. */ } }
  fail('npm is not installed beside Node. Install the official Node LTS distribution.');
}

async function runTask(root, plan, signal) {
  const packagePath = path.join(root, 'package.json');
  await noLinks(packagePath);
  const bytes = await fs.readFile(packagePath);
  if (hash(bytes) !== plan.packageHash) fail('package.json changed. Review the command again.');
  const manifest = JSON.parse(bytes);
  if (!['build', 'test', 'check', 'lint', 'release:check', 'install-dependencies'].includes(plan.task)) fail('Unsupported project task.');
  if (plan.task !== 'install-dependencies' && (typeof manifest.scripts?.[plan.task] !== 'string'
    || manifest.scripts[plan.task] !== plan.script)) fail('The approved package script changed.');
  if (plan.task === 'install-dependencies' && (plan.script !== 'npm install --ignore-scripts --no-audit --no-fund')) fail('Invalid dependency-install approval.');
  const cli = await npmCli();
  const args = plan.task === 'install-dependencies' ? [cli, 'install', '--ignore-scripts', '--no-audit', '--no-fund']
    : [cli, '--ignore-scripts', 'run', plan.task];
  // npm scripts intentionally run as the current OS user, after explicit review.
  // They are not claimed to be sandboxed. Never run a model-provided shell string.
  return new Promise((resolve, reject) => {
    let output = '', timer;
    const child = spawn(process.execPath, args, { cwd: root, shell: false, windowsHide: true, detached: process.platform !== 'win32',
      env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, HOME: os.homedir(),
        USERPROFILE: os.homedir(), TEMP: os.tmpdir(), TMP: os.tmpdir(), npm_config_ignore_scripts: 'true' } });
    const stop = () => {
      if (process.platform === 'win32' && child.pid) {
        spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
      } else { try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') child.kill('SIGKILL'); } }
    };
    const collect = data => { output += data.toString(); if (output.length > 64_000) { output = output.slice(0, 64_000); stop(); } };
    child.stdout.on('data', collect); child.stderr.on('data', collect);
    signal?.addEventListener('abort', stop, { once: true });
    if (signal?.aborted) stop();
    timer = setTimeout(stop, 120_000);
    child.once('error', reject);
    child.once('close', code => { clearTimeout(timer); signal?.removeEventListener('abort', stop); resolve({ exitCode: code, output }); });
  });
}

export async function createConnector({ project, port = 4318, verifyPlan, code = randomBytes(16).toString('hex'), managed = false } = {}) {
  const root = await validateProjectRoot(project);
  const keys = generateKeyPairSync('ed25519');
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const instance = randomBytes(24).toString('hex');
  const sessions = new Map(), consumed = new Set();
  let busy = false, attempts = 0, paired = false, connectedPlan = null;
  const receipt = value => ({ value, signature: sign(null, Buffer.from(JSON.stringify(value)), keys.privateKey).toString('base64url') });
  const verifyRemote = verifyPlan || (async token => {
    const response = await fetch(verifier, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token, instance }) });
    if (!response.ok) fail('The hosted project approval is invalid, expired or no longer current.');
    const result = await response.json();
    return result.plan;
  });
  const server = http.createServer(async (request, response) => {
    const origin = request.headers.origin;
    const send = (data, status = 200) => { response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' }); response.end(JSON.stringify(data)); };
    if (request.headers.host !== `127.0.0.1:${server.address().port}` || !origins.has(origin)) return send({ error: 'Approved browser origin and loopback Host required.' }, 403);
    response.setHeader('access-control-allow-origin', origin);
    response.setHeader('vary', 'Origin');
    if (request.method === 'OPTIONS') {
      response.setHeader('access-control-allow-methods', 'POST');
      response.setHeader('access-control-allow-headers', 'content-type,x-cogent-connector');
      response.setHeader('access-control-allow-private-network', 'true');
      response.writeHead(204); return response.end();
    }
    if (request.method !== 'POST' || !request.headers['content-type']?.startsWith('application/json')) return send({ error: 'JSON POST required.' }, 405);
    try {
      const chunks = []; let size = 0;
      for await (const chunk of request) { size += chunk.length; if (size > 9_000_000) fail('Request too large.'); chunks.push(chunk); }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (request.url === '/ready') return send({ service: 'cogentspec-browser-project', version: connectorVersion,
        ...(managed ? { command: '$qwenlocal', distribution: 'https://github.com/cogentspec/cogentspec-marketplace.git', commandVersion: '1.0.0' } : {}) });
      if (request.url === '/pair') {
        if (paired || ++attempts > 10 || !equal(body.code, code)) return send({ error: 'Pairing code invalid or already used. Restart the connector for a fresh code.' }, 403);
        paired = true;
        const token = randomBytes(32).toString('hex');
        sessions.set(token, Date.now() + 60 * 60_000);
        return send({ token, proof: receipt({ instance, publicKey, targetPath: root, version: connectorVersion }) });
      }
      const sessionToken = request.headers['x-cogent-connector'];
      if (typeof sessionToken !== 'string' || (sessions.get(sessionToken) || 0) <= Date.now()) return send({ error: 'Pair this browser with the connector first.' }, 401);
      if (request.url === '/disconnect') {
        sessions.delete(sessionToken); send({ disconnected: true });
        if (managed) { server.close(); setTimeout(() => server.closeAllConnections(), 100).unref(); }
        return;
      }
      if (request.url === '/status') {
        // Read-only liveness/ownership check. It cannot pair, write, run commands,
        // issue a grant or load a model. No source contents or session tokens leave.
        if (!connectedPlan) return send({ connected: false });
        try { await ownedRoot(root, connectedPlan); }
        catch { connectedPlan = null; return send({ connected: false }); }
        const { ownerId, context, bindingId } = connectedPlan;
        return send({ connected: true, ownerId, context, bindingId, targetPath: root });
      }
      if (request.url !== '/execute' || busy) return send({ error: 'Unknown operation or connector busy.' }, 409);
      busy = true;
      try {
        if (typeof body.token !== 'string' || consumed.has(hash(body.token))) fail('This approval was already used. Request a fresh approval.');
        const plan = await verifyRemote(body.token);
        if (!plan || plan.instance !== instance || plan.publicKey !== publicKey || plan.targetPath !== root
          || !Number.isFinite(plan.expiresAt) || plan.expiresAt <= Date.now()) fail('Approval does not match this connector, project folder or time window.');
        consumed.add(hash(body.token));
        if (consumed.size > 1000) fail('Restart the connector to renew its operation limit.');
        let result;
        if (plan.operation === 'folder') {
          await noLinks(root, true);
          await fs.mkdir(root, { recursive: false }).catch(error => { if (error.code !== 'EEXIST') throw error; });
          const entries = await fs.readdir(root);
          if (entries.length) await ownedRoot(root, plan);
          else {
            await fs.mkdir(path.join(root, '.coge'));
            await fs.writeFile(path.join(root, markerPath), JSON.stringify({ ownerId: plan.ownerId, context: plan.context, bindingId: plan.bindingId }), { flag: 'wx', mode: 0o600 });
          }
          result = { folderReady: true };
        } else if (plan.operation === 'bind') {
          // Explicit adoption is restricted by the hosted grant to the currently
          // selected, already-created account-owned project, never an arbitrary path.
          await noLinks(root);
          const marker = path.join(root, markerPath);
          await noLinks(marker, true);
          let previous;
          try {
            const stat = await fs.lstat(marker);
            if (!stat.isFile() || stat.nlink !== 1 || stat.size > 4096) fail('Invalid project ownership marker.');
            previous = JSON.parse(await fs.readFile(marker, 'utf8'));
            if (previous.ownerId !== plan.ownerId || previous.bindingId !== plan.bindingId) fail('This folder is bound to a different account or project.');
          } catch (error) { if (error.code !== 'ENOENT') throw error; }
          await fs.mkdir(path.dirname(marker), { recursive: true });
          await fs.writeFile(marker, JSON.stringify({ ownerId: plan.ownerId, context: plan.context, bindingId: plan.bindingId }), { flag: previous ? 'w' : 'wx', mode: 0o600 });
          result = { projectBound: true };
        } else {
          await ownedRoot(root, plan);
          if (plan.operation === 'foundation') {
            const checked = decodeFiles(body.files, true);
            if (hash(checked.map(f => `${f.path}\t${f.sha256}\n`).join('')) !== plan.artifactDigest) fail('Foundation artifact digest mismatch.');
            result = { files: await applyFiles(root, body.files, { foundation: true }) };
          }
          else if (plan.operation === 'edit') {
            if (!Array.isArray(body.files) || JSON.stringify(body.files.map(({ path, sha256, beforeHash }) => ({ path, sha256, beforeHash }))) !== JSON.stringify(plan.files)) fail('File batch differs from the approved review.');
            result = { files: await applyFiles(root, body.files) };
          } else if (plan.operation === 'inspect') {
            const files = await inventory(root);
            const selected = plan.paths || [];
            if (!Array.isArray(selected) || selected.length > 20 || selected.some(name => !files.some(f => f.path === name))) fail('Read approval is not in the safe inventory.');
            let total = 0;
            const contents = [];
            for (const name of selected) {
              const full = path.join(root, name);
              await noLinks(full);
              const stat = await fs.lstat(full);
              if (!stat.isFile() || stat.nlink !== 1 || stat.size > 128_000) fail('Selected file changed after inventory.');
              const bytes = await fs.readFile(full); total += bytes.length;
              if (total > 32_000 || bytes.includes(0)) fail('Selected context is binary or exceeds 32 KB.');
              contents.push({ path: name, content: bytes.toString('utf8'), sha256: hash(bytes) });
            }
            result = { inventory: files, contents };
          } else if (plan.operation === 'task') {
            const abort = new AbortController();
            response.on('close', () => { if (!response.writableEnded) abort.abort(); });
            result = await runTask(root, plan, abort.signal);
          } else fail('Unsupported connector operation.');
        }
        connectedPlan = { ownerId: plan.ownerId, context: plan.context, bindingId: plan.bindingId };
        return send({ receipt: receipt({ grantId: plan.grantId, instance, operation: plan.operation, result }) });
      } finally { busy = false; }
    } catch (error) { send({ error: error instanceof Error ? error.message : 'Connector operation failed.' }, 400); }
  });
  server.requestTimeout = 150_000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return { server, port: server.address().port, code, root };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (Number(process.versions.node.split('.')[0]) < 22) fail('Node.js 22 or later is required.');
  if (process.argv.length !== 4) fail('Use the browser Connect this project download, or --project with one exact folder.');
  const prepared = process.argv[2] === '--launch-config';
  let options;
  if (prepared) {
    const configPath = path.resolve(process.argv[3]);
    await noLinks(configPath);
    const stat = await fs.stat(configPath);
    if (!stat.isFile() || stat.size > 2048) fail('Invalid browser connection configuration.');
    const data = JSON.parse(await fs.readFile(configPath, 'utf8'));
    if (!['code,context,project', 'code,context,managed,project'].includes(Object.keys(data).sort().join(',')) || typeof data.project !== 'string'
      || 'managed' in data && data.managed !== true
      || !/^[a-f0-9]{32}$/.test(data.code) || !/^ctx-[a-f0-9]{64}$/.test(data.context)) fail('Invalid browser connection request.');
    if (data.managed) {
      const allowed = path.resolve(process.env.LOCALAPPDATA || '', 'CogentSpec/browser-commands/state');
      if (!process.env.LOCALAPPDATA || path.dirname(configPath) !== allowed || !/^[a-f0-9]{32}\.json$/.test(path.basename(configPath))) fail('Invalid managed command configuration location.');
      await fs.unlink(configPath);
    }
    options = { project: data.project, code: data.code, managed: data.managed === true };
  } else if (process.argv[2] === '--project') options = { project: process.argv[3] };
  else fail('Unsupported browser connector option.');
  const connector = await createConnector(options);
  process.stdout.write(`CogentSpec browser project connector ${connectorVersion}\nFolder: ${connector.root}\n${prepared ? 'Return to the same browser tab; pairing completes there.' : `Pairing code: ${connector.code}`}\nKeep this window open. Ctrl+C revokes this connection.\n`);
  setTimeout(() => { connector.server.close(); connector.server.closeAllConnections(); }, 60 * 60_000).unref();
}
