import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import test from 'node:test';

const root = resolve(import.meta.dirname, '..');
const read = path => readFileSync(resolve(root, path), 'utf8').replaceAll('\r\n', '\n').trimEnd();

// Instructions are shipped twice for each host. A fix must not leave the
// compatibility command executing a different sequence or reporting policy.
for (const [host, commands] of [
  ['plugins', ['gptsnap', 'gptdesk', 'gptweb']],
  ['claude-plugins', ['claudesnap', 'claudedesk', 'claudeweb']],
]) {
  for (const command of commands) {
    test(`${host}: ${command} canonical/compatibility flow parity`, () => {
      const canonical = read(`${host}/cogentspec/skills/${command}/SKILL.md`);
      const compatibility = read(`${host}/cogentstack/skills/${command}/SKILL.md`)
        .replaceAll('../cogentstack/', '../cogentspec/')
        .replaceAll('\\skills\\cogentstack\\', '\\skills\\cogentspec\\');
      assert.equal(compatibility, canonical);
    });
  }
}

function filesUnder(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? filesUnder(path) : [path];
  });
}

test('GPTSnap installed startup executable is identical in both packages', () => {
  assert.equal(read('plugins/cogentspec/skills/gptsnap/scripts/start-gptsnap.ps1'),
    read('plugins/cogentstack/skills/gptsnap/scripts/start-gptsnap.ps1'));
});

test('GPTSnap acknowledgement client is identical in both packages', () => {
  assert.equal(read('plugins/cogentspec/skills/gptsnap/scripts/gptsnap-client.mjs'),
    read('plugins/cogentstack/skills/gptsnap/scripts/gptsnap-client.mjs'));
});

// Guard the exact public file-set boundary that previously broke all commands.
// This deliberately reads each installer's real allowlist instead of copying it.
for (const plugin of ['cogentspec', 'cogentstack']) {
  test(`${plugin}: command update preserves trusted package inventory`, () => {
    const installer = read(`.agents/plugins/install-${plugin}.ps1`);
    const allowedBlock = /\$allowedFiles = @\(([\s\S]*?)\n    \)/.exec(installer);
    assert.ok(allowedBlock, 'Installer must declare an exact public allowlist');
    const allowed = [...allowedBlock[1].matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
    const packageRoot = resolve(root, 'plugins', plugin);
    const actual = filesUnder(packageRoot).map(path => relative(packageRoot, path).replaceAll('\\', '/')).sort();
    assert.deepEqual(actual, allowed);
  });
}
