import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('gptweb verifies separately prepared setup while its legacy launcher stays isolated',async()=>{
 for(const plugin of ['cogentspec','cogentstack']) {
  const root=new URL('../plugins/'+plugin+'/skills/gptweb/',import.meta.url);
  const skill=await readFile(new URL('SKILL.md',root),'utf8');
  const script=await readFile(new URL('scripts/start-gptweb.ps1',root),'utf8');
  assert.ok(skill.includes('gptweb-setup/v1/PROCEDURE.md'));
  assert.match(skill,/retain the same URL/);assert.match(skill,/projectReadUrl/);assert.match(skill,/acknowledgeUrl/);
  assert.match(skill,/do not ask for another copy merely because setup is pending/);
  assert.match(skill,/existing `curl` or Python/);assert.match(skill,/AI session's own Linux/);
  assert.match(script,/ManifestSha256/);assert.match(script,/Get-FileHash/);
  assert.ok(script.includes("-Command '$gptweb'"));
  assert.doesNotMatch(script,/start-cogentstack-bridge|browserNavigationCode|start-workspace-beacon|Start-Process|open_in_codex/);
 }
 const procedure=await readFile(new URL('../gptweb-setup/v1/PROCEDURE.md',import.meta.url),'utf8');
 assert.match(procedure,/project_read_required/);assert.match(procedure,/Page polling and helper heartbeats cannot create or renew AI authorization/);
 assert.match(procedure,/workspaceConnected:true/);assert.match(procedure,/acknowledgementVerified:true/);
 assert.match(procedure,/fresh HTTPS request/);assert.match(procedure,/Linux execution is sufficient/);
 assert.match(procedure,/leave the connection unverified/);
 assert.match(procedure,/Moving focus, hiding the work area or normal idle time does not disconnect/);
 assert.match(procedure,/until its returned `expiresAt`/);assert.doesNotMatch(procedure,/inactive after five minutes/);
});
