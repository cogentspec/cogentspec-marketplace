import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,readdirSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=new URL('../',import.meta.url), source=new URL('plugins/cogentspec/skills/cogentspec/scripts/',root);
const target=new URL('bridge-runtime/gptweb/',root);mkdirSync(new URL('scripts/',target),{recursive:true});
const read=file=>readFileSync(new URL(file,source),'utf8').replaceAll('\r\n','\n');
let launcher=read('start-cogentstack-bridge.ps1');
const scripts=[...launcher.match(/\$sourceScriptNames = @\(([\s\S]*?)\n\)/)[1].matchAll(/'([^']+)'/g)].map(m=>m[1]);
scripts.push('open-chatgpt-desktop-ui.ps1','start-cogentstack-bridge.ps1');
const identity=launcher.slice(launcher.indexOf('$pluginRoot = '),launcher.indexOf('\nfunction Get-HostPowerShellExecutable'));
assert.ok(identity.includes('.codex-plugin')&&identity.includes('.claude-plugin'));
launcher=launcher.replace(identity,`# Standalone runtime identity; no AI plugin manager or skill package is used.
$runtimePackage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\\runtime.json') -Raw | ConvertFrom-Json
if ($runtimePackage.protocol -cne 'cogentspec-standalone-web-runtime-v1') { throw 'Invalid standalone Bridge runtime.' }
$pluginId = 'cogentspec' # Existing worker wire identifier, not an installed plugin.
$pluginVersion = [string]$runtimePackage.bridgeCompatibilityVersion
`);
// First-device approval retains the existing explicit server authorization. It
// returns a private packet and never opens an approval page or approves itself.
launcher=launcher.replace("if ($Surface -eq 'chatgpt' -and $Experience -eq 'split-screen') {\n        if (-not $ResumeApproval)","if ($Surface -eq 'chatgpt' -and $Experience -eq 'web') {\n        if (-not $ResumeApproval)");
for(const name of scripts){
 let text=name==='start-cogentstack-bridge.ps1'?launcher:read(name);
 if(name==='ensure-cogentspec-mcp.ps1')text="throw 'Standalone GPTWeb does not use a Codex MCP or AI plugin connection.'\n";
 writeFileSync(new URL('scripts/'+name,target),text);
}
let command=read('start-workspace-beacon.ps1');
const parameters=command.slice(0,command.indexOf('Set-StrictMode'));
command=command.replace(parameters,()=>`[CmdletBinding()]
param([ValidatePattern('^$|^ctx-[a-f0-9]{64}$')][string]$ContextKey = '')
$Surface = 'chatgpt'
$Experience = 'web'
`);
writeFileSync(new URL('scripts/connect-gptweb.ps1',target),command);
assert.deepEqual(readdirSync(new URL('scripts/',target)).sort(),[...scripts,'connect-gptweb.ps1'].sort(),'Unexpected generated runtime file');
const files={};for(const name of readdirSync(new URL('scripts/',target)).sort()){
 assert.match(name,/^[a-z0-9-]+\.(ps1|mjs)$/);files['scripts/'+name]=createHash('sha256').update(readFileSync(new URL('scripts/'+name,target))).digest('hex');
}
writeFileSync(new URL('runtime.json',target),JSON.stringify({protocol:'cogentspec-standalone-web-runtime-v1',version:'0.1.0',
 repository:'https://github.com/cogentspec/cogentspec-marketplace.git',bridgeCompatibilityVersion:'0.6.171',command:'$gptweb',surface:'chatgpt',experience:'web',
 pluginRequired:false,codexRequired:false,files},null,2)+'\n');
console.log(JSON.stringify({files:Object.keys(files).length,manifestSha256:createHash('sha256').update(readFileSync(new URL('runtime.json',target))).digest('hex')}));
if(process.argv.includes('--public-dir')){
 const revision=execFileSync('git',['rev-parse','HEAD'],{cwd:fileURLToPath(root),encoding:'utf8'}).trim();assert.match(revision,/^[a-f0-9]{40}$/);
 assert.ok(execFileSync('git',['show',revision+':bridge-runtime/gptweb/runtime.json'],{cwd:fileURLToPath(root)}).equals(readFileSync(new URL('runtime.json',target))),'Commit the reviewed runtime before publishing its metadata');
 const directory=resolve(process.argv[process.argv.indexOf('--public-dir')+1]);mkdirSync(directory,{recursive:true});
 const bootstrap=readFileSync(new URL('bridge-runtime/start-gptweb.ps1',root),'utf8').replaceAll('\r\n','\n');
 writeFileSync(join(directory,'start-gptweb.ps1'),bootstrap);
 writeFileSync(join(directory,'release.json'),JSON.stringify({protocol:'cogentspec-standalone-web-release-v1',command:'$gptweb',version:'0.1.0',
  repository:'https://github.com/cogentspec/cogentspec-marketplace.git',sourceDirectory:'bridge-runtime/gptweb',revision,
  manifestSha256:createHash('sha256').update(readFileSync(new URL('runtime.json',target))).digest('hex'),
  bootstrapUrl:'https://cogentspec.app/api/bridge/gptweb/bootstrap',bootstrapSha256:createHash('sha256').update(bootstrap).digest('hex'),
  pluginRequired:false,codexRequired:false},null,2)+'\n');
}
