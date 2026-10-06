$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($watcher, [ref]$tokens, [ref]$errors)
if ($errors.Count) {throw 'Watcher parse failed'}
$initializer = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-PopoutWorkspaceLifecycle'}, $true)
Invoke-Expression $initializer.Extent.Text
Initialize-PopoutWorkspaceLifecycle
$script:Count = 0
function Check($model, $state, $visible, $foreground, $now, $expected, $associated=$true, $exists=$true, $ownerGone=$false) {
    $actual = $model.Decide($state, $associated, $exists, $visible, $foreground, $ownerGone, $now)
    if ($actual -ne $expected) {throw "At ${now}, ${state}: expected $expected; got $actual"}
    $script:Count++
}
foreach ($state in @('hidden', 'blurred')) {
    $m = [CogentSpec.PopoutLifecycleModel]::new()
    Check $m 'active' $true $false 0 'none'
    Check $m $state $true $false 1 'hide'
    Check $m $state $false $false 2 'none'
    Check $m 'active' $false $false 3 'restore'
    Check $m 'active' $true $false 4 'none'
}
$m = [CogentSpec.PopoutLifecycleModel]::new()
Check $m 'blurred' $true $true 0 'none'
Check $m 'active' $false $false 1 'none'
Check $m 'hidden' $true $false 2 'hide'
Check $m 'hidden' $true $true 3 'none'
Check $m 'hidden' $true $false 4 'none'
Check $m 'active' $true $false 5 'none'
Check $m 'hidden' $true $false 6 'hide'
Check $m 'unknown' $false $false 7 'none'
Check $m 'closed' $false $false 10 'none'
Check $m 'closed' $false $false 15009 'none'
Check $m 'closed' $false $false 15010 'dismiss'
$m = [CogentSpec.PopoutLifecycleModel]::new()
Check $m 'closed' $true $false 0 'none'
Check $m 'active' $true $false 14000 'none'
Check $m 'closed' $true $false 15000 'none'
Check $m 'closed' $true $false 30000 'dismiss'
$m = [CogentSpec.PopoutLifecycleModel]::new()
Check $m 'unknown' $false $false 0 'none' $true $true $true
Check $m 'unknown' $false $false 15000 'dismiss' $true $true $true
foreach ($state in @('active', 'hidden', 'blurred', 'closed', 'unknown', 'unmanaged')) {
    foreach ($visible in @($true,$false)) {
        foreach ($foreground in @($true,$false)) {
            $m = [CogentSpec.PopoutLifecycleModel]::new()
            Check $m $state $visible $foreground 50000 'none' $false
            Check $m $state $visible $foreground 50000 'none' $true $false
        }
    }
}
@{status='passed'; assertions=$script:Count; nativeWindowCallsPerformed=$false; physicalAcceptance='not_performed'} | ConvertTo-Json -Compress
