$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helper = Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Launcher has parser errors.' }
$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Confirm-CurrentConversationConnection'
}, $true)
Invoke-Expression $function.Extent.Text

$script:popoutCalls = 0
$script:popoutConfirmed = $true
function Confirm-StandalonePopoutConnection {
    param($SurfaceName, $ConnectedContextKey, $ConnectedThreadId)
    $script:popoutCalls++
    return [ordered]@{
        confirmed = $script:popoutConfirmed
        reason = if ($script:popoutConfirmed) { 'confirmed' } else { 'fixture_not_verified' }
    }
}

$context = 'ctx-' + ('a' * 64)
$thread = '11111111-1111-4111-8111-111111111111'
$desk = Confirm-CurrentConversationConnection chatgpt desktop-ui $context $thread $true $true
if (-not $desk.confirmed -or $desk.popoutConfirmed -or
    $desk.verification -ne 'desktop_thread_presence' -or
    $desk.reason -ne 'desktop_thread_presence_confirmed' -or $script:popoutCalls -ne 0) {
    throw 'Desk did not use its exact thread-bound presence proof.'
}

foreach ($invalid in @(
    @{ Thread = ''; Presence = $true; Isolated = $true },
    @{ Thread = $thread; Presence = $false; Isolated = $true },
    @{ Thread = $thread; Presence = $true; Isolated = $false }
)) {
    $result = Confirm-CurrentConversationConnection chatgpt desktop-ui $context $invalid.Thread $invalid.Presence $invalid.Isolated
    if ($result.confirmed -or $result.reason -ne 'current_desktop_conversation_not_verified' -or $script:popoutCalls -ne 0) {
        throw 'Desk accepted incomplete thread-bound presence evidence.'
    }
}

$web = Confirm-CurrentConversationConnection chatgpt web $context $thread $true $true
if ($web.confirmed -or $web.reason -ne 'not_applicable' -or $script:popoutCalls -ne 0) {
    throw 'Web incorrectly ran desktop conversation confirmation.'
}

$popout = Confirm-CurrentConversationConnection chatgpt popout $context $thread $true $true
if (-not $popout.confirmed -or -not $popout.popoutConfirmed -or
    $popout.verification -ne 'popout_fingerprint' -or $script:popoutCalls -ne 1) {
    throw 'Popout no longer uses its fingerprint confirmation contract.'
}

$script:popoutConfirmed = $false
$legacy = Confirm-CurrentConversationConnection chatgpt legacy $context $thread $true $true
if ($legacy.confirmed -or $legacy.popoutConfirmed -or $legacy.reason -ne 'fixture_not_verified' -or $script:popoutCalls -ne 2) {
    throw 'Legacy Popout-compatible confirmation no longer fails closed.'
}

'PASS: Desk uses exact thread presence; Popout keeps fingerprint confirmation; Web skips the unrelated probe.'
