import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
const root=new URL('../',import.meta.url),file='skills/cogentspec/scripts/project-update.ps1';
test('all four published native packages contain the same bounded project-update reporter',async()=>{
 const canonical=await readFile(new URL('plugins/cogentspec/'+file,root),'utf8');
 for(const host of ['plugins','claude-plugins'])for(const id of ['cogentspec','cogentstack'])assert.equal((await readFile(new URL(`${host}/${id}/skills/${id}/scripts/project-update.ps1`,root),'utf8')).replaceAll('\r\n','\n'),canonical.replaceAll('\r\n','\n'));
 assert.doesNotMatch(canonical,/Start-Process|Invoke-Expression|Write-Output \$token|Write-Host \$token/);
});
for(const shell of ['powershell.exe','pwsh.exe'])test(`${shell}: native reporter uses only the exact authorized update endpoint and rejects invalid payloads without leaking failures`,{skip:process.platform!=='win32'},async t=>{
 const base=resolve(tmpdir()),folder=await mkdtemp(join(base,'coge-update-reporter-'));
 t.after(async()=>{const target=await realpath(folder);assert.ok(target.startsWith(base+ '\\')&&target!==base);await rm(target,{recursive:true,force:true});});
 const helper=decodeURIComponent(new URL('plugins/cogentspec/'+file,root).pathname.slice(1)).replaceAll('/','\\'),quote=s=>"'"+s.replaceAll("'","''")+"'";
 const program=`$ErrorActionPreference='Stop'
$fixtureRoot=${quote(folder)}
$source=Get-Content -LiteralPath ${quote(helper)} -Raw
$original="$"+"credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\\desktop-credential.json'"
if(-not $source.Contains($original)){throw 'Credential location marker missing'}
$source=$source.Replace($original,'$credentialPath = Join-Path $fixtureRoot ''desktop-credential.json''')
$run=[scriptblock]::Create($source)
if($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])){try{Add-Type -AssemblyName System.Security.Cryptography.ProtectedData}catch{Add-Type -AssemblyName System.Security}}
$token='synthetic-update-test-token'
$protected=[Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
@{token=[Convert]::ToBase64String($protected)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $fixtureRoot 'desktop-credential.json')
$context='ctx-'+('a'*64);$id=[guid]'11111111-2222-4333-8444-555555555555';$script:calls=@();$script:fail=$false
function Invoke-RestMethod {param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
 if($TimeoutSec -ne 30 -or $Headers.Authorization -ne 'Bearer synthetic-update-test-token'){throw 'Invalid request'}
 $script:calls+=@{method=$Method;uri=[string]$Uri;body=$Body}
 if($script:fail){throw 'private-response synthetic-update-test-token'}
 return @{accepted=$true}
}
function Check($value,$message){if(-not $value){throw $message}}
$read=& $run -ContextKey $context -UpdateId $id|ConvertFrom-Json
Check ($read.accepted -and $script:calls.Count -eq 1 -and $script:calls[0].method -eq 'Get') 'Read failed'
Check ($script:calls[0].uri -eq "https://cogentspec.com/api/plugin/project-updates?context=$context&updateId=$id") 'Wrong endpoint'
$payload=Join-Path $fixtureRoot 'report.json'
@{updateId=[string]$id;action='acknowledge';revision=1}|ConvertTo-Json|Set-Content -LiteralPath $payload
$sent=& $run -ContextKey $context -UpdateId $id -PayloadPath $payload|ConvertFrom-Json
Check ($sent.accepted -and $script:calls.Count -eq 2 -and $script:calls[1].method -eq 'Post') 'Report failed'
$wire=[Text.Encoding]::UTF8.GetString($script:calls[1].body)|ConvertFrom-Json
Check ($wire.updateId -eq [string]$id -and $wire.revision -eq 1) 'Report payload changed'
foreach($case in @('oversized','mismatch','unsupported')){
 $before=$script:calls.Count
 if($case -eq 'oversized'){'x'*16385|Set-Content -LiteralPath $payload}else{@{updateId=if($case -eq 'mismatch'){'aaaaaaaa-2222-4333-8444-555555555555'}else{[string]$id};action=if($case -eq 'unsupported'){'execute'}else{'acknowledge'}}|ConvertTo-Json|Set-Content -LiteralPath $payload}
 $rejected=& $run -ContextKey $context -UpdateId $id -PayloadPath $payload|ConvertFrom-Json
 Check ($rejected.status -eq 'update_report_not_confirmed' -and $script:calls.Count -eq $before) ('Unsafe local payload: '+$case)
}
$script:fail=$true;$failure=& $run -ContextKey $context -UpdateId $id
Check (-not (($failure -join '') -match 'private-response|synthetic-update-test-token')) 'Private failure leaked'
Check (($failure|ConvertFrom-Json).status -eq 'update_report_not_confirmed') 'Failure unconfirmed'
Write-Output '{"fixture":"project-update-reporter","passed":true,"liveRequests":0,"realCredentialsRead":false}'
`;
 const fixture=join(folder,'exercise.ps1');await writeFile(fixture,program);
 const result=spawnSync(shell,['-NoProfile','-NonInteractive','-File',fixture],{encoding:'utf8',timeout:30000,windowsHide:true});
 assert.equal(result.status,0,result.stdout+result.stderr);assert.match(result.stdout,/'?"passed":true/);assert.equal(result.stderr.trim(),'');
});
