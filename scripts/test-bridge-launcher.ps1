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
    [string]$PluginVersion
)
Start-Sleep -Seconds 30
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
    Assert-BridgeLauncherTest ([string]$result.mcpState -eq 'ready') 'The secure project-data connection was not ready.'
    Assert-BridgeLauncherTest ([int]$result.launcherElapsedMs -ge 0 -and [int]$result.launcherElapsedMs -lt 5000) 'The Bridge launcher exceeded its five-second in-process limit.'
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
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $runtimeRoot = Split-Path -Parent ([string]$state.watcherScript)
    }
    Assert-BridgeLauncherTest ([bool]$runtimeRoot -and (Test-Path -LiteralPath (Join-Path $runtimeRoot 'create-specification-project.ps1') -PathType Leaf)) 'The protected Bridge runtime omitted the specification project helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'inspect-project-git.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic project check helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'save-project-version.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic version save helper.'
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

    [ordered]@{
        status = 'valid'
        bridge = [string]$result.bridge
        launcherElapsedMs = [int]$result.launcherElapsedMs
        observedElapsedMs = [int]$timer.ElapsedMilliseconds
        directAccountCheck = $true
        boundedAccountCheckSeconds = 8
        projectDataConnection = 'ready'
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
