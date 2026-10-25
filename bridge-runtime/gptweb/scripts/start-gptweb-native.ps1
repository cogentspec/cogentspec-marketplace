[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9-]{36}$')][string]$StartupRequest,
    [switch]$ResumeApproval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bytes = $null
$token = $null
try {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security }
    }
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $enrollment=(& (Join-Path $PSScriptRoot 'setup-gptweb-device.ps1') -ContextKey $ContextKey -StartupRequest $StartupRequest -ResumeApproval:$ResumeApproval)|ConvertFrom-Json
        if ($enrollment.status -cne 'enrolled') { $enrollment|ConvertTo-Json -Compress;return }
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $credential=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token=[Text.Encoding]::UTF8.GetString($bytes)
        # A different signed-in browser account cannot start a worker using this
        # computer's existing credential. Prove the request before process work.
        $authorization=Invoke-RestMethod -Method Post -Uri 'https://cogentspec.app/api/bridge/gptweb/startup' -TimeoutSec 10 -ContentType 'application/json' `
            -Headers @{Authorization="Bearer $token"} -Body (@{operation='authorize';requestId=$StartupRequest;contextKey=$ContextKey;command='$gptweb';surface='chatgpt';experience='web'}|ConvertTo-Json -Compress)
        if ($authorization.protocol -cne 'cogentspec-gptweb-startup-v1' -or $authorization.status -cne 'authorized') { throw 'account_mismatch' }
    }
    $arguments = @{ ContextKey=$ContextKey; Surface='chatgpt'; Experience='web'; ListenerOnly=$true }
    if ($ResumeApproval) { $arguments.ResumeApproval=$true }
    $output = @(& (Join-Path $PSScriptRoot 'start-cogentstack-bridge.ps1') @arguments 2>&1)
    $line = @($output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { throw 'startup_result_missing' }
    $result = $line[0] | ConvertFrom-Json
    if ($result.status -ceq 'approval_required') {
        $uri=[Uri][string]$result.approvalUrl
        if ($uri.GetLeftPart([UriPartial]::Authority) -cne 'https://cogentspec.com' -or $uri.AbsolutePath -cne '/activate') { throw 'invalid_approval' }
        # Consumed only by this request's protected existing web tab.
        @{protocol='cogentspec-gptweb-native-v1';status='approval_required';approvalUrl=$uri.AbsoluteUri;browserOpened=$false}|ConvertTo-Json -Compress
        return
    }
    if ($result.status -cne 'ready') {
        @{protocol='cogentspec-gptweb-native-v1';status='not_ready';browserOpened=$false;userMessage=[string]$result.userMessage}|ConvertTo-Json -Compress
        return
    }
    if ($result.contextKey -cne $ContextKey -or $result.contextIsolated -cne $true -or $result.presenceVerified -cne $true -or
        $result.accountState -cne 'signed_in' -or $result.projectDataConnection -cne 'authenticated_desktop_bridge' -or
        $result.defaultDirectoryReady -cne $true -or $result.browserOpened -cne $false) { throw 'invalid_startup_contract' }
    if (-not $token) {
        $credential=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token=[Text.Encoding]::UTF8.GetString($bytes)
    }
    $proof=Invoke-RestMethod -Method Post -Uri 'https://cogentspec.app/api/bridge/gptweb/startup' -TimeoutSec 10 -ContentType 'application/json' `
        -Headers @{Authorization="Bearer $token"} -Body (@{operation='ready';requestId=$StartupRequest;contextKey=$ContextKey;command='$gptweb';surface='chatgpt';experience='web'}|ConvertTo-Json -Compress)
    if ($proof.protocol -cne 'cogentspec-gptweb-startup-v1' -or $proof.status -cne 'ready' -or $proof.workspaceConnected -cne $false) { throw 'invalid_startup_proof' }
    @{protocol='cogentspec-gptweb-native-v1';status='ready';browserOpened=$false;workspaceConnected=$false;acknowledgementVerified=$false}|ConvertTo-Json -Compress
} catch {
    @{protocol='cogentspec-gptweb-native-v1';status='not_ready';browserOpened=$false;workspaceConnected=$false;acknowledgementVerified=$false;
        userMessage='GPTWeb could not verify this computer startup. No tab was opened and no existing worker was replaced.'}|ConvertTo-Json -Compress
} finally {
    $token=$null
    if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
}
