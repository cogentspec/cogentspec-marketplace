param(
    [ValidateSet('inspect', 'delete')]
    [string]$Mode = 'inspect',
    [string]$RequestId = '',
    [string]$ContextKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-context.ps1')
$projectContext = Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$contextQuery = "context=$([Uri]::EscapeDataString($projectContext.ContextKey))"

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
}

$serviceUrl = 'https://cogentspec.com'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 8 -Compress | Write-Output
}

function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-CogentSpecApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$serviceUrl$Path"
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Resolve-ApprovedDeletionTarget([string]$TargetPath, [string]$WorkDirectory, [string]$ProjectSlug) {
    if (
        [string]::IsNullOrWhiteSpace($TargetPath) -or [string]::IsNullOrWhiteSpace($WorkDirectory) -or
        [string]::IsNullOrWhiteSpace($ProjectSlug) -or -not [IO.Path]::IsPathRooted($TargetPath) -or
        -not [IO.Path]::IsPathRooted($WorkDirectory) -or $TargetPath -notmatch '^[A-Za-z]:[\\/]' -or
        $WorkDirectory -notmatch '^[A-Za-z]:[\\/]'
    ) { throw 'The approved specification deletion paths are not absolute Windows drive paths.' }

    $targetFull = [IO.Path]::GetFullPath($TargetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $workFull = [IO.Path]::GetFullPath($WorkDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($targetFull -eq [IO.Path]::GetPathRoot($targetFull) -or $workFull -eq [IO.Path]::GetPathRoot($workFull)) {
        throw 'The approved specification deletion cannot target a drive root.'
    }
    if (
        -not [IO.Path]::GetDirectoryName($targetFull).Equals($workFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($targetFull).Equals($ProjectSlug, [StringComparison]::OrdinalIgnoreCase)
    ) { throw 'The approved specification target is not the exact registered child of its work directory.' }
    if ($targetFull.Replace('/', '\').Split('\') | Where-Object { [string]::Equals($_, '.tmp', [StringComparison]::OrdinalIgnoreCase) }) {
        throw 'Temporary validation folders cannot be deleted through the project library.'
    }

    if (Test-Path -LiteralPath $targetFull) {
        if (Test-Path -LiteralPath $workFull) {
            $workItem = Get-Item -Force -LiteralPath $workFull
            if (($workItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A reparse-point work directory requires manual review before deletion.' }
        }
        $targetItem = Get-Item -Force -LiteralPath $targetFull
        if (-not $targetItem.PSIsContainer) { throw 'The registered specification target is not a directory.' }
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A reparse-point specification folder requires manual review before deletion.' }
        $nestedReparsePoint = Get-ChildItem -Force -LiteralPath $targetFull -Recurse |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($null -ne $nestedReparsePoint) { throw "A nested reparse point requires manual review before deletion: $($nestedReparsePoint.FullName)" }
    }
    return $targetFull
}

function Confirm-SpecificationIdentity([string]$TargetPath, [string]$DraftId) {
    $markerPath = Join-Path $TargetPath '.coge\specification-draft.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'The registered folder no longer contains its CogentSpec specification identity. Deletion stopped for safety.'
    }
    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    $markerTarget = [IO.Path]::GetFullPath([string]$marker.targetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (
        [string]$marker.draftId -ne $DraftId -or
        -not $markerTarget.Equals($TargetPath, [StringComparison]::OrdinalIgnoreCase)
    ) { throw 'The specification folder identity does not match the approved deletion.' }
}

if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    Write-CompactJson ([ordered]@{ status = 'not_connected' })
    exit 0
}

$credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
$token = Unprotect-CogentSpecValue ([string]$credential.token)
$listing = Invoke-CogentSpecApi -Method Get -Path "/api/plugin/specification-deletions?$contextQuery" -Token $token
$requests = @($listing.requests)

if ($Mode -eq 'inspect') {
    Write-CompactJson ([ordered]@{ status = 'ok'; requests = $requests })
    exit 0
}
if ([string]::IsNullOrWhiteSpace($RequestId)) {
    if ($requests.Count -eq 0) { Write-CompactJson ([ordered]@{ status = 'no_requested_deletions' }); exit 0 }
    if ($requests.Count -gt 1) { Write-CompactJson ([ordered]@{ status = 'service_state_error'; requests = $requests }); exit 1 }
    $RequestId = [string]$requests[0].id
}
if ($RequestId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'The specification deletion request ID is invalid.'
}
$selected = $requests | Where-Object { [string]$_.id -eq $RequestId } | Select-Object -First 1
if ($null -eq $selected) { Write-CompactJson ([ordered]@{ status = 'request_not_available'; requestId = $RequestId }); exit 0 }

$draftId = [string]$selected.draftId
if ($draftId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'The approved specification draft ID is invalid.'
}
$targetPath = [string]$selected.targetPath
$executionGrant = ''
$deletionDigest = ''
$claimed = $false
$folderRemoved = $false

try {
    $claim = Invoke-CogentSpecApi -Method Post -Path "/api/plugin/specification-deletions?$contextQuery" -Token $token -Body @{ action = 'claim'; requestId = $RequestId }
    if (
        [string]$claim.status -ne 'claimed' -or $null -eq $claim.request -or
        [string]$claim.request.id -ne $RequestId -or [string]$claim.request.draftId -ne $draftId -or
        [string]::IsNullOrWhiteSpace([string]$claim.executionGrant) -or [string]$claim.deletionDigest -notmatch '^[0-9a-f]{64}$'
    ) { throw 'CogentSpec returned an incomplete specification deletion claim.' }
    $claimed = $true
    $executionGrant = [string]$claim.executionGrant
    $deletionDigest = [string]$claim.deletionDigest
    $targetPath = Resolve-ApprovedDeletionTarget -TargetPath ([string]$claim.request.targetPath) -WorkDirectory ([string]$claim.request.workDirectory) -ProjectSlug ([string]$claim.request.projectSlug)

    if (Test-Path -LiteralPath $targetPath) {
        Confirm-SpecificationIdentity -TargetPath $targetPath -DraftId $draftId
        Remove-Item -LiteralPath $targetPath -Recurse -Force
        if (Test-Path -LiteralPath $targetPath) { throw 'The registered specification folder still exists after deletion.' }
        $folderRemoved = $true
    }

    $completionMessage = if ($folderRemoved) { "Specification draft and folder deleted from $targetPath." } else { "Specification folder was already absent; saved draft deleted for $targetPath." }
    $completed = $null
    for ($attempt = 1; $attempt -le 3 -and $null -eq $completed; $attempt++) {
        try {
            $completed = Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/specification-deletions?$contextQuery" -Token $token -Body @{
                action = 'complete'; requestId = $RequestId; deletionDigest = $deletionDigest
                executionGrant = $executionGrant; statusMessage = $completionMessage
            }
        } catch {
            $remaining = @((Invoke-CogentSpecApi -Method Get -Path "/api/plugin/specification-deletions?$contextQuery" -Token $token).requests)
            if (-not ($remaining | Where-Object { [string]$_.id -eq $RequestId })) { $completed = [pscustomobject]@{ status = 'deleted' }; break }
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    if ([string]$completed.status -ne 'deleted') { throw 'CogentSpec did not confirm the specification as deleted.' }
    Write-CompactJson ([ordered]@{
        status = 'deleted'; requestId = $RequestId; draftId = $draftId; projectName = [string]$claim.request.projectName
        targetPath = $targetPath; folderRemoved = $folderRemoved; recoverable = $false
    })
} catch {
    $message = $_.Exception.Message
    if ($claimed -and $executionGrant -and $deletionDigest) {
        try {
            Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/specification-deletions?$contextQuery" -Token $token -Body @{
                action = 'fail'; requestId = $RequestId; deletionDigest = $deletionDigest
                executionGrant = $executionGrant; statusMessage = $message
            } | Out-Null
        } catch { }
    }
    Write-CompactJson ([ordered]@{
        status = 'failed'; requestId = $RequestId; draftId = $draftId; targetPath = $targetPath
        folderRemoved = $folderRemoved; registrationFinalized = $false; error = $message
    })
    exit 1
}
