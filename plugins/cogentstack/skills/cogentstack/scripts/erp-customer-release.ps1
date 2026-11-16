param([ValidateSet('status','initialize','build','refresh')][string]$Mode='status',[string]$Version='1.0.0',[string]$ContextKey='',[switch]$Wait,[ValidateRange(10,7200)][int]$TimeoutSeconds=3600)
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
 if($Mode -eq 'refresh'){
  # Package metadata is internal. The user keeps the same visible layer number.
  $source=[string]$handoff.erpCustomerBuild.sourceDirectory
  $metadata=Get-Content -LiteralPath (Join-Path $source 'pyproject.toml') -Raw
  if($metadata -notmatch '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"\s*$'){throw 'The selected customer package metadata is unavailable.'}
  $Version=$Matches[1]
 }
 $body=if($Mode -eq 'status'){@{action='status';workId=$work.id}}else{@{action='request';workId=$work.id;input=@{action=$Mode;version=$Version;workRevision=$work.updatedAt}}}
 $result=Invoke-RestMethod -Method Post -Uri "https://cogentspec.com/api/plugin/erp-customer-releases?$query" -Headers $headers -MaximumRedirection 0 -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 30
 if($Wait -and $Mode -ne 'status'){
  $operationId=[string]$result.id;$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do{
   Start-Sleep -Seconds 5
   $statusBody=@{action='status';workId=$work.id}|ConvertTo-Json -Compress
   $view=Invoke-RestMethod -Method Post -Uri "https://cogentspec.com/api/plugin/erp-customer-releases?$query" -Headers $headers -MaximumRedirection 0 -ContentType 'application/json' -Body $statusBody -TimeoutSec 30
   $result=@($view.releases|Where-Object {$_.id -ceq $operationId})|Select-Object -First 1
   if(-not $result){throw 'The layer update could not be found.'}
   if($result.state -in @('failed','recovery_required')){throw 'The layer update failed. Inspect its retained operation journal; do not retry over a recovery hold.'}
   if($Mode -eq 'refresh' -and $result.state -eq 'deployed'){
    # Activation is not proof that the platform's inspection address has caught
    # up. Wait for the existing installation worker to report this exact image.
    $checked=Invoke-RestMethod -Method Get -Uri "https://cogentspec.com/api/plugin/project-changes?$query" -Headers $headers -MaximumRedirection 0 -TimeoutSec 30
    if($checked.erpCustomisation.id -cne $work.id -or $checked.erpCustomisation.updatedAt -cne $work.updatedAt){throw 'The selected layer changed while refreshing.'}
    $target=$checked.erpInspection.target
    if($target.status -eq 'ready' -and $target.target.releaseId -ceq $operationId -and $target.target.viewedWorkId -ceq $work.id){
     $result|Add-Member -NotePropertyName interfaceUrl -NotePropertyValue ([string]$target.target.localUrl) -Force
     break
    }
   }elseif($result.state -in @('complete','candidate','deployed')){break}
  }while([DateTime]::UtcNow -lt $deadline)
  if($result.state -notin @('complete','candidate','deployed') -or ($Mode -eq 'refresh' -and -not $result.PSObject.Properties['interfaceUrl'])){
   @{status='in_progress';id=$operationId;message='The layer update is still running. Use status; do not queue another update.'}|ConvertTo-Json -Compress;exit 0
  }
 }
 $result|ConvertTo-Json -Depth 14 -Compress
}catch{ @{status='customer_release_unavailable';error='The current customer build helper could not confirm this operation. Check its workspace status.'}|ConvertTo-Json -Compress;exit 1 }
finally{$token=$null;if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
