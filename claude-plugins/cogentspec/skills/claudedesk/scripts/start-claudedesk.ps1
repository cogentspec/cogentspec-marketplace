[CmdletBinding(DefaultParameterSetName = 'Normal')]
param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [ValidateRange(1, 100)]
    [int]$WorkflowTimeoutSeconds = 100,
    [Parameter(Mandatory = $true, ParameterSetName = 'VerifiedUpdate')]
    [switch]$UpdateAlreadyVerified,
    [Parameter(Mandatory = $true, ParameterSetName = 'VerifiedUpdate')]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$VerifiedInstalledVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$stages = [Collections.Generic.List[object]]::new()
$stage = 'initialization'
$update = $null
$timedOut = $false

function Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Remaining {
    $milliseconds = ($WorkflowTimeoutSeconds * 1000) - [int]$timer.ElapsedMilliseconds
    if ($milliseconds -le 0) {
        $script:timedOut = $true
        throw 'workflow_timeout'
    }
    return $milliseconds
}

function Quote-Argument([string]$Argument) {
    # Standard Windows argv escaping, including trailing backslashes.
    if ($Argument -notmatch '[\s"]' -and $Argument.Length) { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-OwnedProcess([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    try { $Process.Kill($true) } catch {
        if ($Process.HasExited) { return }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
        $info.Arguments = "/PID $($Process.Id) /T /F"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $killer = [Diagnostics.Process]::new()
        $killer.StartInfo = $info
        try {
            if ($killer.Start() -and -not $killer.WaitForExit(1500)) {
                try { $killer.Kill() } catch { }
            }
        } finally { $killer.Dispose() }
    }
    [void]$Process.WaitForExit(1500)
}

function Run-Json([string]$File, [string[]]$Arguments, [string]$StageName, [switch]$PlainOutput) {
    $script:stage = $StageName
    $startedAt = [int]$timer.ElapsedMilliseconds
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ([IO.Path]::GetExtension($File) -in @('.cmd', '.bat')) {
        $info.FileName = $env:ComSpec
        $quoted = @($Arguments | ForEach-Object { '"' + $_.Replace('"', '""') + '"' })
        $info.Arguments = '/d /s /c ""' + $File + '" ' + ($quoted -join ' ') + '"'
    } elseif ($info.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
    } else {
        $info.Arguments = (@($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        [void](Remaining)
        $started = $process.Start()
        if (-not $started) { throw 'process_start_failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit((Remaining))) {
            $script:timedOut = $true
            throw 'workflow_timeout'
        }
        if (-not $stdout.Wait((Remaining)) -or -not $stderr.Wait((Remaining))) {
            $script:timedOut = $true
            throw 'workflow_timeout'
        }
        # Never echo helper output or stderr on failure: it can contain handoffs.
        $output = $stdout.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) { throw 'helper_exit_failed' }
        if (-not $output) { throw 'helper_result_missing' }
        if ($PlainOutput) { $result = [pscustomobject]@{ status = 'completed' } }
        else { try { $result = $output | ConvertFrom-Json } catch {
            $lines = @($output.Split([char]10) | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') })
            if (-not $lines.Count) { throw 'helper_result_invalid' }
            try { $result = $lines[-1] | ConvertFrom-Json } catch { throw 'helper_result_invalid' }
        }
        }
        [void](Remaining)
        $script:stages.Add([ordered]@{ stage = $StageName; durationMs = [int]$timer.ElapsedMilliseconds - $startedAt })
        return $result
    } finally {
        if ($started -and -not $process.HasExited) { Stop-OwnedProcess $process }
        $process.Dispose()
    }
}

function Run-Helper([string]$File, [string[]]$Arguments, [string]$StageName) {
    return Run-Json $script:powerShellPath (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Arguments) $StageName
}

function Finish($Result) {
    $Result | Add-Member -NotePropertyName protocol -NotePropertyValue 'cogentspec-claudedesk-start-v1' -Force
    $Result | Add-Member -NotePropertyName workflowElapsedMs -NotePropertyValue ([int]$timer.ElapsedMilliseconds) -Force
    $Result | Add-Member -NotePropertyName workflowBudgetSeconds -NotePropertyValue $WorkflowTimeoutSeconds -Force
    $Result | Add-Member -NotePropertyName completedStages -NotePropertyValue @($stages) -Force
    $Result | Add-Member -NotePropertyName updateStatus -NotePropertyValue ([string](Value $update 'status' 'not_checked')) -Force
    $Result | ConvertTo-Json -Compress -Depth 7 | Write-Output
}

function Forward-Failure($Result) {
    $safe = [pscustomobject]@{
        status = [string](Value $Result 'status' 'failed')
        failureStage = $script:stage
        userMessage = [string](Value $Result 'userMessage' 'CogentSpec could not verify ClaudeDesk startup. No workspace-open request was made.')
    }
    foreach ($name in @('reason', 'userMessage', 'conversationConnectionReason', 'conversationUserMessage',
        'conversationVerification')) {
        $property = $Result.PSObject.Properties[$name]
        if ($property) { $safe | Add-Member -NotePropertyName $name -NotePropertyValue $property.Value -Force }
    }
    Finish $safe
}

function Marketplace {
    $result = @(Run-Json $script:claudePath @('plugin', 'marketplace', 'list', '--json') 'marketplace_inspection')
    $matches = @($result | Where-Object { $_.name -eq 'cogentstack' })
    if ($matches.Count -ne 1 -or $matches[0].source -cne 'github' -or
        $matches[0].repo -cne 'cogentspec/cogentspec-marketplace') { throw 'marketplace_source_mismatch' }
    return [string]$matches[0].installLocation
}

function Installed([string]$Id) {
    $result = @(Run-Json $script:claudePath @('plugin', 'list', '--json') 'installed_inspection')
    $matches = @($result | Where-Object { $_.id -ceq "$Id@cogentstack" })
    if ($matches.Count -ne 1 -or $matches[0].enabled -cne $true -or
        $matches[0].scope -notin @('user', 'project', 'local', 'managed')) { throw 'installed_package_unavailable' }
    return $matches[0]
}

function Test-Workspace([string]$Url, [string]$Context, [string]$Open, [string]$FragmentPrefix) {
    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'cogentspec.app' -or $uri.Port -ne 443 -or
            $uri.UserInfo -or $uri.AbsolutePath -cne '/stack') { return $false }
        $query = @{}
        foreach ($entry in $uri.Query.TrimStart('?').Split('&')) {
            $parts = $entry.Split('=', 2)
            if ($parts.Count -ne 2) { return $false }
            $key = [Uri]::UnescapeDataString($parts[0])
            if ($query.ContainsKey($key)) { return $false }
            $query[$key] = [Uri]::UnescapeDataString($parts[1])
        }
        return $query.Count -eq 5 -and $query.surface -ceq 'claude-desktop' -and $query.context -ceq $Context -and
            $query.experience -ceq 'desktop-ui' -and $query.open -ceq $Open -and
            $query.nav -match '^[a-f0-9]{32}$' -and $uri.Fragment.StartsWith($FragmentPrefix) -and
            $uri.Fragment.Substring($FragmentPrefix.Length) -match '^cgw_[A-Za-z0-9_-]{32,200}$'
    } catch { return $false }
}

try {
    if ($SessionId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') { throw 'claude_session_unavailable' }
    $pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
    $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
    $pluginId = [string]$manifest.name
    if ($pluginId -notin @('cogentspec', 'cogentstack')) { throw 'package_identity_invalid' }
    $coreScripts = Join-Path $pluginRoot "skills\$pluginId\scripts"
    $script:powerShellPath = (Get-Process -Id $PID).Path
    if ($UpdateAlreadyVerified) {
        # The caller must have checked the full trusted update-only contract.
        # Match its version to this installed package; never rerun its update.
        if ([string]$manifest.version -cne $VerifiedInstalledVersion) { throw 'refreshed_package_identity_invalid' }
        $update = [pscustomobject]@{ status = 'verified_update'; installedVersion = $VerifiedInstalledVersion }
    } else {
        $update = Run-Helper (Join-Path $PSScriptRoot 'check-claudedesk-update.ps1') @() 'update_check'
    }
    if ([string]$update.status -eq 'execution_permission_required') { Forward-Failure $update; return }
    if ([string]$update.status -eq 'update_available') {
        $script:claudePath = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        [void](Marketplace)
        $installedBefore = Installed $pluginId
        if ([IO.Path]::GetFullPath([string]$installedBefore.installPath) -ine $pluginRoot) { throw 'installed_package_unavailable' }
        $scope = [string]$installedBefore.scope
        [void](Run-Json $script:claudePath @('plugin', 'marketplace', 'update', 'cogentstack') 'marketplace_upgrade' -PlainOutput)
        $marketplaceRoot = Marketplace
        $published = Get-Content -LiteralPath (Join-Path $marketplaceRoot "claude-plugins\$pluginId\.claude-plugin\plugin.json") -Raw | ConvertFrom-Json
        if ($published.name -cne $pluginId -or [string]$published.version -cne [string]$update.availableVersion) { throw 'refreshed_package_identity_invalid' }
        [void](Run-Json $script:claudePath @('plugin', 'update', "$pluginId@cogentstack", '--scope', $scope) 'package_update' -PlainOutput)
        $installedAfter = Installed $pluginId
        if ($installedAfter.scope -cne $scope -or $installedAfter.version -cne $published.version) { throw 'update_contract_invalid' }
        $pluginRoot = (Resolve-Path -LiteralPath $installedAfter.installPath).Path
        $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        if ($manifest.name -cne $pluginId -or $manifest.version -cne $published.version) { throw 'refreshed_package_identity_invalid' }
        # The command's own hash/version/session checks replace only its own
        # worker. Never run the global reset that clears other connector types.
        $coreScripts = Join-Path $pluginRoot "skills\$pluginId\scripts"
        $update = [pscustomobject]@{ status = 'updated'; installedVersion = $manifest.version }
    } elseif ([string]$update.status -notin @('current', 'check_unavailable', 'verified_update')) {
        Forward-Failure $update
        return
    }
    $context = Run-Helper (Join-Path $coreScripts 'project-context.ps1') @() 'context_resolution'
    if ((Value $context 'isolated') -cne $true -or [string]$context.contextKey -notmatch '^ctx-[a-f0-9]{64}$') {
        throw 'isolated_context_unavailable'
    }
    $result = Run-Helper (Join-Path $pluginRoot 'skills\claudedesk\scripts\start-claudedesk-bridge.ps1') @(
        '-ContextKey', [string]$context.contextKey, '-SessionId', $SessionId
    ) 'desk_launcher'
    if ([string]$result.status -cne 'ready') { Forward-Failure $result; return }
    $stage = 'ready_contract'
    if ($result.accountState -cne 'signed_in' -or $result.mcpState -cne 'not_required' -or
        $result.projectDataConnection -cne 'authenticated_desktop_bridge' -or
        $result.presenceVerified -cne $true -or $result.contextIsolated -cne $true -or $result.threadId -cne $SessionId -or
        $result.browserOpened -cne $false -or $result.bridge -notin @('started', 'already_running') -or
        $result.contextKey -cne $context.contextKey -or $result.workspaceUrl -cne $result.chatgptWorkspaceUrl -or
        -not (Test-Workspace $result.workspaceUrl $context.contextKey 'chatgpt' '#desktop-chatgpt=') -or
        -not (Test-Workspace $result.webWorkspaceUrl $context.contextKey 'web' '#desktop-web=')) {
        throw 'desk_ready_contract_invalid'
    }
    # ClaudeDesk is bound to its invoking Claude session. A Snap acknowledgement or
    # legacy Popout confirmation cannot verify this conversation.
    $deskConfirmed = (Value $result 'currentConversationConnected' $false) -ceq $true -and
        (Value $result 'conversationVerification') -ceq 'claude_desktop_session_presence'
    # Keep only the native-open contract and bounded reporting fields.
    $safe = [pscustomobject]@{
        status = 'ready'; bridge = $result.bridge; contextKey = $result.contextKey
        accountState = $result.accountState; mcpState = $result.mcpState; browserOpened = $false
        workspaceUrl = $result.workspaceUrl; chatgptWorkspaceUrl = $result.chatgptWorkspaceUrl; webWorkspaceUrl = $result.webWorkspaceUrl
        pluginVersion = [string]$manifest.version; refreshedPluginPath = $pluginRoot
        currentConversationConnected = $deskConfirmed
        conversationVerification = Value $result 'conversationVerification'
        conversationConnectionReason = if ($deskConfirmed) { Value $result 'conversationConnectionReason' } else { 'current_claude_desktop_session_not_verified' }
        conversationUserMessage = if ($deskConfirmed) { Value $result 'conversationUserMessage' } else { 'The project-data Bridge is ready, but the current ClaudeDesk conversation could not be verified. The workspace remains disconnected.' }
        launcherElapsedMs = Value $result 'launcherElapsedMs'
    }
    Finish $safe
} catch {
    # Do not expose private helper output, exception bodies, paths or credentials.
    $failureCode = [string]$_.Exception.Message
    if ($failureCode -notin @('workflow_timeout', 'package_identity_invalid', 'process_start_failed',
        'helper_exit_failed', 'helper_result_missing', 'helper_result_invalid', 'marketplace_source_mismatch',
        'marketplace_upgrade_failed', 'verified_installer_missing', 'update_contract_invalid',
        'refreshed_package_identity_invalid', 'isolated_context_unavailable', 'desk_ready_contract_invalid',
        'claude_session_unavailable', 'installed_package_unavailable')) {
        $failureCode = 'desk_start_failed'
    }
    Finish ([pscustomobject]@{
        status = 'failed'; failureStage = $stage; workflowTimedOut = $timedOut
        reason = if ($timedOut) { 'workflow_timeout' } else { $failureCode }
        userMessage = if ($timedOut) { 'CogentSpec could not finish ClaudeDesk startup within its time budget. No workspace-open request was made.' }
            else { "CogentSpec could not complete ClaudeDesk startup at stage '$stage'. No workspace-open request was made." }
    })
}
