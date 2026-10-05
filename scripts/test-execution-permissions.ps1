param([switch]$ExpectSandbox)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$canonicalScripts = Join-Path $repositoryRoot 'plugins/cogentspec/skills/cogentspec/scripts'
. (Join-Path $canonicalScripts 'native-command.ps1')

foreach ($identity in @('PC\CodexSandboxOffline', 'PC\CodexSandboxOnline', 'PC\codexsandbox1')) {
    if (-not (Test-CogentSpecSandboxIdentity $identity)) { throw "Sandbox identity not recognized: $identity" }
}
foreach ($identity in @('PC\paula', 'PC\user', 'PC\MyCodexSandbox')) {
    if (Test-CogentSpecSandboxIdentity $identity) { throw "Normal user rejected: $identity" }
}
$failure = Get-CogentSpecExecutionPermissionFailure
if ([bool]$failure -ne [bool]$ExpectSandbox) { throw 'Test was run in the wrong execution context.' }
$blockedHelpers = 0
if ($ExpectSandbox) {
    foreach ($relativePath in @(
        'plugins/cogentspec/skills/cogentspec/scripts',
        'plugins/cogentstack/skills/cogentstack/scripts',
        'claude-plugins/cogentspec/skills/cogentspec/scripts',
        'claude-plugins/cogentstack/skills/cogentstack/scripts'
    )) {
        foreach ($name in @('connect-cogentstack.ps1', 'start-cogentstack-bridge.ps1', 'check-cogentspec-update.ps1')) {
            $helper = Join-Path (Join-Path $repositoryRoot $relativePath) $name
            if (-not (Test-Path -LiteralPath $helper)) { continue }
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper
            if ($LASTEXITCODE -ne 0) { throw "$relativePath/$name did not return a structured result." }
            $result = $output | ConvertFrom-Json
            if ($result.status -ne 'execution_permission_required' -or
                $result.reason -ne 'windows_user_execution_required' -or
                $result.credentialRead -ne $false -or $result.networkAttempted -ne $false) {
                throw "$relativePath/$name attempted connection in the sandbox."
            }
            $blockedHelpers++
        }
    }
    if ($blockedHelpers -ne 10) { throw 'Not all packaged helper variants were checked.' }
}
[ordered]@{ status = 'valid'; sandbox = [bool]$ExpectSandbox; identityCases = 6; blockedHelpers = $blockedHelpers } | ConvertTo-Json -Compress
