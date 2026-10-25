// Explicit packaging command; ordinary builds never rewrite native artifacts or locks.
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const directory = fileURLToPath(new URL('./', import.meta.url));
const root = fileURLToPath(new URL('../../../../../', import.meta.url));
const output = process.argv[2] && resolve(process.argv[2]);
const revision = process.argv[3];
if (process.platform !== 'win32' || !output || !/^[a-f0-9]{40}$/.test(revision || ''))
  throw new Error('Use Windows: node build-native.mjs <output-directory> <immutable-marketplace-revision>');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const git = args => execFileSync('git', args, { cwd: root, windowsHide: true });
for (const path of ['bridge/types/web/gpt/windows/GptWebLauncher.cs', 'bridge/types/web/gpt/windows/bootstrap.ps1', 'bridge-runtime/gptweb/runtime.json']) {
  if (!git(['show', revision + ':' + path]).equals(await readFile(join(root, path))))
    throw new Error('Native packaging requires the exact committed source: ' + path);
}
await mkdir(output, { recursive: true });
const exe = join(output, 'CogentSpec-GPTWeb-Bridge.exe');
execFileSync('C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe', ['/nologo', '/target:winexe', '/platform:anycpu',
  '/reference:System.Web.Extensions.dll', '/out:' + exe, join(directory, 'GptWebLauncher.cs')], { windowsHide: true });
await copyFile(join(directory, 'bootstrap.ps1'), join(output, 'native-bootstrap.ps1'));
const metadata = { protocol: 'cogentspec-gptweb-native-release-v1', command: '$gptweb', version: '0.2.1',
  repository: 'https://github.com/cogentspec/cogentspec-marketplace.git', runtimeRevision: revision,
  runtimeManifestSha256: digest(await readFile(join(root, 'bridge-runtime/gptweb/runtime.json'))),
  launcherSourceSha256: digest(await readFile(join(directory, 'GptWebLauncher.cs'))),
  bootstrapSha256: digest(await readFile(join(output, 'native-bootstrap.ps1'))), installerSha256: digest(await readFile(exe)) };
await writeFile(join(output, 'native-release.json'), JSON.stringify(metadata, null, 2) + '\n');
console.log(JSON.stringify({ status: 'packaged', ...metadata }));
