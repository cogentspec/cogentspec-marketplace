param(
    [ValidateSet('inspect', 'create')]
    [string]$Mode = 'inspect',
    [string]$RequestId = '',
    [string]$ContextKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-command.ps1')
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

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 8 -Compress | Write-Output
}

function Write-DesktopAuthorizationRequired([string]$Reason) {
    Write-CompactJson ([ordered]@{
        status = 'desktop_authorization_required'
        reason = $Reason
        projectRequestPreserved = $true
        nextAction = 'connect_desktop'
    })
}

function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-CogentSpecApi(
    [string]$Method,
    [string]$Path,
    [string]$Token,
    $Body = $null
) {
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

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Resolve-ApprovedTarget([string]$TargetPath) {
    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not [IO.Path]::IsPathRooted($TargetPath) -or $TargetPath -notmatch '^[A-Za-z]:[\\/]') {
        throw 'The approved project target is not an absolute Windows drive path.'
    }
    $fullPath = [IO.Path]::GetFullPath($TargetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($fullPath) -or $fullPath -eq [IO.Path]::GetPathRoot($fullPath)) {
        throw 'The approved project target cannot be a drive root.'
    }
    return $fullPath
}

function Assert-FoundationTarget([string]$TargetPath, $SpecificationDraft) {
    if (-not (Test-Path -LiteralPath $TargetPath)) { return }
    $existingFiles = @(Get-ChildItem -Force -File -Recurse -LiteralPath $TargetPath)
    if ($existingFiles.Count -eq 0) { return }
    if ($null -eq $SpecificationDraft -or [string]$SpecificationDraft.folderStatus -ne 'ready') {
        throw "The approved project target contains files that are not a verified CogentSpec specification: $TargetPath"
    }
    $markerPath = Join-Path $TargetPath '.coge\specification-draft.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'The existing specification project marker is missing.'
    }
    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    if ([string]$marker.draftId -ne [string]$SpecificationDraft.id -or [string]$marker.contextKey -ne $projectContext.ContextKey) {
        throw 'The existing specification project does not belong to this approved AI task.'
    }
    $markedTarget = [IO.Path]::GetFullPath([string]$marker.targetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $markedTarget.Equals($TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The existing specification project marker names a different target.'
    }
    $allowed = @(
        '.coge/specification-draft.json', 'PROJECT_KNOWLEDGE.md', 'CURRENT_STATE.md',
        'HANDOFF.md', 'AGENTS.md', 'docs/decisions/README.md'
    )
    foreach ($file in $existingFiles) {
        $relative = $file.FullName.Substring($TargetPath.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -notin $allowed) { throw "The specification project contains an unexpected file: $relative" }
    }
}

function Test-ArtifactPath([string]$ArtifactPath) {
    if ([string]::IsNullOrWhiteSpace($ArtifactPath) -or [IO.Path]::IsPathRooted($ArtifactPath) -or $ArtifactPath -match '^[A-Za-z]:') {
        return $false
    }
    $segments = $ArtifactPath.Replace('\', '/').Split('/')
    return -not ($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' })
}

if (-not (Test-Path -LiteralPath $credentialPath)) {
    Write-DesktopAuthorizationRequired 'missing'
    exit 0
}

$credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
$token = Unprotect-CogentSpecValue ([string]$credential.token)
try {
    $listing = Invoke-CogentSpecApi -Method Get -Path "/api/plugin/project-requests?status=requested&limit=20&$contextQuery" -Token $token
} catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($statusCode -eq 401) {
        Write-DesktopAuthorizationRequired 'expired_or_revoked'
        exit 0
    }
    throw
}
$requests = @($listing.requests)

if ($Mode -eq 'inspect') {
    Write-CompactJson ([ordered]@{ status = 'ok'; requests = $requests })
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RequestId)) {
    if ($requests.Count -eq 0) {
        Write-CompactJson ([ordered]@{ status = 'no_requested_projects' })
        exit 0
    }
    if ($requests.Count -gt 1) {
        Write-CompactJson ([ordered]@{ status = 'selection_required'; requests = $requests })
        exit 0
    }
    $RequestId = [string]$requests[0].id
}

if ($RequestId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'The project request ID is invalid.'
}

$selected = $requests | Where-Object { [string]$_.id -eq $RequestId } | Select-Object -First 1
if ($null -eq $selected) {
    Write-CompactJson ([ordered]@{ status = 'request_not_available'; requestId = $RequestId })
    exit 0
}

$targetPath = Resolve-ApprovedTarget ([string]$selected.targetPath)
$executionGrant = ''
$artifactDigest = ''
$claimed = $false

try {
    $claim = Invoke-CogentSpecApi -Method Post -Path "/api/plugin/project-requests?$contextQuery" -Token $token -Body @{
        action = 'claim'
        requestId = $RequestId
    }
    if ([string]$claim.status -ne 'claimed' -or $null -eq $claim.artifact -or [string]::IsNullOrWhiteSpace([string]$claim.executionGrant)) {
        throw 'CogentSpec returned an incomplete project artifact.'
    }
    $claimed = $true
    $executionGrant = [string]$claim.executionGrant
    $artifactDigest = [string]$claim.artifact.digest
    if ($artifactDigest -notmatch '^[0-9a-f]{64}$') {
        throw 'CogentSpec returned an invalid project artifact digest.'
    }

    $files = @($claim.artifact.files)
    if ($files.Count -eq 0 -or $files.Count -gt 200) {
        throw 'CogentSpec returned an invalid project artifact file count.'
    }

    $canonical = New-Object Text.StringBuilder
    $totalBytes = 0
    $seenPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $artifactPath = ([string]$file.path).Replace('\', '/')
        if (-not (Test-ArtifactPath $artifactPath)) {
            throw "CogentSpec returned an unsafe project artifact path: $artifactPath"
        }
        if (-not $seenPaths.Add($artifactPath)) {
            throw "CogentSpec returned a duplicate project artifact path: $artifactPath"
        }
        $expectedHash = [string]$file.sha256
        if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
            throw "CogentSpec returned an invalid checksum for $artifactPath"
        }
        $bytes = [Convert]::FromBase64String([string]$file.contentBase64)
        if ($bytes.Length -gt 1500000) {
            throw "CogentSpec returned an oversized project artifact file: $artifactPath"
        }
        $totalBytes += $bytes.Length
        if ($totalBytes -gt 6000000) {
            throw 'CogentSpec returned an oversized project artifact.'
        }
        if ((Get-Sha256Hex $bytes) -ne $expectedHash) {
            throw "Project artifact verification failed for $artifactPath"
        }
        [void]$canonical.Append($artifactPath).Append("`t").Append($expectedHash).Append("`n")
    }
    $computedDigest = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))
    if ($computedDigest -ne $artifactDigest) {
        throw 'Project artifact verification failed.'
    }
    $claimedTarget = [IO.Path]::GetFullPath([string]$claim.request.targetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $claimedTarget.Equals($targetPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The claimed project target does not match the approved request.'
    }
    $targetPath = Resolve-ApprovedTarget $claimedTarget
    Assert-FoundationTarget $targetPath $claim.specificationDraft

    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    $targetPrefix = $targetPath.TrimEnd('\') + '\'
    foreach ($file in $files) {
        $artifactPath = ([string]$file.path).Replace('\', '/')
        $relativeWindowsPath = $artifactPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destination = [IO.Path]::GetFullPath((Join-Path $targetPath $relativeWindowsPath))
        if (-not $destination.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Project artifact escaped the approved target: $artifactPath"
        }
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [IO.File]::WriteAllBytes($destination, [Convert]::FromBase64String([string]$file.contentBase64))
    }

    $installResult = Invoke-CogentSpecNativeCommand -FilePath 'npm.cmd' -ArgumentList @(
        'ci', '--prefer-offline', '--no-audit', '--no-fund', '--prefix', $targetPath
    )
    if ($installResult.ExitCode -ne 0) {
        throw "Dependency installation failed: $($installResult.Output)"
    }
    $testResult = Invoke-CogentSpecNativeCommand -FilePath 'npm.cmd' -ArgumentList @(
        'test', '--prefix', $targetPath
    )
    if ($testResult.ExitCode -ne 0) {
        throw "Project acceptance tests failed: $($testResult.Output)"
    }

    $gitInitResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'init', '--quiet')
    if ($gitInitResult.ExitCode -ne 0) { throw 'Git initialization failed.' }
    $gitAddResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'add', '-A')
    if ($gitAddResult.ExitCode -ne 0) { throw 'Git staging failed.' }

    $gitNameResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'config', 'user.name')
    if ($gitNameResult.ExitCode -ne 0 -or -not $gitNameResult.Output) {
        $gitSetNameResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'config', 'user.name', 'CogentSpec Desktop')
        if ($gitSetNameResult.ExitCode -ne 0) { throw 'Git identity configuration failed.' }
    }
    $gitEmailResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'config', 'user.email')
    if ($gitEmailResult.ExitCode -ne 0 -or -not $gitEmailResult.Output) {
        $gitSetEmailResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'config', 'user.email', 'desktop@cogentspec.local')
        if ($gitSetEmailResult.ExitCode -ne 0) { throw 'Git identity configuration failed.' }
    }

    $gitCommitResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'commit', '--quiet', '-m', 'Initialize CogentSpec project foundation')
    if ($gitCommitResult.ExitCode -ne 0) { throw 'Git baseline commit failed.' }
    $gitRevisionResult = Invoke-CogentSpecNativeCommand -FilePath 'git' -ArgumentList @('-C', $targetPath, 'rev-parse', 'HEAD')
    if ($gitRevisionResult.ExitCode -ne 0 -or -not $gitRevisionResult.Output) { throw 'Git baseline revision could not be read.' }
    $commit = $gitRevisionResult.Output

    $completed = Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/project-requests?$contextQuery" -Token $token -Body @{
        action = 'complete'
        requestId = $RequestId
        artifactDigest = $artifactDigest
        executionGrant = $executionGrant
        statusMessage = "Project foundation created and verified at $targetPath."
    }
    Write-CompactJson ([ordered]@{
        status = [string]$completed.status
        requestId = $RequestId
        targetPath = $targetPath
        projectName = [string]$claim.request.projectName
        patternId = [string]$claim.request.patternId
        releaseMode = [string]$claim.request.releaseMode
        pack = $claim.request.pack
        tests = 'passed'
        commit = $commit
    })
} catch {
    $message = $_.Exception.Message
    if ($claimed -and $executionGrant -and $artifactDigest) {
        try {
            Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/project-requests?$contextQuery" -Token $token -Body @{
                action = 'fail'
                requestId = $RequestId
                artifactDigest = $artifactDigest
                executionGrant = $executionGrant
                statusMessage = $message
            } | Out-Null
        } catch {
            # Preserve the original creation failure; the server grant will expire automatically.
        }
    }
    Write-CompactJson ([ordered]@{
        status = 'failed'
        requestId = $RequestId
        targetPath = $targetPath
        partialTargetRetained = (Test-Path -LiteralPath $targetPath)
        error = $message
    })
    exit 1
}
