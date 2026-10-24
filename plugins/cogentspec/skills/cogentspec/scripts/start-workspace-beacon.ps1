[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('chatgpt','claude-desktop','qwen-web')][string]$Surface,
    [Parameter(Mandatory)][ValidateSet('web','split-screen','popout','desktop','desktop-ui')][string]$Experience,
    [string]$ContextKey = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = 'bridge_start'
$bytes = $null
$token = $null
try {
    if ($Surface -eq 'qwen-web' -and $Experience -ne 'web') { throw 'invalid_destination' }
    # This launcher resolves the invoking project, checks the current device and
    # starts/verifies its worker. ListenerOnly never opens or controls a window.
    $output = @(& (Join-Path $PSScriptRoot 'start-cogentstack-bridge.ps1') -ContextKey $ContextKey -Surface $Surface -Experience $Experience -ListenerOnly 2>&1)
    $line = @($output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { throw 'bridge_result_missing' }
    $result = $line[0] | ConvertFrom-Json
    if ($result.status -cne 'ready') {
        [ordered]@{status = $result.status; browserOpened = $false; userMessage = $result.userMessage} | ConvertTo-Json -Compress
        return
    }
    if (($ContextKey -and $result.contextKey -cne $ContextKey) -or $result.contextIsolated -cne $true -or $result.presenceVerified -cne $true -or
        $result.defaultDirectoryReady -cne $true -or $result.accountState -cne 'signed_in' -or
        $result.projectDataConnection -cne 'authenticated_desktop_bridge' -or $result.browserOpened -cne $false -or
        $result.contextKey -cnotmatch '^ctx-[a-f0-9]{64}$') { throw 'bridge_contract_invalid' }
    $embedded = $Experience -in @('desktop','desktop-ui')
    $uri = [Uri]$(if ($embedded) { $result.chatgptWorkspaceUrl } else { $result.webWorkspaceUrl })
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'cogentspec.app' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or
        $uri.AbsolutePath -notin @('/stack','/popout-launch')) { throw 'invalid_workspace_handoff' }
    $query = @{}
    foreach ($entry in $uri.Query.TrimStart('?').Split('&')) {
        $pair = $entry.Split('=',2)
        if ($pair.Count -ne 2) { throw 'invalid_workspace_handoff' }
        $name = [Uri]::UnescapeDataString($pair[0])
        if ($query.ContainsKey($name)) { throw 'invalid_workspace_handoff' }
        $query[$name] = [Uri]::UnescapeDataString($pair[1])
    }
    $fragment = if ($embedded) { '^#desktop-chatgpt=(cgw_[A-Za-z0-9_-]{32,200})$' } else { '^#desktop-web=(cgw_[A-Za-z0-9_-]{32,200})$' }
    if ($query.Count -ne 5 -or $query.surface -cne $Surface -or $query.experience -cne $Experience -or
        $query.context -cne $result.contextKey -or $query.nav -cnotmatch '^[a-f0-9]{32}$' -or
        $query.open -cne $(if ($embedded) { 'chatgpt' } else { 'web' }) -or $uri.Fragment -cnotmatch $fragment) { throw 'invalid_workspace_handoff' }
    $code = $Matches[1]
    $stage = 'workspace_reuse'
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    $credential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $token = [Text.Encoding]::UTF8.GetString($bytes)
    $reply = Invoke-RestMethod -Method Post -Uri 'https://cogentspec.com/api/device-authorization/workspace-reuse' -TimeoutSec 12 `
        -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } `
        -Body (@{code=$code;contextKey=$result.contextKey;surface=$Surface;experience=$Experience} | ConvertTo-Json -Compress)
    if ($reply.protocol -cne 'cogentspec-workspace-reuse-v1' -or $reply.contextKey -cne $result.contextKey -or
        $reply.surface -cne $Surface -or $reply.experience -cne $Experience) { throw 'invalid_acknowledgement' }
    $connected = $reply.status -ceq 'reused' -and $reply.acknowledgementVerified -ceq $true
    [ordered]@{protocol='cogentspec-workspace-beacon-start-v1';status=$(if($connected){'connected'}else{'not_connected'});
        workspaceConnected=$connected;acknowledgementVerified=$connected;browserReused=$connected;browserOpened=$false;
        browserHandoff='authenticated-workspace-reuse';surface=$Surface;experience=$Experience;
        userMessage=$(if($connected){'Bridge connected.'}else{'The registered work area did not acknowledge this command. Select Initiate Bridge in your existing tab, then send the command again. No other tab was opened.'})} | ConvertTo-Json -Compress
} catch {
    [ordered]@{status='not_connected';workspaceConnected=$false;acknowledgementVerified=$false;browserOpened=$false;failureStage=$stage;
        userMessage='The Bridge connection could not be verified. Keep your existing work area open and check its listener. No other tab was opened.'} | ConvertTo-Json -Compress
} finally {
    $token = $null
    if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
}
