[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][string]$ContextKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-command.ps1')

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
}

$serviceUrl = 'https://cogentspec.com'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'
$contextQuery = "context=$([Uri]::EscapeDataString($ContextKey))"

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 10 -Compress | Write-Output
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

function Invoke-CogentSpecApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$serviceUrl$Path"
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Resolve-ExactProjectTarget([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathRooted($Value) -or $Value -notmatch '^[A-Za-z]:[\\/]') {
        throw 'The active project target is not an absolute Windows drive path.'
    }
    $resolved = [IO.Path]::GetFullPath($Value).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw 'The active project folder is unavailable.'
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The active project folder cannot be a reparse point.'
    }
    return $resolved
}

function Invoke-Git([string]$Root, [string[]]$Arguments, [switch]$AllowFailure) {
    $result = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList (@('-C', $Root) + $Arguments)
    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        throw "Git could not inspect the project: $($result.Output)"
    }
    return $result
}

if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    Write-CompactJson ([ordered]@{ status = 'desktop_authorization_required'; reason = 'missing'; requestPreserved = $true })
    exit 0
}

$token = ''
$claimed = $false
try {
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $token = Unprotect-CogentSpecValue ([string]$credential.token)
    $requestPath = "/api/plugin/git-requests?$contextQuery&id=$([Uri]::EscapeDataString($RequestId))"
    $listing = Invoke-CogentSpecApi -Method Get -Path $requestPath -Token $token
    if (-not $listing.activeProject -or -not $listing.request -or [string]$listing.request.action -ne 'refresh') {
        throw 'The approved project check is unavailable.'
    }
    if ([string]$listing.request.status -eq 'requested') {
        Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/git-requests?$contextQuery" -Token $token -Body @{
            requestId = $RequestId
            action = 'claim'
            statusMessage = 'Desktop Bridge is checking the project.'
        } | Out-Null
        $claimed = $true
    } elseif ([string]$listing.request.status -eq 'applying') {
        $claimed = $true
    } else {
        throw 'The approved project check is no longer waiting.'
    }

    $activeProject = $listing.activeProject.project
    $root = Resolve-ExactProjectTarget ([string]$activeProject.targetPath)
    $manifestPath = Join-Path $root '.coge\knowledge-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The project identity file is missing.'
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ([string]$manifest.project.requestId -ne [string]$activeProject.id) {
        throw 'The project folder does not match the active CogentSpec project.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container)) {
        throw 'The active project is not a Git repository.'
    }

    $repositoryCheck = Invoke-Git $root @('rev-parse', '--is-inside-work-tree')
    if ($repositoryCheck.Output.Trim() -ne 'true') { throw 'The active project is not a Git worktree.' }
    $branch = (Invoke-Git $root @('branch', '--show-current')).Output.Trim()
    # The branch header keeps PowerShell's outer output trim from removing the
    # first status column when the first file has only a working-tree change.
    $statusLines = @((Invoke-Git $root @('status', '--porcelain=v1', '--branch', '--untracked-files=normal')).Output -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('## ') })
    $files = @($statusLines | Select-Object -First 200 | ForEach-Object {
        $line = [string]$_
        $code = if ($line.Length -ge 2) { $line.Substring(0, 2) } else { $line }
        $path = if ($line.Length -gt 3) { $line.Substring(3) } else { '' }
        [ordered]@{
            path = $path.Trim('"')
            status = $code.Trim()
            staged = $code.Length -gt 0 -and $code[0] -notin @(' ', '?')
        }
    })

    $name = (Invoke-Git $root @('config', '--get', 'user.name') -AllowFailure).Output.Trim()
    $email = (Invoke-Git $root @('config', '--get', 'user.email') -AllowFailure).Output.Trim()
    $remoteResult = Invoke-Git $root @('remote', 'get-url', 'origin') -AllowFailure
    $remoteUrl = if ($remoteResult.ExitCode -eq 0) { $remoteResult.Output.Trim() } else { '' }
    $commitLines = @((Invoke-Git $root @('log', '-n', '12', '--date=iso-strict', '--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%aI') -AllowFailure).Output -split "`r?`n" | Where-Object { $_ })
    $commits = @($commitLines | ForEach-Object {
        $parts = @(([string]$_) -split [char]31)
        if ($parts.Count -ge 5) {
            [ordered]@{ hash = $parts[0]; shortHash = $parts[1]; subject = $parts[2]; author = $parts[3]; committedAt = $parts[4] }
        }
    } | Where-Object { $null -ne $_ })

    $workingDiff = (Invoke-Git $root @('diff', '--no-ext-diff', '--unified=3', '--') -AllowFailure).Output
    $stagedDiff = (Invoke-Git $root @('diff', '--cached', '--no-ext-diff', '--unified=3', '--') -AllowFailure).Output
    $diff = @($stagedDiff, $workingDiff) -join "`n"
    $diffLimit = 12000
    $diffTruncated = $diff.Length -gt $diffLimit
    if ($diffTruncated) { $diff = $diff.Substring(0, $diffLimit) }
    $capturedAt = [DateTimeOffset]::UtcNow.ToString('O')
    $snapshot = [ordered]@{
        requestId = [string]$activeProject.id
        targetPath = $root
        repository = $true
        branch = $branch
        clean = $files.Count -eq 0
        identityConfigured = -not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($email)
        remoteUrl = $remoteUrl
        files = $files
        commits = $commits
        diffPreview = $diff
        diffTruncated = $diffTruncated
        capturedAt = $capturedAt
    }
    Invoke-CogentSpecApi -Method Put -Path "/api/plugin/git-requests?$contextQuery" -Token $token -Body @{
        requestId = $RequestId
        snapshot = $snapshot
    } | Out-Null
    Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/git-requests?$contextQuery" -Token $token -Body @{
        requestId = $RequestId
        action = 'complete'
        statusMessage = 'Project check completed.'
    } | Out-Null
    Write-CompactJson ([ordered]@{
        status = 'refreshed'
        projectRequestId = [string]$activeProject.id
        targetPath = $root
        changedFiles = $files.Count
        capturedAt = $capturedAt
    })
} catch {
    $reason = $_.Exception.Message
    if ($claimed -and -not [string]::IsNullOrWhiteSpace($token)) {
        try {
            Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/git-requests?$contextQuery" -Token $token -Body @{
                requestId = $RequestId
                action = 'fail'
                statusMessage = $reason
            } | Out-Null
        } catch { }
    }
    Write-CompactJson ([ordered]@{ status = 'failed'; reason = $reason; requestPreserved = $true })
} finally {
    $token = $null
}
