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
    [string]$WatcherPluginVersion,
    [string]$WatcherThreadId,
    [string]$WatcherReadyPath
) {
    $escape = {
        param([string]$Value)
        return $Value.Replace("'", "''")
    }
    $command = "& '$(& $escape $WatcherScript)' -ContextKey '$(& $escape $WatcherContextKey)' -PluginId '$(& $escape $WatcherPluginId)' -PluginVersion '$(& $escape $WatcherPluginVersion)' -ThreadId '$(& $escape $WatcherThreadId)' -ReadyPath '$(& $escape $WatcherReadyPath)'"
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

function Test-BridgePresenceReady(
    [string]$ReadyPath,
    [int]$ProcessId,
    [string]$ExpectedContextKey,
    [string]$ExpectedPluginId,
    [string]$ExpectedPluginVersion,
    [string]$ExpectedThreadId
) {
    if (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) { return $false }
    try {
        $marker = Get-Content -Raw -LiteralPath $ReadyPath | ConvertFrom-Json
        if ([int]$marker.processId -ne $ProcessId -or
            [string]$marker.contextKey -cne $ExpectedContextKey -or
            [string]$marker.pluginId -cne $ExpectedPluginId -or
            [string]$marker.pluginVersion -cne $ExpectedPluginVersion -or
            ($ExpectedThreadId -and (-not $marker.PSObject.Properties['threadId'] -or [string]$marker.threadId -cne $ExpectedThreadId)) -or
            -not [bool]$marker.serverAcknowledged) {
            return $false
        }
        $acknowledgedAt = if ($marker.acknowledgedAt -is [DateTime]) {
            ([DateTime]$marker.acknowledgedAt).ToUniversalTime()
        } else {
            [DateTime]::Parse(
                [string]$marker.acknowledgedAt,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
        }
        $age = [DateTime]::UtcNow - $acknowledgedAt
        return $age.TotalSeconds -ge -1 -and $age.TotalSeconds -le 12
    } catch {
        return $false
    }
}

function Wait-BridgePresenceReady(
    [string]$ReadyPath,
    [int]$ProcessId,
    [string]$ExpectedContextKey,
    [string]$ExpectedPluginId,
    [string]$ExpectedPluginVersion,
    [string]$ExpectedThreadId,
    [int]$TimeoutMilliseconds
) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $false }
        if (Test-BridgePresenceReady `
            -ReadyPath $ReadyPath `
            -ProcessId $ProcessId `
            -ExpectedContextKey $ExpectedContextKey `
            -ExpectedPluginId $ExpectedPluginId `
            -ExpectedPluginVersion $ExpectedPluginVersion `
            -ExpectedThreadId $ExpectedThreadId) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
$connectionUrl = "https://cogentspec.com/stack?surface=$([Uri]::EscapeDataString($Surface))"
$threadId = if ($Surface -eq 'chatgpt' -and [string]$env:CODEX_THREAD_ID -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    [string]$env:CODEX_THREAD_ID
} else { '' }
$workspaceUrl = $connectionUrl
$webWorkspaceUrl = $connectionUrl
$chatgptWorkspaceUrl = $connectionUrl
$connectionScript = Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
$sourceScriptNames = @(
    'connect-cogentstack.ps1',
    'create-specification-project.ps1',
    'delete-specification-project.ps1',
    'delete-project.ps1',
    'ensure-cogentspec-mcp.ps1',
    'fulfil-project.ps1',
    'generate-project-preview.ps1',
    'inspect-project-git.ps1',
    'restore-project-version.ps1',
    'save-project-version.ps1',
    'native-command.ps1',
    'open-chatgpt-popup.ps1',
    'prepare-development-handoff.ps1',
    'project-context.ps1',
    'project-build-handoff.ps1',
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
$mcpState = 'not_required'
if ($Surface -eq 'chatgpt') {
    $mcpSetupScript = Join-Path $PSScriptRoot 'ensure-cogentspec-mcp.ps1'
    $mcpOutput = @(& $mcpSetupScript -Surface $Surface 2>&1)
    $mcpJson = @($mcpOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $mcpJson) { throw 'CogentSpec could not finish connecting.' }
    $mcpSetup = $mcpJson | ConvertFrom-Json
    if ([string]$mcpSetup.status -ne 'ready') {
        Write-CompactJson ([ordered]@{
            status = 'connection_required'
            contextKey = $resolvedContext
            contextIsolated = [bool]$projectContext.Isolated
            workspaceUrl = $workspaceUrl
            webWorkspaceUrl = $webWorkspaceUrl
            chatgptWorkspaceUrl = $chatgptWorkspaceUrl
            browserOpened = $false
            accountState = 'signed_in'
            userMessage = if ($mcpSetup.userMessage) { [string]$mcpSetup.userMessage } else { 'CogentSpec needs permission to continue. Complete the connection window, then run CogentSpec again.' }
            launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
        })
        return
    }
    $mcpState = 'ready'
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
$readyPath = Join-Path $stateRoot "$contextHash.ready.json"
$existingProcessId = 0
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $existingProcessId = [int]$state.processId
        $existingProcess = if ($existingProcessId -gt 0) { Get-CimInstance Win32_Process -Filter "ProcessId=$existingProcessId" -ErrorAction SilentlyContinue } else { $null }
        $expectedWatcher = [string]$state.watcherScript
        $sameRuntime = [string]$state.runtimeVersion -eq $runtimeVersion
        $sameThread = -not $threadId -or ($state.PSObject.Properties['threadId'] -and [string]$state.threadId -ceq $threadId)
        $verifiedBridgeProcess = $existingProcess -and
            $expectedWatcher -and
            [string]$state.contextKey -ceq $resolvedContext -and
            [string]$existingProcess.ExecutablePath -ieq $powershellExecutable -and
            ([string]$existingProcess.CommandLine).IndexOf('-EncodedCommand', [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($verifiedBridgeProcess -and $sameRuntime -and $sameThread) {
            $presenceReady = Wait-BridgePresenceReady `
                -ReadyPath $readyPath `
                -ProcessId $existingProcessId `
                -ExpectedContextKey $resolvedContext `
                -ExpectedPluginId $pluginId `
                -ExpectedPluginVersion $pluginVersion `
                -ExpectedThreadId $threadId `
                -TimeoutMilliseconds 3000
            if ($presenceReady) {
                Write-CompactJson ([ordered]@{
                    status = 'ready'
                    bridge = 'already_running'
                    presenceVerified = $true
                    processId = $existingProcessId
                    contextKey = $resolvedContext
                    contextIsolated = [bool]$projectContext.Isolated
                    workspaceUrl = $workspaceUrl
                    webWorkspaceUrl = $webWorkspaceUrl
                    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
                    browserOpened = $false
                    accountState = 'signed_in'
                    mcpState = $mcpState
                    pluginId = $pluginId
                    pluginVersion = $pluginVersion
                    launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
                })
                return
            }
            Stop-Process -Id $existingProcessId -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $existingProcessId -Timeout 2 -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
        }
        if ($verifiedBridgeProcess -and (-not $sameRuntime -or -not $sameThread)) {
            Stop-Process -Id $existingProcessId -Force
        }
    } catch { }
}

Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue

$watcher = Start-DetachedBridgeWatcher `
    -PowerShellExecutable $powershellExecutable `
    -WatcherScript $watcherScript `
    -WatcherContextKey $resolvedContext `
    -WatcherPluginId $pluginId `
    -WatcherPluginVersion $pluginVersion `
    -WatcherThreadId $threadId `
    -WatcherReadyPath $readyPath
$presenceReady = Wait-BridgePresenceReady `
    -ReadyPath $readyPath `
    -ProcessId $watcher.Id `
    -ExpectedContextKey $resolvedContext `
    -ExpectedPluginId $pluginId `
    -ExpectedPluginVersion $pluginVersion `
    -ExpectedThreadId $threadId `
    -TimeoutMilliseconds 8000
if (-not $presenceReady) {
    Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    throw 'Desktop Bridge started, but CogentSpec did not verify this AI task.'
}

[ordered]@{
    processId = $watcher.Id
    runtimeVersion = $runtimeVersion
    watcherScript = $watcherScript
    readyPath = $readyPath
    contextKey = $resolvedContext
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    startedAt = [DateTime]::UtcNow.ToString('o')
    pluginId = $pluginId
    pluginVersion = $pluginVersion
    threadId = $threadId
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-CompactJson ([ordered]@{
    status = 'ready'
    bridge = 'started'
    presenceVerified = $true
    processId = $watcher.Id
    contextKey = $resolvedContext
    contextIsolated = [bool]$projectContext.Isolated
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    browserOpened = $false
    accountState = 'signed_in'
    mcpState = $mcpState
    pluginId = $pluginId
    pluginVersion = $pluginVersion
    launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
})
