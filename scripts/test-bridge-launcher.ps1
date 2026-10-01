[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-BridgeLauncherTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-TextSha256([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
    finally { $algorithm.Dispose() }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("cogentspec-bridge-launcher-" + [Guid]::NewGuid().ToString('N'))
$fixturePlugin = Join-Path $fixtureRoot 'cogentspec'
$fixtureScripts = Join-Path $fixturePlugin 'skills\cogentspec\scripts'
$contextDigest = ([BitConverter]::ToString((Get-TextSha256 $fixtureRoot))).Replace('-', '').ToLowerInvariant()
$contextKey = "ctx-$contextDigest"
$contextHash = ([BitConverter]::ToString((Get-TextSha256 $contextKey))).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\bridge'
$statePath = Join-Path $stateRoot "$contextHash.json"
$readyPath = Join-Path $stateRoot "$contextHash.ready.json"
$connectorProcessPath = Join-Path $fixtureRoot 'connector-process.txt'
$runtimeRoot = ''
$workerProcessId = 0
$launcherProcessId = 0
$launcherProcess = $null
$originalConnectorProcessPath = $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH

try {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec') -Destination $fixturePlugin -Recurse -Force

    $connectionFixture = @'
param(
    [string]$Mode,
    [string]$Surface,
    [string]$ContextKey,
    [switch]$WorkspaceGrant,
    [int]$RequestTimeoutSeconds
)
if ($Mode -ne 'status' -or -not $WorkspaceGrant -or $RequestTimeoutSeconds -ne 8) {
    throw 'The launcher did not make the bounded direct status request.'
}
[string]$PID | Set-Content -LiteralPath $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH -Encoding ascii
[ordered]@{
    status = 'connected'
    webWorkspaceCode = 'cgw_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    chatgptWorkspaceCode = 'cgw_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'connect-cogentstack.ps1') -Value $connectionFixture -Encoding UTF8

    $projectDataConnectionFixture = @'
param([string]$Surface)
[ordered]@{
    status = 'ready'
    connection = 'already_connected'
    userMessage = 'CogentSpec is ready.'
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'ensure-cogentspec-mcp.ps1') -Value $projectDataConnectionFixture -Encoding UTF8

$watcherFixture = @'
param(
    [string]$ContextKey,
    [string]$PluginId,
    [string]$PluginVersion,
    [string]$ReadyPath
)
Start-Sleep -Milliseconds 700
for ($heartbeat = 0; $heartbeat -lt 15; $heartbeat += 1) {
    [ordered]@{
        processId = $PID
        contextKey = $ContextKey
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        serverAcknowledged = $true
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ReadyPath -Encoding UTF8
    Start-Sleep -Seconds 2
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'watch-cogentstack-bridge.ps1') -Value $watcherFixture -Encoding UTF8

    $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH = $connectorProcessPath
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $launcherCommand = "& '$((Join-Path $fixtureScripts 'start-cogentstack-bridge.ps1').Replace("'", "''"))' -ContextKey '$contextKey' -Surface chatgpt"
    $encodedLauncherCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcherCommand))
    $launcherStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $launcherStartInfo.FileName = $powerShellExecutable
    $launcherStartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedLauncherCommand"
    $launcherStartInfo.UseShellExecute = $false
    $launcherStartInfo.CreateNoWindow = $true
    $launcherStartInfo.RedirectStandardOutput = $true
    $launcherStartInfo.RedirectStandardError = $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $launcherProcess = [Diagnostics.Process]::Start($launcherStartInfo)
    $stdoutTask = $launcherProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $launcherProcess.StandardError.ReadToEndAsync()
    $launcherProcessId = $launcherProcess.Id
    if (-not $launcherProcess.WaitForExit(10000)) {
        Stop-Process -Id $launcherProcessId -Force -ErrorAction SilentlyContinue
        throw 'The Bridge launcher exceeded the ten-second process limit.'
    }
    $timer.Stop()
    $launcherExitCode = $launcherProcess.ExitCode
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $launcherProcess.Dispose()
    $launcherProcess = $null
    $output = @($stdoutText, $stderrText) -split "`r?`n" | Where-Object { $_ }
    Assert-BridgeLauncherTest ($launcherExitCode -eq 0) ("The Bridge launcher process failed: {0}" -f ($output -join ' '))
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    Assert-BridgeLauncherTest ([bool]$jsonLine) 'The Bridge launcher returned no JSON result.'
    $result = $jsonLine | ConvertFrom-Json

    Assert-BridgeLauncherTest ([string]$result.status -eq 'ready') 'The Bridge launcher did not become ready.'
    Assert-BridgeLauncherTest ([string]$result.bridge -eq 'started') 'The Bridge launcher did not start the fixture worker.'
    Assert-BridgeLauncherTest ([bool]$result.presenceVerified) 'The Bridge launcher reported ready before server presence was verified.'
    Assert-BridgeLauncherTest ([string]$result.mcpState -eq 'ready') 'The secure project-data connection was not ready.'
    Assert-BridgeLauncherTest ([int]$result.launcherElapsedMs -ge 500 -and [int]$result.launcherElapsedMs -lt 5000) 'The Bridge launcher did not wait for the delayed server acknowledgement within its five-second in-process limit.'
    Assert-BridgeLauncherTest ($timer.ElapsedMilliseconds -lt 10000) 'The Bridge launcher exceeded the ten-second cold-process fixture limit.'
    Assert-BridgeLauncherTest ([string]$result.webWorkspaceUrl -match '#desktop-web=') 'The web workspace handoff is missing.'
    Assert-BridgeLauncherTest ([string]$result.chatgptWorkspaceUrl -match '#desktop-chatgpt=') 'The ChatGPT workspace handoff is missing.'
    Assert-BridgeLauncherTest ([string]$result.webWorkspaceUrl -match '&open=web&nav=[a-f0-9]{32}#desktop-web=') 'The web link does not force a fresh normal-click navigation.'
    Assert-BridgeLauncherTest ([string]$result.chatgptWorkspaceUrl -match '&open=chatgpt&nav=[a-f0-9]{32}#desktop-chatgpt=') 'The ChatGPT link does not force a fresh normal-click navigation.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath $connectorProcessPath -PathType Leaf) 'The fixture connector did not record its process.'
    $connectorProcessId = [int](Get-Content -Raw -LiteralPath $connectorProcessPath)
    Assert-BridgeLauncherTest ($connectorProcessId -eq $launcherProcessId) 'The account check was launched in a nested PowerShell process.'

    $workerProcessId = [int]$result.processId
    Assert-BridgeLauncherTest ($workerProcessId -ne $launcherProcessId) 'The fixture worker incorrectly reused the launcher process.'
    Assert-BridgeLauncherTest ($workerProcessId -gt 0 -and [bool](Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue)) 'The fixture worker is not running.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath $readyPath -PathType Leaf) 'The server acknowledgement marker was not written.'
    $readyMarker = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
    Assert-BridgeLauncherTest ([int]$readyMarker.processId -eq $workerProcessId -and [bool]$readyMarker.serverAcknowledged) 'The server acknowledgement marker does not identify the verified worker.'

    $reuseOutput = @(& (Join-Path $fixtureScripts 'start-cogentstack-bridge.ps1') -ContextKey $contextKey -Surface chatgpt 2>&1)
    $reuseJsonLine = @($reuseOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    Assert-BridgeLauncherTest ([bool]$reuseJsonLine) 'The reused Bridge launcher returned no JSON result.'
    $reuseResult = $reuseJsonLine | ConvertFrom-Json
    Assert-BridgeLauncherTest ([string]$reuseResult.status -eq 'ready' -and [string]$reuseResult.bridge -eq 'already_running') 'The Bridge launcher did not reuse the verified worker.'
    Assert-BridgeLauncherTest ([bool]$reuseResult.presenceVerified -and [int]$reuseResult.processId -eq $workerProcessId) 'The reused Bridge worker was reported ready without verified context presence.'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $runtimeRoot = Split-Path -Parent ([string]$state.watcherScript)
    }
    Assert-BridgeLauncherTest ([bool]$runtimeRoot -and (Test-Path -LiteralPath (Join-Path $runtimeRoot 'create-specification-project.ps1') -PathType Leaf)) 'The protected Bridge runtime omitted the specification project helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'inspect-project-git.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic project check helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'restore-project-version.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic version restore helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'save-project-version.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic version save helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'prepare-development-handoff.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the development handoff helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'ensure-cogentspec-mcp.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the project-data connection helper.'

    $connectorText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\connect-cogentstack.ps1')
    Assert-BridgeLauncherTest (-not $connectorText.Contains('exit 0')) 'The account helper can still terminate its calling launcher process.'
    $saveHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\save-project-version.ps1')
    Assert-BridgeLauncherTest ($saveHelperText.Contains("request.action -ne 'commit'")) 'The automatic version save helper does not require an exact commit request.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("manifest.project.requestId -ne")) 'The automatic version save helper does not verify the protected project identity.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("@('add', '--all', '--', '.')")) 'The automatic version save helper does not stage the complete approved project state.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("@('commit', '--quiet', '-m', `$message.Trim())")) 'The automatic version save helper does not use the approved version description.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("status = 'saved'")) 'The automatic version save helper does not report a verified saved result.'
    Assert-BridgeLauncherTest (-not $saveHelperText.Contains('Start-Process')) 'The automatic version save helper must not open another application.'
    $restoreHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\restore-project-version.ps1')
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("request.action -ne 'revert'")) 'The automatic version restore helper does not require an exact restore request.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('merge-base', '--is-ancestor'")) 'The automatic version restore helper does not constrain the target to current project history.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('status', '--porcelain=v1', '--untracked-files=all')")) 'The automatic version restore helper does not require a clean worktree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('read-tree', '--reset', '-u', `$targetHash)")) 'The automatic version restore helper does not restore the exact selected tree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("'HEAD^{tree}'")) 'The automatic version restore helper does not verify the restored tree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("status = 'restored'")) 'The automatic version restore helper does not report a verified restored result.'
    Assert-BridgeLauncherTest (-not $restoreHelperText.Contains('Start-Process')) 'The automatic version restore helper must not open another application.'
    $popupHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-popup.ps1')
    Assert-BridgeLauncherTest ($popupHelperText.Contains('Add-Type -AssemblyName UIAutomationClient')) 'The ChatGPT popout helper does not use the accessible composer surface.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("[string]`$_.Current.Name -eq 'Work with ChatGPT'")) 'The ChatGPT popout helper does not require the exact composer identity.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[System.Windows.Automation.ValuePattern]::Pattern')) 'The ChatGPT popout helper does not require safe value input.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$valuePattern.SetValue($Text)')) 'The ChatGPT popout helper does not preload the exact requested command.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$placeholderValue = $currentValue.TrimEnd("`r", "`n")')) "The ChatGPT popout helper does not recognize Chromium's empty-composer placeholder value."
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$placeholderValue -ceq [string]$composer.Current.Name')) 'The ChatGPT popout helper does not bind its empty-composer check to the verified accessible name.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('function Invoke-PopupActivation')) 'The ChatGPT popout helper does not absorb transient Windows foreground-lock failures within one click.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[DateTime]::UtcNow.AddSeconds(1)')) 'The ChatGPT popout activation retry is not bounded.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("ChatGPT already contains text in the composer. CogentSpec left that draft unchanged.")) 'The ChatGPT popout helper can overwrite an existing draft.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('composerPreloaded = $true')) 'The ChatGPT popout helper does not verify the preloaded composer.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("composerText = '`$cogentspec'")) 'The ChatGPT popout helper does not report the exact CogentSpec command.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('VK_RETURN')) 'The ChatGPT popout helper must not submit the preloaded command.'
    $popupParityPaths = @(
        'plugins\cogentstack\skills\cogentstack\scripts\open-chatgpt-popup.ps1',
        'claude-plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-popup.ps1',
        'claude-plugins\cogentstack\skills\cogentstack\scripts\open-chatgpt-popup.ps1'
    )
    foreach ($relativePath in $popupParityPaths) {
        $candidateText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot $relativePath)
        Assert-BridgeLauncherTest ($candidateText -ceq $popupHelperText) "The ChatGPT popout helper is inconsistent at $relativePath."
    }
    $watcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\watch-cogentstack-bridge.ps1')
    Assert-BridgeLauncherTest ($watcherText.Contains("ChatGPT popout shown with `$cogentspec ready in the composer")) 'The Bridge does not report the preloaded ChatGPT composer.'
    Assert-BridgeLauncherTest ($watcherText.IndexOf('Write-BridgePresenceReady', $watcherText.IndexOf('Invoke-BridgeApi -Method Get')) -gt $watcherText.IndexOf('Invoke-BridgeApi -Method Get')) 'The Bridge does not record readiness after the server acknowledges context presence.'
    Assert-BridgeLauncherTest ($watcherText.Contains('serverAcknowledged = $true')) 'The Bridge readiness marker does not record server acknowledgement.'
    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\start-cogentstack-bridge.ps1')
    Assert-BridgeLauncherTest ($launcherText.Contains('function Wait-BridgePresenceReady')) 'The Bridge launcher does not wait for server-acknowledged context presence.'
    Assert-BridgeLauncherTest ($launcherText.Contains('presenceVerified = $true')) 'The Bridge launcher does not expose verified context presence.'
    $bridgeParityRoots = @(
        'plugins\cogentstack\skills\cogentstack\scripts',
        'claude-plugins\cogentspec\skills\cogentspec\scripts',
        'claude-plugins\cogentstack\skills\cogentstack\scripts'
    )
    foreach ($relativeRoot in $bridgeParityRoots) {
        $candidateLauncherText = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $repositoryRoot $relativeRoot) 'start-cogentstack-bridge.ps1')
        $candidateWatcherText = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $repositoryRoot $relativeRoot) 'watch-cogentstack-bridge.ps1')
        Assert-BridgeLauncherTest ($candidateLauncherText -ceq $launcherText) "The Bridge launcher is inconsistent at $relativeRoot."
        Assert-BridgeLauncherTest ($candidateWatcherText -ceq $watcherText) "The Bridge watcher is inconsistent at $relativeRoot."
    }

    [ordered]@{
        status = 'valid'
        bridge = [string]$result.bridge
        launcherElapsedMs = [int]$result.launcherElapsedMs
        observedElapsedMs = [int]$timer.ElapsedMilliseconds
        directAccountCheck = $true
        boundedAccountCheckSeconds = 8
        projectDataConnection = 'ready'
        presenceVerified = [bool]$result.presenceVerified
        reuseVerified = [bool]$reuseResult.presenceVerified
        workspaceLinksReturned = 2
    } | ConvertTo-Json -Compress
} finally {
    if ($launcherProcess) { $launcherProcess.Dispose() }
    if ($workerProcessId -gt 0 -and $workerProcessId -ne $PID) {
        $workerProcess = Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue
        if ($workerProcess) {
            Stop-Process -Id $workerProcessId -Force -ErrorAction SilentlyContinue
            [void]$workerProcess.WaitForExit(2000)
        }
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Remove-Item -LiteralPath $statePath -Force }
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) { Remove-Item -LiteralPath $readyPath -Force }
    if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    if ($null -eq $originalConnectorProcessPath) {
        Remove-Item Env:\COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH -ErrorAction SilentlyContinue
    } else {
        $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH = $originalConnectorProcessPath
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
