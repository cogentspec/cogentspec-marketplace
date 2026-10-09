param(
    [Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [Parameter(Mandatory=$true)][guid]$CaseId,
    [string]$PayloadPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
function Write-Result($Value) { $Value | ConvertTo-Json -Depth 40 -Compress | Write-Output }
if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    Write-Result @{ status='desktop_authorization_required'; activeProjectPreserved=$true }
    exit 0
}
$token = $null
try {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String([string]$credential.token), $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token = [Text.Encoding]::UTF8.GetString($bytes)
    $uri = "https://cogentspec.com/api/plugin/project-reviews?context=$([Uri]::EscapeDataString($ContextKey))&caseId=$CaseId"
    $headers = @{ Accept='application/json'; Authorization="Bearer $token" }
    if ($PayloadPath) {
        $raw = Get-Content -Raw -LiteralPath $PayloadPath
        if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 2097152) { throw 'Review payload too large.' }
        $payload = $raw | ConvertFrom-Json
        if ([string]$payload.caseId -ne [string]$CaseId) { throw 'Review case mismatch.' }
        if ([string]$payload.action -notin @('report','verify','refresh','use_correction')) { throw 'Unsupported review action.' }
        Write-Result (Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($raw)) -TimeoutSec 30)
    } else {
        Write-Result (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30)
    }
} catch {
    # Never emit credentials, request headers, raw provider errors or diagnostic payloads.
    Write-Result @{ status='review_request_failed'; activeProjectPreserved=$true; message='The review request was not accepted. Read the case again; check its revision, project identity and connection before retrying.' }
} finally { $token=$null; $bytes=$null; $headers=$null; $credential=$null }
