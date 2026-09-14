[CmdletBinding()]
param(
    [string]$ContextKey = '',

    [ValidateSet('chatgpt', 'claude-desktop')]
    [string]$Surface = 'chatgpt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-context.ps1')

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

function Get-TextSha256([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $algorithm.Dispose()
    }
}

$projectContext = Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$resolvedContext = [string]$projectContext.ContextKey
$connectionUrl = "https://cogentspec.com/stack?surface=$([Uri]::EscapeDataString($Surface))"
$workspaceUrl = $connectionUrl
$connectionScript = Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
$sourceScriptNames = @(
    'connect-cogentstack.ps1',
    'delete-project.ps1',
    'fulfil-project.ps1',
    'generate-project-preview.ps1',
    'native-command.ps1',
    'project-context.ps1',
    'watch-cogentstack-bridge.ps1'
)
if (-not (Test-Path -LiteralPath $connectionScript -PathType Leaf) -or @($sourceScriptNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) }).Count -gt 0) {
    throw 'Desktop Bridge is incomplete. Repair the CogentSpec installation.'
}

$powershellCommand = Get-Command powershell.exe, pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $powershellCommand) { throw 'Windows PowerShell is required by Desktop Bridge.' }
$connectionOutput = @(& ([string]$powershellCommand.Source) -NoProfile -ExecutionPolicy Bypass -File $connectionScript -Mode status -Surface $Surface -ContextKey $resolvedContext -WorkspaceGrant 2>&1)
$connectionJson = @($connectionOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
if (-not $connectionJson) { throw 'Desktop Bridge could not verify the account-bound installation.' }
$connection = $connectionJson | ConvertFrom-Json
if ([string]$connection.status -ne 'connected') {
    Write-CompactJson ([ordered]@{
        status = 'signed_out'
        contextKey = $resolvedContext
        contextIsolated = [bool]$projectContext.Isolated
        workspaceUrl = $workspaceUrl
        browserOpened = $false
        reason = if ($connection.reason) { [string]$connection.reason } else { 'desktop_bridge_not_installed' }
    })
    exit 0
}
if ([string]$connection.workspaceCode -notmatch '^cgw_[A-Za-z0-9_-]{32,}$') {
    throw 'Desktop Bridge could not create a private CogentSpec.app workspace handoff.'
}
$workspaceUrl = "https://cogentspec.app/stack?surface=$([Uri]::EscapeDataString($Surface))&context=$([Uri]::EscapeDataString($resolvedContext))#desktop=$([Uri]::EscapeDataString([string]$connection.workspaceCode))"

$localStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$stateRoot = Join-Path $localStateRoot 'bridge'
[void](New-Item -ItemType Directory -Path $stateRoot -Force)
$sourceHashes = $sourceScriptNames | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
$runtimeDigestBytes = Get-TextSha256 ($sourceHashes -join "`n")
$runtimeVersion = ([BitConverter]::ToString($runtimeDigestBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$runtimeRoot = Join-Path $localStateRoot "bridge-runtime\$runtimeVersion"
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
    foreach ($scriptName in $sourceScriptNames) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Destination (Join-Path $runtimeRoot $scriptName) -Force
    }
}
$watcherScript = Join-Path $runtimeRoot 'watch-cogentstack-bridge.ps1'
$contextHashBytes = Get-TextSha256 $resolvedContext
$contextHash = ([BitConverter]::ToString($contextHashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$statePath = Join-Path $stateRoot "$contextHash.json"
$existingProcessId = 0
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $existingProcessId = [int]$state.processId
        $existingProcess = if ($existingProcessId -gt 0) { Get-CimInstance Win32_Process -Filter "ProcessId=$existingProcessId" -ErrorAction SilentlyContinue } else { $null }
        $expectedWatcher = [string]$state.watcherScript
        $sameRuntime = [string]$state.runtimeVersion -eq $runtimeVersion
        $verifiedBridgeProcess = $existingProcess -and $expectedWatcher -and ([string]$existingProcess.CommandLine).IndexOf($expectedWatcher, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($verifiedBridgeProcess -and $sameRuntime) {
            Write-CompactJson ([ordered]@{
                status = 'ready'
                bridge = 'already_running'
                processId = $existingProcessId
                contextKey = $resolvedContext
                contextIsolated = [bool]$projectContext.Isolated
                workspaceUrl = $workspaceUrl
                browserOpened = $false
                accountState = 'signed_in'
            })
            exit 0
        }
        if ($verifiedBridgeProcess -and -not $sameRuntime) {
            Stop-Process -Id $existingProcessId -Force
        }
    } catch { }
}

$watcher = Start-Process -FilePath ([string]$powershellCommand.Source) -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcherScript, '-ContextKey', $resolvedContext
) -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 350
if ($watcher.HasExited) { throw 'Desktop Bridge stopped before it became ready.' }

[ordered]@{
    processId = $watcher.Id
    runtimeVersion = $runtimeVersion
    watcherScript = $watcherScript
    contextKey = $resolvedContext
    workspaceUrl = $workspaceUrl
    startedAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-CompactJson ([ordered]@{
    status = 'ready'
    bridge = 'started'
    processId = $watcher.Id
    contextKey = $resolvedContext
    contextIsolated = [bool]$projectContext.Isolated
    workspaceUrl = $workspaceUrl
    browserOpened = $false
    accountState = 'signed_in'
})
