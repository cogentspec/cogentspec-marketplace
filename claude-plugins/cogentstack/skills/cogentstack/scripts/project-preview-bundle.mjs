export const previewManifestName = 'cogentspec-preview.json';
export const previewMaxBytes = 16 * 1024 * 1024;
export const previewMaxFiles = 1500;
const extensions = new Set('html css js mjs json svg png jpg jpeg webp gif ico avif woff woff2 ttf txt xml webmanifest mp4 webm mp3 audio ogg pdf wasm'.split(' '));
export function safePreviewPath(path) {
  return typeof path === 'string' && path.length <= 300 && /^[A-Za-z0-9_@+., ()/~-]+$/.test(path)
    && !path.startsWith('/') && !path.split('/').some(p => !p || p.startsWith('.') || ['src','server','node_modules'].includes(p.toLowerCase()))
    && extensions.has(path.split('.').at(-1).toLowerCase())
    && !/(?:^|\/)(?:package(?:-lock)?\.json|.*(?:secret|credential|private.?key|\.pem|\.key))$/i.test(path);
}
const decode = value => Uint8Array.from(atob(value), char => char.charCodeAt(0));
export function inspectPreviewEntries(entries, expectedProjectId) {
  if (!Array.isArray(entries) || !entries.length || entries.length > previewMaxFiles) throw Error('Choose a built preview with no more than 1,500 files.');
  const paths = new Set(); let total = 0;
  for (const file of entries) {
    if (!file || !safePreviewPath(file.path) || paths.has(file.path) || typeof file.content !== 'string'
      || file.content.length > previewMaxBytes * 1.4 || file.content.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(file.content)) throw Error('The preview contains an unsafe, duplicate or unsupported file.');
    paths.add(file.path); total += file.content.length / 4 * 3 - (file.content.endsWith('==') ? 2 : file.content.endsWith('=') ? 1 : 0);
    if (total > previewMaxBytes) throw Error('The preview must be no larger than 16 MB.');
  }
  const metadata = entries.find(file => file.path === previewManifestName);
  if (!metadata) {
    if (!paths.has('index.html')) throw Error('Choose the static build folder containing index.html, or the application dist folder containing server and client.');
    return { kind: 'static', bytes: total };
  }
  if (metadata.content.length > 8192) throw Error('Invalid application preview manifest.');
  let manifest; try { manifest = JSON.parse(new TextDecoder().decode(decode(metadata.content))); } catch { throw Error('Invalid application preview manifest.'); }
  const keys = ['protocol','kind','projectId','runtimeId','entry','assets','data'];
  if (!manifest || Object.keys(manifest).some(key => !keys.includes(key)) || manifest.protocol !== 1 || manifest.kind !== 'vinext-worker-v1'
    || manifest.entry !== 'app/index.js' || manifest.assets !== 'assets' || manifest.data !== 'isolated'
    || typeof manifest.projectId !== 'string' || typeof manifest.runtimeId !== 'string'
    || (expectedProjectId && manifest.projectId !== expectedProjectId) || !paths.has(manifest.entry)
    || entries.some(file => file.path !== previewManifestName && !/^(?:app\/.+\.(?:js|mjs)|assets\/.+)$/.test(file.path))) throw Error('This application preview format or project identity is not supported.');
  return { kind: 'vinext-worker-v1', manifest, bytes: total };
}
function encode(bytes) {
  let binary = ''; for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  return btoa(binary);
}
const digest = async bytes => [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(n => n.toString(16).padStart(2,'0')).join('');
export async function packPreviewFiles(files, project, signal) {
  signal?.throwIfAborted();
  if (!files?.length || files.length > 3000) throw Error('Choose the built preview folder.');
  const named = [...files].map(file => ({ file, path: file.webkitRelativePath ? file.webkitRelativePath.split('/').slice(1).join('/') : file.name }));
  const application = named.some(entry => entry.path === 'server/index.js');
  const entries = [], paths = new Set(), rows = []; let total = 0;
  for (const entry of named) {
    signal?.throwIfAborted(); let path = entry.path;
    if (application) {
      if (/^server\/(?:index\.js|vinext-client-assets\.js|__vite_rsc_assets_manifest\.js|(?:_next\/static|ssr)\/.+\.(?:js|mjs))$/.test(path)) path = 'app/' + path.slice(7);
      else if (path === 'client/.vite/manifest.json') continue;
      else if (path.startsWith('client/')) path = 'assets/' + path.slice(7);
      else continue; // No Wrangler vars, source tree, runtime state or private build metadata.
    }
    if (/(?:^|\/)(?:\.assetsignore|_headers)$/.test(path)) continue;
    if (!safePreviewPath(path) || paths.has(path)) throw Error('Choose only built preview files, without source files, hidden paths or credentials.');
    total += entry.file.size; if (total > previewMaxBytes) throw Error('The preview must be no larger than 16 MB.');
    const bytes = new Uint8Array(await entry.file.arrayBuffer()); total += bytes.length - entry.file.size;
    if (total > previewMaxBytes) throw Error('The preview must be no larger than 16 MB.');
    signal?.throwIfAborted(); paths.add(path); entries.push({ path, content: encode(bytes) }); rows.push([path, await digest(bytes)]);
  }
  if (application) {
    if (!project.runtimeId) throw Error('Refresh projects before preparing this application preview.');
    const bytes = new TextEncoder().encode(JSON.stringify({ protocol:1, kind:'vinext-worker-v1', projectId:project.id, runtimeId:project.runtimeId, entry:'app/index.js', assets:'assets', data:'isolated' }));
    entries.push({ path:previewManifestName, content:encode(bytes) }); rows.push([previewManifestName,await digest(bytes)]);
  }
  const inspected = inspectPreviewEntries(entries, project.id);
  rows.sort((a,b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
  return { files:entries, kind:inspected.kind, digest:await digest(new TextEncoder().encode(JSON.stringify(rows))) };
}
