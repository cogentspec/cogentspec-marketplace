import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const runners = [
  '../plugins/cogentspec/skills/cogentspec/scripts/provision-project-credentials.mjs',
  '../plugins/cogentstack/skills/cogentstack/scripts/provision-project-credentials.mjs',
  '../claude-plugins/cogentspec/skills/cogentspec/scripts/provision-project-credentials.mjs',
  '../claude-plugins/cogentstack/skills/cogentstack/scripts/provision-project-credentials.mjs',
  '../web-bridge/v1/runtime/provision-project-credentials.mjs',
];

for (const path of runners) {
  const { credentialAdapterEnvironment, provisionInitialCredentials } = await import(path);
  test(`${path}: keeps Windows plugin paths and excludes unrelated credentials`, () => {
    assert.deepEqual(credentialAdapterEnvironment({
      Path:'bin', PROGRAMFILES:'programs', ProgramW6432:'programs64', USERPROFILE:'profile',
      SystemRoot:'windows', TEMP:'temp', TMP:'tmp', HOME:'home',
      COGENTSTACK_AUTH_SECRET:'must-not-reach-adapter', OPENAI_API_KEY:'must-not-reach-adapter',
      DOCKER_AUTH_CONFIG:'must-not-reach-adapter', NODE_OPTIONS:'--require=untrusted',
    }), { Path:'bin', PROGRAMFILES:'programs', ProgramW6432:'programs64', USERPROFILE:'profile',
      SystemRoot:'windows', TEMP:'temp', TMP:'tmp', HOME:'home' });
  });
  test(`${path}: real adapter subprocess receives plugin paths without ambient secrets`, () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'cogentspec-credential-env-')));
    const programFilesKey=Object.keys(process.env).find(key=>key.toLowerCase()==='programfiles')||'ProgramFiles';
    const previous = { [programFilesKey]:process.env[programFilesKey], COGENTSTACK_AUTH_SECRET:process.env.COGENTSTACK_AUTH_SECRET };
    const expectedPluginPath=process.env[programFilesKey]||'synthetic-docker-plugin-root';
    try {
      if(!process.env[programFilesKey])process.env[programFilesKey]=expectedPluginPath;
      process.env.COGENTSTACK_AUTH_SECRET = 'synthetic-secret-excluded';
      mkdirSync(join(root,'.coge'));
      writeFileSync(join(root,'.coge/knowledge-manifest.json'), JSON.stringify({project:{requestId:'project-a'},binding:{packRef:'pack@1.0.0',releaseMode:'local'}}));
      writeFileSync(join(root,'.coge/credential-provisioner.mjs'), `
        let text=''; for await(const part of process.stdin)text+=part;
        const input=JSON.parse(text);
        const pluginPath=Object.entries(process.env).find(([key])=>key.toLowerCase()==='programfiles')?.[1];
        if(pluginPath!==${JSON.stringify(expectedPluginPath)}||process.env.COGENTSTACK_AUTH_SECRET)process.exit(2);
        process.stdout.write(JSON.stringify({jobId:input.jobId,projectId:input.projectId,status:'applied',loginVerified:true,unauthenticatedDenied:true,persisted:true}));
      `);
      assert.equal(provisionInitialCredentials({targetPath:root,projectId:'project-a',runtimeId:'runtime-a',packRef:'pack@1.0.0',
        mode:'provision_initial',id:'job-a',entryId:'entry-a',kind:'backend',loginName:'synthetic@example.invalid',password:'synthetic-test-only'}), 'applied');
    } finally {
      for(const [key,value] of Object.entries(previous)){if(value===undefined)delete process.env[key];else process.env[key]=value;}
      assert.match(root.replaceAll('\\','/'), /\/cogentspec-credential-env-[^/]+$/);
      rmSync(root,{recursive:true});
    }
  });
}

test('Windows Docker Compose is discoverable in the exact credential adapter environment', {skip:process.platform!=='win32'}, async () => {
  const {credentialAdapterEnvironment}=await import(runners[0]);
  const probe=spawnSync('docker',['compose','version','--short'],{encoding:'utf8',timeout:15000,windowsHide:true});
  if(probe.error?.code==='ENOENT')return;
  assert.equal(probe.status,0,'The installed Docker Compose baseline must work.');
  const result=spawnSync('docker',['compose','version','--short'],{env:credentialAdapterEnvironment(),encoding:'utf8',timeout:15000,windowsHide:true});
  assert.equal(result.status,0,'Compose must also be available inside the private credential worker.');
  assert.equal(result.stdout.trim(),probe.stdout.trim());
});
