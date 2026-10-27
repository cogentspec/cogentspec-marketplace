# ClaudeDesk command contract v1. This entry point is intentionally independent
# of the Web, Snap, Local and GPTDesk launchers. Account/credential checks and
# approved project actions remain the existing package primitives.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$SessionId
)
$Surface = 'claude-desktop'
$Experience = 'desktop-ui'
$pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
$pluginManifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
$coreScripts = Join-Path $pluginRoot "skills\$($pluginManifest.name)\scripts"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$launcherTimer = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $coreScripts 'project-context.ps1')
. (Join-Path $coreScripts 'native-command.ps1')

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 6 -Compress | Write-Output
}

$executionFailure = Get-CogentSpecExecutionPermissionFailure
if ($executionFailure) {
    Write-CompactJson $executionFailure
    exit 0
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

function Get-BridgeWatcherCommand(
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
    return "& '$(& $escape $WatcherScript)' -ContextKey '$(& $escape $WatcherContextKey)' -PluginId '$(& $escape $WatcherPluginId)' -PluginVersion '$(& $escape $WatcherPluginVersion)' -ThreadId '$(& $escape $WatcherThreadId)' -ReadyPath '$(& $escape $WatcherReadyPath)'"
}

function Test-BridgeWatcherProcess(
    $ProcessInfo,
    [string]$WatcherScript,
    [string]$WatcherContextKey,
    [string]$WatcherPluginId,
    [string]$WatcherPluginVersion,
    [string]$WatcherThreadId,
    [string]$WatcherReadyPath
) {
    if (-not $ProcessInfo) { return $false }
    $executableLeaf = [IO.Path]::GetFileName([string]$ProcessInfo.ExecutablePath)
    if ($executableLeaf -notmatch '^(pwsh|powershell)(\.exe)?$') { return $false }

    $encodedMatch = [regex]::Match(
        [string]$ProcessInfo.CommandLine,
        '(?i)(?:^|\s)-EncodedCommand(?:\s+|=)(?:"([A-Za-z0-9+/=]+)"|''([A-Za-z0-9+/=]+)''|([A-Za-z0-9+/=]+))'
    )
    if (-not $encodedMatch.Success) { return $false }
    $actualEncodedCommand = if ($encodedMatch.Groups[1].Success) {
        $encodedMatch.Groups[1].Value
    } elseif ($encodedMatch.Groups[2].Success) {
        $encodedMatch.Groups[2].Value
    } else {
        $encodedMatch.Groups[3].Value
    }
    $expectedCommand = Get-BridgeWatcherCommand `
        -WatcherScript $WatcherScript `
        -WatcherContextKey $WatcherContextKey `
        -WatcherPluginId $WatcherPluginId `
        -WatcherPluginVersion $WatcherPluginVersion `
        -WatcherThreadId $WatcherThreadId `
        -WatcherReadyPath $WatcherReadyPath
    $expectedEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($expectedCommand))
    return $actualEncodedCommand -ceq $expectedEncodedCommand
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
    $command = Get-BridgeWatcherCommand `
        -WatcherScript $WatcherScript `
        -WatcherContextKey $WatcherContextKey `
        -WatcherPluginId $WatcherPluginId `
        -WatcherPluginVersion $WatcherPluginVersion `
        -WatcherThreadId $WatcherThreadId `
        -WatcherReadyPath $WatcherReadyPath
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $commandLine = '"' + $PowerShellExecutable + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
    # Hide at process creation, before PowerShell can parse -WindowStyle.
    # Keep the existing WMI detachment so the worker survives its caller.
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{
        ShowWindow = [UInt16]0
    }
    $creation = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine
        ProcessStartupInformation = $startup
    }
    if ([int]$creation.ReturnValue -ne 0 -or [int]$creation.ProcessId -le 0) {
        throw "Desktop Bridge worker could not be started (Windows result $([int]$creation.ReturnValue))."
    }
    $process = Get-Process -Id ([int]$creation.ProcessId) -ErrorAction SilentlyContinue
    if (-not $process) { throw 'Desktop Bridge worker stopped during startup.' }
    return $process
}

function Confirm-CurrentConversationConnection(
    [string]$SurfaceName, [string]$ExperienceName, [string]$ConnectedContextKey,
    [string]$ConnectedThreadId, [bool]$PresenceVerified, [bool]$ContextIsolated
) {
    $confirmed = $SurfaceName -ceq 'claude-desktop' -and $ExperienceName -ceq 'desktop-ui' -and
        $ConnectedContextKey -ceq $ContextKey -and $ConnectedThreadId -ceq $SessionId -and
        $PresenceVerified -and $ContextIsolated
    return [ordered]@{
        confirmed = $confirmed; popoutConfirmed = $false; verification = 'claude_desktop_session_presence'
        reason = if ($confirmed) { 'claude_desktop_session_presence_confirmed' } else { 'current_claude_desktop_session_not_verified' }
        userMessage = if ($confirmed) { 'The current ClaudeDesk conversation is connected.' }
            else { 'The project-data Bridge is ready, but the current ClaudeDesk conversation could not be verified.' }
    }
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
$threadId = $SessionId
$workspaceUrl = $connectionUrl
$webWorkspaceUrl = $connectionUrl
$chatgptWorkspaceUrl = $connectionUrl
$connectionScript = Join-Path $coreScripts 'connect-cogentstack.ps1'
$sourceScriptNames = @(
    'connect-cogentstack.ps1',
    'ensure-default-project-directory.ps1',
    'create-specification-project.ps1',
    'delete-specification-project.ps1',
    'delete-project.ps1',
    'fulfil-project.ps1',
    'generate-project-preview.ps1',
    'inspect-project-git.ps1',
    'project-git-connection.ps1',
    'restore-project-version.ps1',
    'save-project-version.ps1',
    'native-command.ps1',
    'project-context.ps1',
    'project-preview-readiness.ps1',
    'project-credential-worker.ps1',
    'provision-project-credentials.mjs',
    'project-knowledge.ps1'
)
if (-not (Test-Path -LiteralPath $connectionScript -PathType Leaf) -or @($sourceScriptNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $coreScripts $_) -PathType Leaf) }).Count -gt 0) {
    throw 'Desktop Bridge is incomplete. Repair the CogentSpec installation.'
}

$powershellExecutable = Get-HostPowerShellExecutable
$connectionOutput = @(& $connectionScript -Mode status -Surface $Surface -ContextKey $resolvedContext -Experience $Experience -WorkspaceGrant -RequestTimeoutSeconds 6 2>&1)
$connectionJson = @($connectionOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
if (-not $connectionJson) { throw 'Desktop Bridge could not verify the account-bound installation.' }
$connection = $connectionJson | ConvertFrom-Json
if ([string]$connection.status -eq 'execution_permission_required') {
    Write-CompactJson $connection
    exit 0
}
if ([string]$connection.status -ne 'connected') {
    if ([string]$connection.status -in @('licence_required', 'licence_verification_unavailable')) {
        Write-CompactJson $connection
        return
    }
    $connectionReason = if ($connection.PSObject.Properties['reason'] -and [string]$connection.reason) { [string]$connection.reason } else { 'desktop_bridge_not_installed' }
    $recoveryExperience = if ($Experience -eq 'split-screen') { 'split-screen' } else { 'standard' }
    $recoveryUrl = "https://cogentspec.com/install?mode=reconnect&experience=$([Uri]::EscapeDataString($recoveryExperience))"
    $retryCommand = '$claudedesk'
    $userMessage = switch ($connectionReason) {
        'legal_update_required' { 'Sign in to CogentSpec and confirm the current terms for this computer. The reconnect page will then prepare the required connection step.' }
        'installation_replaced_revoked_or_inactive' { 'CogentSpec needs to reconnect this computer. Open the guided reconnect page; your projects and website account are unaffected.' }
        'legacy_connection_not_bound_to_installation' { 'CogentSpec needs to update this computer to the current secure connection. Open the guided reconnect page to continue.' }
        default { 'CogentSpec needs to connect this computer. Open the guided reconnect page to continue.' }
    }
    Write-CompactJson ([ordered]@{
        status = 'signed_out'
        contextKey = $resolvedContext
        contextIsolated = [bool]$projectContext.Isolated
        workspaceUrl = $workspaceUrl
        webWorkspaceUrl = $webWorkspaceUrl
        chatgptWorkspaceUrl = $chatgptWorkspaceUrl
        browserOpened = $false
        reason = $connectionReason
        recoveryRequired = $true
        recoveryUrl = $recoveryUrl
        recoveryExperience = $recoveryExperience
        retryCommand = $retryCommand
        userMessage = $userMessage
        launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
    })
    return
}
$mcpState = 'not_required'
$projectDataConnection = 'authenticated_desktop_bridge'
if ([string]$connection.webWorkspaceCode -notmatch '^cgw_[A-Za-z0-9_-]{32,}$' -or
    [string]$connection.chatgptWorkspaceCode -notmatch '^cgw_[A-Za-z0-9_-]{32,}$') {
    throw 'Desktop Bridge could not create the two private CogentSpec.app workspace handoffs.'
}
. (Join-Path $coreScripts 'ensure-default-project-directory.ps1')
$defaultDirectory = Initialize-CogentSpecDefaultProjectDirectory
if ([string]$defaultDirectory.status -ne 'ready') {
    Write-CompactJson ([ordered]@{
        status = 'default_directory_unavailable'
        contextKey = $resolvedContext
        contextIsolated = [bool]$projectContext.Isolated
        accountState = 'signed_in'
        browserOpened = $false
        reason = [string]$defaultDirectory.reason
        userMessage = [string]$defaultDirectory.userMessage
        launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
    })
    return
}
$workspaceBaseUrl = "https://cogentspec.app/stack?surface=$([Uri]::EscapeDataString($Surface))&context=$([Uri]::EscapeDataString($resolvedContext))"
if ($Experience -ne 'legacy') {
    $workspaceBaseUrl += "&experience=$([Uri]::EscapeDataString($Experience))"
}
$navigationKey = [Guid]::NewGuid().ToString('N')
$webLaunchBaseUrl = $workspaceBaseUrl
$webWorkspaceUrl = "$webLaunchBaseUrl&open=web&nav=$navigationKey#desktop-web=$([Uri]::EscapeDataString([string]$connection.webWorkspaceCode))"
$chatgptWorkspaceUrl = "$workspaceBaseUrl&open=chatgpt&nav=$navigationKey#desktop-chatgpt=$([Uri]::EscapeDataString([string]$connection.chatgptWorkspaceCode))"
$workspaceUrl = $chatgptWorkspaceUrl
$localStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$stateRoot = Join-Path $localStateRoot 'claudedesk-v1'
[void](New-Item -ItemType Directory -Path $stateRoot -Force)
$sourceHashes = $sourceScriptNames | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $coreScripts $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
$deskWorker = Join-Path $PSScriptRoot 'watch-claudedesk-bridge.ps1'
$sourceHashes += (Get-FileHash -LiteralPath $deskWorker -Algorithm SHA256).Hash.ToLowerInvariant()
$runtimeDigestBytes = Get-TextSha256 ($sourceHashes -join "`n")
$runtimeVersion = ([BitConverter]::ToString($runtimeDigestBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$runtimeRoot = Join-Path $localStateRoot "claudedesk-runtime-v1\$runtimeVersion"
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
    foreach ($scriptName in $sourceScriptNames) {
        Copy-Item -LiteralPath (Join-Path $coreScripts $scriptName) -Destination (Join-Path $runtimeRoot $scriptName) -Force
    }
}
Copy-Item -LiteralPath $deskWorker -Destination (Join-Path $runtimeRoot 'watch-claudedesk-bridge.ps1') -Force
$watcherScript = Join-Path $runtimeRoot 'watch-claudedesk-bridge.ps1'
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
        $recordedWatcher = [string]$state.watcherScript
        $recordedPluginId = [string]$state.pluginId
        $recordedPluginVersion = [string]$state.pluginVersion
        $recordedRuntimeVersion = [string]$state.runtimeVersion
        $recordedThreadId = if ($state.PSObject.Properties['threadId']) { [string]$state.threadId } else { '' }
        $recordedRuntimeWatcher = Join-Path $localStateRoot "claudedesk-runtime-v1\$recordedRuntimeVersion\watch-claudedesk-bridge.ps1"
        $sameRuntime = $recordedRuntimeVersion -eq $runtimeVersion
        $sameThread = (-not $threadId) -or ($recordedThreadId -ceq $threadId)
        $verifiedBridgeProcess = $existingProcess -and
            $recordedWatcher -and
            $recordedRuntimeVersion -match '^[a-f0-9]{24}$' -and
            [string]$recordedWatcher -ieq $recordedRuntimeWatcher -and
            [string]$state.contextKey -ceq $resolvedContext -and
            $recordedPluginId -in @('cogentspec', 'cogentstack') -and
            $recordedPluginVersion -match '^\d+\.\d+\.\d+$' -and
            (Test-BridgeWatcherProcess `
                -ProcessInfo $existingProcess `
                -WatcherScript $recordedWatcher `
                -WatcherContextKey $resolvedContext `
                -WatcherPluginId $recordedPluginId `
                -WatcherPluginVersion $recordedPluginVersion `
                -WatcherThreadId $recordedThreadId `
                -WatcherReadyPath $readyPath)
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
                $conversationConnection = Confirm-CurrentConversationConnection `
                    -SurfaceName $Surface `
                    -ExperienceName $Experience `
                    -ConnectedContextKey $resolvedContext `
                    -ConnectedThreadId $threadId `
                    -PresenceVerified $true `
                    -ContextIsolated ([bool]$projectContext.Isolated)
                Write-CompactJson ([ordered]@{
                    status = 'ready'
                    bridge = 'already_running'
                    presenceVerified = $true
                    threadId = $threadId
                    processId = $existingProcessId
                    contextKey = $resolvedContext
                    contextIsolated = [bool]$projectContext.Isolated
                    workspaceUrl = $workspaceUrl
                    webWorkspaceUrl = $webWorkspaceUrl
                    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
                    browserOpened = $false
                    accountState = 'signed_in'
                    mcpState = $mcpState
                    defaultDirectoryReady = $true
                    defaultDirectoryCreated = [bool]$defaultDirectory.created
                    projectDataConnection = $projectDataConnection
                    pluginId = $pluginId
                    pluginVersion = $pluginVersion
                    currentConversationConnected = [bool]$conversationConnection.confirmed
                    conversationVerification = [string]$conversationConnection.verification
                    conversationUserMessage = [string]$conversationConnection.userMessage
                    conversationConnectionReason = [string]$conversationConnection.reason
                    popoutConnectionConfirmed = [bool]$conversationConnection.popoutConfirmed
                    popoutUserMessage = [string]$conversationConnection.userMessage
                    popoutConnectionReason = [string]$conversationConnection.reason
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
            Wait-Process -Id $existingProcessId -Timeout 2 -ErrorAction SilentlyContinue
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
$conversationConnection = Confirm-CurrentConversationConnection `
    -SurfaceName $Surface `
    -ExperienceName $Experience `
    -ConnectedContextKey $resolvedContext `
    -ConnectedThreadId $threadId `
    -PresenceVerified $true `
    -ContextIsolated ([bool]$projectContext.Isolated)

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
                    threadId = $threadId
    processId = $watcher.Id
    contextKey = $resolvedContext
    contextIsolated = [bool]$projectContext.Isolated
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    browserOpened = $false
    accountState = 'signed_in'
    mcpState = $mcpState
    defaultDirectoryReady = $true
    defaultDirectoryCreated = [bool]$defaultDirectory.created
    projectDataConnection = $projectDataConnection
    pluginId = $pluginId
    pluginVersion = $pluginVersion
    currentConversationConnected = [bool]$conversationConnection.confirmed
    conversationVerification = [string]$conversationConnection.verification
    conversationUserMessage = [string]$conversationConnection.userMessage
    conversationConnectionReason = [string]$conversationConnection.reason
    popoutConnectionConfirmed = [bool]$conversationConnection.popoutConfirmed
    popoutUserMessage = [string]$conversationConnection.userMessage
    popoutConnectionReason = [string]$conversationConnection.reason
    launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
})
