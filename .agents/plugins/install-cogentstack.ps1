[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallationRequest,

    [ValidateRange(30, 150)]
    [int]$InstallerTimeoutSeconds = 120,

    [switch]$MarketplacePrepared,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$protocol = 'trusted-marketplace-v3'
$marketplaceName = 'cogentstack'
$marketplaceSource = 'https://github.com/cogentspec/cogentspec-marketplace.git'
$workspaceUrl = 'https://cogentspec.com/stack'
$requiredSparsePaths = @('.agents/plugins', 'plugins/cogentstack')
$timer = [Diagnostics.Stopwatch]::StartNew()
$privateInstallationRequest = [string]$InstallationRequest
$InstallationRequest = ''
$claimJob = $null
$claimAttempted = $false
$claimSucceeded = $false
$installerTimedOut = $false
$nativeCommandsStarted = 0
$nativeCommandsCompleted = 0
$lastNativeOperation = $null
$completedStages = [Collections.Generic.List[object]]::new()
$stage = 'initialization'
$stageStartedMs = 0

function Set-InstallStage {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:stage = $Name
    $script:stageStartedMs = [int]$script:timer.ElapsedMilliseconds
}

function Complete-InstallStage {
    $script:completedStages.Add([ordered]@{
        stage = $script:stage
        durationMs = [Math]::Max(0, [int]$script:timer.ElapsedMilliseconds - $script:stageStartedMs)
    })
}

function Throw-InstallerTimeout {
    $script:installerTimedOut = $true
    throw "The running installer exceeded its process-owned $InstallerTimeoutSeconds-second limit."
}

function Get-RemainingMilliseconds {
    $remaining = ($InstallerTimeoutSeconds * 1000) - [int]$timer.ElapsedMilliseconds
    if ($remaining -le 0) {
        Throw-InstallerTimeout
    }
    return $remaining
}

function Invoke-BoundedNative {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $remaining = Get-RemainingMilliseconds
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $isCommandScript = [IO.Path]::GetExtension($FilePath) -in @('.cmd', '.bat')
    $startInfo.FileName = if ($isCommandScript) { $env:ComSpec } else { $FilePath }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($isCommandScript) {
        $quotedArguments = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' })
        $startInfo.Arguments = '/d /s /c ""' + $FilePath + '" ' + ($quotedArguments -join ' ') + '"'
    } else {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $script:lastNativeOperation = $Operation
    try {
        if (-not $process.Start()) {
            throw "Could not start the $Operation command."
        }
        $script:nativeCommandsStarted++
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($remaining)) {
            try { $process.Kill($true) } catch { }
            Throw-InstallerTimeout
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $script:nativeCommandsCompleted++
        if ($process.ExitCode -ne 0) {
            $detail = if ($stderr) { $stderr } elseif ($stdout) { $stdout } else { "exit code $($process.ExitCode)" }
            throw "$Operation failed: $detail"
        }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

function Read-JsonResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    try {
        return $Text | ConvertFrom-Json
    } catch {
        throw "$Operation did not return valid JSON."
    }
}

function Get-MarketplaceState {
    $json = Invoke-BoundedNative -FilePath $script:codexPath -Arguments @('plugin', 'marketplace', 'list', '--json') -Operation 'marketplace inspection'
    $result = Read-JsonResult -Text $json -Operation 'Marketplace inspection'
    return @($result.marketplaces | Where-Object { $_.name -eq $marketplaceName }) | Select-Object -First 1
}

function Test-StringSetEqual {
    param([string[]]$Actual, [string[]]$Expected)
    $difference = @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object))
    return $difference.Count -eq 0
}

try {
    if ($privateInstallationRequest -notmatch '^cgb_[A-Za-z0-9_-]{40,}$') {
        throw 'The current installation invocation is missing a valid account-bound request.'
    }
    if (-not $MarketplacePrepared) {
        throw 'Protocol v3 requires a marketplace prepared by Codex before this installer process starts.'
    }

    $codexCommand = @(Get-Command codex.cmd -CommandType Application -ErrorAction Stop) | Select-Object -First 1
    $gitCommand = @(Get-Command git.cmd -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $gitCommand) {
        $gitCommand = @(Get-Command git.exe -CommandType Application -ErrorAction Stop) | Select-Object -First 1
    }
    $script:codexPath = [string]$codexCommand.Source
    $gitPath = [string]$gitCommand.Source
    Complete-InstallStage

    Set-InstallStage -Name 'workspace_readiness'
    $webTimeout = [Math]::Max(1, [Math]::Min(10, [Math]::Floor((Get-RemainingMilliseconds) / 1000)))
    $response = Invoke-WebRequest `
        -Uri $workspaceUrl `
        -UseBasicParsing `
        -MaximumRedirection 0 `
        -TimeoutSec $webTimeout
    if ([int]$response.StatusCode -ne 200) {
        throw 'The CogentSpec workspace did not return HTTP 200.'
    }
    $baseResponseProperties = @($response.BaseResponse.PSObject.Properties.Name)
    $finalUrl = if ($baseResponseProperties -contains 'RequestMessage' -and $response.BaseResponse.RequestMessage.RequestUri) {
        $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    } elseif ($baseResponseProperties -contains 'ResponseUri' -and $response.BaseResponse.ResponseUri) {
        $response.BaseResponse.ResponseUri.AbsoluteUri
    } else {
        $workspaceUrl
    }
    if ($finalUrl -ne $workspaceUrl) {
        throw 'The CogentSpec workspace redirected instead of returning the official web workspace.'
    }
    if ($response.Content -notmatch 'What would you like to create\?' -or $response.Content -notmatch 'project-idea') {
        throw 'The CogentSpec workspace is missing a required project-creation marker.'
    }
    Complete-InstallStage

    Set-InstallStage -Name 'prepared_marketplace_verification'
    $marketplace = Get-MarketplaceState
    if (-not $marketplace -or -not (Test-Path -LiteralPath ([string]$marketplace.root))) {
        throw 'The prepared CogentSpec marketplace registration is unavailable.'
    }
    $marketplaceRoot = (Resolve-Path -LiteralPath ([string]$marketplace.root) -ErrorAction Stop).Path.TrimEnd('\', '/')
    $installerMarketplaceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..') -ErrorAction Stop).Path.TrimEnd('\', '/')
    if (-not [string]::Equals($marketplaceRoot, $installerMarketplaceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installer is not running from the prepared CogentSpec marketplace.'
    }
    $preparedRemote = Invoke-BoundedNative -FilePath $gitPath -Arguments @('-C', $marketplaceRoot, 'remote', 'get-url', 'origin') -Operation 'marketplace remote verification'
    $preparedSparse = @((Invoke-BoundedNative -FilePath $gitPath -Arguments @('-C', $marketplaceRoot, 'sparse-checkout', 'list') -Operation 'marketplace sparse-path verification') -split "`r?`n" | Where-Object { $_ })
    if ($preparedRemote.Trim() -ne $marketplaceSource -or -not (Test-StringSetEqual -Actual $preparedSparse -Expected $requiredSparsePaths)) {
        throw 'The prepared CogentSpec marketplace does not match the official Git source and sparse paths.'
    }
    Complete-InstallStage

    Set-InstallStage -Name 'plugin_installation'
    $installJson = Invoke-BoundedNative -FilePath $script:codexPath -Arguments @('plugin', 'add', 'cogentstack@cogentstack', '--json') -Operation 'plugin installation'
    $installResult = Read-JsonResult -Text $installJson -Operation 'Plugin installation'
    $installedPath = [string]$installResult.installedPath
    if (-not $installedPath -or -not (Test-Path -LiteralPath $installedPath)) {
        throw 'The CogentSpec plugin installation did not return a valid installed package path.'
    }
    Complete-InstallStage

    Set-InstallStage -Name 'installed_state_verification'
    $pluginListJson = Invoke-BoundedNative -FilePath $script:codexPath -Arguments @('plugin', 'list', '--json') -Operation 'installed plugin inspection'
    $pluginList = Read-JsonResult -Text $pluginListJson -Operation 'Installed plugin inspection'
    $installedPlugin = @($pluginList.installed | Where-Object { $_.pluginId -eq 'cogentstack@cogentstack' }) | Select-Object -First 1
    if (-not $installedPlugin -or -not [bool]$installedPlugin.installed -or -not [bool]$installedPlugin.enabled) {
        throw 'The CogentSpec plugin is not installed and enabled.'
    }
    Complete-InstallStage

    Set-InstallStage -Name 'package_integrity_verification'
    $sourcePluginPath = Join-Path $marketplaceRoot 'plugins\cogentstack'
    $sourceManifestPath = Join-Path $sourcePluginPath '.codex-plugin\plugin.json'
    $installedManifestPath = Join-Path $installedPath '.codex-plugin\plugin.json'
    $sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
    $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    if ([string]$sourceManifest.version -ne [string]$installedManifest.version -or [string]$installedPlugin.version -ne [string]$sourceManifest.version) {
        throw 'The installed CogentSpec version does not match the prepared marketplace package.'
    }

    $allowedFiles = @(
        '.codex-plugin/plugin.json',
        'assets/icon.png',
        'assets/logo.png',
        'skills/cogentstack/agents/openai.yaml',
        'skills/cogentstack/scripts/connect-cogentstack.ps1',
        'skills/cogentstack/scripts/delete-project.ps1',
        'skills/cogentstack/scripts/fulfil-project.ps1',
        'skills/cogentstack/scripts/generate-project-preview.ps1',
        'skills/cogentstack/scripts/native-command.ps1',
        'skills/cogentstack/scripts/prepare-deployment.ps1',
        'skills/cogentstack/scripts/project-context.ps1',
        'skills/cogentstack/scripts/project-knowledge.ps1',
        'skills/cogentstack/scripts/start-cogentstack-bridge.ps1',
        'skills/cogentstack/scripts/watch-cogentstack-bridge.ps1',
        'skills/cogentstack/SKILL.md'
    )
    $actualFiles = @(Get-ChildItem -LiteralPath $installedPath -Recurse -Force -File | ForEach-Object {
        $_.FullName.Substring($installedPath.Length + 1).Replace('\', '/')
    })
    if (-not (Test-StringSetEqual -Actual $actualFiles -Expected $allowedFiles)) {
        throw 'The installed CogentSpec package does not match the official public-file allowlist.'
    }
    foreach ($relativePath in $allowedFiles) {
        $nativeRelativePath = $relativePath.Replace('/', '\')
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $sourcePluginPath $nativeRelativePath) -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath (Join-Path $installedPath $nativeRelativePath) -Algorithm SHA256).Hash
        if ($sourceHash -ne $installedHash) {
            throw "The installed package differs from the prepared marketplace at $relativePath."
        }
    }
    Complete-InstallStage

    Set-InstallStage -Name 'launcher_contract_verification'
    $skillText = Get-Content -LiteralPath (Join-Path $installedPath 'skills\cogentstack\SKILL.md') -Raw
    $requiredSkillStatements = @(
        'Run `scripts/project-context.ps1` exactly once',
        'Run `scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt` exactly once.',
        'This helper performs the one account-status check itself.',
        '`browserOpened: false`',
        'Do not open the workspace link, call a browser-control tool, create or select a browser tab',
        'https://cogentspec.app',
        'https://cogentspec.com/stack',
        'Qwen Desktop is an optional CogentSpec-owned integrated application and includes the same Bridge',
        'queues `create_project` for Desktop Bridge',
        'queues `preview_project` for Desktop Bridge',
        'queues `delete_project` immediately'
    )
    foreach ($statement in $requiredSkillStatements) {
        if (-not $skillText.Contains($statement)) {
            throw 'The installed launcher skill is missing a required web-first Desktop Bridge guarantee.'
        }
    }

    $bridgeScript = Get-Content -LiteralPath (Join-Path $installedPath 'skills\cogentstack\scripts\start-cogentstack-bridge.ps1') -Raw
    foreach ($prohibitedMarker in @('Start-Process ([string]$workspaceUrl', '--app', '--new-window', 'SetWindowPos', 'SW_MAXIMIZE')) {
        if ($bridgeScript.Contains($prohibitedMarker)) {
            throw 'The Desktop Bridge launcher contains a prohibited browser or window-arrangement action.'
        }
    }
    foreach ($requiredMarker in @("browserOpened = `$false", "bridge = 'started'", "bridge = 'already_running'", '-WorkspaceGrant', '-ContextKey $resolvedContext', 'https://cogentspec.app/stack', '#desktop=', 'start-cogentstack-bridge.ps1')) {
        if (-not ($bridgeScript.Contains($requiredMarker) -or $skillText.Contains($requiredMarker))) {
            throw 'The Desktop Bridge launcher is missing a required web-first connection marker.'
        }
    }
    Complete-InstallStage

    if ($ValidateOnly) {
        [ordered]@{
            protocol = $protocol
            status = 'validated'
            failureStage = $null
            installerStarted = $true
            installerTimedOut = $false
            marketplacePrepared = $true
            nativeCommandsStarted = $nativeCommandsStarted
            nativeCommandsCompleted = $nativeCommandsCompleted
            lastNativeOperation = $lastNativeOperation
            completedStages = @($completedStages)
            claimAttempted = $false
            accountRequestConsumed = $false
            connected = $false
            installed = $true
            enabled = $true
            version = [string]$installedManifest.version
            installerElapsedMs = [int]$timer.ElapsedMilliseconds
        } | ConvertTo-Json -Compress -Depth 5 | Write-Output
        exit 0
    }

    Set-InstallStage -Name 'account_bound_claim'
    $remainingForClaim = Get-RemainingMilliseconds
    if ($remainingForClaim -lt 5000) {
        throw 'The running installer did not leave at least five seconds to begin the account-bound claim safely.'
    }
    $connectScript = Join-Path $installedPath 'skills\cogentstack\scripts\connect-cogentstack.ps1'
    $claimJob = Start-Job -ScriptBlock {
        param($ConnectionHelper, $PrivateRequest)
        & $ConnectionHelper -Mode claim -InstallationRequest $PrivateRequest
    } -ArgumentList $connectScript, $privateInstallationRequest
    $claimAttempted = $true
    $privateInstallationRequest = ''

    $claimWaitSeconds = [Math]::Max(1, [Math]::Floor((Get-RemainingMilliseconds) / 1000))
    if (-not (Wait-Job -Job $claimJob -Timeout $claimWaitSeconds)) {
        Stop-Job -Job $claimJob -ErrorAction SilentlyContinue
        Throw-InstallerTimeout
    }
    $claimOutput = (@(Receive-Job -Job $claimJob -ErrorAction Stop) | ForEach-Object { [string]$_ }) -join "`n"
    $claimResult = Read-JsonResult -Text $claimOutput.Trim() -Operation 'Account-bound installation claim'
    if ([string]$claimResult.status -ne 'connected' -or -not [bool]$claimResult.accountBound -or -not [bool]$claimResult.installationBound) {
        throw 'The account-bound installation claim did not return the three required connection guarantees.'
    }
    $claimSucceeded = $true
    Complete-InstallStage

    [ordered]@{
        protocol = $protocol
        status = 'installed'
        failureStage = $null
        installerStarted = $true
        installerTimedOut = $false
        marketplacePrepared = $true
        nativeCommandsStarted = $nativeCommandsStarted
        nativeCommandsCompleted = $nativeCommandsCompleted
        lastNativeOperation = $lastNativeOperation
        completedStages = @($completedStages)
        claimAttempted = $true
        accountRequestConsumed = $true
        connected = $true
        accountBound = $true
        installationBound = $true
        version = [string]$installedManifest.version
        installerElapsedMs = [int]$timer.ElapsedMilliseconds
    } | ConvertTo-Json -Compress -Depth 5 | Write-Output
} catch {
    [ordered]@{
        protocol = $protocol
        status = 'failed'
        failureStage = $stage
        installerStarted = $true
        installerTimedOut = $installerTimedOut
        marketplacePrepared = [bool]$MarketplacePrepared
        nativeCommandsStarted = $nativeCommandsStarted
        nativeCommandsCompleted = $nativeCommandsCompleted
        lastNativeOperation = $lastNativeOperation
        completedStages = @($completedStages)
        failedStageElapsedMs = [Math]::Max(0, [int]$timer.ElapsedMilliseconds - $stageStartedMs)
        claimAttempted = $claimAttempted
        accountRequestConsumed = if ($claimSucceeded) { $true } elseif ($claimAttempted) { $null } else { $false }
        exactReason = [string]$_.Exception.Message
        installerElapsedMs = [int]$timer.ElapsedMilliseconds
    } | ConvertTo-Json -Compress -Depth 5 | Write-Output
    exit 1
} finally {
    $InstallationRequest = ''
    $privateInstallationRequest = ''
    if ($claimJob) {
        Remove-Job -Job $claimJob -Force -ErrorAction SilentlyContinue
    }
}
