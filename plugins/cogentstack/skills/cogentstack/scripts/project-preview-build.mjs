import { lstat, realpath, readdir, open } from 'node:fs/promises';
import path from 'node:path';
import { constants } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { packPreviewFiles, safePreviewPath, previewMaxBytes, previewMaxFiles } from './project-preview-bundle.mjs';

const fail = code => { throw Object.assign(Error(code), { code }); };
const identity = s => [s.dev, s.ino, s.size, s.mtimeNs, s.ctimeNs].join(':');
export async function collectProjectPreview({ targetPath, projectId, runtimeId }) {
  if (!path.isAbsolute(targetPath || '') || !projectId || !runtimeId || path.parse(targetPath).root === path.resolve(targetPath)) fail('identity_mismatch');
  const root = path.resolve(targetPath), observed = [];
  // Never follow junctions/symlinks, including ones above the registered folder.
  for (let part = root;; part = path.dirname(part)) {
    const info = await lstat(part);
    if (info.isSymbolicLink() || !info.isDirectory()) fail('unsafe_build');
    if (part === path.dirname(part)) break;
  }
  if (await realpath(root) !== root) fail('unsafe_build');
  const stat = async full => {
    const info = await lstat(full, { bigint: true });
    if (info.isSymbolicLink()) fail('unsafe_build');
    observed.push([full, identity(info)]); return info;
  };
  const read = async full => {
    const before = await stat(full);
    if (!before.isFile() || before.nlink !== 1n) fail('unsafe_build');
    if (before.size > BigInt(previewMaxBytes)) fail('build_too_large');
    const handle = await open(full, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    try {
      if (identity(await handle.stat({ bigint: true })) !== identity(before)) fail('build_changed');
      const bytes = await handle.readFile();
      if (identity(await handle.stat({ bigint: true })) !== identity(before)) fail('build_changed');
      return bytes;
    } finally { await handle.close(); }
  };
  try {
    if (!(await stat(path.join(root, '.coge'))).isDirectory()) fail('identity_mismatch');
    const manifest = JSON.parse((await read(path.join(root, '.coge', 'knowledge-manifest.json'))).toString('utf8'));
    if (manifest.project?.requestId !== projectId) fail('identity_mismatch');
  } catch (error) { if (error.code === 'unsafe_build' || error.code === 'build_changed') throw error; fail('identity_mismatch'); }
  const exists = async full => { try { return await lstat(full); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
  let build = null, application = false;
  for (const name of ['dist', 'build', 'out']) {
    const candidate = path.join(root, name), info = await exists(candidate);
    if (!info) continue;
    if (info.isSymbolicLink() || !info.isDirectory()) fail('unsafe_build');
    if (await exists(path.join(candidate, 'server'))) {
      if (!await exists(path.join(candidate, 'server', 'index.js')) || !await exists(path.join(candidate, 'client'))) fail('build_missing');
      build = candidate; application = true; break;
    }
    if (await exists(path.join(candidate, 'index.html'))) { build = candidate; break; }
  }
  // Plain HTML projects may have no build system. Do not mistake a source entry
  // in a package-based app for completed production output.
  if (!build && !await exists(path.join(root, 'package.json')) && await exists(path.join(root, 'index.html'))) build = root;
  if (!build) fail('build_missing');
  const files = []; let bytes = 0, visited = 0;
  const include = relative => {
    if (application) {
      if (/^server\/(?:index\.js|vinext-client-assets\.js|__vite_rsc_assets_manifest\.js|(?:_next\/static|ssr)\/.+\.(?:js|mjs))$/.test(relative)) return true;
      return relative.startsWith('client/') && safePreviewPath('assets/' + relative.slice(7));
    }
    return safePreviewPath(relative) && relative !== 'cogentspec-preview.json';
  };
  const walk = async dir => {
    const info = await stat(dir); if (!info.isDirectory()) fail('unsafe_build');
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (++visited > 6000) fail('build_too_large');
      const full = path.join(dir, entry.name), relative = path.relative(build, full).replaceAll('\\', '/');
      if (entry.name.startsWith('.') || ['node_modules', 'src', 'data', 'coverage'].includes(entry.name)) continue;
      if (entry.isSymbolicLink()) fail('unsafe_build');
      if (entry.isDirectory()) {
        if (!application || /^(?:server(?:\/(?:_next|ssr)(?:\/.*)?)?|client(?:\/.*)?)$/.test(relative)) await walk(full);
      } else if (include(relative)) {
        const content = await read(full); bytes += content.length;
        if (bytes > previewMaxBytes || files.length >= previewMaxFiles - 1) fail('build_too_large');
        files.push({ name: entry.name, webkitRelativePath: 'build/' + relative, size: content.length,
          arrayBuffer: async () => content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength) });
      }
    }
  };
  await walk(build);
  let packed;
  try { packed = await packPreviewFiles(files, { id: projectId, runtimeId }); }
  catch { fail('unsafe_build'); }
  for (const [full, stamp] of observed) if (identity(await lstat(full, { bigint: true })) !== stamp) fail('build_changed');
  return { projectId, files: packed.files, buildDigest: packed.digest, kind: packed.kind };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let input = ''; for await (const chunk of process.stdin) { input += chunk; if (input.length > 8192) fail('unavailable'); }
  try { console.log(JSON.stringify(await collectProjectPreview(JSON.parse(input)))); }
  catch (error) { console.log(JSON.stringify({ error: ['identity_mismatch','unsafe_build','build_missing','build_too_large','build_changed'].includes(error.code) ? error.code : 'unavailable' })); }
}
