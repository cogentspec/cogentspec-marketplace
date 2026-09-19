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

$credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
$credentialExistedBefore = Test-Path -LiteralPath $credentialPath -PathType Leaf

if ($TestMode) {
    if (-not $TestStateRoot) { throw 'TestMode requires TestStateRoot.' }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $localStateRoot = [IO.Path]::GetFullPath($TestStateRoot).TrimEnd('\', '/')
    if (-not $localStateRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $localStateRoot) -notlike 'cogentspec-reset-test-*') {
        throw 'The test state root must be a dedicated cogentspec-reset-test-* directory beneath the system temporary directory.'
    }
    $credentialPath = Join-Path $localStateRoot 'desktop-credential.json'
    $credentialExistedBefore = Test-Path -LiteralPath $credentialPath -PathType Leaf
} else {
    $localStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
}

$bridgeStateRoot = Join-Path $localStateRoot 'bridge'
$runtimeRoot = Join-Path $localStateRoot 'bridge-runtime'
$resolvedStateRoot = [IO.Path]::GetFullPath($localStateRoot).TrimEnd('\', '/')

foreach ($target in @($bridgeStateRoot, $runtimeRoot)) {
    $resolvedTarget = [IO.Path]::GetFullPath($target).TrimEnd('\', '/')
    if (-not $resolvedTarget.StartsWith($resolvedStateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A Bridge cleanup target resolved outside the CogentSpec local state directory.'
    }
}

$workersStopped = 0
if (Test-Path -LiteralPath $bridgeStateRoot -PathType Container) {
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $bridgeStateRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $state = Get-Content -Raw -LiteralPath $stateFile.FullName | ConvertFrom-Json
            $processId = [int]$state.processId
            $watcherScript = [string]$state.watcherScript
            if ($processId -le 0 -or -not $watcherScript) { continue }

            $resolvedWatcher = [IO.Path]::GetFullPath($watcherScript)
            $resolvedRuntimeRoot = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $resolvedWatcher.StartsWith($resolvedRuntimeRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }

            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
            if ($process -and ([string]$process.CommandLine).IndexOf($resolvedWatcher, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Stop-Process -Id $processId -Force -ErrorAction Stop
                $workersStopped++
            }
        } catch {
            if ($_.Exception.Message -match 'Access is denied|Cannot stop process') { throw }
        }
    }
}

foreach ($target in @($bridgeStateRoot, $runtimeRoot)) {
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

$credentialPreserved = (-not $credentialExistedBefore) -or (Test-Path -LiteralPath $credentialPath -PathType Leaf)
if (-not $credentialPreserved) { throw 'The encrypted Desktop Bridge credential was not preserved.' }

Write-CompactJson ([ordered]@{
    status = 'reset'
    packageRuntimeCleared = $true
    workerStateCleared = $true
    workersStopped = $workersStopped
    credentialPreserved = $true
})
