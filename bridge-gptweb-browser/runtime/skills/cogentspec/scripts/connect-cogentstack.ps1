# GPTWeb's read-only account adapter. It cannot renew, remove or replace the
# credential used by other connectors. Account changes use the existing setup.
[CmdletBinding()]
param([ValidateSet('status')][string]$Mode='status',[ValidateSet('chatgpt')][string]$Surface='chatgpt',
    [Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [ValidateSet('web')][string]$Experience='web',[switch]$WorkspaceGrant,
    [ValidateRange(3,20)][int]$RequestTimeoutSeconds=6)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$serviceUrl='https://cogentspec.com'
$token=$null;$bytes=$null
try {
    Add-Type -AssemblyName System.Security
    $credentialPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    $credential=Get-Content -LiteralPath $credentialPath -Raw|ConvertFrom-Json
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token=[Text.Encoding]::UTF8.GetString($bytes)
    $headers=@{Accept='application/json';Authorization="Bearer $token"}
    $connection=Invoke-RestMethod -Method Get -Uri "$serviceUrl/api/device-authorization/token" -Headers $headers -TimeoutSec $RequestTimeoutSeconds
    $result=[ordered]@{status='connected'}
    if($WorkspaceGrant) {
        $grant=Invoke-RestMethod -Method Post -Uri "$serviceUrl/api/device-authorization/browser-grant" -Headers $headers -TimeoutSec $RequestTimeoutSeconds `
            -ContentType 'application/json' -Body (@{contextKey=$ContextKey;surface='chatgpt';experience='web'}|ConvertTo-Json -Compress)
        $result.webWorkspaceCode=[string]$grant.webWorkspaceCode
        $result.chatgptWorkspaceCode=[string]$grant.chatgptWorkspaceCode
    }
    $result|ConvertTo-Json -Compress
} catch {
    @{status='licence_verification_unavailable';userMessage='GPTWeb could not verify the existing computer approval. The saved account credentials were preserved.'}|ConvertTo-Json -Compress
} finally {
    $token=$null
    if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
}
