[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$RequestId,
    [Parameter(Mandatory=$true)][ValidateSet('$gptweb','$claudeweb')][string]$Command)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$token=$null
$execution=[Guid]::NewGuid().ToString()
try{
    if($env:OS -ne 'Windows_NT'){throw 'windows_execution_required'}
    try{Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop}catch{Add-Type -AssemblyName System.Security -ErrorAction Stop}
    $credentialPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if(-not (Test-Path -LiteralPath $credentialPath)){throw 'account_authorization_required'}
    try{
        $credential=Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token=[Text.Encoding]::UTF8.GetString($bytes)
    }catch{throw 'windows_user_permission_required'}
    function Send([string]$Operation,[string]$Context=''){
        $body=@{operation=$Operation;id=$RequestId;command=$Command;executionId=$execution}
        if($Context){$body.contextKey=$Context}
        return Invoke-RestMethod -Uri 'https://cogentspec.app/api/bridge/web/v1/worker' -Method Post -MaximumRedirection 0 -TimeoutSec 8 `
            -Headers @{Authorization="Bearer $token";Accept='application/json'} -ContentType 'application/json' -Body ($body|ConvertTo-Json -Compress)
    }
    $selected=Send 'describe'
    $surface=if($Command -ceq '$gptweb'){'chatgpt'}else{'claude-desktop'}
    if($selected.protocol -cne 'cogentspec-web-command-v1' -or $selected.status -cne 'prepared' -or
        $selected.contextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or $selected.surface -cne $surface -or $selected.experience -cne 'web'){throw 'invalid_web_request'}
    . (Join-Path $PSScriptRoot 'ensure-default-project-directory.ps1')
    $directory=Initialize-CogentSpecDefaultProjectDirectory
    if($directory.status -cne 'ready'){throw 'default_directory_unavailable'}
    & (Join-Path $PSScriptRoot 'start-web-worker.ps1') -ContextKey $selected.contextKey -Command $Command
    & (Join-Path $PSScriptRoot 'bridge-manager.ps1') -Mode RegisterWeb -ContextKey $selected.contextKey -Surface $surface
    $null=Send 'ready' $selected.contextKey
    $deadline=[DateTime]::UtcNow.AddSeconds(45)
    do{
        $result=Send 'status' $selected.contextKey
        if($result.protocol -ceq 'cogentspec-web-command-v1' -and $result.status -ceq 'connected' -and
            $result.workspaceConnected -ceq $true -and $result.acknowledgementVerified -ceq $true -and $result.browserOpened -ceq $false){
            [ordered]@{protocol='cogentspec-web-command-v1';status='connected';workspaceConnected=$true;acknowledgementVerified=$true;
                browserOpened=$false;browserControlled=$false;pluginInstalled=$false}|ConvertTo-Json -Compress
            return
        }
        if($result.status -cne 'waiting_for_tab'){throw 'invalid_web_receipt'}
        Start-Sleep -Seconds 1
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'tab_acknowledgement_timeout'
}catch{
    $reason=if([string]$_.Exception.Message -cmatch '^[a-z_]{1,60}$'){[string]$_.Exception.Message}else{'connection_failed'}
    $message=switch($reason){
        'account_authorization_required' {'Authorize this computer once in your CogentSpec account, then copy the Web command again. The helper files are installed.'}
        'windows_user_permission_required' {'This connection needs the host permission to execute as the installing Windows user. No account credential was changed.'}
        'default_directory_unavailable' {'CogentSpec could not prepare the projects folder for this Windows user.'}
        'tab_acknowledgement_timeout' {'The existing Web tab did not acknowledge this connection before its deadline. No other tab was opened.'}
        default {'The Web connection could not be verified. No other work area was selected or opened.'}
    }
    # Preserve bounded service messages without exposing response bodies, tokens or grants.
    try{$detail=$_.ErrorDetails.Message|ConvertFrom-Json;if($detail.userMessage -and $detail.reason -match '^[a-z_]{1,60}$'){$reason=$detail.reason;$message=$detail.userMessage}}catch{}
    [ordered]@{protocol='cogentspec-web-command-v1';status='not_connected';reason=$reason;userMessage=$message;
        workspaceConnected=$false;acknowledgementVerified=$false;browserOpened=$false;browserControlled=$false;pluginInstalled=$false}|ConvertTo-Json -Compress
}finally{$token=$null}
