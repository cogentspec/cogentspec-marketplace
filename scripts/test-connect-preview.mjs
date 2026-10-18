import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

test('inactive licences preserve the installation; unknown access failures never claim a missing licence',async()=>{
  const fixture=await mkdtemp(join(tmpdir(),'cogentspec-connect-preview-'));
  const quote=value=>value.replaceAll("'","''");
  try {
    const source=await readFile(new URL('../plugins/cogentspec/skills/cogentspec/scripts/connect-cogentstack.ps1',import.meta.url),'utf8');
    for(const [http,code,expected,preserved] of [
      [403,'subscription_inactive','licence_required',true],
      [403,'unrecognised_failure','access_check_unavailable',true],
      [401,'installation_revoked','signed_out',false],
    ]) {
      const script=join(fixture,'connect-fixture.ps1');
      const body=source
        .replace(". (Join-Path $PSScriptRoot 'native-command.ps1')",'function Get-CogentSpecExecutionPermissionFailure { return $null }')
        .replace("$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'",`$stateRoot = '${quote(fixture)}'`)
        .replace("if ($Mode -eq 'status') {",`
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$TimeoutSec,$ContentType,$Body)
    $status = if ($Method -eq 'Get') { 401 } else { ${http} }
    $errorCode = if ($Method -eq 'Get') { 'expired' } else { '${code}' }
    $exception = New-Object System.Exception 'Fixture access response'
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=$status})
    $record = New-Object System.Management.Automation.ErrorRecord($exception,'FixtureResponse',[System.Management.Automation.ErrorCategory]::PermissionDenied,$null)
    $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails ('{"code":"' + $errorCode + '"}')
    throw $record
}
@{token=(Protect-CogentSpecValue 'fixture-token');renewalToken=(Protect-CogentSpecValue 'fixture-renewal');connectedAt='fixture'} | ConvertTo-Json | Set-Content -LiteralPath $credentialPath -Encoding UTF8
[IO.File]::Copy($credentialPath,($credentialPath + '.before'),$true)
if ($Mode -eq 'status') {`);
      await writeFile(script,body,'utf8');
      const command=`& '${quote(script)}' -Mode status`;
      // Dummy credentials only, isolated from the real installation and network.
      const run=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(command,'utf16le').toString('base64')],{encoding:'utf8',timeout:30000});
      assert.equal(run.status,0,run.stderr);
      const result=JSON.parse(run.stdout.trim());
      assert.equal(result.status,expected);
      if(preserved) assert.equal(result.credentialPreserved,true);
      assert.doesNotMatch(run.stdout,/fixture-token|fixture-renewal/);
      const remaining=await readFile(join(fixture,'desktop-credential.json'),'utf8').then(()=>true,()=>false);
      assert.equal(remaining,preserved);
      if(preserved) assert.equal(await readFile(join(fixture,'desktop-credential.json'),'utf8'),await readFile(join(fixture,'desktop-credential.json.before'),'utf8'));
    }
  } finally { await rm(fixture,{recursive:true,force:true}); }
});

test('free Web launchers preserve the provider and isolated context without issuing paid handoffs',async()=>{
  const fixture=await mkdtemp(join(tmpdir(),'cogentspec-free-web-preview-'));
  const context='ctx-'+'a'.repeat(64);
  try {
    for(const [packageRoot,provider,commandName] of [['plugins','chatgpt','gptweb'],['claude-plugins','claude-desktop','claudeweb']]) {
      for(const brand of ['cogentspec','cogentstack']) {
        const sourceRoot=new URL(`../${packageRoot}/${brand}/skills/`,import.meta.url);
        const root=join(fixture,packageRoot,brand,'skills');
        const core=join(root,brand,'scripts'),commands=join(root,commandName,'scripts');
        await mkdir(core,{recursive:true});await mkdir(commands,{recursive:true});
        await copyFile(new URL(`${brand}/scripts/project-context.ps1`,sourceRoot),join(core,'project-context.ps1'));
        await copyFile(new URL(`${commandName}/scripts/start-${commandName}.ps1`,sourceRoot),join(commands,`start-${commandName}.ps1`));
        await writeFile(join(core,'start-cogentstack-bridge.ps1'),`param($ContextKey,$Surface,$Experience)\nif ($Surface -cne '${provider}' -or $Experience -cne 'web') { throw 'Wrong provider' }\n$env:COGENTSPEC_FREE_PREVIEW_FIXTURE | Write-Output\n`);
        const target=`https://cogentspec.com/workspace?surface=${provider}&context=${context}&experience=web`;
        for(const previewUrl of [target,target.replace('cogentspec.com','other.invalid'),target.replace(context,'ctx-'+'b'.repeat(64))]) {
          const command=`& '${join(commands,`start-${commandName}.ps1`).replaceAll("'","''")}' -ContextKey '${context}'`;
          const run=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(command,'utf16le').toString('base64')],{encoding:'utf8',timeout:30000,cwd:fixture,env:{...process.env,COGENTSPEC_FREE_PREVIEW_FIXTURE:JSON.stringify({status:'free_web_available',previewUrl})}});
          assert.equal(run.status,0,run.stderr);
          const result=JSON.parse(run.stdout.trim());
          assert.equal(result.status,previewUrl===target?'free_web_available':'invalid_workspace_handoff');
          assert.equal(result.browserNavigationCode,undefined);
          if(previewUrl===target) {
            assert.equal(result.previewUrl,target);assert.equal(result.canUsePaidWorkspace,false);assert.equal(result.currentConversationConnected,false);
          } else assert.equal(result.previewUrl,undefined);
        }
      }
    }
  } finally { await rm(fixture,{recursive:true,force:true}); }
});
