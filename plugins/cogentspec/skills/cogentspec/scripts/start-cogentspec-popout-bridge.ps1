[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$TestStateRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Compress -Depth 5 | Write-Output
}

function Get-PowerShellExecutable {
    $candidate = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    $command = @(Get-Command pwsh.exe, powershell.exe -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    throw 'Windows PowerShell is required by Standalone Popout Bridge.'
}

$pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
$manifestPath = @(
    (Join-Path $pluginRoot '.codex-plugin\plugin.json'),
    (Join-Path $pluginRoot '.claude-plugin\plugin.json')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $manifestPath) { throw 'CogentSpec package identity is missing.' }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$pluginId = [string]$manifest.name
$pluginVersion = [string]$manifest.version
if ($pluginId -notin @('cogentspec', 'cogentstack') -or $pluginVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'CogentSpec package identity is invalid.'
}

if ($TestMode) {
    if (-not $TestStateRoot) { throw 'TestMode requires TestStateRoot.' }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $stateRoot = [IO.Path]::GetFullPath($TestStateRoot).TrimEnd('\', '/')
    if (-not $stateRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $stateRoot) -notlike 'cogentspec-popout-test-*') {
        throw 'The test state root must be a dedicated cogentspec-popout-test-* directory beneath the system temporary directory.'
    }
} else {
    $stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
}

$runtimeRoot = Join-Path $stateRoot "popout-runtime\$pluginId-$pluginVersion"
$bridgeStateRoot = Join-Path $stateRoot 'popout-bridge'
[void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
[void](New-Item -ItemType Directory -Path $bridgeStateRoot -Force)
foreach ($scriptName in @('watch-cogentspec-popout-bridge.ps1', 'open-chatgpt-popup.ps1')) {
    $source = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Standalone Popout Bridge is missing $scriptName." }
    Copy-Item -LiteralPath $source -Destination (Join-Path $runtimeRoot $scriptName) -Force
}

$watcherPath = Join-Path $runtimeRoot 'watch-cogentspec-popout-bridge.ps1'
$readyPath = Join-Path $bridgeStateRoot 'ready.json'
$statePath = Join-Path $bridgeStateRoot 'worker.json'
$powerShell = Get-PowerShellExecutable
$existingProcessId = 0
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $existingState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $existingProcessId = [int]$existingState.processId
        $process = if ($existingProcessId -gt 0) { Get-CimInstance Win32_Process -Filter "ProcessId=$existingProcessId" -ErrorAction SilentlyContinue } else { $null }
        $sameWorker = $process -and [string]$existingState.watcherScript -eq $watcherPath -and
            ([string]$process.CommandLine).IndexOf('watch-cogentspec-popout-bridge.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($sameWorker -and (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            $marker = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
            $age = [DateTime]::UtcNow - ([DateTime]$marker.acknowledgedAt).ToUniversalTime()
            if ([bool]$marker.serverAcknowledged -and $age.TotalSeconds -ge 0 -and $age.TotalSeconds -le 12) {
                Write-CompactJson ([ordered]@{ status = 'ready'; bridge = 'already_running'; processId = $existingProcessId; pluginId = $pluginId; pluginVersion = $pluginVersion })
                return
            }
        }
        if ($process -and $sameWorker) { Stop-Process -Id $existingProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

if ($TestMode) {
    Write-CompactJson ([ordered]@{ status = 'prepared'; bridge = 'not_started_in_test_mode'; supervised = $true; runtimeRoot = $runtimeRoot; watcherScript = $watcherPath; pluginId = $pluginId; pluginVersion = $pluginVersion })
    return
}

$escape = { param([string]$Value) $Value.Replace("'", "''") }
$watcherInvocation = "& '$(& $escape $watcherPath)' -PluginId '$pluginId' -PluginVersion '$pluginVersion' -ReadyPath '$(& $escape $readyPath)'"
$workerCommand = "`$ErrorActionPreference = 'Continue'; while (`$true) { try { $watcherInvocation } catch { }; Start-Sleep -Seconds 5 }"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
$commandLine = '"' + $powerShell + '" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
$runCommand = $commandLine
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'CogentSpecStandalonePopoutBridge' -Value $runCommand -PropertyType String -Force | Out-Null
$creation = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
if ([int]$creation.ReturnValue -ne 0 -or [int]$creation.ProcessId -le 0) { throw 'Standalone Popout Bridge could not be started.' }
$processId = [int]$creation.ProcessId
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    Start-Sleep -Milliseconds 100
    if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { break }
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
        try {
            $marker = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
            if ([int]$marker.processId -eq $processId -and [bool]$marker.serverAcknowledged) { break }
        } catch { }
    }
} while ([DateTime]::UtcNow -lt $deadline)

if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    throw 'Standalone Popout Bridge started, but CogentSpec did not acknowledge it.'
}
$ready = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
if ([int]$ready.processId -ne $processId -or -not [bool]$ready.serverAcknowledged) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    throw 'Standalone Popout Bridge did not become ready.'
}
[ordered]@{
    processId = $processId
    watcherScript = $watcherPath
    readyPath = $readyPath
    pluginId = $pluginId
    pluginVersion = $pluginVersion
    supervised = $true
    startedAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-CompactJson ([ordered]@{ status = 'ready'; bridge = 'started'; supervised = $true; processId = $processId; pluginId = $pluginId; pluginVersion = $pluginVersion })
