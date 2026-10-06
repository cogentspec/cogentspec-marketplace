$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/watch-cogentspec-popout-bridge.ps1'
$source = Get-Content -LiteralPath $path -Raw
$match = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Native source not found.' }
Add-Type -TypeDefinition $match.Groups[1].Value
foreach ($state in @('active', 'blurred', 'hidden', 'unknown')) {
    foreach ($verified in @($false, $true)) {
        foreach ($pinned in @($false, $true)) {
            foreach ($known in @($false, $true)) {
                foreach ($inPopup in @($false, $true)) {
                    $expected = $verified -and $pinned -and $known -and
                        ($state -eq 'hidden' -or ($state -eq 'blurred' -and -not $inPopup))
                    $actual = [CogentSpec.ChatGptPopupPinHotkey]::ShouldAutoUnpin($state, $verified, $pinned, $known, $inPopup)
                    if ($expected -ne $actual) { throw "Unpin gate failed: $state/$verified/$pinned/$known/$inPopup" }
                }
            }
        }
    }
}
# Test the production PowerShell freshness/identity gate without native mutation.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-WorkspaceAwayPin' }, $true)
# Redirect only the native call to a counter; all production gate code stays intact.
$definition = $functionAst.Extent.Text.Replace('[void][CogentSpec.ChatGptPopupPinHotkey]::UnpinWhenWorkspaceAway([string]$focus.state)', '$script:Calls++')
Invoke-Expression $definition
$script:PinHotkeyReady = $true
$script:VerifiedPopupVisible = $true
$script:CurrentConversationState = 'identified'
$script:CurrentConversationKey = 'a' * 64
foreach ($case in @(
    @{ age = 0; key = ('a' * 64); state = 'identified'; expected = 1 },
    @{ age = 20; key = ('a' * 64); state = 'identified'; expected = 0 },
    @{ age = -10; key = ('a' * 64); state = 'identified'; expected = 0 },
    @{ age = 0; key = ('b' * 64); state = 'identified'; expected = 0 },
    @{ age = 0; key = ('a' * 64); state = 'unknown'; expected = 0 }
)) {
    $script:Calls = 0
    $script:CurrentConversationState = $case.state
    $script:WorkspaceFocus = [pscustomobject]@{ state = 'blurred'; conversationKey = $case.key;
        updatedAt = [DateTime]::UtcNow.AddSeconds(-$case.age) }
    Update-WorkspaceAwayPin
    if ($script:Calls -ne $case.expected) { throw 'Freshness/identity gate failed.' }
}
Write-Output 'Auto-unpin: 64 native gate permutations, typed timestamp, stale/future/mismatch/unknown gates passed. No windows mutated.'
