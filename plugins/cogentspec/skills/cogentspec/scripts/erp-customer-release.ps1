param([ValidateSet('status','initialize','build')][string]$Mode='status',[string]$Version='1.0.0',[string]$ContextKey='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'project-context.ps1')
$context=Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$query='context='+[Uri]::EscapeDataString([string]$context.ContextKey)
$path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
$token=$null;$bytes=$null
try {
 if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Connect this computer first.'}
 if($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])){Add-Type -AssemblyName System.Security}
 $credential=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
 $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
 $token=[Text.Encoding]::UTF8.GetString($bytes)
 $headers=@{Authorization="Bearer $token";Accept='application/json'}
 $handoff=Invoke-RestMethod -Method Get -Uri "https://cogentspec.com/api/plugin/project-changes?$query" -Headers $headers -MaximumRedirection 0 -TimeoutSec 30
 if(-not $handoff.erpCustomisation -or $handoff.project.projectType -ne 'erpnext_business_app'){throw 'Open this ERP customer customisation first.'}
 $work=$handoff.erpCustomisation
 $body=if($Mode -eq 'status'){@{action='status';workId=$work.id}}else{@{action='request';workId=$work.id;input=@{action=$Mode;version=$Version;workRevision=$work.updatedAt}}}
 $result=Invoke-RestMethod -Method Post -Uri "https://cogentspec.com/api/plugin/erp-customer-releases?$query" -Headers $headers -MaximumRedirection 0 -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 30
 $result|ConvertTo-Json -Depth 14 -Compress
}catch{ @{status='customer_release_unavailable';error='The current customer build helper could not confirm this operation. Check its workspace status.'}|ConvertTo-Json -Compress;exit 1 }
finally{$token=$null;if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
