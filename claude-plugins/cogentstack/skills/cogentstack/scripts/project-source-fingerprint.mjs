// Hash only reviewable project inputs. Never execute project code or upload file contents.
// This self-contained function is also embedded in the local connector and release verifier.
export const projectSourceFingerprintProgram = String.raw`async function fingerprintProjectSource(directory, budget = 20000) {
  const fs = await import('node:fs/promises');
  const path = await import('node:path');
  const { createHash } = await import('node:crypto');
  const root = await fs.realpath(directory);
  const ignoredDirectories = new Set(['.git', 'node_modules', '.next', 'dist', 'build', 'target', 'coverage', 'evidence', '.coge-review-evidence', '.venv', '__pycache__', '.cache', '.wrangler']);
  const ignoredRootFiles = new Set(['AGENTS.md', 'PROJECT_KNOWLEDGE.md', 'CURRENT_STATE.md', 'HANDOFF.md', 'PROJECT_NOTES.md']);
  const ignoredPaths = new Set(['.coge/browser-project.json', '.coge/knowledge-manifest.json', '.coge/review-manifest.json', '.coge/review-evidence.json', '.coge/runtime']);
  const rows = [], observed = [], started = Date.now();
  let totalBytes = 0;
  const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  const identity = stat => [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(':');
  const bounded = () => { if (rows.length > 20000 || totalBytes > 1024 * 1024 * 1024 || Date.now() - started > budget) throw new Error('Project source check exceeded its safe limits.'); };
  const walk = async dir => {
    bounded();
    const before = await fs.lstat(dir, { bigint: true });
    if (before.isSymbolicLink() || !before.isDirectory()) throw new Error('Linked source paths cannot be checked.');
    observed.push([dir, identity(before)]);
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      const full = path.resolve(dir, entry.name), relative = path.relative(root, full).replaceAll('\\', '/');
      if (relative.startsWith('../') || path.isAbsolute(relative)) throw new Error('Source path escaped project.');
      if (ignoredDirectories.has(entry.name) || entry.name === 'review-evidence.json'
        || ignoredPaths.has(relative) || dir === root && ignoredRootFiles.has(entry.name)) continue;
      if (entry.isSymbolicLink()) throw new Error('Linked source paths cannot be checked.');
      if (entry.name.startsWith('.env') || /^(?:\.npmrc|\.yarnrc.*|.*\.(?:pem|key|pfx|p12)|id_rsa|id_ed25519)$/i.test(entry.name)) {
        const stat = await fs.lstat(full, { bigint: true });
        if (!stat.isFile() || stat.nlink !== 1n) throw new Error('Private configuration cannot be checked.');
        // Detect configuration edits without opening credentials or hashing their values.
        rows.push([relative, 'private-configuration-metadata', stat.size.toString(), stat.mtimeNs.toString(), stat.ctimeNs.toString()]);
        observed.push([full, identity(stat)]); bounded(); continue;
      }
      if (entry.isDirectory()) await walk(full);
      else if (entry.isFile()) {
        const file = await fs.open(full, 'r');
        try {
          const stat = await file.stat({ bigint: true });
          const current = await fs.lstat(full, { bigint: true });
          if (!stat.isFile() || current.isSymbolicLink() || stat.nlink !== 1n || identity(stat) !== identity(current)) throw new Error('Source identity changed during check.');
          totalBytes += Number(stat.size); bounded();
          const digest = createHash('sha256');
          for await (const chunk of file.createReadStream({ autoClose: false })) { digest.update(chunk); bounded(); }
          if (identity(await file.stat({ bigint: true })) !== identity(stat)) throw new Error('Source changed during check.');
          rows.push([relative, digest.digest('hex'), stat.mode & 0o111n ? 1 : 0]); observed.push([full, identity(stat)]); bounded();
        } finally { await file.close(); }
      } else throw new Error('Unsupported source entry.');
    }
  };
  await walk(root);
  for (const [full, stamp] of observed) if (identity(await fs.lstat(full, { bigint: true })) !== stamp) throw new Error('Source changed during check.');
  rows.sort((left, right) => left[0] < right[0] ? -1 : left[0] > right[0] ? 1 : 0);
  return { protocol: 'cogentspec-project-source-v1', sourceDigest: hash(JSON.stringify(rows)), files: rows.length };
}`;
// Static trusted code only. Keeping the program as data prevents the web bundler
// from rewriting its dynamic imports before embedding it in standalone helpers.
export const fingerprintProjectSource = new Function('return (' + projectSourceFingerprintProgram + ')')();

import {pathToFileURL} from 'node:url';
if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href){
 try{
  const fs=await import('node:fs/promises'),path=await import('node:path');
  let input; if(process.argv[2]) input={targetPath:process.argv[2],projectId:process.argv[3]};else{let text='';for await(const chunk of process.stdin){text+=chunk;if(text.length>4096)throw Error('Input too large');}input=JSON.parse(text);}
  const root=path.resolve(input.targetPath||''),id=input.projectId;
  if(!id || !path.isAbsolute(input.targetPath) || path.parse(root).root===root || (await fs.lstat(root)).isSymbolicLink())throw Error('Invalid project');
  const manifest=JSON.parse(await fs.readFile(path.join(root,'.coge','knowledge-manifest.json'),'utf8'));
  if(manifest.project?.requestId!==id)throw Error('Wrong project');
  console.log(JSON.stringify(await fingerprintProjectSource(root, 5000)));
 }catch{console.log(JSON.stringify({available:false}));process.exitCode=1;}
}
