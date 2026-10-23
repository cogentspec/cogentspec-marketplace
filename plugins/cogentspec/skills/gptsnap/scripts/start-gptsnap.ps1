[CmdletBinding(DefaultParameterSetName = 'Normal')]
param(
    [ValidateRange(1, 50)][int]$WorkflowTimeoutSeconds = 50,
    [ValidateRange(1, 120)][int]$UpdateTimeoutSeconds = 120,
    [switch]$PrepareOnly,
    [Parameter(Mandatory = $true, ParameterSetName = 'Resume')]
    [switch]$ResumeApproval,
    [Parameter(Mandatory = $true, ParameterSetName = 'Resume')]
    [ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$script:deadlineMs = $WorkflowTimeoutSeconds * 1000
$stages = [Collections.Generic.List[object]]::new()
$stage = 'initialization'
$update = $null
$installer = $null
$installerVerified = $false
$timedOut = $false

function Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Remaining {
    $milliseconds = $script:deadlineMs - [int]$timer.ElapsedMilliseconds
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

function Run-Json([string]$File, [string[]]$Arguments, [string]$StageName) {
    $script:stage = $StageName
    $startedAt = [int]$timer.ElapsedMilliseconds
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.UseShellExecute = $false
    $info.WorkingDirectory = (Get-Location).ProviderPath
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
        try { $result = $output | ConvertFrom-Json } catch {
            $lines = @($output.Split([char]10) | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') })
            if (-not $lines.Count) { throw 'helper_result_invalid' }
            try { $result = $lines[-1] | ConvertFrom-Json } catch { throw 'helper_result_invalid' }
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
    $Result | Add-Member -NotePropertyName protocol -NotePropertyValue 'cogentspec-gptsnap-start-v1' -Force
    $Result | Add-Member -NotePropertyName workflowElapsedMs -NotePropertyValue ([int]$timer.ElapsedMilliseconds) -Force
    $Result | Add-Member -NotePropertyName workflowBudgetSeconds -NotePropertyValue ([int]($script:deadlineMs / 1000)) -Force
    $Result | Add-Member -NotePropertyName completedStages -NotePropertyValue @($stages) -Force
    $Result | Add-Member -NotePropertyName updateStatus -NotePropertyValue ([string](Value $update 'status' 'not_checked')) -Force
    if ($installerVerified) {
        $Result | Add-Member -NotePropertyName installedVersion -NotePropertyValue ([string](Value $installer 'version' '')) -Force
        $Result | Add-Member -NotePropertyName installerElapsedMs -NotePropertyValue (Value $installer 'installerElapsedMs') -Force
        $Result | Add-Member -NotePropertyName installerBudgetSeconds -NotePropertyValue (Value $installer 'installerBudgetSeconds') -Force
    }
    $Result | ConvertTo-Json -Compress -Depth 7 | Write-Output
}

function Forward-Failure($Result) {
    $safe = [pscustomobject]@{
        status = [string](Value $Result 'status' 'failed')
        failureStage = $script:stage
        userMessage = [string](Value $Result 'userMessage' 'CogentSpec could not verify GPTSnap startup. No workspace-open request was made.')
    }
    foreach ($name in @('userMessage')) {
        $property = $Result.PSObject.Properties[$name]
        if ($property) { $safe | Add-Member -NotePropertyName $name -NotePropertyValue $property.Value -Force }
    }
    Finish $safe
}

function Marketplace {
    $result = Run-Json $script:codexPath @('plugin', 'marketplace', 'list', '--json') 'marketplace_inspection'
    $matches = @($result.marketplaces | Where-Object { $_.name -eq 'cogentstack' })
    if ($matches.Count -ne 1 -or [string](Value (Value $matches[0] 'marketplaceSource') 'source' '') -cne 'https://github.com/cogentspec/cogentspec-marketplace.git') {
        throw 'marketplace_source_mismatch'
    }
    return [string]$matches[0].root
}


function Query([Uri]$Uri) {
    $values = @{}
    foreach ($entry in $Uri.Query.TrimStart('?').Split('&')) {
        $parts = $entry.Split('=', 2)
        if ($parts.Count -ne 2) { throw 'invalid_handoff' }
        $key = [Uri]::UnescapeDataString($parts[0])
        if ($values.ContainsKey($key)) { throw 'invalid_handoff' }
        $values[$key] = [Uri]::UnescapeDataString($parts[1])
    }
    return $values
}
function Safe-Origin([Uri]$Uri, [string]$HostName, [string]$Path) {
    return $Uri.Scheme -ceq 'https' -and $Uri.Host -ceq $HostName -and
        $Uri.Port -eq 443 -and -not $Uri.UserInfo -and $Uri.AbsolutePath -ceq $Path
}
try {
    $pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
    $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    $pluginId = [string]$manifest.name
    if ($pluginId -notin @('cogentspec', 'cogentstack')) { throw 'package_identity_invalid' }
    $coreScripts = Join-Path $pluginRoot "skills\$pluginId\scripts"
    $script:powerShellPath = (Get-Process -Id $PID).Path
    if ($ResumeApproval) {
        # Resume the same server-bound pending context; never update or create a replacement request.
        $resolvedContext = $ContextKey
        $update = [pscustomobject]@{ status = 'not_repeated_after_approval' }
    } else {
        $update = Run-Helper (Join-Path $coreScripts 'check-cogentspec-update.ps1') @('-Surface', 'chatgpt') 'update_check'
        if ([string]$update.status -eq 'update_available') {
            # Installation owns its separate 110s cleanup budget; normal connection remains capped at 50s.
            $script:deadlineMs += $UpdateTimeoutSeconds * 1000
            $script:codexPath = (Get-Command codex -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            [void](Marketplace)
            $upgrade = Run-Json $script:codexPath @('plugin', 'marketplace', 'upgrade', 'cogentstack', '--json') 'marketplace_upgrade'
            if (@(Value $upgrade 'errors' @()).Count) { throw 'marketplace_upgrade_failed' }
            $marketplaceRoot = Marketplace
            $installerPath = Join-Path $marketplaceRoot ".agents\plugins\install-$pluginId.ps1"
            if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw 'verified_installer_missing' }
            $installer = Run-Helper $installerPath @('-UpdateOnly', '-MarketplacePrepared', '-InstallerTimeoutSeconds', '120', '-DeferConnectionStartup') 'package_update'
            if ((Value $installer 'protocol') -cne 'trusted-marketplace-update-v1' -or
                (Value $installer 'status') -cne 'updated' -or
                (Value $installer 'claimAttempted') -cne $false -or
                (Value $installer 'accountRequestConsumed') -cne $false) { throw 'update_contract_invalid' }
            foreach ($field in @('credentialPreserved', 'previousPackageReplaced', 'packageRuntimeCleared',
                'workerStateCleared', 'connectionStartupDeferred', 'continueCurrentTask', 'fastUpdatePath', 'workspaceReadinessSkipped')) {
                if ((Value $installer $field) -cne $true) { throw 'update_contract_invalid' }
            }
            foreach ($field in @('popoutBridgeReady', 'desktopUiBridgeReady', 'projectDataConnectionReady')) {
                if ((Value $installer $field) -cne $false) { throw 'update_contract_invalid' }
            }
            $pluginRoot = (Resolve-Path -LiteralPath $installer.refreshedPluginPath).Path
            $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
            if ([string]$manifest.name -cne $pluginId -or [string]$manifest.version -cne [string]$installer.version) {
                throw 'refreshed_package_identity_invalid'
            }
            $installerVerified = $true
            $coreScripts = Join-Path $pluginRoot "skills\$pluginId\scripts"
        } elseif ([string]$update.status -notin @('current', 'check_unavailable')) {
            Forward-Failure $update; return
        }
        $context = Run-Helper (Join-Path $coreScripts 'project-context.ps1') @() 'context_resolution'
        if ((Value $context 'isolated') -cne $true -or [string]$context.contextKey -notmatch '^ctx-[a-f0-9]{64}$') {
            throw 'isolated_context_unavailable'
        }
        $resolvedContext = [string]$context.contextKey
    }
    $launcherArguments = @('-ContextKey', $resolvedContext, '-Surface', 'chatgpt', '-Experience', 'split-screen')
    if ($ResumeApproval) { $launcherArguments += '-ResumeApproval' }
    $result = Run-Helper (Join-Path $coreScripts 'start-cogentstack-bridge.ps1') $launcherArguments 'snap_launcher'
    $stage = 'destination_verification'
    if ([string]$result.status -eq 'approval_required') {
        if ($ResumeApproval -or (Value $result 'approvalProtocol') -cne 'cogentspec-gptsnap-approval-v1' -or
            (Value $result 'contextKey') -cne $resolvedContext -or (Value $result 'browserOpened') -cne $false) {
            throw 'invalid_approval'
        }
        $uri = [Uri][string]$result.approvalUrl
        $query = Query $uri
        $expiry = [DateTimeOffset]$result.expiresAt
        if (-not (Safe-Origin $uri 'cogentspec.com' '/activate') -or $uri.Fragment -or
            $query.Count -ne 2 -or -not $query.code -or $query.experience -cne 'split-screen' -or
            $expiry -le [DateTimeOffset]::UtcNow -or [int]$result.pollAfterSeconds -lt 5) { throw 'invalid_approval' }
        Finish ([pscustomobject]@{
            status = 'approval_required'; contextKey = $resolvedContext
            approvalProtocol = 'cogentspec-gptsnap-approval-v1'; approvalUrl = [string]$result.approvalUrl
            expiresAt = $expiry.ToString('o'); pollAfterSeconds = [int]$result.pollAfterSeconds
            browserOpened = $false; refreshedPluginPath = $pluginRoot
            browserNavigationCode = 'await gptPopTab.goto(' + (ConvertTo-Json -InputObject ([string]$result.approvalUrl) -Compress) + ');'
            userMessage = 'Approve this computer in CogentSpec to finish connecting GPTSnap.'
        }); return
    }
    if ([string]$result.status -cne 'ready') { Forward-Failure $result; return }
    $uri = [Uri][string]$result.workspaceUrl
    $query = Query $uri
    if (-not (Safe-Origin $uri 'cogentspec.app' '/stack') -or $query.Count -ne 5 -or
        $query.surface -cne 'chatgpt' -or $query.context -cne $resolvedContext -or
        $query.experience -cne 'split-screen' -or $query.open -cne 'web' -or
        $query.nav -notmatch '^[a-f0-9]{32}$' -or $uri.Fragment -notmatch '^#desktop-web=cgw_[A-Za-z0-9_-]{32,}$' -or
        $result.workspaceUrl -cne $result.webWorkspaceUrl -or $result.contextKey -cne $resolvedContext -or
        (Value $result 'contextIsolated') -cne $true -or (Value $result 'presenceVerified') -cne $true -or
        (Value $result 'accountState') -cne 'signed_in' -or (Value $result 'projectDataConnection') -cne 'authenticated_desktop_bridge' -or
        (Value $result 'mcpState') -cne 'not_required' -or (Value $result 'defaultDirectoryReady') -cne $true -or
        (Value $result 'browserOpened') -cne $false -or (Value $result 'bridge') -notin @('started', 'already_running')) {
        throw 'snap_ready_contract_invalid'
    }
    Finish ([pscustomobject]@{
        status = if ($PrepareOnly) { 'ready' } else { 'workspace_ready' }; contextKey = $resolvedContext; contextIsolated = $true
        workspaceUrl = [string]$result.workspaceUrl; webWorkspaceUrl = [string]$result.workspaceUrl
        browserNavigationProtocol = 'cogentspec-gptpop-navigation-v1'
        browserNavigationCode = 'await gptPopTab.goto(' + (ConvertTo-Json -InputObject ([string]$result.workspaceUrl) -Compress) + ');'
        browserOpened = $false; bridge = [string]$result.bridge
        presenceVerified = $true; accountState = 'signed_in'; projectDataConnection = 'authenticated_desktop_bridge'
        mcpState = 'not_required'; defaultDirectoryReady = $true
        pluginVersion = [string]$manifest.version; refreshedPluginPath = $pluginRoot
        userMessage = 'GPTSnap is ready to connect to the browser workspace.'
    })
    if ($PrepareOnly) { return }
    $workspaceCode = [Uri]::UnescapeDataString($uri.Fragment.Substring('#desktop-web='.Length))
    $acknowledgement = Run-Helper (Join-Path $coreScripts 'connect-cogentstack.ps1') @(
        '-Mode', 'workspace-status', '-ContextKey', $resolvedContext, '-Surface', 'chatgpt',
        '-WorkspaceCode', $workspaceCode, '-RequestTimeoutSeconds', '10'
    ) 'workspace_acknowledgement'
    if ((Value $acknowledgement 'protocol') -ceq 'cogentspec-workspace-connection-v1' -and
        (Value $acknowledgement 'status') -ceq 'connected' -and
        (Value $acknowledgement 'contextKey') -ceq $resolvedContext -and
        (Value $acknowledgement 'surface') -ceq 'chatgpt' -and
        (Value $acknowledgement 'experience') -ceq 'split-screen' -and
        (Value $acknowledgement 'acknowledgementVerified') -ceq $true) {
        Finish ([pscustomobject]@{ status = 'connected'; workspaceConnected = $true;
            contextKey = $resolvedContext; acknowledgementVerified = $true; userMessage = 'GPTSnap connected.' })
    } else {
        Finish ([pscustomobject]@{ status = 'not_connected'; workspaceConnected = $false;
            userMessage = 'The workspace opened, but GPTSnap could not confirm its connection. Nothing was retried.' })
    }
} catch {
    Finish ([pscustomobject]@{
        status = 'failed'; failureStage = $stage; workflowTimedOut = $timedOut
        userMessage = if ($timedOut) { 'GPTSnap could not connect within its startup time limit. No workspace was opened.' }
            else { 'GPTSnap could not verify the connection. Your projects are unchanged.' }
    })
}
