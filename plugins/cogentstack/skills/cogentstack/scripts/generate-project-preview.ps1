[CmdletBinding()]
param(
    [ValidateSet('generate', 'watch')]
    [string]$Mode = 'generate',
    [string]$RequestId = '',
    [string]$TargetPath = '',
    [string]$LocalUrl = '',
    [int]$ProcessId = 0,
    [string]$ContextKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-context.ps1')
$projectContext = Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$contextQuery = "context=$([Uri]::EscapeDataString($projectContext.ContextKey))"

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
    } catch {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
}

$serviceUrl = 'https://cogentspec.com'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'
$watcherRoot = Join-Path $stateRoot 'preview-watchers'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 8 -Compress | Write-Output
}

function Write-Utf8NoBom([string]$LiteralPath, [string]$Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($LiteralPath, $Value, $encoding)
}

function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-DesktopToken {
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { return '' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    if (-not $credential.token) { return '' }
    return Unprotect-CogentSpecValue ([string]$credential.token)
}

function Invoke-CogentSpecApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$serviceUrl$Path"
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Resolve-ExactProjectTarget([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathRooted($Value) -or $Value -notmatch '^[A-Za-z]:[\\/]') {
        throw 'The active project target is not an absolute Windows drive path.'
    }
    $resolved = [IO.Path]::GetFullPath($Value).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw 'The active project target is unavailable.'
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The active project target cannot be a reparse point.'
    }
    return $resolved
}

function ConvertTo-SafeLoopbackUrl([string]$Value) {
    $parsed = $null
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed)) { return $null }
    if ($parsed.Scheme -ne 'http' -or $parsed.Host -notin @('localhost', '127.0.0.1', '::1', '[::1]') -or $parsed.Port -le 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($parsed.UserInfo)) { return $null }
    return $parsed
}

function Test-HealthyPreview([Uri]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url.AbsoluteUri -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

function Test-ProcessTreeMatchesTarget([int]$ListenerProcessId, [string]$ExactTargetPath) {
    $seen = New-Object 'Collections.Generic.HashSet[int]'
    $currentProcessId = $ListenerProcessId
    for ($depth = 0; $depth -lt 12 -and $currentProcessId -gt 0 -and $seen.Add($currentProcessId); $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$currentProcessId" -ErrorAction SilentlyContinue
        if (-not $process) { return $false }
        $commandLine = [string]$process.CommandLine
        if ($commandLine.IndexOf($ExactTargetPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        $currentProcessId = [int]$process.ParentProcessId
    }
    return $false
}

function Get-VerifiedPreview([string]$CandidateUrl, [string]$ExactTargetPath) {
    $url = ConvertTo-SafeLoopbackUrl $CandidateUrl
    if (-not $url) { return $null }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $url.Port -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalAddress -in @('127.0.0.1', '::1')
    })
    foreach ($listener in $listeners) {
        $listenerProcessId = [int]$listener.OwningProcess
        if ((Test-ProcessTreeMatchesTarget $listenerProcessId $ExactTargetPath) -and (Test-HealthyPreview $url)) {
            return [pscustomobject]@{ Url = $url.AbsoluteUri; Port = $url.Port; ProcessId = $listenerProcessId }
        }
    }
    return $null
}

function Find-ProjectPreview([string]$ExactTargetPath, [string[]]$RememberedUrls) {
    $seenUrls = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $RememberedUrls) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not $seenUrls.Add($candidate)) { continue }
        $verified = Get-VerifiedPreview $candidate $ExactTargetPath
        if ($verified) { return $verified }
    }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalPort -ge 3000 -and $_.LocalPort -le 3099 -and $_.LocalAddress -in @('127.0.0.1', '::1')
    } | Sort-Object LocalPort -Unique)
    foreach ($listener in $listeners) {
        $listenerProcessId = [int]$listener.OwningProcess
        if (-not (Test-ProcessTreeMatchesTarget $listenerProcessId $ExactTargetPath)) { continue }
        $verified = Get-VerifiedPreview "http://localhost:$([int]$listener.LocalPort)/" $ExactTargetPath
        if ($verified) { return $verified }
    }
    return $null
}

function Report-PreviewState([string]$Token, [string]$ExactRequestId, [string]$ExactTargetPath, [string]$State, [string]$Url, [int]$ListenerProcessId) {
    return Invoke-CogentSpecApi -Method Put -Path "/api/plugin/project-runtime?$contextQuery" -Token $Token -Body @{
        requestId = $ExactRequestId
        targetPath = $ExactTargetPath
        state = $State
        localUrl = $Url
        processId = if ($State -eq 'running') { $ListenerProcessId } else { $null }
    }
}

function Get-WatcherStatePath([string]$ExactRequestId) {
    Join-Path $watcherRoot "$ExactRequestId.json"
}

function Start-PreviewWatcher([string]$ExactRequestId, [string]$ExactTargetPath, [string]$Url, [int]$ListenerProcessId) {
    New-Item -ItemType Directory -Path $watcherRoot -Force | Out-Null
    $watcherPath = Get-WatcherStatePath $ExactRequestId
    if (Test-Path -LiteralPath $watcherPath -PathType Leaf) {
        try {
            $existing = Get-Content -Raw -LiteralPath $watcherPath | ConvertFrom-Json
            $existingProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$existing.processId)" -ErrorAction SilentlyContinue
            if ($existingProcess -and [string]$existingProcess.CommandLine -match [regex]::Escape($ExactRequestId)) { return $false }
        } catch { }
    }
    $powershellCommand = Get-Command powershell.exe, pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $powershellCommand) { throw 'Windows PowerShell is required to monitor the local preview.' }
    $quotedScript = $PSCommandPath.Replace("'", "''")
    $quotedRequest = $ExactRequestId.Replace("'", "''")
    $quotedTarget = $ExactTargetPath.Replace("'", "''")
    $quotedUrl = $Url.Replace("'", "''")
    $command = "& '$quotedScript' -Mode watch -RequestId '$quotedRequest' -TargetPath '$quotedTarget' -LocalUrl '$quotedUrl' -ProcessId $ListenerProcessId"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $watcher = Start-Process -FilePath ([string]$powershellCommand.Source) -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
    Write-Utf8NoBom $watcherPath (([ordered]@{ processId = $watcher.Id; requestId = $ExactRequestId; localUrl = $Url; startedAt = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Compress)
    return $true
}

if ($Mode -eq 'watch') {
    $token = Get-DesktopToken
    if (-not $token -or $RequestId -notmatch '^[0-9a-fA-F-]{36}$') { exit 0 }
    $exactTarget = Resolve-ExactProjectTarget $TargetPath
    $safeUrl = ConvertTo-SafeLoopbackUrl $LocalUrl
    if (-not $safeUrl) { exit 0 }
    try {
        while ($true) {
            $verified = Get-VerifiedPreview $safeUrl.AbsoluteUri $exactTarget
            if (-not $verified) {
                Report-PreviewState $token $RequestId $exactTarget 'unavailable' $safeUrl.AbsoluteUri 0 | Out-Null
                break
            }
            Report-PreviewState $token $RequestId $exactTarget 'running' $verified.Url $verified.ProcessId | Out-Null
            Start-Sleep -Seconds 5
        }
    } catch {
        # A revoked Desktop connection or changed active project ends this local watcher quietly.
    } finally {
        $watcherPath = Get-WatcherStatePath $RequestId
        if (Test-Path -LiteralPath $watcherPath -PathType Leaf) {
            try {
                $state = Get-Content -Raw -LiteralPath $watcherPath | ConvertFrom-Json
                if ([int]$state.processId -eq $PID) { Remove-Item -LiteralPath $watcherPath -Force }
            } catch { }
        }
    }
    exit 0
}

$token = Get-DesktopToken
if (-not $token) {
    Write-CompactJson ([ordered]@{ status = 'desktop_authorization_required'; reason = 'missing'; activeProjectPreserved = $true })
    exit 0
}

try {
    $listing = Invoke-CogentSpecApi -Method Get -Path "/api/plugin/project-runtime?$contextQuery" -Token $token
} catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($statusCode -eq 401) {
        Write-CompactJson ([ordered]@{ status = 'desktop_authorization_required'; reason = 'expired_or_revoked'; activeProjectPreserved = $true })
        exit 0
    }
    throw
}

if (-not $listing.activeProject) {
    Write-CompactJson ([ordered]@{ status = 'no_active_project' })
    exit 0
}

$activeProject = $listing.activeProject
$exactRequestId = [string]$activeProject.requestId
$exactTarget = Resolve-ExactProjectTarget ([string]$activeProject.targetPath)
if ($exactRequestId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'CogentSpec returned an invalid active project identity.' }

$runtimePath = Join-Path $exactTarget '.coge\runtime.json'
$rememberedUrls = New-Object 'Collections.Generic.List[string]'
if ($listing.runtime -and $listing.runtime.localUrl) { $rememberedUrls.Add([string]$listing.runtime.localUrl) }
$localRuntime = $null
if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
    try {
        $localRuntime = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
        if ($localRuntime.url) { $rememberedUrls.Add([string]$localRuntime.url) }
    } catch { }
}

$verifiedPreview = Find-ProjectPreview $exactTarget $rememberedUrls.ToArray()
$generated = $false
if (-not $verifiedPreview) {
    $startScript = Join-Path $exactTarget 'scripts\start-local.ps1'
    if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
        Write-CompactJson ([ordered]@{ status = 'preview_not_supported'; requestId = $exactRequestId; targetPath = $exactTarget })
        exit 0
    }
    $startItem = Get-Item -LiteralPath $startScript -Force
    if ($startItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The local preview launcher cannot be a reparse point.' }
    if (Test-Path -LiteralPath $runtimePath -PathType Leaf) { Remove-Item -LiteralPath $runtimePath -Force }

    $preferredPort = 3000
    foreach ($rememberedUrl in $rememberedUrls) {
        $parsedRememberedUrl = ConvertTo-SafeLoopbackUrl $rememberedUrl
        if ($parsedRememberedUrl -and $parsedRememberedUrl.Port -ge 3000 -and $parsedRememberedUrl.Port -le 3099) {
            $preferredPort = $parsedRememberedUrl.Port
            break
        }
    }
    $powershellCommand = Get-Command powershell.exe, pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $powershellCommand) { throw 'Windows PowerShell is required to generate the local preview.' }
    $previewLauncher = Start-Process -FilePath ([string]$powershellCommand.Source) -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $startScript, '-PreferredPort', [string]$preferredPort
    ) -WindowStyle Hidden -PassThru
    $previewDeadline = [DateTime]::UtcNow.AddSeconds(125)
    while ([DateTime]::UtcNow -lt $previewDeadline -and -not $verifiedPreview) {
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            try {
                $started = Get-Content -Raw -LiteralPath $runtimePath | ConvertFrom-Json
                if ($started.url) { $verifiedPreview = Get-VerifiedPreview ([string]$started.url) $exactTarget }
            } catch { }
        }
        if ($verifiedPreview) { break }
        if ($previewLauncher.HasExited -and $previewLauncher.ExitCode -ne 0) {
            throw "Local preview generation failed with exit code $($previewLauncher.ExitCode)."
        }
        Start-Sleep -Milliseconds 400
    }
    if (-not $verifiedPreview) { throw 'The generated preview does not belong to the exact active CogentSpec project.' }
    $generated = $true
}

Report-PreviewState $token $exactRequestId $exactTarget 'running' $verifiedPreview.Url $verifiedPreview.ProcessId | Out-Null
$watcherStarted = Start-PreviewWatcher $exactRequestId $exactTarget $verifiedPreview.Url $verifiedPreview.ProcessId
Write-CompactJson ([ordered]@{
    status = if ($generated) { 'generated' } else { 'already_running' }
    requestId = $exactRequestId
    projectName = [string]$activeProject.projectName
    targetPath = $exactTarget
    localUrl = $verifiedPreview.Url
    port = $verifiedPreview.Port
    processId = $verifiedPreview.ProcessId
    remembered = $true
    watcherStarted = $watcherStarted
    nextAction = 'use_view_project_button'
})
