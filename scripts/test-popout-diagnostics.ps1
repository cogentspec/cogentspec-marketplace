param([switch]$EmitWireFixtures)
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts'
$source=Get-Content -Raw (Join-Path $root 'capture-popout-diagnostics.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
if($EmitWireFixtures) {
 # Run the production marker reader AND HTTP serializer with synthetic data.
 # No native UI, real marker, credential or network is accessed.
 foreach($name in @('Read-Worker','Request')) {
  $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  if(!$function){throw "Missing production function $name"}
  Invoke-Expression $function.Extent.Text
 }
 $config=@{id='aaaaaaaa-1111-1111-1111-111111111111';service='https://cogentspec.com';token='fixture-only'}
 function Get-Content {param($LiteralPath,[switch]$Raw) $script:fixtureMarker}
 function Invoke-RestMethod {param($Method,$Uri,$Headers,$TimeoutSec,$MaximumRedirection,$ContentType,$Body) $Body}
 try {
  foreach($count in @(0,1,2,64)) {
   $attempts=@(for($i=0;$i -lt $count;$i++){@{sequence=$i+1;status='target_hidden';nativeCalled=$false;handle=22;foregroundHandle=10;at='2026-10-08T06:15:37.0000000Z';text='private-fixture'}})
   $script:fixtureMarker=@{pluginVersion='fixture';pinCaptureSession=$config.id;pinAttempts=$attempts}|ConvertTo-Json -Depth 6
   Request Post @{sequence=$count;evidence=@{kind='capture_batch';samples=@((Read-Worker))}}
  }
 } finally {Remove-Item Function:\Get-Content;Remove-Item Function:\Invoke-RestMethod}
 return
}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Import-DecisionFunctions'},$true)
Invoke-Expression $fn.Extent.Text
Import-DecisionFunctions (Join-Path $root 'open-chatgpt-popup.ps1')
if((Get-ChatGptPopupStartupDecision 'unknown' $false) -ne 'stop_unverified'){throw 'Production function import lost parameters'}
if((Resolve-ChatGptPopupDiscovery @()).state -ne 'absent'){throw 'Evidence import failed'}
if($source -match 'SendInput|SetForegroundWindow|ShowWindow|WM_CLOSE|Read-Host'){throw 'Collector must not mutate UI or require console interaction'}
if($source -match 'Current.Value|TextPattern|WindowText'){throw 'Collector reads forbidden content'}

# Execute the real collector orchestration with fake network and reader processes.
# No native entrypoint, process enumeration, UIA, account token or HTTP is used.
Add-Type @'
using System;
using System.Threading.Tasks;
public class DiagnosticFixtureProcess {
 public bool HasExited=false;public int ExitCode=0;public bool Killed=false;
 public void Kill(){Killed=true;HasExited=true;}public void Dispose(){}
}
'@
$start=$source.IndexOf("try {`n    # Recheck")
if($start -lt 0){$start=$source.IndexOf("try {`r`n    # Recheck")}
if($start -lt 0){throw 'Collector orchestration not found'}
$block=[scriptblock]::Create($source.Substring($start))
foreach($scenario in @('stop','wrong-session','wrong-worker','lost-claim','upload-fails')) {
 $config=@{id='aaaaaaaa-1111-1111-1111-111111111111';worker='bbbbbbbb-1111-1111-1111-111111111111'}
 $deadline=[DateTime]::UtcNow.AddSeconds(2);$jobs=@{};$sequence=0;$lastUia=[DateTime]::MinValue
 $script:reads=0;$script:writes=0;$script:started=0;$script:processes=@()
 function Request([string]$Method,$Body=$null) {
  if($Method -eq 'Post'){$script:writes++;if($scenario -eq 'upload-fails' -and $script:writes -gt 1){throw 'fixture transport loss'};return @{accepted=($scenario -ne 'lost-claim')}}
  $script:reads++
  if($scenario -eq 'wrong-session'){return @{capture=@{id='other'}}}
  if($scenario -eq 'wrong-worker'){return @{capture=@{id=$config.id;worker='other'}}}
  if($script:reads -gt 2){return @{capture=$null}}
  return @{capture=@{id=$config.id;worker=$null}}
 }
 function Start-Reader([string]$Kind) {
  if($Kind -eq 'uia'){throw 'Passive capture must not start a competing accessibility inspector'}
  $script:started++;$p=[DiagnosticFixtureProcess]::new();$script:processes+=,$p
  $pending=[Threading.Tasks.TaskCompletionSource[string]]::new()
  return @{process=$p;line=$pending.Task;started=[DateTime]::UtcNow}
 }
 function Read-Worker {return @{kind='worker';visible=$false;verified=$false}}
 function Start-Sleep {param($Milliseconds)}
 try {. $block}catch{if($scenario -ne 'upload-fails'){throw}}
 if($scenario -in @('wrong-session','wrong-worker','lost-claim') -and $started -ne 0){throw 'Unowned capture inspected native UI'}
 if($scenario -in @('stop','upload-fails')) {
  if($writes -ne 2 -or $started -ne 1){throw 'Capture pipeline was not exercised'}
  if(@($processes|Where-Object {!$_.Killed}).Count){throw 'Owned reader process leaked'}
 }
 Write-Output "PASS: collector $scenario"
}
Write-Output 'PASS: policy import, privacy, read-only contract, opt-in/session/worker fences, real orchestration and child cleanup; no native UI accessed.'

# Execute marker ingestion, including legacy and cross-session markers, without
# touching real worker state. Pin evidence must survive JSON and stay scoped.
$reader=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-Worker'},$true)
Invoke-Expression $reader.Extent.Text
$config=@{id='aaaaaaaa-1111-1111-1111-111111111111'}
$script:fixtureMarker=@{pluginVersion='fixture';pinCaptureSession=$config.id;pinAttempts=@(@{sequence=1;status='no_verified_target';nativeCalled=$false})}|ConvertTo-Json -Depth 6
function Get-Content {param($LiteralPath,[switch]$Raw) $script:fixtureMarker}
try {
 $m=Read-Worker
 if(!$m.pinTraceAvailable -or $m.pinAttempts[0].status -ne 'no_verified_target'){throw 'Pin trace lost in collector'}
 foreach($count in @(0,1,2,64)) {
  $attempts=@(for($i=0;$i -lt $count;$i++){@{sequence=$i+1;status='target_hidden'}})
  $script:fixtureMarker=@{pinCaptureSession=$config.id;pinAttempts=$attempts}|ConvertTo-Json -Depth 6
  $wire=@{samples=@((Read-Worker))}|ConvertTo-Json -Depth 10 -Compress
  $roundtrip=$wire|ConvertFrom-Json
  if($roundtrip.samples[0].pinAttempts -isnot [array] -or $roundtrip.samples[0].pinAttempts.Count -ne $count){throw "Pin array lost on JSON roundtrip: $count"}
 }
 $config.id='bbbbbbbb-1111-1111-1111-111111111111';$m=Read-Worker
 if($m.pinTraceAvailable -or $m.pinAttempts.Count){throw 'Foreign capture evidence leaked'}
 if($m.pinAttempts -isnot [array]){throw 'Foreign capture must emit an empty array'}
 $script:fixtureMarker='{"pluginVersion":"legacy"}';$m=Read-Worker
 if($m.pinTraceAvailable -or $m.pinAttempts.Count){throw 'Legacy marker fabricated trace coverage'}
 if($m.pinAttempts -isnot [array]){throw 'Legacy marker must emit an empty array'}
} finally {Remove-Item Function:\Get-Content}
Write-Output 'PASS: pin attempt ingestion, unavailable legacy coverage and capture-session isolation.'
