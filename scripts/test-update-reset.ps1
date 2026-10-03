[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ResetTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resetScript = Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\reset-cogentspec-update.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-reset-test-' + [Guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $fixtureRoot 'bridge'
$runtimeRoot = Join-Path $fixtureRoot 'bridge-runtime\old-runtime'
$popoutStateRoot = Join-Path $fixtureRoot 'popout-bridge'
$popoutRuntimeRoot = Join-Path $fixtureRoot 'popout-runtime\old-runtime'
$credentialPath = Join-Path $fixtureRoot 'desktop-credential.json'
$watcherPath = Join-Path $runtimeRoot 'watch-cogentstack-bridge.ps1'
$popoutWatcherPath = Join-Path $popoutRuntimeRoot 'watch-cogentspec-popout-bridge.ps1'
$worker = $null
$orphanWorker = $null
$popoutWorker = $null
$orphanPopoutWorker = $null

try {
    [void](New-Item -ItemType Directory -Path $stateRoot -Force)
    [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
    [void](New-Item -ItemType Directory -Path $popoutStateRoot -Force)
    [void](New-Item -ItemType Directory -Path $popoutRuntimeRoot -Force)
    Set-Content -LiteralPath $credentialPath -Value '{"protected":"fixture"}' -Encoding UTF8
    Set-Content -LiteralPath $watcherPath -Value 'Start-Sleep -Seconds 120' -Encoding UTF8
    Set-Content -LiteralPath $popoutWatcherPath -Value 'Start-Sleep -Seconds 120' -Encoding UTF8

    $worker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcherPath) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixtureRoot 'worker.stdout.log') -RedirectStandardError (Join-Path $fixtureRoot 'worker.stderr.log') -PassThru
    $orphanCommand = "& '$($watcherPath.Replace("'", "''"))'"
    $orphanEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($orphanCommand))
    $orphanWorker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $orphanEncodedCommand) -WindowStyle Hidden -PassThru
    $popoutWorker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $popoutWatcherPath) -WindowStyle Hidden -PassThru
    $orphanPopoutCommand = "& '$($popoutWatcherPath.Replace("'", "''"))'"
    $orphanPopoutEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($orphanPopoutCommand))
    $orphanPopoutWorker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $orphanPopoutEncodedCommand) -WindowStyle Hidden -PassThru
    [ordered]@{
        processId = $worker.Id
        runtimeVersion = 'old-runtime'
        watcherScript = $watcherPath
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'fixture.json') -Encoding UTF8
    [ordered]@{
        processId = $popoutWorker.Id
        watcherScript = $popoutWatcherPath
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $popoutStateRoot 'worker.json') -Encoding UTF8

    $result = (& $resetScript -TestMode -TestStateRoot $fixtureRoot) | ConvertFrom-Json
    Assert-ResetTest ([string]$result.status -eq 'reset') 'The reset helper did not report reset.'
    Assert-ResetTest ([bool]$result.packageRuntimeCleared) 'The reset helper did not report runtime cleanup.'
    Assert-ResetTest ([bool]$result.workerStateCleared) 'The reset helper did not report worker-state cleanup.'
    Assert-ResetTest ([bool]$result.credentialPreserved) 'The reset helper did not preserve the credential fixture.'
    Assert-ResetTest ([int]$result.workersStopped -eq 4) 'The reset helper did not stop both task workers and both standalone Popout workers.'
    Assert-ResetTest (-not (Test-Path -LiteralPath $stateRoot)) 'The Bridge state directory remains after reset.'
    Assert-ResetTest (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'bridge-runtime'))) 'The Bridge runtime directory remains after reset.'
    Assert-ResetTest (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'popout-bridge'))) 'The standalone Popout state directory remains after reset.'
    Assert-ResetTest (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'popout-runtime'))) 'The standalone Popout runtime directory remains after reset.'
    Assert-ResetTest (Test-Path -LiteralPath $credentialPath -PathType Leaf) 'The credential fixture was removed.'

    [ordered]@{
        status = 'valid'
        workersStopped = [int]$result.workersStopped
        packageRuntimeCleared = [bool]$result.packageRuntimeCleared
        workerStateCleared = [bool]$result.workerStateCleared
        credentialPreserved = [bool]$result.credentialPreserved
    } | ConvertTo-Json -Compress
} finally {
    if ($worker -and -not $worker.HasExited) { Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue }
    if ($orphanWorker -and -not $orphanWorker.HasExited) { Stop-Process -Id $orphanWorker.Id -Force -ErrorAction SilentlyContinue }
    if ($popoutWorker -and -not $popoutWorker.HasExited) { Stop-Process -Id $popoutWorker.Id -Force -ErrorAction SilentlyContinue }
    if ($orphanPopoutWorker -and -not $orphanPopoutWorker.HasExited) { Stop-Process -Id $orphanPopoutWorker.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
