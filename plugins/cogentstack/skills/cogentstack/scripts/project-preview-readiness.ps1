Set-StrictMode -Version Latest

function Invoke-CogentSpecGitLines(
    [string]$ExactTargetPath,
    [string[]]$GitArguments
) {
    $gitCommand = Get-Command git.exe, git -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCommand) { throw 'Git is required to verify that a project has moved beyond its generated foundation.' }
    # Windows PowerShell turns Git's harmless line-ending warnings into terminating
    # errors when the caller uses ErrorActionPreference=Stop. Keep those warnings
    # out of the Bridge result while still checking Git's real exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& ([string]$gitCommand.Source) -C $ExactTargetPath @GitArguments 2>$null)
        $gitExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($gitExitCode -ne 0) { throw "Git could not verify preview readiness for the active project." }
    return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

function Test-CogentSpecImplementationPath([string]$Path) {
    $normalized = $Path.Replace('\', '/').TrimStart('/')
    if (-not $normalized) { return $false }
    if ($normalized -match '^(?:\.coge/|\.git(?:/|$)|docs/decisions/)') { return $false }
    if ($normalized -in @(
        'AGENTS.md',
        'PROJECT_KNOWLEDGE.md',
        'CURRENT_STATE.md',
        'HANDOFF.md',
        'PROJECT_NOTES.md'
    )) { return $false }
    return $true
}

function Get-CogentSpecProjectPreviewReadiness(
    [string]$ExactTargetPath,
    [string]$ExpectedRequestId,
    [string]$ExpectedContextKey,
    [string]$ExpectedProjectName = '',
    [string]$ExpectedProjectType = ''
) {
    $manifestPath = Join-Path $ExactTargetPath '.coge\knowledge-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{
            Ready = $false
            Status = 'preview_identity_unverified'
            Reason = 'The project identity record is missing. Rebuild the project foundation before opening a preview.'
            ChangedPaths = @()
        }
    }

    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            Ready = $false
            Status = 'preview_identity_unverified'
            Reason = 'The project identity record is invalid. Rebuild the project foundation before opening a preview.'
            ChangedPaths = @()
        }
    }

    $identityMatches = $manifest.project `
        -and [string]$manifest.project.requestId -eq $ExpectedRequestId `
        -and [string]$manifest.project.contextKey -eq $ExpectedContextKey `
        -and ([string]::IsNullOrWhiteSpace($ExpectedProjectName) -or [string]$manifest.project.name -eq $ExpectedProjectName) `
        -and ([string]::IsNullOrWhiteSpace($ExpectedProjectType) -or [string]$manifest.project.type -eq $ExpectedProjectType)
    if (-not $identityMatches) {
        return [pscustomobject]@{
            Ready = $false
            Status = 'preview_identity_mismatch'
            Reason = 'The files in this folder do not belong to the active CogentSpec project. No preview was opened.'
            ChangedPaths = @()
        }
    }

    try {
        $rootCommits = @(Invoke-CogentSpecGitLines $ExactTargetPath @('rev-list', '--max-parents=0', '--reverse', 'HEAD'))
        if ($rootCommits.Count -ne 1 -or $rootCommits[0] -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
            throw 'The generated foundation commit could not be identified.'
        }
        $changedPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @(Invoke-CogentSpecGitLines $ExactTargetPath @('diff', '--name-only', '--diff-filter=ACMRTUXB', $rootCommits[0], '--'))) {
            [void]$changedPaths.Add($path)
        }
        foreach ($path in @(Invoke-CogentSpecGitLines $ExactTargetPath @('ls-files', '--others', '--exclude-standard'))) {
            [void]$changedPaths.Add($path)
        }
        $implementationPaths = @($changedPaths | Where-Object { Test-CogentSpecImplementationPath $_ } | Sort-Object)
    } catch {
        return [pscustomobject]@{
            Ready = $false
            Status = 'preview_readiness_unverified'
            Reason = $_.Exception.Message
            ChangedPaths = @()
        }
    }

    if ($implementationPaths.Count -eq 0) {
        $projectLabel = if ([string]::IsNullOrWhiteSpace($ExpectedProjectName)) { 'This project' } else { $ExpectedProjectName }
        return [pscustomobject]@{
            Ready = $false
            Status = 'preview_not_ready'
            Reason = "$projectLabel is still the generic project foundation. Develop and verify its real content before opening a preview."
            ChangedPaths = @()
        }
    }

    return [pscustomobject]@{
        Ready = $true
        Status = 'ready'
        Reason = ''
        ChangedPaths = $implementationPaths
    }
}
