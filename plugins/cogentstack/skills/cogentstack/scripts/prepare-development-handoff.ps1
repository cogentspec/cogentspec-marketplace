[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][string]$ContextKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
}

$serviceUrl = 'https://cogentspec.com'
$credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
$query = "context=$([Uri]::EscapeDataString($ContextKey))"
$claim = $null
$target = ''

function Write-CompactJson($Value) { $Value | ConvertTo-Json -Depth 8 -Compress }

function Get-DesktopToken {
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'CogentSpec Desktop is not connected.' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    if (-not $credential.token) { throw 'CogentSpec Desktop credential is empty.' }
    $bytes = [Convert]::FromBase64String([string]$credential.token)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($plain)
}

function Invoke-Api([string]$Method, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$serviceUrl/api/plugin/development-handoffs?$query"
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Get-ContentHash([string]$Content) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Content)))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-FileHashValue([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-SafeTarget([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'The registered project path is invalid.' }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ($resolved.TrimEnd('\') -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\')) { throw 'A drive root cannot be used as a project folder.' }
    $item = Get-Item -LiteralPath $resolved -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The registered project folder is not a safe local directory.' }
    return $resolved
}

function Resolve-SafeDestination([string]$Root, [string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized.StartsWith('/') -or $normalized.Contains('../') -or $normalized.Contains('/..') -or $normalized.Contains(':')) {
        throw "The development handoff contains an unsafe path: $RelativePath"
    }
    $allowed = $normalized -eq '.cogent/compilation-manifest.json' `
        -or $normalized -eq '.cogent/execution-provider.json' `
        -or $normalized -eq '.specify/memory/constitution.md' `
        -or $normalized -match '^specs/001-[a-z0-9][a-z0-9-]{0,79}/(spec|plan|tasks)\.md$' `
        -or $normalized -match '^specs/001-[a-z0-9][a-z0-9-]{0,79}/checklists/requirements\.md$'
    if (-not $allowed) { throw "The development handoff contains an unapproved path: $RelativePath" }
    $destination = [IO.Path]::GetFullPath((Join-Path $Root $normalized.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = $Root.TrimEnd('\') + '\'
    if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "The development handoff path escaped the project folder: $RelativePath" }
    return $destination
}

$token = Get-DesktopToken
try {
    $claim = Invoke-Api -Method Post -Token $token -Body @{ action = 'claim'; requestId = $RequestId }
    $target = Resolve-SafeTarget ([string]$claim.targetPath)
    $identityPath = Join-Path $target '.coge\knowledge-manifest.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { throw 'The registered project identity is missing.' }
    $identity = Get-Content -Raw -LiteralPath $identityPath | ConvertFrom-Json
    if ([string]$identity.project.requestId -ne [string]$claim.request.projectRequestId) { throw 'The registered project identity does not match this handoff.' }

    $files = @($claim.artifact.files)
    if ($files.Count -ne 7) { throw 'The approved Spec Kit-compatible handoff must contain exactly seven files.' }
    $statePath = Join-Path $target '.cogent\development-handoff.json'
    $previousState = $null
    $previousStateBytes = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $previousStateBytes = [IO.File]::ReadAllBytes($statePath)
            $previousState = [Text.Encoding]::UTF8.GetString($previousStateBytes) | ConvertFrom-Json
        }
        catch { throw 'conflict: The previous CogentSpec handoff record is unreadable.' }
        if ([string]$previousState.projectRequestId -ne [string]$claim.request.projectRequestId) {
            throw 'conflict: The previous handoff belongs to a different project.'
        }
    }

    $destinations = @()
    foreach ($file in $files) {
        $path = [string]$file.path
        $content = [string]$file.content
        if ((Get-ContentHash $content) -ne [string]$file.sha256) { throw "The handoff integrity check failed for $path." }
        $destination = Resolve-SafeDestination $target $path
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $currentHash = Get-FileHashValue $destination
            $previous = if ($previousState) { @($previousState.files | Where-Object { [string]$_.path -eq $path } | Select-Object -First 1) } else { @() }
            if ($currentHash -ne [string]$file.sha256 -and (-not $previous -or $currentHash -ne [string]$previous.sha256)) {
                throw "conflict: $path contains changes that were not written by the previous CogentSpec handoff. No files were changed."
            }
        }
        $destinations += [pscustomobject]@{ path = $path; destination = $destination; content = $content; sha256 = [string]$file.sha256 }
    }

    $backups = @{}
    $temporaries = @()
    $stateTemporary = "$statePath.cogentspec-$PID.tmp"
    try {
        foreach ($entry in $destinations) {
            $parent = Split-Path -Parent $entry.destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $backups[$entry.destination] = if (Test-Path -LiteralPath $entry.destination -PathType Leaf) { [IO.File]::ReadAllBytes($entry.destination) } else { $null }
            $temporary = "$($entry.destination).cogentspec-$PID.tmp"
            [IO.File]::WriteAllText($temporary, [string]$entry.content, [Text.UTF8Encoding]::new($false))
            $temporaries += $temporary
        }
        foreach ($entry in $destinations) {
            $temporary = "$($entry.destination).cogentspec-$PID.tmp"
            Move-Item -LiteralPath $temporary -Destination $entry.destination -Force
        }
        $state = [ordered]@{
            schemaVersion = 1
            projectRequestId = [string]$claim.request.projectRequestId
            artifactDigest = [string]$claim.artifact.digest
            compilationDigest = [string]$claim.request.compilationDigest
            installedAt = [DateTime]::UtcNow.ToString('o')
            files = @($destinations | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256 } })
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        [IO.File]::WriteAllText($stateTemporary, ($state | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $stateTemporary -Destination $statePath -Force
    } catch {
        foreach ($temporary in $temporaries) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $stateTemporary -Force -ErrorAction SilentlyContinue
        foreach ($entry in $destinations) {
            if (-not $backups.ContainsKey($entry.destination)) { continue }
            if ($null -eq $backups[$entry.destination]) { Remove-Item -LiteralPath $entry.destination -Force -ErrorAction SilentlyContinue }
            else { [IO.File]::WriteAllBytes($entry.destination, [byte[]]$backups[$entry.destination]) }
        }
        if ($null -eq $previousStateBytes) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
        else { [IO.File]::WriteAllBytes($statePath, [byte[]]$previousStateBytes) }
        throw
    }

    Invoke-Api -Method Patch -Token $token -Body @{
        action = 'complete'; requestId = $RequestId; artifactDigest = [string]$claim.artifact.digest
        executionGrant = [string]$claim.executionGrant; statusMessage = 'Spec Kit-compatible development handoff prepared in the registered project folder.'
    } | Out-Null
    Write-CompactJson ([ordered]@{ status = 'prepared'; requestId = $RequestId; targetPath = $target; files = @($destinations.path) })
} catch {
    $message = $_.Exception.Message
    if ($claim) {
        $action = if ($message.StartsWith('conflict:', [StringComparison]::OrdinalIgnoreCase)) { 'conflict' } else { 'fail' }
        try {
            Invoke-Api -Method Patch -Token $token -Body @{
                action = $action; requestId = $RequestId; artifactDigest = [string]$claim.artifact.digest
                executionGrant = [string]$claim.executionGrant; statusMessage = $message
            } | Out-Null
        } catch { }
    }
    Write-CompactJson ([ordered]@{ status = 'failed'; requestId = $RequestId; targetPath = $target; error = $message })
    exit 1
}
