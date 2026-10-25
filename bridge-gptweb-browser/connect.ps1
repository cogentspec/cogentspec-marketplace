[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$RequestId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$endpoint = 'https://cogentspec.app/api/bridge/gptweb/browser-start'
$token = $null
$bytes = $null
$context = ''
$authorized = $false
function Send-GptWebRequest([string]$Operation, [switch]$Authenticated) {
    $arguments = @{ Method='Post'; Uri=$endpoint; TimeoutSec=10; ContentType='application/json';
        Body=(@{operation=$Operation;requestId=$RequestId;command='$gptweb';contextKey=$context}|ConvertTo-Json -Compress) }
    if ($Authenticated) { $arguments.Headers=@{Authorization="Bearer $token"} }
    $result = Invoke-RestMethod @arguments
    if ($result.protocol -cne 'cogentspec-gptweb-browser-start-v1') { throw 'Invalid GPTWeb response.' }
    return $result
}
try {
    $info = Send-GptWebRequest 'inspect'
    if ($info.command -cne '$gptweb' -or $info.contextKey -cnotmatch '^ctx-[a-f0-9]{64}$') { throw 'Invalid GPTWeb request.' }
    $context = [string]$info.contextKey
    Add-Type -AssemblyName System.Security
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    $credential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token = [Text.Encoding]::UTF8.GetString($bytes)
    $permission = Send-GptWebRequest 'authorize' -Authenticated
    if ($permission.status -cne 'authorized') { throw 'GPTWeb did not authorize this computer.' }
    $authorized = $true
    # A frozen GPTWeb-only snapshot owns its process state and mutex. The Snap
    # and Desk scripts, workers and registries are never called or replaced.
    $launcher = Join-Path $PSScriptRoot 'runtime\skills\gptweb\scripts\start-gptweb.ps1'
    $result = (& $launcher -ContextKey $context) | ConvertFrom-Json
    if ($result.status -cne 'ready' -or $result.contextKey -cne $context -or $result.presenceVerified -cne $true -or
        $result.accountState -cne 'signed_in' -or $result.browserOpened -cne $false) { throw 'GPTWeb did not verify its worker.' }
    $proof = Send-GptWebRequest 'ready' -Authenticated
    if ($proof.status -cne 'ready' -or $proof.workspaceConnected -cne $false) { throw 'Invalid GPTWeb startup proof.' }
} catch {
    if ($authorized) { try { $null = Send-GptWebRequest 'failed' -Authenticated } catch {} }
    exit 1
} finally {
    $token = $null
    if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
}
