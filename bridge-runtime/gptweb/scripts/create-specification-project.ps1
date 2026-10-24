param(
    [ValidateSet('create')][string]$Mode = 'create',
    [Parameter(Mandatory = $true)][string]$RequestId,
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

function Write-CompactJson($Value) { $Value | ConvertTo-Json -Depth 8 -Compress | Write-Output }
function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Invoke-CogentSpecApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{ Method = $Method; Uri = "$serviceUrl$Path"; Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }; TimeoutSec = 30 }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}
function Resolve-SafeTarget([string]$TargetPath) {
    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not [IO.Path]::IsPathRooted($TargetPath) -or $TargetPath -notmatch '^[A-Za-z]:[\\/]') {
        throw 'The specification target is not an absolute Windows drive path.'
    }
    $fullPath = [IO.Path]::GetFullPath($TargetPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($fullPath -eq [IO.Path]::GetPathRoot($fullPath)) { throw 'The specification target cannot be a drive root.' }
    if (Test-Path -LiteralPath $fullPath) { throw "The specification project folder already exists: $fullPath" }
    return $fullPath
}
function Write-Utf8File([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

if ($RequestId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'The specification draft ID is invalid.'
}
if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    Write-CompactJson ([ordered]@{ status = 'desktop_authorization_required'; reason = 'missing'; specificationPreserved = $true })
    exit 0
}

$credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
$token = Unprotect-CogentSpecValue ([string]$credential.token)
$claim = $null
$temporaryPath = ''
try {
    $claim = Invoke-CogentSpecApi -Method Post -Path "/api/plugin/specification-drafts?$contextQuery" -Token $token -Body @{
        action = 'claim'; draftId = $RequestId
    }
    if ([string]$claim.status -ne 'claimed' -or $null -eq $claim.draft -or [string]::IsNullOrWhiteSpace([string]$claim.executionGrant)) {
        throw 'CogentSpec returned an incomplete specification folder request.'
    }
    if ([string]$claim.draft.id -ne $RequestId -or [string]$claim.draft.contextKey -ne $projectContext.ContextKey) {
        throw 'The claimed specification does not match this AI task context.'
    }
    $targetPath = Resolve-SafeTarget ([string]$claim.draft.targetPath)
    $parent = Split-Path -Parent $targetPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryPath = Join-Path $parent ".cogentspec-draft-$([Guid]::NewGuid().ToString('N')).tmp"
    New-Item -ItemType Directory -Path $temporaryPath | Out-Null

    $marker = [ordered]@{
        schemaVersion = 1
        draftId = [string]$claim.draft.id
        contextKey = [string]$claim.draft.contextKey
        projectName = [string]$claim.draft.projectName
        idea = [string]$claim.draft.idea
        targetPath = $targetPath
        createdAt = [string]$claim.draft.createdAt
        syncedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6
    Write-Utf8File (Join-Path $temporaryPath '.coge\specification-draft.json') $marker
    Write-Utf8File (Join-Path $temporaryPath 'PROJECT_KNOWLEDGE.md') "# $([string]$claim.draft.projectName)`r`n`r`n## Original idea`r`n`r`n$([string]$claim.draft.idea)`r`n"
    Write-Utf8File (Join-Path $temporaryPath 'CURRENT_STATE.md') "# Current state`r`n`r`nSpecification discovery is in progress in CogentSpec. No project foundation has been created yet.`r`n"
    Write-Utf8File (Join-Path $temporaryPath 'HANDOFF.md') "# Handoff`r`n`r`nContinue the saved specification in CogentSpec. When its SDD contract is approved, Desktop Bridge will add the verified foundation to this same folder.`r`n"
    Write-Utf8File (Join-Path $temporaryPath 'AGENTS.md') "# CogentSpec project`r`n`r`nRead PROJECT_KNOWLEDGE.md, CURRENT_STATE.md, HANDOFF.md, and .coge/specification-draft.json before changing this project.`r`n"
    Write-Utf8File (Join-Path $temporaryPath 'docs\decisions\README.md') "# Specification decisions`r`n`r`nApproved decisions will be recorded here as the specification develops.`r`n"

    [IO.Directory]::Move($temporaryPath, $targetPath)
    $temporaryPath = ''
    $completed = Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/specification-drafts?$contextQuery" -Token $token -Body @{
        action = 'complete'
        draftId = $RequestId
        manifestDigest = [string]$claim.manifestDigest
        executionGrant = [string]$claim.executionGrant
        statusMessage = 'Specification project folder created and verified.'
    }
    if ([string]$completed.status -ne 'ready') { throw 'CogentSpec did not confirm the specification folder.' }
    Write-CompactJson ([ordered]@{ status = 'specification_created'; draftId = $RequestId; projectName = [string]$claim.draft.projectName; targetPath = $targetPath })
} catch {
    $failure = $_.Exception.Message
    if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Container)) {
        Remove-Item -LiteralPath $temporaryPath -Recurse -Force
    }
    if ($null -ne $claim -and $claim.executionGrant -and $claim.manifestDigest) {
        try {
            Invoke-CogentSpecApi -Method Patch -Path "/api/plugin/specification-drafts?$contextQuery" -Token $token -Body @{
                action = 'fail'; draftId = $RequestId; manifestDigest = [string]$claim.manifestDigest
                executionGrant = [string]$claim.executionGrant; statusMessage = $failure
            } | Out-Null
        } catch { }
    }
    Write-CompactJson ([ordered]@{ status = 'failed'; draftId = $RequestId; reason = $failure })
}
