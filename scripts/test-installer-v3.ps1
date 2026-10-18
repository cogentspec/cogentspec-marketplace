[CmdletBinding()]
param(
    [ValidateSet('cogentspec', 'cogentstack')]
    [string]$PluginName = 'cogentspec',
    [switch]$ExerciseTimeout,
    [switch]$ExerciseDefaultBudget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-InstallerTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Invoke-InstallerFixture {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [string]$Reference = '',
        [switch]$UpdateOnly,
        [switch]$ValidateOnly,
        [int]$TimeoutSeconds = 120
    )
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $InstallerPath,
        '-MarketplacePrepared',
        '-InstallerTimeoutSeconds', $TimeoutSeconds
    )
    if ($Reference) { $arguments += @('-InstallationRequest', $Reference) }
    if ($UpdateOnly) { $arguments += '-UpdateOnly' }
    if ($ValidateOnly) { $arguments += '-ValidateOnly' }
    $runTimer = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $PowerShellPath @arguments 2>&1)
    $runTimer.Stop()
    return [ordered]@{
        exitCode = $LASTEXITCODE
        wallElapsedMs = [int]$runTimer.ElapsedMilliseconds
        result = ($output[-1].ToString() | ConvertFrom-Json)
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("cogentspec-installer-v3-" + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
if ([IO.Path]::GetDirectoryName($fixtureRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
    [IO.Path]::GetFileName($fixtureRoot) -notmatch '^cogentspec-installer-v3-[a-f0-9]{32}$') {
    throw 'Installer fixture cleanup target is outside its isolated temporary directory.'
}
$fixtureMarketplace = Join-Path $fixtureRoot 'marketplace'
$fixtureInstallerDirectory = Join-Path $fixtureMarketplace '.agents\plugins'
$fixturePlugin = Join-Path $fixtureMarketplace "plugins\$PluginName"
$fixtureInstalledPlugin = Join-Path $fixtureRoot "installed\$PluginName"
$fixtureBin = Join-Path $fixtureRoot 'bin'
$originalPath = $env:Path

try {
    [void](New-Item -ItemType Directory -Path $fixtureInstallerDirectory -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePlugin) -Force)
    [void](New-Item -ItemType Directory -Path $fixtureBin -Force)
    Copy-Item -LiteralPath (Join-Path $repositoryRoot ".agents\plugins\install-$PluginName.ps1") -Destination $fixtureInstallerDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "plugins\$PluginName") -Destination $fixturePlugin -Recurse -Force

    $claimFixture = @'
param(
    [string]$Mode,
    [string]$InstallationRequest
)
if ($Mode -ne 'claim' -or $InstallationRequest -notmatch '^cgb_[A-Za-z0-9_-]{40,}$') {
    throw 'Unexpected account-bound claim fixture invocation.'
}
[ordered]@{
    status = 'connected'
    accountBound = $true
    installationBound = $true
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixturePlugin "skills\$PluginName\scripts\connect-cogentstack.ps1") -Value $claimFixture -Encoding UTF8

    $resetFixture = @'
if ($env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE -eq 'superseded_bridge_cleanup') {
    [string]$PID | Set-Content -LiteralPath $env:COGENTSPEC_INSTALLER_TEST_PID_PATH
    Start-Sleep -Seconds 35
}
[ordered]@{
    status = 'reset'
    packageRuntimeCleared = $true
    workerStateCleared = $true
    workersStopped = 1
    credentialPreserved = $true
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixturePlugin "skills\$PluginName\scripts\reset-cogentspec-update.ps1") -Value $resetFixture -Encoding UTF8

    $popoutBridgeFixture = @'
if ($env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE -eq 'standalone_popout_bridge') {
    [string]$PID | Set-Content -LiteralPath $env:COGENTSPEC_INSTALLER_TEST_PID_PATH
    Start-Sleep -Seconds 35
}
[ordered]@{
    status = 'ready'
    bridge = 'started'
    processId = 4242
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixturePlugin "skills\$PluginName\scripts\start-cogentspec-popout-bridge.ps1") -Value $popoutBridgeFixture -Encoding UTF8

    $desktopUiBridgeFixture = @'
if ($env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE -eq 'desktop_ui_bridge') {
    [string]$PID | Set-Content -LiteralPath $env:COGENTSPEC_INSTALLER_TEST_PID_PATH
    Start-Sleep -Seconds 35
}
[ordered]@{
    status = 'ready'
    bridge = 'started'
    processId = 4343
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixturePlugin "skills\$PluginName\scripts\start-cogentspec-desktop-ui-bridge.ps1") -Value $desktopUiBridgeFixture -Encoding UTF8

    $pluginManifest = Get-Content -LiteralPath (Join-Path $fixturePlugin '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    $escapedMarketplace = $fixtureMarketplace.Replace("'", "''")
    $escapedSourcePlugin = $fixturePlugin.Replace("'", "''")
    $escapedInstalledPlugin = $fixtureInstalledPlugin.Replace("'", "''")
    $escapedVersion = ([string]$pluginManifest.version).Replace("'", "''")
    $escapedMcpState = (Join-Path $fixtureRoot 'mcp-authorized.txt').Replace("'", "''")

    $codexStub = @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$CliArgs)
`$ErrorActionPreference = 'Stop'
if (`$CliArgs.Count -ge 4 -and `$CliArgs[0] -eq 'plugin' -and `$CliArgs[1] -eq 'marketplace' -and `$CliArgs[2] -eq 'list') {
    if (`$env:COGENTSPEC_INSTALLER_TEST_STALL -eq '1') {
        `$stallSeconds = if (`$env:COGENTSPEC_INSTALLER_TEST_STALL_SECONDS) { [int]`$env:COGENTSPEC_INSTALLER_TEST_STALL_SECONDS } else { 35 }
        Start-Sleep -Seconds `$stallSeconds
    }
    [ordered]@{ marketplaces = @([ordered]@{ name = 'cogentstack'; root = '$escapedMarketplace' }) } | ConvertTo-Json -Compress
    exit 0
}
if (`$CliArgs.Count -ge 3 -and `$CliArgs[0] -eq 'plugin' -and `$CliArgs[1] -eq 'add') {
    if (Test-Path -LiteralPath '$escapedInstalledPlugin') { Remove-Item -LiteralPath '$escapedInstalledPlugin' -Recurse -Force }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent '$escapedInstalledPlugin') -Force)
    Copy-Item -LiteralPath '$escapedSourcePlugin' -Destination '$escapedInstalledPlugin' -Recurse -Force
    [ordered]@{ installedPath = '$escapedInstalledPlugin' } | ConvertTo-Json -Compress
    exit 0
}
if (`$CliArgs.Count -ge 3 -and `$CliArgs[0] -eq 'plugin' -and `$CliArgs[1] -eq 'list') {
    [ordered]@{ installed = @([ordered]@{ pluginId = '$PluginName@cogentstack'; installed = `$true; enabled = `$true; version = '$escapedVersion' }) } | ConvertTo-Json -Compress
    exit 0
}
if (`$CliArgs.Count -eq 2 -and `$CliArgs[0] -eq 'mcp' -and `$CliArgs[1] -eq 'list') {
    `$auth = if (Test-Path -LiteralPath '$escapedMcpState') { 'OAuth' } else { 'Not logged in' }
    "cogentspec           https://cogentspec.com/mcp         -                     enabled  `$auth"
    exit 0
}
if (`$CliArgs.Count -eq 3 -and `$CliArgs[0] -eq 'mcp' -and `$CliArgs[1] -eq 'login' -and `$CliArgs[2] -eq 'cogentspec') {
    'authorized' | Set-Content -LiteralPath '$escapedMcpState' -Encoding ascii
    'CogentSpec connected.'
    exit 0
}
Write-Error ('Unexpected Codex fixture arguments: ' + (`$CliArgs -join ' '))
exit 2
"@
    Set-Content -LiteralPath (Join-Path $fixtureBin 'codex-stub.ps1') -Value $codexStub -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureBin 'codex.cmd') -Value "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0codex-stub.ps1`" %*`r`n" -Encoding ASCII

    $gitStub = @'
using System;

public static class GitFixture
{
    public static int Main(string[] args)
    {
        if (args.Length >= 4 && args[2] == "remote" && args[3] == "get-url")
        {
            Console.WriteLine("https://github.com/cogentspec/cogentspec-marketplace.git");
            return 0;
        }
        if (args.Length >= 4 && args[2] == "sparse-checkout" && args[3] == "list")
        {
            Console.WriteLine(".agents/plugins");
            if (System.IO.Directory.Exists(System.IO.Path.Combine(args[1], "plugins", "cogentspec")))
                Console.WriteLine("plugins/cogentspec");
            Console.WriteLine("plugins/cogentstack");
            return 0;
        }
        Console.Error.WriteLine("Unexpected Git fixture arguments: " + string.Join(" ", args));
        return 2;
    }
}
'@
    Add-Type -TypeDefinition $gitStub -Language CSharp -OutputAssembly (Join-Path $fixtureBin 'git.exe') -OutputType ConsoleApplication
    $env:Path = "$fixtureBin$([IO.Path]::PathSeparator)$originalPath"

    $powerShellPath = (Get-Process -Id $PID).Path
    $installerPath = Join-Path $fixtureInstallerDirectory "install-$PluginName.ps1"
    $validReference = 'cgb_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $validRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference -ValidateOnly
    $valid = $validRun.result

    Assert-InstallerTest ($validRun.exitCode -eq 0) ("The isolated v3 installer validation returned a non-zero exit code: {0}" -f ($valid | ConvertTo-Json -Compress -Depth 5))
    Assert-InstallerTest ([string]$valid.protocol -eq 'trusted-marketplace-v3') 'The isolated installer returned the wrong protocol.'
    Assert-InstallerTest ([string]$valid.status -eq 'validated') 'The isolated installer did not complete validation.'
    Assert-InstallerTest ([bool]$valid.installerStarted) 'The installer did not report that its process started.'
    Assert-InstallerTest (-not [bool]$valid.installerTimedOut) 'The isolated installer reported a false timeout.'
    Assert-InstallerTest ([int]$valid.nativeCommandsStarted -eq 5) 'The isolated installer did not start the five expected native commands.'
    Assert-InstallerTest ([int]$valid.nativeCommandsCompleted -eq 5) 'The isolated installer did not complete the five expected native commands.'
    Assert-InstallerTest (-not [bool]$valid.claimAttempted) 'ValidateOnly must never attempt an account claim.'
    Assert-InstallerTest ($valid.accountRequestConsumed -eq $false) 'ValidateOnly must report that the account request was not consumed.'
    Assert-InstallerTest ([int]$valid.installerElapsedMs -gt 0 -and [int]$valid.installerElapsedMs -lt 120000) 'The isolated installer duration is outside its process-owned limit.'
    Assert-InstallerTest ([int]$valid.installerBudgetSeconds -eq 110) 'The installer must reserve cleanup time below the two-minute target.'
    $completedStageNames = @($valid.completedStages | ForEach-Object { [string]$_.stage })
    Assert-InstallerTest ($completedStageNames -contains 'plugin_installation') 'The plugin installation stage was not evidenced.'
    Assert-InstallerTest ($completedStageNames -contains 'package_integrity_verification') 'The package integrity stage was not evidenced.'
    Assert-InstallerTest ($completedStageNames -contains 'launcher_contract_verification') 'The launcher verification stage was not evidenced.'

    $updateRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -UpdateOnly
    $update = $updateRun.result
    Assert-InstallerTest ($updateRun.exitCode -eq 0) ("The isolated update fixture returned a non-zero exit code: {0}" -f ($update | ConvertTo-Json -Compress -Depth 5))
    Assert-InstallerTest ([string]$update.protocol -eq 'trusted-marketplace-update-v1') 'The update fixture returned the wrong protocol.'
    Assert-InstallerTest ([string]$update.status -eq 'updated') 'The update fixture did not complete the update.'
    Assert-InstallerTest ([bool]$update.credentialPreserved) 'The update fixture did not preserve the existing credential.'
    Assert-InstallerTest ([bool]$update.previousPackageReplaced) 'The update fixture did not report replacement of the previous package.'
    Assert-InstallerTest ([bool]$update.packageRuntimeCleared) 'The update fixture did not clear the superseded Bridge runtime.'
    Assert-InstallerTest ([bool]$update.workerStateCleared) 'The update fixture did not clear the superseded worker state.'
    Assert-InstallerTest ([bool]$update.popoutBridgeReady) 'The update fixture did not start the standalone Popout Bridge.'
    Assert-InstallerTest ([bool]$update.desktopUiBridgeReady) 'The update fixture did not start the independent Desktop UI Bridge.'
    Assert-InstallerTest ([int]$update.workersStopped -eq 1) 'The update fixture did not report the stopped verified worker.'
    Assert-InstallerTest ([bool]$update.continueCurrentTask) 'The update fixture did not permit the current task to continue.'
    Assert-InstallerTest ([bool]$update.fastUpdatePath) 'The update fixture did not use the fast update-only path.'
    Assert-InstallerTest ([bool]$update.workspaceReadinessSkipped) 'The update fixture repeated the first-install web readiness check.'
    Assert-InstallerTest ([bool]$update.projectDataConnectionReady) 'The update fixture did not prepare the secure project-data connection.'
    Assert-InstallerTest ([int]$update.installerElapsedMs -gt 0 -and [int]$update.installerElapsedMs -lt 20000) 'The update-only installer exceeded the twenty-second regression limit.'
    Assert-InstallerTest ([int]$updateRun.wallElapsedMs -lt 20000) 'The update fixture took over twenty seconds including process shutdown.'
    Assert-InstallerTest ([string]$update.refreshedPluginPath -eq $fixtureInstalledPlugin) 'The update fixture did not return the refreshed plugin path.'
    Assert-InstallerTest (-not [bool]$update.claimAttempted) 'The update fixture attempted an account claim.'
    Assert-InstallerTest ($update.accountRequestConsumed -eq $false) 'The update fixture did not prove that no account request was consumed.'
    $updateStageNames = @($update.completedStages | ForEach-Object { [string]$_.stage })
    Assert-InstallerTest ($updateStageNames -contains 'superseded_bridge_cleanup') 'The update fixture did not evidence superseded Bridge cleanup.'
    Assert-InstallerTest ($updateStageNames -contains 'standalone_popout_bridge') 'The update fixture did not evidence standalone Popout Bridge startup.'
    Assert-InstallerTest ($updateStageNames -contains 'desktop_ui_bridge') 'The update fixture did not evidence Desktop UI Bridge startup.'
    Assert-InstallerTest ($updateStageNames -contains 'secure_project_data_connection') 'The update fixture did not evidence the secure project-data connection.'
    Assert-InstallerTest ($updateStageNames -contains 'workspace_readiness_skipped_for_update') 'The update fixture did not evidence the skipped first-install web check.'
    Assert-InstallerTest ($updateStageNames -notcontains 'workspace_readiness') 'The update fixture repeated the first-install web readiness stage.'

    $unsafeUpdateRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference -UpdateOnly
    $unsafeUpdate = $unsafeUpdateRun.result
    Assert-InstallerTest ($unsafeUpdateRun.exitCode -ne 0) 'An update carrying an account-bound reference unexpectedly succeeded.'
    Assert-InstallerTest ([int]$unsafeUpdate.nativeCommandsStarted -eq 0) 'An update carrying an account-bound reference started a native command.'
    Assert-InstallerTest (-not [bool]$unsafeUpdate.claimAttempted) 'An update carrying an account-bound reference attempted a claim.'
    Assert-InstallerTest ($unsafeUpdate.accountRequestConsumed -eq $false) 'An update carrying an account-bound reference did not prove non-consumption.'

    $claimRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference
    $claim = $claimRun.result
    Assert-InstallerTest ($claimRun.exitCode -eq 0) ("The isolated v3 claim fixture returned a non-zero exit code: {0}" -f ($claim | ConvertTo-Json -Compress -Depth 5))
    Assert-InstallerTest ([string]$claim.status -eq 'installed') 'The isolated claim fixture did not complete installation.'
    Assert-InstallerTest ([bool]$claim.popoutBridgeReady) 'The isolated claim fixture did not start the standalone Popout Bridge.'
    Assert-InstallerTest ([bool]$claim.desktopUiBridgeReady) 'The isolated claim fixture did not start the independent Desktop UI Bridge.'
    Assert-InstallerTest ([bool]$claim.claimAttempted) 'The isolated claim fixture did not attempt its local claim helper.'
    Assert-InstallerTest ([bool]$claim.accountRequestConsumed) 'The isolated claim fixture did not report consumption.'
    Assert-InstallerTest ([bool]$claim.connected -and [bool]$claim.accountBound -and [bool]$claim.installationBound) 'The isolated claim fixture did not return all connection guarantees.'
    Assert-InstallerTest ([bool]$claim.projectDataConnectionReady) 'The isolated claim fixture did not prepare the secure project-data connection.'
    $claimStageNames = @($claim.completedStages | ForEach-Object { [string]$_.stage })
    Assert-InstallerTest ($claimStageNames -contains 'account_bound_claim') 'The isolated claim fixture did not complete the account-bound claim stage.'

    $invalidRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference 'missing'
    $invalid = $invalidRun.result
    Assert-InstallerTest ($invalidRun.exitCode -ne 0) 'An invalid current-message reference unexpectedly succeeded.'
    Assert-InstallerTest ([string]$invalid.status -eq 'failed') 'The invalid-reference result did not report failure.'
    Assert-InstallerTest ([string]$invalid.failureStage -eq 'initialization') 'The invalid reference did not fail during initialization.'
    Assert-InstallerTest ([int]$invalid.nativeCommandsStarted -eq 0) 'The invalid reference started a native command.'
    Assert-InstallerTest (-not [bool]$invalid.claimAttempted) 'The invalid reference attempted an account claim.'
    Assert-InstallerTest ($invalid.accountRequestConsumed -eq $false) 'The invalid reference did not prove non-consumption.'

    $timeoutCasePassed = $null
    $timeoutElapsedMs = $null
    $helperTimeoutCases = @()
    $postClaimTimeoutCase = $null
    if ($ExerciseTimeout) {
        $env:COGENTSPEC_INSTALLER_TEST_STALL = '1'
        try {
            $timeoutRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference -ValidateOnly -TimeoutSeconds 30
        } finally {
            Remove-Item Env:\COGENTSPEC_INSTALLER_TEST_STALL -ErrorAction SilentlyContinue
        }
        $timeout = $timeoutRun.result
        Assert-InstallerTest ($timeoutRun.exitCode -ne 0) 'The forced-timeout installer run unexpectedly succeeded.'
        Assert-InstallerTest ([string]$timeout.status -eq 'failed') 'The forced-timeout result did not report failure.'
        Assert-InstallerTest ([string]$timeout.failureStage -eq 'prepared_marketplace_verification') 'The forced timeout was attributed to the wrong stage.'
        Assert-InstallerTest ([bool]$timeout.installerTimedOut) 'The forced-timeout result did not expose the timeout.'
        Assert-InstallerTest ([int]$timeout.nativeCommandsStarted -eq 1) 'The forced-timeout result reported the wrong started-command count.'
        Assert-InstallerTest ([int]$timeout.nativeCommandsCompleted -eq 0) 'The forced-timeout result reported a command completion.'
        Assert-InstallerTest (-not [bool]$timeout.claimAttempted) 'The forced-timeout run attempted an account claim.'
        Assert-InstallerTest ($timeout.accountRequestConsumed -eq $false) 'The forced-timeout run did not prove non-consumption.'
        Assert-InstallerTest ([string]$timeout.exactReason -match 'process-owned 30-second limit') 'The forced-timeout result did not preserve the exact timeout reason.'
        Assert-InstallerTest ([int]$timeout.installerElapsedMs -ge 29000 -and [int]$timeout.installerElapsedMs -lt 35000) 'The forced timeout did not stop near its process-owned limit.'
        $timeoutCasePassed = $true
        $timeoutElapsedMs = [int]$timeout.installerElapsedMs
        foreach ($helperStage in @('superseded_bridge_cleanup', 'standalone_popout_bridge', 'desktop_ui_bridge')) {
            $originalStallStage = $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE
            $originalPidPath = $env:COGENTSPEC_INSTALLER_TEST_PID_PATH
            $pidPath = Join-Path $fixtureRoot "$helperStage.pid"
            try {
                $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE = $helperStage
                $env:COGENTSPEC_INSTALLER_TEST_PID_PATH = $pidPath
                Write-Host "Testing bounded $PluginName $helperStage..."
                $stalledRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -UpdateOnly -TimeoutSeconds 30
            } finally {
                $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE = $originalStallStage
                $env:COGENTSPEC_INSTALLER_TEST_PID_PATH = $originalPidPath
            }
            $stalled = $stalledRun.result
            Assert-InstallerTest ($stalledRun.exitCode -ne 0 -and [bool]$stalled.installerTimedOut) "The $helperStage fixture did not time out."
            Assert-InstallerTest ([string]$stalled.failureStage -eq $helperStage) "The $helperStage timeout lost its exact failed stage."
            Assert-InstallerTest ([int]$stalledRun.wallElapsedMs -ge 29000 -and [int]$stalledRun.wallElapsedMs -lt 35000) "The $helperStage fixture escaped the shared thirty-second budget."
            Assert-InstallerTest (-not [bool]$stalled.claimAttempted -and $stalled.accountRequestConsumed -eq $false) "The $helperStage update tried to consume a claim."
            Assert-InstallerTest (@($stalled.completedStages.stage) -notcontains $helperStage) "The stalled $helperStage was reported completed."
            $childId = [int](Get-Content -LiteralPath $pidPath -Raw)
            Assert-InstallerTest (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) "The timed-out $helperStage process survived."
            $helperTimeoutCases += [ordered]@{ stage = $helperStage; wallElapsedMs = [int]$stalledRun.wallElapsedMs; ownedChildStopped = $true }
        }
        $originalStallStage = $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE
        $originalPidPath = $env:COGENTSPEC_INSTALLER_TEST_PID_PATH
        try {
            $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE = 'desktop_ui_bridge'
            $env:COGENTSPEC_INSTALLER_TEST_PID_PATH = Join-Path $fixtureRoot 'post-claim.pid'
            Write-Host "Testing bounded $PluginName startup after a completed synthetic claim..."
            $postClaimRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference -TimeoutSeconds 30
        } finally {
            $env:COGENTSPEC_INSTALLER_TEST_STALL_STAGE = $originalStallStage
            $env:COGENTSPEC_INSTALLER_TEST_PID_PATH = $originalPidPath
        }
        $postClaim = $postClaimRun.result
        Assert-InstallerTest ($postClaimRun.exitCode -ne 0 -and [bool]$postClaim.installerTimedOut) 'A stalled post-claim worker did not time out.'
        Assert-InstallerTest ([string]$postClaim.failureStage -eq 'desktop_ui_bridge') 'A post-claim timeout lost its stage.'
        Assert-InstallerTest ([bool]$postClaim.claimAttempted -and $postClaim.accountRequestConsumed -eq $true) 'A post-claim timeout must not invite another account-bound claim.'
        Assert-InstallerTest ([int]$postClaimRun.wallElapsedMs -ge 29000 -and [int]$postClaimRun.wallElapsedMs -lt 35000) 'Post-claim startup escaped the shared deadline.'
        $postClaimTimeoutCase = [ordered]@{ wallElapsedMs = [int]$postClaimRun.wallElapsedMs; accountRequestConsumed = $true; retryAllowed = $false }
    }

    $defaultBudgetTimeoutCase = $null
    if ($ExerciseDefaultBudget) {
        $originalStall = $env:COGENTSPEC_INSTALLER_TEST_STALL
        $originalStallSeconds = $env:COGENTSPEC_INSTALLER_TEST_STALL_SECONDS
        try {
            $env:COGENTSPEC_INSTALLER_TEST_STALL = '1'
            $env:COGENTSPEC_INSTALLER_TEST_STALL_SECONDS = '130'
            Write-Host "Testing the default $PluginName 110-second work budget..."
            $defaultRun = Invoke-InstallerFixture -PowerShellPath $powerShellPath -InstallerPath $installerPath -Reference $validReference -ValidateOnly
        } finally {
            $env:COGENTSPEC_INSTALLER_TEST_STALL = $originalStall
            $env:COGENTSPEC_INSTALLER_TEST_STALL_SECONDS = $originalStallSeconds
        }
        Assert-InstallerTest ($defaultRun.exitCode -ne 0 -and [bool]$defaultRun.result.installerTimedOut) 'The default budget did not stop the stall.'
        Assert-InstallerTest ([int]$defaultRun.result.installerBudgetSeconds -eq 110) 'The default work budget is not 110 seconds.'
        Assert-InstallerTest ([int]$defaultRun.wallElapsedMs -ge 109000 -and [int]$defaultRun.wallElapsedMs -lt 120000) 'The default fixture did not return below two minutes.'
        Assert-InstallerTest (-not [bool]$defaultRun.result.claimAttempted -and $defaultRun.result.accountRequestConsumed -eq $false) 'The default timeout attempted an account claim.'
        $defaultBudgetTimeoutCase = [ordered]@{ wallElapsedMs = [int]$defaultRun.wallElapsedMs; workBudgetSeconds = 110; returnedUnderTwoMinutes = $true }
    }

    [ordered]@{
        status = 'valid'
        protocol = [string]$valid.protocol
        plugin = $PluginName
        installerElapsedMs = [int]$valid.installerElapsedMs
        nativeCommandsStarted = [int]$valid.nativeCommandsStarted
        nativeCommandsCompleted = [int]$valid.nativeCommandsCompleted
        completedStages = $completedStageNames
        invalidReferenceRejectedBeforeCommands = $true
        updateCasePassed = $true
        updatedVersion = [string]$update.version
        updateElapsedMs = [int]$update.installerElapsedMs
        updateWallElapsedMs = [int]$updateRun.wallElapsedMs
        installerBudgetSeconds = [int]$update.installerBudgetSeconds
        fastUpdatePath = [bool]$update.fastUpdatePath
        windowsPowerShellExecutablePathPassed = $true
        claimPathCasePassed = $true
        timeoutCasePassed = $timeoutCasePassed
        timeoutElapsedMs = $timeoutElapsedMs
        helperTimeoutCases = @($helperTimeoutCases)
        postClaimTimeoutCase = $postClaimTimeoutCase
        defaultBudgetTimeoutCase = $defaultBudgetTimeoutCase
        claimAttempted = $false
        accountRequestConsumed = $false
    } | ConvertTo-Json -Compress
} finally {
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
