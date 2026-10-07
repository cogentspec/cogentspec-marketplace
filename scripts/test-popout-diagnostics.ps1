$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts'
$source=Get-Content -Raw (Join-Path $root 'capture-popout-diagnostics.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
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
  $script:started++;$p=[DiagnosticFixtureProcess]::new();$script:processes+=,$p
  $pending=[Threading.Tasks.TaskCompletionSource[string]]::new()
  return @{process=$p;line=$pending.Task;started=[DateTime]::UtcNow}
 }
 function Read-Worker {return @{kind='worker';visible=$false;verified=$false}}
 function Start-Sleep {param($Milliseconds)}
 try {. $block}catch{if($scenario -ne 'upload-fails'){throw}}
 if($scenario -in @('wrong-session','wrong-worker','lost-claim') -and $started -ne 0){throw 'Unowned capture inspected native UI'}
 if($scenario -in @('stop','upload-fails')) {
  if($writes -ne 2 -or $started -ne 2){throw 'Capture pipeline was not exercised'}
  if(@($processes|Where-Object {!$_.Killed}).Count){throw 'Owned reader process leaked'}
 }
 Write-Output "PASS: collector $scenario"
}
Write-Output 'PASS: policy import, privacy, read-only contract, opt-in/session/worker fences, real orchestration and child cleanup; no native UI accessed.'
