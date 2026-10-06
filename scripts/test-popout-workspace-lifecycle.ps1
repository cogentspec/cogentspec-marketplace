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
    @('hidden', $true, $false, $false, $true, 'none'),
    @('blurred', $true, $false, $false, $false, 'none'),
    @('active', $true, $false, $false, $true, 'none'),
    @('closing', $true, $false, $false, $true, 'none'),
    @('closed', $true, $false, $false, $true, 'dismiss'),
    @('unknown', $true, $false, $false, $false, 'none'),
    @('unknown', $true, $true, $false, $false, 'dismiss'),
    @('active', $true, $true, $false, $false, 'none'),
    @('closed', $false, $false, $false, $false, 'none'),
    @('hidden', $true, $false, $true, $false, 'none')
)
foreach ($case in $cases) {
    $actual = [CogentSpec.PopoutWorkspaceLifecycle]::Decide($case[0], $case[1], $case[2], $case[3], $case[4])
    if ($actual -ne $case[5]) { throw "Unexpected lifecycle action for $($case[0]): $actual" }
}
foreach ($state in @('active', 'blurred', 'hidden', 'closing')) {
    foreach ($ownerGone in @($true, $false)) {
        foreach ($popupForeground in @($true, $false)) {
            foreach ($ownerForeground in @($true, $false)) {
                if ([CogentSpec.PopoutWorkspaceLifecycle]::Decide($state, $true, $ownerGone, $popupForeground, $ownerForeground) -ne 'none') {
                    throw "Non-terminal state destroyed Popout: $state"
                }
            }
        }
    }
}
$source = Get-Content -Raw $watcher
if ($source -match 'ShowWindowAsync|SW_HIDE|RetainConnection|Preserve-IntentionalDismissalIdentity') { throw 'Temporary hide/retention workaround must be absent' }
@{status='passed'; cases=$cases.Count; nonTerminalCombinations=32; nativeWindowCallsPerformed=$false} | ConvertTo-Json -Compress
