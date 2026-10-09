param(
    [string]$ContextKey = '',
    [ValidateSet('', 'activity', 'inspect', 'propose', 'apply', 'complete_repair')][string]$ChangeAction = '',
    [string]$ChangePayloadPath = '',
    [switch]$Approved
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-context.ps1')

$serviceUrl = 'https://cogentspec.com'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'
$projectContext = Get-CogentSpecProjectContext -ExplicitContextKey $ContextKey
$contextQuery = "context=$([Uri]::EscapeDataString($projectContext.ContextKey))"

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 20 -Compress | Write-Output
}

function Unprotect-CogentSpecValue([string]$Value) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop } catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    Write-CompactJson ([ordered]@{ status = 'desktop_authorization_required'; activeProjectPreserved = $true })
    exit 0
}

$credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
$token = Unprotect-CogentSpecValue ([string]$credential.token)
try {
    if ($ChangeAction) {
        $uri = "$serviceUrl/api/plugin/project-changes?$contextQuery"
        $headers = @{ Accept = 'application/json'; Authorization = "Bearer $token" }
        if ($ChangeAction -eq 'activity') {
            Write-CompactJson (Invoke-RestMethod -Method Get -Uri "$serviceUrl/api/plugin/project-activity?$contextQuery" -Headers $headers -TimeoutSec 30)
        } elseif ($ChangeAction -eq 'inspect') {
            Write-CompactJson (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30)
        } else {
            if (-not $ChangePayloadPath) { throw 'A reviewed change payload file is required.' }
            $raw = Get-Content -LiteralPath $ChangePayloadPath -Raw
            if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 24576) { throw 'Change payload too large.' }
            $payload = $raw | ConvertFrom-Json
            if ($ChangeAction -eq 'apply' -and -not $Approved) { throw 'Explicit approval is required before applying a baseline proposal.' }
            $body = if ($ChangeAction -eq 'propose') {
                @{action='propose';projectId=$payload.projectId;runtimeId=$payload.runtimeId;patch=$payload.patch}
            } elseif ($ChangeAction -eq 'complete_repair') { @{action='complete_repair';repair=$payload} }
            else { @{action='apply';proposalId=$payload.proposalId;approved=[bool]$Approved} }
            Write-CompactJson (Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 30)
        }
        return
    }
    $handoff = Invoke-RestMethod `
        -Method Get `
        -Uri "$serviceUrl/api/plugin/project-build-handoff?$contextQuery" `
        -Headers @{ Accept = 'application/json'; Authorization = "Bearer $token" } `
        -TimeoutSec 30
    Write-CompactJson $handoff
} catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    $serverResponse = $null
    if ($_.ErrorDetails.Message) {
        try { $serverResponse = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $serverResponse = $null }
    }
    if ($statusCode -ne 401 -and $serverResponse -and $serverResponse.status) {
        Write-CompactJson ([ordered]@{
            status = [string]$serverResponse.status
            error = [string]$serverResponse.error
            activeProjectPreserved = $true
        })
        exit 0
    }
    Write-CompactJson ([ordered]@{
        status = if ($statusCode -eq 401) { 'desktop_authorization_required' } else { 'build_handoff_unavailable' }
        activeProjectPreserved = $true
    })
} finally {
    $token = $null
}
