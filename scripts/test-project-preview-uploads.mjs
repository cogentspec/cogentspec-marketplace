import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, mkdir, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import http from 'node:http';
const repository = new URL('../', import.meta.url), canonical = new URL('plugins/cogentspec/skills/cogentspec/scripts/', repository);
const files = ['project-preview-worker.ps1','project-preview-build.mjs','project-preview-bundle.mjs','project-preview-upload.mjs'];
test('all four native packages share the bounded automatic preview collector, worker and startup inventory', async () => {
  for (const host of ['plugins','claude-plugins']) for (const plugin of ['cogentspec','cogentstack']) {
    const scripts = new URL(`${host}/${plugin}/skills/${plugin}/scripts/`, repository);
    for (const file of files) assert.equal(await readFile(new URL(file, scripts), 'utf8'), await readFile(new URL(file, canonical), 'utf8'));
    const start = await readFile(new URL('start-cogentstack-bridge.ps1', scripts), 'utf8'), worker = await readFile(new URL('watch-cogentstack-bridge.ps1', scripts), 'utf8');
    for (const file of files) assert.ok(start.includes("'" + file + "'"));
    assert.match(worker, /Invoke-ProjectPreviewUploads -Token \$token/);
    const runtime = await readFile(new URL(`${host}/${plugin}/skills/qwenlocal/scripts/qwen-runtime.mjs`, repository), 'utf8');
    assert.match(runtime, /request.url === '\/preview-build'/); assert.match(runtime, /async function collectBuiltPreview/);
  }
});
for (const shell of ['powershell.exe','pwsh.exe']) test(`${shell}: real worker collects and uploads only its requested build with no credential output`, { skip: process.platform !== 'win32' }, async t => {
  const parent = resolve(tmpdir()), root = await mkdtemp(join(parent, 'coge-preview-worker-test-'));
  t.after(async () => { const target = await realpath(root); assert.ok(target.startsWith(parent + '\\')); await rm(target, { recursive: true, force: true }); });
  const project = join(root, 'project'); await mkdir(join(project, '.coge'), { recursive: true }); await mkdir(join(project, 'dist'));
  await writeFile(join(project, '.coge/knowledge-manifest.json'), JSON.stringify({ project: { requestId: 'project-fixture' } }));
  await writeFile(join(project, 'dist/index.html'), '<h1>Synthetic preview</h1>'); await writeFile(join(project, '.env'), 'PRIVATE_LOCAL_VALUE');
  const received = [];
  const server = http.createServer(async (req, res) => {
    let text = ''; for await (const part of req) text += part;
    received.push({ body: JSON.parse(text), authorization: req.headers.authorization });
    res.setHeader('content-type', 'application/json'); res.end('{"accepted":true}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => new Promise(resolve => server.close(resolve)));
  const endpoint = 'http://127.0.0.1:' + server.address().port;
  for (const file of files) {
    let source = await readFile(new URL(file, canonical), 'utf8');
    if (file === 'project-preview-upload.mjs') source = source.replace('https://cogentspec.com', endpoint);
    await writeFile(join(root, file), source);
  }
  const quote = s => "'" + s.replaceAll("'", "''") + "'";
  await writeFile(join(root, 'exercise.ps1'), `$ErrorActionPreference='Stop'
$ContextKey='ctx-'+('a'*64);$contextQuery='context='+$ContextKey
function Invoke-BridgeApi {param($Method,$Path,$Token)
 if($Token -ne 'synthetic-preview-token'){throw 'Wrong token'}
 if($Path.StartsWith('/api/plugin/project-preview-uploads?')){return @{uploads=@(@{id='job-fixture';projectId='project-fixture';runtimeId='runtime-fixture';targetPath=${quote(project)}})}}
 return @{}
}
. (Join-Path $PSScriptRoot 'project-preview-worker.ps1')
Invoke-ProjectPreviewUploads -Token 'synthetic-preview-token'
Write-Output 'PREVIEW_WORKER_FINISHED'
`);
  const child = spawn(shell, ['-NoProfile','-NonInteractive','-File',join(root, 'exercise.ps1')], { windowsHide: true });
  let output = '', errors = ''; child.stdout.on('data', chunk => output += chunk); child.stderr.on('data', chunk => errors += chunk);
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  assert.equal(code, 0, errors); assert.equal(errors, ''); assert.match(output, /PREVIEW_WORKER_FINISHED/);
  assert.doesNotMatch(output, /synthetic-preview-token|PRIVATE_LOCAL_VALUE|Synthetic preview/);
  assert.equal(received.length, 1); assert.equal(received[0].authorization, 'Bearer synthetic-preview-token');
  assert.equal(received[0].body.projectId, 'project-fixture'); assert.equal(received[0].body.files[0].path, 'index.html');
  assert.doesNotMatch(JSON.stringify(received[0].body), /PRIVATE_LOCAL_VALUE|targetPath|\.env/);
});
