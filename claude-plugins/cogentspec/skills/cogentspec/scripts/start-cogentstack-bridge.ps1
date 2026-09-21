[CmdletBinding()]
param(
    [string]$ContextKey = '',

    [ValidateSet('chatgpt', 'claude-desktop')]
    [string]$Surface = 'chatgpt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$launcherTimer = [Diagnostics.Stopwatch]::StartNew()
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
$pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
$manifestPath = @(
    (Join-Path $pluginRoot '.codex-plugin\plugin.json'),
    (Join-Path $pluginRoot '.claude-plugin\plugin.json')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $manifestPath) { throw 'CogentSpec package identity is missing. Repair the installation.' }
$pluginManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$pluginId = [string]$pluginManifest.name
$pluginVersion = [string]$pluginManifest.version
if ($pluginId -notin @('cogentspec', 'cogentstack') -or $pluginVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'CogentSpec package identity is invalid. Repair the installation.'
}

function Get-HostPowerShellExecutable {
    $runtimeProcessPath = ''
    $processPathProperty = [Environment].GetProperty('ProcessPath', [Reflection.BindingFlags]'Public,Static')
    if ($processPathProperty) { $runtimeProcessPath = [string]$processPathProperty.GetValue($null) }
    $candidates = @(
        $runtimeProcessPath,
        (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        $leaf = [IO.Path]::GetFileName([string]$candidate)
        if ($leaf -match '^(pwsh|powershell)(\.exe)?$' -and (Test-Path -LiteralPath ([string]$candidate) -PathType Leaf)) {
            return [string]$candidate
        }
    }
    $command = @(Get-Command pwsh.exe, powershell.exe -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    throw 'Windows PowerShell is required by Desktop Bridge.'
}

function Start-DetachedBridgeWatcher(
    [string]$PowerShellExecutable,
    [string]$WatcherScript,
    [string]$WatcherContextKey,
    [string]$WatcherPluginId,
    [string]$WatcherPluginVersion
) {
    $escape = {
        param([string]$Value)
        return $Value.Replace("'", "''")
    }
    $command = "& '$(& $escape $WatcherScript)' -ContextKey '$(& $escape $WatcherContextKey)' -PluginId '$(& $escape $WatcherPluginId)' -PluginVersion '$(& $escape $WatcherPluginVersion)'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $commandLine = '"' + $PowerShellExecutable + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
    $creation = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
    if ([int]$creation.ReturnValue -ne 0 -or [int]$creation.ProcessId -le 0) {
        throw "Desktop Bridge worker could not be started (Windows result $([int]$creation.ReturnValue))."
    }
    $process = Get-Process -Id ([int]$creation.ProcessId) -ErrorAction SilentlyContinue
    if (-not $process) { throw 'Desktop Bridge worker stopped during startup.' }
    return $process
}
$connectionUrl = "https://cogentspec.com/stack?surface=$([Uri]::EscapeDataString($Surface))"
$workspaceUrl = $connectionUrl
$webWorkspaceUrl = $connectionUrl
$chatgptWorkspaceUrl = $connectionUrl
$connectionScript = Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
$sourceScriptNames = @(
    'connect-cogentstack.ps1',
    'create-specification-project.ps1',
    'delete-project.ps1',
    'fulfil-project.ps1',
    'generate-project-preview.ps1',
    'native-command.ps1',
    'project-context.ps1',
    'project-preview-readiness.ps1',
    'watch-cogentstack-bridge.ps1'
)
if (-not (Test-Path -LiteralPath $connectionScript -PathType Leaf) -or @($sourceScriptNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) }).Count -gt 0) {
    throw 'Desktop Bridge is incomplete. Repair the CogentSpec installation.'
}

$powershellExecutable = Get-HostPowerShellExecutable
$connectionOutput = @(& $connectionScript -Mode status -Surface $Surface -ContextKey $resolvedContext -WorkspaceGrant -RequestTimeoutSeconds 8 2>&1)
$connectionJson = @($connectionOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
if (-not $connectionJson) { throw 'Desktop Bridge could not verify the account-bound installation.' }
$connection = $connectionJson | ConvertFrom-Json
if ([string]$connection.status -ne 'connected') {
    Write-CompactJson ([ordered]@{
        status = 'signed_out'
        contextKey = $resolvedContext
        contextIsolated = [bool]$projectContext.Isolated
        workspaceUrl = $workspaceUrl
        webWorkspaceUrl = $webWorkspaceUrl
        chatgptWorkspaceUrl = $chatgptWorkspaceUrl
        browserOpened = $false
        reason = if ($connection.reason) { [string]$connection.reason } else { 'desktop_bridge_not_installed' }
        launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
    })
    return
}
if ([string]$connection.webWorkspaceCode -notmatch '^cgw_[A-Za-z0-9_-]{32,}$' -or
    [string]$connection.chatgptWorkspaceCode -notmatch '^cgw_[A-Za-z0-9_-]{32,}$') {
    throw 'Desktop Bridge could not create the two private CogentSpec.app workspace handoffs.'
}
$workspaceBaseUrl = "https://cogentspec.app/stack?surface=$([Uri]::EscapeDataString($Surface))&context=$([Uri]::EscapeDataString($resolvedContext))"
$navigationKey = [Guid]::NewGuid().ToString('N')
$webWorkspaceUrl = "$workspaceBaseUrl&open=web&nav=$navigationKey#desktop-web=$([Uri]::EscapeDataString([string]$connection.webWorkspaceCode))"
$chatgptWorkspaceUrl = "$workspaceBaseUrl&open=chatgpt&nav=$navigationKey#desktop-chatgpt=$([Uri]::EscapeDataString([string]$connection.chatgptWorkspaceCode))"
$workspaceUrl = $chatgptWorkspaceUrl

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
                webWorkspaceUrl = $webWorkspaceUrl
                chatgptWorkspaceUrl = $chatgptWorkspaceUrl
                browserOpened = $false
                accountState = 'signed_in'
                pluginId = $pluginId
                pluginVersion = $pluginVersion
                launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
            })
            return
        }
        if ($verifiedBridgeProcess -and -not $sameRuntime) {
            Stop-Process -Id $existingProcessId -Force
        }
    } catch { }
}

$watcher = Start-DetachedBridgeWatcher `
    -PowerShellExecutable $powershellExecutable `
    -WatcherScript $watcherScript `
    -WatcherContextKey $resolvedContext `
    -WatcherPluginId $pluginId `
    -WatcherPluginVersion $pluginVersion
Start-Sleep -Milliseconds 350
if ($watcher.HasExited) { throw 'Desktop Bridge stopped before it became ready.' }

[ordered]@{
    processId = $watcher.Id
    runtimeVersion = $runtimeVersion
    watcherScript = $watcherScript
    contextKey = $resolvedContext
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    startedAt = [DateTime]::UtcNow.ToString('o')
    pluginId = $pluginId
    pluginVersion = $pluginVersion
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-CompactJson ([ordered]@{
    status = 'ready'
    bridge = 'started'
    processId = $watcher.Id
    contextKey = $resolvedContext
    contextIsolated = [bool]$projectContext.Isolated
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    browserOpened = $false
    accountState = 'signed_in'
    pluginId = $pluginId
    pluginVersion = $pluginVersion
    launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
})
