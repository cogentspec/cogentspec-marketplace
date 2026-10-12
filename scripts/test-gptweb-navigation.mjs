import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';

// The launcher fixture is piped directly from PowerShell. No private URL is
// written to a file, clipboard, local server, or console output.
let raw = '';
for await (const chunk of process.stdin) raw += chunk;
const result = JSON.parse(raw.replace(/^\uFEFF/, ''));
assert.equal(result.browserNavigationProtocol, 'cogentspec-gptweb-navigation-v1');
let calls = 0;
const tab = { async goto(url) {
  calls++;
  assert.equal(url, result.workspaceUrl, 'Navigation must preserve the entire verified URL');
  const target = new URL(url);
  assert.equal(target.searchParams.get('context'), result.contextKey);
  assert.equal(target.searchParams.get('experience'), 'web');
  assert.equal(target.searchParams.get('open'), 'web');
  assert.match(target.hash, /^#desktop-web=cgw_[A-Za-z0-9_-]{32,}$/);
}};
await runInNewContext('(async () => {' + result.browserNavigationCode + '})()', { gptWebTab: tab }, { timeout: 1000 });
assert.equal(calls, 1, 'The prepared browser call must navigate exactly once');
console.log('DIRECT_BROWSER_NAVIGATION_VERIFIED=true');
