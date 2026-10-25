[CmdletBinding()]
param(
    [string]$ContextKey = '',

    [ValidateSet('chatgpt', 'claude-desktop', 'qwen-web')]
    [string]$Surface = 'chatgpt',

    [ValidateSet('legacy', 'popout', 'desktop-ui', 'web', 'split-screen')]
    [string]$Experience = 'legacy',

    [switch]$ListenerOnly,

    [switch]$ResumeApproval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$launcherTimer = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'project-context.ps1')
. (Join-Path $PSScriptRoot 'native-command.ps1')

function Get-GptPopBrowserNavigation([string]$WorkspaceUrl, [string]$ContextKey, [string]$SurfaceName) {
    # Return only the exact context-bound external-tab call; never open a host pane.
    $expected = '^https://cogentspec\.app/stack\?surface=chatgpt&context=' + [Regex]::Escape($ContextKey) + '&experience=split-screen&open=web&nav=[a-f0-9]{32}#desktop-web=cgw_[A-Za-z0-9_-]{32,}$'
    if ($SurfaceName -cne 'chatgpt' -or $ContextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or $WorkspaceUrl -cnotmatch $expected) {
        throw 'The GPTPop external browser handoff is invalid.'
    }
    return [ordered]@{
        protocol = 'cogentspec-gptpop-navigation-v1'
        code = 'await gptPopTab.goto(' + (ConvertTo-Json -InputObject $WorkspaceUrl -Compress) + ');'
    }
}

function Get-ClaudeSnapBrowserNavigation([string]$WorkspaceUrl, [string]$ContextKey, [string]$SurfaceName) {
    # Keep Claude's context-bound handoff separate from GPT and ordinary Web.
    $expected = '^https://cogentspec\.app/stack\?surface=claude-desktop&context=' + [Regex]::Escape($ContextKey) + '&experience=split-screen&open=web&nav=[a-f0-9]{32}#desktop-web=cgw_[A-Za-z0-9_-]{32,}$'
    if ($SurfaceName -cne 'claude-desktop' -or $ContextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or $WorkspaceUrl -cnotmatch $expected) {
        throw 'The ClaudeSnap external browser handoff is invalid.'
    }
    return [ordered]@{
        protocol = 'cogentspec-claudesnap-navigation-v1'
        code = 'await claudeSnapTab.goto(' + (ConvertTo-Json -InputObject $WorkspaceUrl -Compress) + ');'
    }
}

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
# Standalone runtime identity; no AI plugin manager or skill package is used.
$runtimePackage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\runtime.json') -Raw | ConvertFrom-Json
if ($runtimePackage.protocol -cne 'cogentspec-standalone-web-runtime-v1') { throw 'Invalid standalone Bridge runtime.' }
$pluginId = 'cogentspec' # Existing worker wire identifier, not an installed plugin.
$pluginVersion = [string]$runtimePackage.bridgeCompatibilityVersion

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
    $transport = ''
    if ($env:COGENTSPEC_GPTWEB_LOOPBACK_PROXY) {
        $proxy = [string]$env:COGENTSPEC_GPTWEB_LOOPBACK_PROXY
        if ($proxy -cnotmatch '^http://127\.0\.0\.1:([0-9]{4,5})$' -or [int]$Matches[1] -lt 1024 -or [int]$Matches[1] -gt 65535) {
            throw 'GPTWeb loopback transport is invalid.'
        }
        $transport = "[Net.WebRequest]::DefaultWebProxy=New-Object Net.WebProxy('$proxy'); "
    }
    return $transport + "& '$(& $escape $WatcherScript)' -ContextKey '$(& $escape $WatcherContextKey)' -PluginId '$(& $escape $WatcherPluginId)' -PluginVersion '$(& $escape $WatcherPluginVersion)' -ThreadId '$(& $escape $WatcherThreadId)' -ReadyPath '$(& $escape $WatcherReadyPath)'"
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
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [UInt16]0 }
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

function Read-DesktopBridgeToken {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { return '' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $protected = [Convert]::FromBase64String([string]$credential.token)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-FreshPopoutInspection([string]$HelperPath) {
    try {
        $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
        $state = Get-Content -Raw -LiteralPath (Join-Path $root 'popout-bridge\worker.json') | ConvertFrom-Json
        $marker = Get-Content -Raw -LiteralPath (Join-Path $root 'popout-bridge\ready.json') | ConvertFrom-Json
        $expectedWatcher = Join-Path $root "popout-runtime\$pluginId-$pluginVersion\watch-cogentspec-popout-bridge.ps1"
        $age = ([DateTime]::UtcNow - ([DateTime]$marker.acknowledgedAt).ToUniversalTime()).TotalSeconds
        if ($age -lt 0 -or $age -gt 3 -or -not [bool]$marker.serverAcknowledged -or
            [string]$marker.status -ne 'ready' -or [string]$marker.pluginId -cne $pluginId -or
            [string]$marker.pluginVersion -cne $pluginVersion -or
            [int]$marker.processId -ne [int]$state.processId -or [int]$state.processId -le 0 -or
            [string]$state.watcherScript -ine $expectedWatcher -or
            [string]$marker.conversationState -ne 'identified' -or -not [bool]$marker.connectedChatMarkerFound -or
            [string]$marker.currentConversationKey -notmatch '^[a-f0-9]{64}$' -or
            [long]$marker.popupWindowHandle -eq 0) { return $null }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.processId)" -ErrorAction Stop
        if (-not $process -or [string]$process.CommandLine -notmatch '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)') { return $null }
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        if (-not $command.Contains($expectedWatcher.Replace("'", "''"))) { return $null }
        # Never consume a snapshot from another or stale package implementation.
        $runtimeHelper = Join-Path (Split-Path -Parent $expectedWatcher) 'open-chatgpt-popup.ps1'
        if ((Get-FileHash -LiteralPath $runtimeHelper -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath $HelperPath -Algorithm SHA256).Hash) { return $null }
        return [pscustomobject]@{
            status = 'ready'; publisherVerified = $true; popupVerified = $true
            conversationState = 'identified'; currentConversationKey = [string]$marker.currentConversationKey
            chatFingerprint = [string]$marker.currentConversationKey
        }
    } catch { return $null }
}

function Confirm-StandalonePopoutConnection([string]$SurfaceName, [string]$ConnectedContextKey, [string]$ConnectedThreadId) {
    if ($ListenerOnly) { return [ordered]@{ confirmed = $false; popoutConfirmed = $false; reason = 'authenticated_workspace'; verification = 'authenticated_workspace'; userMessage = 'The owning workspace listener confirms this connection.' } }
    if ($SurfaceName -ne 'chatgpt') { return [ordered]@{ confirmed = $false; reason = 'not_applicable' } }
    $token = ''
    try {
        $token = Read-DesktopBridgeToken
        if (-not $token) { return [ordered]@{ confirmed = $false; reason = 'desktop_credential_unavailable' } }
        $popupHelperPath = Join-Path $PSScriptRoot 'open-chatgpt-popup.ps1'
        if (-not (Test-Path -LiteralPath $popupHelperPath -PathType Leaf)) {
            return [ordered]@{ confirmed = $false; reason = 'inspection_helper_missing' }
        }
        # UI Automation has a measurable cold-start cost. Keep this bounded well
        # below the one-minute workflow target without killing a valid first run.
        $inspection = Read-FreshPopoutInspection -HelperPath $popupHelperPath
        if ($null -eq $inspection) {
        $inspectionResult = Invoke-CogentSpecNativeCommand -FilePath $popupHelperPath -ArgumentList @('-Mode', 'inspect') -TimeoutSeconds 15
        if ($inspectionResult.TimedOut) {
            return [ordered]@{ confirmed = $false; reason = 'popout_inspection_timed_out' }
        }
        if ($inspectionResult.ExitCode -ne 0) {
            return [ordered]@{ confirmed = $false; reason = 'popout_inspection_failed' }
        }
        $inspectionOutput = @($inspectionResult.Output -split "`r?`n")
        $inspectionJson = @($inspectionOutput | ForEach-Object { [string]$_ } |
            Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if (-not $inspectionJson) {
            return [ordered]@{ confirmed = $false; reason = 'popout_inspection_unavailable' }
        }
        $inspection = $inspectionJson | ConvertFrom-Json
        }
        $chatFingerprint = if ($inspection.PSObject.Properties['chatFingerprint']) {
            [string]$inspection.chatFingerprint
        } else { '' }
        $currentConversationKey = if ($inspection.PSObject.Properties['currentConversationKey']) {
            [string]$inspection.currentConversationKey
        } else { '' }
        $conversationState = if ($inspection.PSObject.Properties['conversationState']) {
            [string]$inspection.conversationState
        } else { 'unknown' }
        if ([string]$inspection.status -ne 'ready' -or -not [bool]$inspection.publisherVerified -or
            -not [bool]$inspection.popupVerified -or $conversationState -ne 'identified' -or
            $chatFingerprint -notmatch '^[a-f0-9]{64}$' -or
            $currentConversationKey -cne $chatFingerprint) {
            return [ordered]@{ confirmed = $false; reason = 'current_popout_conversation_not_verified' }
        }
        $body = @{
            contextKey = $ConnectedContextKey
            threadId = $ConnectedThreadId
            chatFingerprint = $chatFingerprint
        } | ConvertTo-Json -Compress
        $requestParameters = @{
            Method = 'Post'
            Uri = 'https://cogentspec.com/api/plugin/desktop-popout-actions'
            Headers = @{ Accept = 'application/json'; Authorization = "Bearer $token" }
            ContentType = 'application/json'
            Body = $body
            TimeoutSec = 5
        }
        $response = Invoke-RestMethod @requestParameters
        if ([bool]$response.confirmed) {
            return [ordered]@{ confirmed = $true; reason = 'confirmed' }
        }
        return [ordered]@{ confirmed = $false; reason = 'server_rejected_confirmation' }
    } catch {
        # The normal task connection must not fail when no standalone Popout
        # reconnection is waiting to be confirmed, but the result must expose
        # that exact-chat confirmation did not complete.
        return [ordered]@{ confirmed = $false; reason = 'connection_confirmation_failed' }
    } finally {
        $token = $null
    }
}

function Confirm-CurrentConversationConnection(
    [string]$SurfaceName,
    [string]$ExperienceName,
    [string]$ConnectedContextKey,
    [string]$ConnectedThreadId,
    [bool]$PresenceVerified,
    [bool]$ContextIsolated
) {
    if ($SurfaceName -ne 'chatgpt') {
        return [ordered]@{
            confirmed = $false; popoutConfirmed = $false; reason = 'not_applicable'
            verification = 'not_applicable'; userMessage = 'Exact ChatGPT conversation verification does not apply to this surface.'
        }
    }
    if ($ExperienceName -eq 'desktop-ui') {
        # GPTDesk is attached to the invoking host task, not to the standalone
        # Popout window. The ready marker has already been authenticated by the
        # service and matched to this exact context, package, process and thread.
        $threadVerified = $ConnectedThreadId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        if (-not $PresenceVerified -or -not $ContextIsolated -or -not $threadVerified) {
            return [ordered]@{
                confirmed = $false; popoutConfirmed = $false; reason = 'current_desktop_conversation_not_verified'
                verification = 'desktop_thread_presence'
                userMessage = 'The project-data Bridge is ready, but the current GPT Desk conversation could not be verified. The workspace remains disconnected.'
            }
        }
        return [ordered]@{
            confirmed = $true; popoutConfirmed = $false; reason = 'desktop_thread_presence_confirmed'
            verification = 'desktop_thread_presence'; userMessage = 'The current GPT Desk conversation is connected.'
        }
    }
    if ($ExperienceName -eq 'split-screen') {
        return [ordered]@{
            confirmed = $false; popoutConfirmed = $false; reason = 'not_applicable'
            verification = 'authenticated_workspace'
            userMessage = 'The split-screen workspace uses the authenticated project Bridge; no Popout conversation is required.'
        }
    }
    if ($ExperienceName -eq 'web') {
        return [ordered]@{
            confirmed = $false; popoutConfirmed = $false; reason = 'not_applicable'
            verification = 'web_destination'; userMessage = 'Exact desktop-conversation verification does not apply to the Web destination.'
        }
    }
    $popout = Confirm-StandalonePopoutConnection `
        -SurfaceName $SurfaceName `
        -ConnectedContextKey $ConnectedContextKey `
        -ConnectedThreadId $ConnectedThreadId
    return [ordered]@{
        confirmed = [bool]$popout.confirmed
        popoutConfirmed = [bool]$popout.confirmed
        reason = [string]$popout.reason
        verification = 'popout_fingerprint'
        userMessage = if ($popout.confirmed) { 'The current Popout conversation is connected.' }
            else { 'The project-data Bridge is ready, but the current Popout conversation could not be verified. The workspace remains disconnected.' }
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
$threadId = if ($Surface -eq 'chatgpt' -and [string]$env:CODEX_THREAD_ID -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    [string]$env:CODEX_THREAD_ID
} else { '' }
$workspaceUrl = $connectionUrl
$webWorkspaceUrl = $connectionUrl
$chatgptWorkspaceUrl = $connectionUrl
$connectionScript = Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
$sourceScriptNames = @(
    'connect-cogentstack.ps1',
    'ensure-default-project-directory.ps1',
    'create-specification-project.ps1',
    'delete-specification-project.ps1',
    'delete-project.ps1',
    'ensure-cogentspec-mcp.ps1',
    'fulfil-project.ps1',
    'generate-project-preview.ps1',
    'inspect-project-git.ps1',
    'project-git-connection.ps1',
    'restore-project-version.ps1',
    'save-project-version.ps1',
    'native-command.ps1',
    'open-chatgpt-popup.ps1',
    'open-claude-desktop-ui.ps1',
    'prepare-development-handoff.ps1',
    'project-context.ps1',
    'project-build-handoff.ps1',
    'project-preview-readiness.ps1',
    'project-credential-worker.ps1',
    'provision-project-credentials.mjs',
    'watch-cogentstack-bridge.ps1'
)
if ($Surface -eq 'chatgpt' -or (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'open-chatgpt-desktop-ui.ps1') -PathType Leaf)) {
    # The worker resolves main-window visibility actions from this hashed runtime.
    # Keep one runtime per package even when a Codex package serves a Claude context.
    # Claude-only packages intentionally omit ChatGPT native window helpers.
    $sourceScriptNames += 'open-chatgpt-desktop-ui.ps1'
}
if (-not (Test-Path -LiteralPath $connectionScript -PathType Leaf) -or @($sourceScriptNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) }).Count -gt 0) {
    throw 'Desktop Bridge is incomplete. Repair the CogentSpec installation.'
}

$powershellExecutable = Get-HostPowerShellExecutable
# This package is GPTWeb's private, versioned runtime. Its pending approval is
# separate from Snap; completing it never opens a tab or starts another command.
if ($ResumeApproval) {
    $resumeOutput = @(& $connectionScript -Mode complete -Surface chatgpt -ContextKey $resolvedContext -BrowserApproval -RequestTimeoutSeconds 6 2>&1)
    $resumeLine = @($resumeOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $resumeLine) { throw 'GPTWeb approval could not be verified.' }
    $resumed = $resumeLine[0] | ConvertFrom-Json
    if ($resumed.status -ne 'connected') { Write-CompactJson $resumed; return }
}
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
    if ($Surface -eq 'chatgpt' -and $Experience -eq 'web') {
        if (-not $ResumeApproval) {
            $approval = (& $connectionScript -Mode start -Surface $Surface -ContextKey $resolvedContext -BrowserApproval -RequestTimeoutSeconds 6) | ConvertFrom-Json
            if ($approval.status -ne 'approval_required') {
                Write-CompactJson $approval
                return
            }
            $approvalUri = [Uri][string]$approval.approvalUrl
            if ($approvalUri.GetLeftPart([UriPartial]::Authority) -cne 'https://cogentspec.com' -or $approvalUri.AbsolutePath -cne '/activate') {
                throw 'The GPTWeb approval destination is invalid.'
            }
            Write-CompactJson ([ordered]@{
                status = 'approval_required'
                contextKey = $resolvedContext
                approvalUrl = [string]$approval.approvalUrl
                expiresAt = ([DateTimeOffset]$approval.expiresAt).ToString('o')
                pollAfterSeconds = [int]$approval.pollAfterSeconds
                approvalProtocol = 'cogentspec-gptweb-approval-v1'
                browserNavigationCode = 'await gptPopTab.goto(' + (ConvertTo-Json -InputObject ([string]$approval.approvalUrl) -Compress) + ');'
                userMessage = 'Approve this computer during one-time GPTWeb setup. The existing tab will finish connecting after approval.'
                browserOpened = $false
                launcherElapsedMs = [int]$launcherTimer.ElapsedMilliseconds
            })
            return
        }
        Write-CompactJson ([ordered]@{ status = 'connection_required'; userMessage = 'The computer approval did not create a usable connection. Your projects are unchanged.' })
        return
    }
    $connectionReason = if ($connection.PSObject.Properties['reason'] -and [string]$connection.reason) { [string]$connection.reason } else { 'desktop_bridge_not_installed' }
    $recoveryExperience = if ($Experience -eq 'split-screen') { 'split-screen' } else { 'standard' }
    $recoveryUrl = "https://cogentspec.com/install?mode=reconnect&experience=$([Uri]::EscapeDataString($recoveryExperience))"
    $retryCommand = if ($Experience -eq 'split-screen' -and $Surface -eq 'chatgpt') { '$gptsnap' } else { '$cogentspec' }
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
# The authenticated device check and browser grant above, plus fresh worker
# acknowledgement below, authorize Web. A separate CLI tool login is not a
# prerequisite for opening that workspace. Desk/Popout keep their existing gate.
$requiresCodexMcp = -not $ListenerOnly -and $Surface -eq 'chatgpt' -and $Experience -notin @('web', 'split-screen')
$projectDataConnection = if ($requiresCodexMcp) { 'codex_mcp' } else { 'authenticated_desktop_bridge' }
if ($requiresCodexMcp) {
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
. (Join-Path $PSScriptRoot 'ensure-default-project-directory.ps1')
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
$webLaunchBaseUrl = if ($Surface -eq 'chatgpt' -and $Experience -in @('legacy', 'popout')) { $workspaceBaseUrl.Replace('/stack?', '/popout-launch?') } else { $workspaceBaseUrl }
$webWorkspaceUrl = "$webLaunchBaseUrl&open=web&nav=$navigationKey#desktop-web=$([Uri]::EscapeDataString([string]$connection.webWorkspaceCode))"
$chatgptWorkspaceUrl = "$workspaceBaseUrl&open=chatgpt&nav=$navigationKey#desktop-chatgpt=$([Uri]::EscapeDataString([string]$connection.chatgptWorkspaceCode))"
$workspaceUrl = if ($Experience -in @('popout', 'web', 'split-screen')) { $webWorkspaceUrl } else { $chatgptWorkspaceUrl }
$splitScreenNavigation = $null
if ($Experience -eq 'split-screen') {
    try {
        $splitScreenNavigation = if ($Surface -eq 'claude-desktop') {
            Get-ClaudeSnapBrowserNavigation -WorkspaceUrl $workspaceUrl -ContextKey $resolvedContext -SurfaceName $Surface
        } else {
            Get-GptPopBrowserNavigation -WorkspaceUrl $workspaceUrl -ContextKey $resolvedContext -SurfaceName $Surface
        }
    } catch {
        Write-CompactJson ([ordered]@{ status = 'invalid_workspace_handoff'; reason = 'split_screen_url_contract_mismatch'; userMessage = 'CogentSpec could not prepare the verified external split-screen workspace link.' })
        return
    }
}

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
        $recordedWatcher = [string]$state.watcherScript
        $recordedPluginId = [string]$state.pluginId
        $recordedPluginVersion = [string]$state.pluginVersion
        $recordedRuntimeVersion = [string]$state.runtimeVersion
        $recordedThreadId = if ($state.PSObject.Properties['threadId']) { [string]$state.threadId } else { '' }
        $recordedRuntimeWatcher = Join-Path $localStateRoot "bridge-runtime\$recordedRuntimeVersion\watch-cogentstack-bridge.ps1"
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
        # A verified compatible worker may belong to a different connector.
        # Reuse it in place; this GPTWeb runtime never replaces an existing worker.
        if ($verifiedBridgeProcess) {
            $presenceReady = Wait-BridgePresenceReady `
                -ReadyPath $readyPath `
                -ProcessId $existingProcessId `
                -ExpectedContextKey $resolvedContext `
                -ExpectedPluginId $recordedPluginId `
                -ExpectedPluginVersion $recordedPluginVersion `
                -ExpectedThreadId $recordedThreadId `
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
                    processId = $existingProcessId
                    contextKey = $resolvedContext
                    contextIsolated = [bool]$projectContext.Isolated
                    workspaceUrl = $workspaceUrl
                    webWorkspaceUrl = $webWorkspaceUrl
                    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
                    browserOpened = $false
                    browserNavigationProtocol = if ($splitScreenNavigation) { $splitScreenNavigation.protocol } else { $null }
                    browserNavigationCode = if ($splitScreenNavigation) { $splitScreenNavigation.code } else { $null }
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
            Write-CompactJson ([ordered]@{ status = 'worker_in_use'; browserOpened = $false; userMessage = 'The existing worker is not ready. GPTWeb did not stop or replace it.' })
            return
        }
        if ($existingProcess) {
            Write-CompactJson ([ordered]@{ status = 'worker_in_use'; browserOpened = $false; userMessage = 'GPTWeb could not verify the existing worker. It was not stopped or replaced.' })
            return
        }
    } catch { }
}

# Do not remove a readiness record belonging to a concurrent connector startup.

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
    processId = $watcher.Id
    contextKey = $resolvedContext
    contextIsolated = [bool]$projectContext.Isolated
    workspaceUrl = $workspaceUrl
    webWorkspaceUrl = $webWorkspaceUrl
    chatgptWorkspaceUrl = $chatgptWorkspaceUrl
    browserOpened = $false
    browserNavigationProtocol = if ($splitScreenNavigation) { $splitScreenNavigation.protocol } else { $null }
    browserNavigationCode = if ($splitScreenNavigation) { $splitScreenNavigation.code } else { $null }
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
