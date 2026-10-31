param(
    [Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [Parameter(Mandatory=$true)][guid]$UpdateId,
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
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token), $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token = [Text.Encoding]::UTF8.GetString($bytes)
    $uri = "https://cogentspec.com/api/plugin/project-updates?context=$([Uri]::EscapeDataString($ContextKey))&updateId=$UpdateId"
    $headers = @{ Accept='application/json'; Authorization="Bearer $token" }
    if ($PayloadPath) {
        if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf) -or (Get-Item -LiteralPath $PayloadPath).Length -gt 16384) { throw 'A bounded update payload file is required.' }
        $raw = Get-Content -Raw -LiteralPath $PayloadPath
        if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 16384) { throw 'Update payload too large.' }
        $payload = $raw | ConvertFrom-Json
        if ([string]$payload.updateId -ne [string]$UpdateId) { throw 'Update request mismatch.' }
        if ([string]$payload.action -notin @('acknowledge','progress','complete','failed','blocked')) { throw 'Unsupported update action.' }
        Write-Result (Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($raw)) -TimeoutSec 30)
    } else {
        Write-Result (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30)
    }
} catch {
    # Keep private tokens, claim receipts, request bodies and provider errors out of failures.
    Write-Result @{ status='update_report_not_confirmed'; activeProjectPreserved=$true;
        userMessage='The update report was not confirmed. Read this exact request again and check its project, contract version and revision. Do not claim completion in CogentSpec.' }
} finally { $token=$null; $bytes=$null; $headers=$null; $credential=$null }
