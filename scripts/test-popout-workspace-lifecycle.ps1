$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($watcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Watcher parse failed' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-PopoutWorkspaceLifecycle' }, $true)
Invoke-Expression $function.Extent.Text
Initialize-PopoutWorkspaceLifecycle
$cases = @(
    @('blurred', $true, $false, $true, $false, 'none'),
    @('hidden', $true, $false, $false, $true, 'hide'),
    @('blurred', $true, $false, $false, $false, 'hide'),
    @('active', $true, $false, $false, $true, 'none'),
    @('closing', $true, $false, $false, $true, 'hide'),
    @('closed', $true, $false, $false, $true, 'dismiss'),
    @('unknown', $true, $false, $false, $false, 'none'),
    @('unknown', $true, $true, $false, $false, 'dismiss'),
    @('active', $true, $true, $false, $false, 'hide'),
    @('closed', $false, $false, $false, $false, 'none'),
    @('hidden', $true, $false, $true, $false, 'none')
)
foreach ($case in $cases) {
    $actual = [CogentSpec.PopoutWorkspaceLifecycle]::Decide($case[0], $case[1], $case[2], $case[3], $case[4])
    if ($actual -ne $case[5]) { throw "Unexpected lifecycle action for $($case[0]): $actual" }
}
$preserveFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Preserve-IntentionalDismissalIdentity' }, $true)
Invoke-Expression $preserveFunction.Extent.Text
$key = 'a' * 64
$absent = [pscustomobject]@{publisherVerified=$true; popupDetected=$false}
$present = [pscustomobject]@{publisherVerified=$true; popupDetected=$true}
$retentionCases = @(
    @($absent, $true, 'identified', $key, $key, $false, $true),
    @($absent, $false, 'identified', $key, $key, $false, $false),
    @($present, $true, 'identified', $key, $key, $false, $false),
    @($absent, $true, 'blank', $key, $key, $false, $false),
    @($absent, $true, 'unknown', $key, $key, $false, $false),
    @($absent, $true, 'identified', $key, ('b' * 64), $false, $false),
    @($absent, $true, 'identified', $key, $key, $true, $false),
    @([pscustomobject]@{publisherVerified=$false; popupDetected=$false}, $true, 'identified', $key, $key, $false, $false)
)
foreach ($case in $retentionCases) {
    $actual = Preserve-IntentionalDismissalIdentity $case[0] $case[1] $case[2] $case[3] $case[4] $case[5]
    if ([bool]$actual -ne $case[6]) { throw 'Intentional dismissal identity gate failed' }
}
$source = Get-Content -Raw $watcher
if ($source -match 'ShowWindowAsync|SW_HIDE') { throw 'Direct Windows hiding must not be present' }
@{status='passed'; cases=$cases.Count; retentionCases=$retentionCases.Count; nativeWindowCallsPerformed=$false} | ConvertTo-Json -Compress
