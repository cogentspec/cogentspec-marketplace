$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$source=Get-Content -Raw -LiteralPath $watcher
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($watcher,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Watcher parse failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-PopoutWorkspaceLifecycle'},$true)
if($fn.Extent.Text -match 'browser-lifecycle|local_extension|awaiting_extension|SendKeys|keybd_event|SendInput'){throw 'Extension or synthetic shortcuts remain'}
Invoke-Expression $fn.Extent.Text
Initialize-PopoutWorkspaceLifecycle
$count=0
function Check($m,$state,$exists,$visible,$popupFocus,$workFocus,$expected){
 $actual=$m.Decide($state,$exists,$visible,$popupFocus,$workFocus)
 if($actual -ne $expected){throw "$state expected $expected got $actual"}
 $script:count++
}
foreach($away in @('hidden','blurred')){
 $m=[CogentSpec.PopoutLifecycleModel]::new()
 Check $m 'active' $true $true $false $true 'none'
 Check $m $away $true $true $false $false 'hide'
 Check $m $away $true $false $false $false 'none'
 Check $m 'active' $true $false $false $false 'none'
 Check $m 'active' $true $false $false $true 'restore'
 Check $m 'active' $true $true $false $true 'none'
}
$m=[CogentSpec.PopoutLifecycleModel]::new()
Check $m 'blurred' $true $true $true $false 'none'
Check $m 'hidden' $true $true $false $false 'hide'
Check $m 'hidden' $true $true $true $false 'none'
Check $m 'hidden' $true $true $false $false 'none'
Check $m 'active' $true $true $false $true 'none'
Check $m 'hidden' $true $true $false $false 'hide'
foreach($state in @('unknown','departed','closing','closed','disconnected','unmanaged')){
 $m=[CogentSpec.PopoutLifecycleModel]::new()
 Check $m $state $true $true $false $false 'none'
 Check $m $state $true $false $false $true 'none'
}
$m=[CogentSpec.PopoutLifecycleModel]::new()
Check $m 'hidden' $true $true $false $false 'hide'
Check $m 'active' $false $false $false $true 'none'
Check $m 'active' $true $false $false $true 'none'
Check $m 'close' $true $false $false $false 'close'
Check $m 'close' $false $false $false $false 'none'
$mirror=Join-Path $PSScriptRoot '..\plugins\cogentstack\skills\cogentstack\scripts\watch-cogentspec-popout-bridge.ps1'
if((Get-Content -Raw $mirror) -ne $source){throw 'Watcher mirrors differ'}
@{status='passed';assertions=$count;nativeWindowCallsPerformed=$false;physicalAcceptance='not_performed'}|ConvertTo-Json -Compress
