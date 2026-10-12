[CmdletBinding()]
param(
    [string]$ContextKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreScripts = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\cogentspec\scripts') -ErrorAction Stop).Path
. (Join-Path $coreScripts 'project-context.ps1')

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

function Get-ResultProperty($Value, [string]$Name, $Default = $null) {
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-QueryValues([Uri]$Uri) {
    $values = @{}
    foreach ($entry in $Uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $entry.Split('=', 2)
        $name = [Uri]::UnescapeDataString([string]$parts[0])
        $value = if ($parts.Count -eq 2) { [Uri]::UnescapeDataString([string]$parts[1]) } else { '' }
        if ($values.ContainsKey($name)) { throw "The GPTWeb workspace handoff contains a duplicate '$name' parameter." }
        $values[$name] = $value
    }
    return $values
}

function Write-InvalidHandoff([string]$ResolvedContext, [string]$Reason) {
    Write-CompactJson ([ordered]@{
        status = 'invalid_workspace_handoff'
        contextKey = $ResolvedContext
        reason = $Reason
        userMessage = 'CogentSpec could not create a verified GPT web workspace link. The legacy authorization route was not opened.'
    })
}

$projectContext = Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$resolvedContext = [string]$projectContext.ContextKey
if (-not [bool]$projectContext.Isolated) {
    Write-CompactJson ([ordered]@{
        status = 'unscoped_context'
        contextKey = $resolvedContext
        userMessage = 'CogentSpec could not identify an isolated project workspace for GPTWeb.'
    })
    return
}

$launcher = Join-Path $coreScripts 'start-cogentstack-bridge.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw 'The CogentSpec GPTWeb launcher is incomplete. Repair the CogentSpec installation.'
}

$launcherOutput = @(& $launcher -ContextKey $resolvedContext -Surface chatgpt -Experience web 2>&1)
$launcherJson = @(
    $launcherOutput |
        ForEach-Object { $_.ToString() } |
        Where-Object { $_.Trim().StartsWith('{') } |
        Select-Object -Last 1
)
if (-not $launcherJson) {
    Write-CompactJson ([ordered]@{
        status = 'bridge_start_failed'
        contextKey = $resolvedContext
        userMessage = 'CogentSpec could not start the GPT web workspace.'
    })
    return
}

$result = $launcherJson | ConvertFrom-Json
$status = [string](Get-ResultProperty $result 'status' '')
if ($status -ne 'ready') {
    $failure = [ordered]@{
        status = if ($status) { $status } else { 'bridge_start_failed' }
        contextKey = $resolvedContext
    }
    $reason = [string](Get-ResultProperty $result 'reason' '')
    $userMessage = [string](Get-ResultProperty $result 'userMessage' '')
    if ($reason) { $failure.reason = $reason }
    if ($userMessage) { $failure.userMessage = $userMessage }
    Write-CompactJson $failure
    return
}

$workspaceUrl = [string](Get-ResultProperty $result 'workspaceUrl' '')
$webWorkspaceUrl = [string](Get-ResultProperty $result 'webWorkspaceUrl' '')
$chatgptWorkspaceUrl = [string](Get-ResultProperty $result 'chatgptWorkspaceUrl' '')
if (-not $workspaceUrl -or $workspaceUrl -cne $webWorkspaceUrl) {
    Write-InvalidHandoff $resolvedContext 'workspace_not_web_destination'
    return
}
if ($chatgptWorkspaceUrl -and $workspaceUrl -ceq $chatgptWorkspaceUrl) {
    Write-InvalidHandoff $resolvedContext 'workspace_selected_desktop_destination'
    return
}

try {
    $uri = [Uri]$workspaceUrl
    $query = Get-QueryValues $uri
} catch {
    Write-InvalidHandoff $resolvedContext 'workspace_url_invalid'
    return
}

$valid = $uri.Scheme -ceq 'https' -and
    $uri.Host -ceq 'cogentspec.app' -and
    $uri.AbsolutePath -ceq '/stack' -and
    $query.Count -eq 5 -and
    [string]$query.surface -ceq 'chatgpt' -and
    [string]$query.context -ceq $resolvedContext -and
    [string]$query.experience -ceq 'web' -and
    [string]$query.open -ceq 'web' -and
    [string]$query.nav -match '^[a-f0-9]{32}$' -and
    $uri.Fragment -match '^#desktop-web=cgw_[A-Za-z0-9_-]{32,}$' -and
    $uri.Fragment -notmatch '^#desktop=' -and
    $uri.Fragment -notmatch '^#desktop-chatgpt='

if (-not $valid) {
    Write-InvalidHandoff $resolvedContext 'workspace_url_contract_mismatch'
    return
}

if ([string](Get-ResultProperty $result 'contextKey' '') -cne $resolvedContext -or
    -not [bool](Get-ResultProperty $result 'contextIsolated' $false) -or
    -not [bool](Get-ResultProperty $result 'presenceVerified' $false) -or
    [string](Get-ResultProperty $result 'accountState' '') -cne 'signed_in' -or
    [string](Get-ResultProperty $result 'mcpState' '') -cne 'ready' -or
    [bool](Get-ResultProperty $result 'browserOpened' $true)) {
    Write-InvalidHandoff $resolvedContext 'bridge_ready_contract_mismatch'
    return
}

Write-CompactJson ([ordered]@{
    status = 'ready'
    bridge = [string](Get-ResultProperty $result 'bridge' '')
    presenceVerified = $true
    contextKey = $resolvedContext
    contextIsolated = $true
    workspaceUrl = $workspaceUrl
    browserOpened = $false
    accountState = 'signed_in'
    mcpState = 'ready'
    pluginId = [string](Get-ResultProperty $result 'pluginId' '')
    pluginVersion = [string](Get-ResultProperty $result 'pluginVersion' '')
    launcherElapsedMs = [int](Get-ResultProperty $result 'launcherElapsedMs' 0)
})
