Set-StrictMode -Version Latest

function ConvertTo-CogentSpecContextKey([string]$ProjectIdentifier) {
    if ([string]::IsNullOrWhiteSpace($ProjectIdentifier)) { return 'default' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("chatgpt-project:$($ProjectIdentifier.Trim().ToLowerInvariant())")
        $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        return "ctx-$digest"
    } finally {
        $sha.Dispose()
    }
}

function Test-CogentSpecContextKey([string]$Value) {
    return $Value -eq 'default' -or $Value -match '^ctx-[0-9a-f]{64}$'
}

function Test-CogentSpecPathWithin([string]$Candidate, [string]$Parent) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    $separator = [IO.Path]::DirectorySeparatorChar
    $normalizedParent = $Parent.TrimEnd([char[]]@('/', '\'))
    return $Candidate.Equals($normalizedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith("$normalizedParent$separator", [StringComparison]::OrdinalIgnoreCase)
}

function Get-CogentSpecWorkspaceIdentifier([string]$WorkingDirectory) {
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { return '' }
    try {
        $workspaceItem = Get-Item -LiteralPath $WorkingDirectory -ErrorAction Stop
        if (-not $workspaceItem.PSIsContainer) { return '' }
        $workspacePath = [IO.Path]::GetFullPath([string]$workspaceItem.FullName).TrimEnd([char[]]@('/', '\'))
        $filesystemRoot = [IO.Path]::GetPathRoot($workspacePath).TrimEnd([char[]]@('/', '\'))
        if ($workspacePath.Equals($filesystemRoot, [StringComparison]::OrdinalIgnoreCase)) { return '' }

        $exactUnscopedRoots = @(
            [Environment]::GetFolderPath('UserProfile'),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
        )
        foreach ($unscopedRoot in $exactUnscopedRoots) {
            if ([string]::IsNullOrWhiteSpace($unscopedRoot)) { continue }
            $normalizedRoot = [IO.Path]::GetFullPath($unscopedRoot).TrimEnd([char[]]@('/', '\'))
            if ($workspacePath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) { return '' }
        }
        $unscopedTrees = @(
            [IO.Path]::GetTempPath(),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\plugins\cache'),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\.tmp\marketplaces'),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\skills')
        )
        foreach ($unscopedRoot in $unscopedTrees) {
            if ([string]::IsNullOrWhiteSpace($unscopedRoot)) { continue }
            $normalizedRoot = [IO.Path]::GetFullPath($unscopedRoot).TrimEnd([char[]]@('/', '\'))
            if (Test-CogentSpecPathWithin $workspacePath $normalizedRoot) { return '' }
        }
        return "workspace-directory:$workspacePath"
    } catch { return '' }
}

function Get-CogentSpecProjectContext(
    [string]$ExplicitContextKey = '',
    [string]$WorkingDirectory = (Get-Location).Path
) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitContextKey)) {
        $normalized = $ExplicitContextKey.Trim().ToLowerInvariant()
        if (-not (Test-CogentSpecContextKey $normalized)) { throw 'The explicit CogentSpec project context is invalid.' }
        return [pscustomobject]@{ ContextKey = $normalized; Source = 'explicit'; Isolated = $normalized -ne 'default' }
    }

    $projectIdentifier = ''
    $source = ''
    if ($env:CODEX_PROJECT_ID -match '^g-p-[0-9a-f]{32}$') {
        $projectIdentifier = $env:CODEX_PROJECT_ID
        $source = 'codex-project-environment'
    } elseif ($WorkingDirectory -match '(?i)[\\/]\.codex[\\/]\.chatgpt-projects[\\/](g-p-[0-9a-f]{32})(?:[\\/]|$)') {
        $projectIdentifier = $Matches[1]
        $source = 'chatgpt-project-worktree'
    } else {
        $projectIdentifier = Get-CogentSpecWorkspaceIdentifier $WorkingDirectory
        if ($projectIdentifier) { $source = 'codex-workspace-directory' }
    }

    if (-not $projectIdentifier) {
        return [pscustomobject]@{ ContextKey = 'default'; Source = 'legacy-default'; Isolated = $false }
    }
    $contextKey = ConvertTo-CogentSpecContextKey $projectIdentifier
    return [pscustomobject]@{ ContextKey = $contextKey; Source = $source; Isolated = $true }
}

function Add-CogentSpecContextToPath([string]$Path, [string]$ContextKey) {
    if (-not (Test-CogentSpecContextKey $ContextKey)) { throw 'The CogentSpec project context is invalid.' }
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    return "$Path${separator}context=$([Uri]::EscapeDataString($ContextKey))"
}

if ($MyInvocation.InvocationName -ne '.') {
    $resolvedContext = Get-CogentSpecProjectContext
    [ordered]@{
        contextKey = [string]$resolvedContext.ContextKey
        source = [string]$resolvedContext.Source
        isolated = [bool]$resolvedContext.Isolated
    } | ConvertTo-Json -Compress | Write-Output
}
