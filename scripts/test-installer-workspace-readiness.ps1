[CmdletBinding()]
param([switch]$Live)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-ReadinessTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$results = @()
foreach ($plugin in @('cogentspec', 'cogentstack')) {
    $installerPath = Join-Path $repositoryRoot ".agents\plugins\install-$plugin.ps1"
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
    Assert-ReadinessTest ($parseErrors.Count -eq 0) "$plugin installer must parse successfully."
    $assignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$workspaceUrl'
    }, $true)
    $literal = $assignment.Right.Find({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $true)
    $workspaceUrl = [string]$literal.Value
    Assert-ReadinessTest ($workspaceUrl -ceq 'https://cogentspec.app/stack') "$plugin must check the public workspace shell."
    $request = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-WebRequest'
    }, $true)
    $block = $request.Parent
    while ($block -and $block -isnot [Management.Automation.Language.StatementBlockAst]) { $block = $block.Parent }
    Assert-ReadinessTest ($null -ne $block) "$plugin readiness block must be present."
    $readiness = [scriptblock]::Create($block.Extent.Text.Trim().Substring(1, $block.Extent.Text.Trim().Length - 2))

    function Get-RemainingMilliseconds { return 30000 }
    function Set-InstallStage([string]$Name) { Assert-ReadinessTest ($Name -eq 'workspace_readiness') 'Unexpected stage.' }
    function Complete-InstallStage { $script:readinessCompleted = $true }
    function Invoke-WebRequest {
        param([string]$Uri, [switch]$UseBasicParsing, [int]$MaximumRedirection, [int]$TimeoutSec)
        $script:readinessCalls++
        Assert-ReadinessTest ($Uri -ceq 'https://cogentspec.app/stack') 'Readiness must not require the marketing account session.'
        Assert-ReadinessTest ($MaximumRedirection -eq 0 -and $TimeoutSec -gt 0 -and $TimeoutSec -le 10) 'Redirect and timeout protections must remain enabled.'
        if ($script:readinessCase -eq 'http-error') { throw 'HTTP 307 Temporary Redirect' }
        $finalUrl = switch ($script:readinessCase) {
            'wrong-origin' { 'https://example.invalid/stack' }
            'login-page' { 'https://cogentspec.com/account?return_to=%2Fstack' }
            default { $Uri }
        }
        $status = if ($script:readinessCase -eq 'non-200') { 503 } else { 200 }
        $content = if ($script:readinessCase -eq 'missing-markers') { '<h1>Sign in</h1>' } else { '<h1>What would you like to create?</h1><section class="project-idea"></section>' }
        return [pscustomobject]@{
            StatusCode = $status
            Content = $content
            BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]$finalUrl } }
        }
    }

    foreach ($case in @('ready', 'http-error', 'non-200', 'wrong-origin', 'login-page', 'missing-markers')) {
        $script:readinessCase = $case
        $script:readinessCalls = 0
        $script:readinessCompleted = $false
        $failure = $null
        try { & $readiness } catch { $failure = $_.Exception.Message }
        $expected = $case -eq 'ready'
        Assert-ReadinessTest ($script:readinessCalls -eq 1) "$plugin/$case must make exactly one readiness request."
        Assert-ReadinessTest ($script:readinessCompleted -eq $expected) "$plugin/$case incorrectly completed readiness."
        Assert-ReadinessTest (($null -eq $failure) -eq $expected) "$plugin/$case returned the wrong result."
        $results += [ordered]@{ plugin = $plugin; case = $case; passed = $true }
    }
    Remove-Item Function:\Invoke-WebRequest
    if ($Live) {
        $script:readinessCompleted = $false
        & $readiness
        Assert-ReadinessTest $script:readinessCompleted "$plugin live public-shell readiness failed."
        $results += [ordered]@{ plugin = $plugin; case = 'live-public-shell'; passed = $true }
    }
}
[ordered]@{ status = 'passed'; cases = $results.Count; results = $results; claimAttempted = $false; accountRequestConsumed = $false } | ConvertTo-Json -Depth 4 -Compress
