import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const root = new URL('../', import.meta.url), target = new URL('web-bridge/v1/', root);
const baseline = '2fe075a1b10e000a573cc0fbc808d9f3cbc2bf7f';
const sourceRoot = 'plugins/cogentspec/skills/cogentspec/scripts/';
const source = file => execFileSync('git', ['show', baseline + ':' + sourceRoot + file], { cwd: root, encoding: 'utf8', windowsHide: true }).replaceAll('\r\n','\n');
// This immutable snapshot has exactly two consumers. Never refresh it implicitly
// from current common code when changing another connector.
if (process.argv.includes('--initialize-snapshot')) {
  const start = source('start-cogentstack-bridge.ps1');
  const files = [...start.match(/\$sourceScriptNames = @\(([\s\S]*?)\n\)/)[1].matchAll(/'([^']+)'/g)].map(m => m[1]);
  mkdirSync(new URL('runtime/',target), { recursive: true });
  for (const file of files.filter(name => !['ensure-cogentspec-mcp.ps1','open-chatgpt-popup.ps1','open-claude-desktop-ui.ps1','watch-cogentstack-bridge.ps1'].includes(name))) {
    writeFileSync(new URL('runtime/'+file,target),source(file));
  }
  let worker = source('watch-cogentstack-bridge.ps1');
  worker = worker.replace("[Parameter(Mandatory = $true)][string]$ReadyPath", "[Parameter(Mandatory = $true)][ValidateSet('gptweb','claudeweb')][string]$WebCommand,\n    [Parameter(Mandatory = $true)][string]$ReadyPath");
  worker = worker.replace('Local\\CogentSpecBridge-$contextHash','Local\\CogentSpecWebV1-$WebCommand-$contextHash');
  // Web does not offer Desktop/Popout window operations.
  worker = worker.replace(/^\s*'(?:open_chatgpt_popup|set_chatgpt_popup_topmost|set_chatgpt_desktop_topmost|set_claude_desktop_topmost)' \{ @?\([^\n]*\}|^\s*'(?:open_chatgpt_popup|set_chatgpt_popup_topmost|set_chatgpt_desktop_topmost|set_claude_desktop_topmost)' \{ '[^\n]*\}\r?$/gm,'');
  // Remove only single-line dispatcher entries. Other descriptive result text
  // is inert; unsupported actions fail before it can be reached.
  worker = worker.replace(/^\s*'(?:open_chatgpt_popup|set_chatgpt_popup_topmost|set_chatgpt_desktop_topmost|set_claude_desktop_topmost)' \{ '[^\n]*\}\r?$/gm,'');
  worker = worker.replace('            $request = $listing.request\n', () => `            $request = $listing.request
            # Another connector may use the same project context. Leave its
            # window/control actions unclaimed for that connector's worker.
            if ([string]$request.action -notin @('create_specification','delete_specification','create_project','delete_project','preview_project',
                'refresh_project_git','save_project_git','restore_project_version','prepare_development_handoff')) {
                Start-Sleep -Seconds 2
                continue
            }
`);
  writeFileSync(new URL('runtime/watch-web-worker.ps1',target),worker);
}
const files = Object.fromEntries(readdirSync(new URL('runtime/',target)).sort().map(file => {
  if (!/^[a-z0-9-]+\.(ps1|mjs)$/.test(file)) throw new Error('Unexpected runtime file: '+file);
  return ['runtime/'+file,createHash('sha256').update(readFileSync(new URL('runtime/'+file,target))).digest('hex')];
}));
writeFileSync(new URL('manifest.json',target),JSON.stringify({ protocol:'cogentspec-web-runtime-v1',version:'1.0.0',
  commands:['$gptweb','$claudeweb'],bridgeCompatibilityVersion:'0.6.175',sourceSnapshot:baseline,files },null,2)+'\n');
console.log(JSON.stringify({files:Object.keys(files).length,manifestSha256:createHash('sha256').update(readFileSync(new URL('manifest.json',target))).digest('hex')}));
