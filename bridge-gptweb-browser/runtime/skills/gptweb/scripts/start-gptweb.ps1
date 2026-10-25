[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$core=Join-Path $PSScriptRoot '..\..\cogentspec\scripts\start-cogentstack-bridge.ps1'
$output=@(& $core -ContextKey $ContextKey -Surface chatgpt -Experience web -ListenerOnly 2>&1)
$line=@($output|ForEach-Object {$_.ToString()}|Where-Object {$_.Trim().StartsWith('{')}|Select-Object -Last 1)
if(-not $line){throw 'GPTWeb did not return its worker result.'}
$result=$line[0]|ConvertFrom-Json
if($result.status -cne 'ready' -or $result.contextKey -cne $ContextKey -or $result.presenceVerified -cne $true -or
    $result.defaultDirectoryReady -cne $true -or $result.accountState -cne 'signed_in' -or
    $result.projectDataConnection -cne 'authenticated_desktop_bridge' -or $result.browserOpened -cne $false) {
    throw 'GPTWeb could not verify this work area.'
}
# Handoff codes created by the frozen runtime stay private. The browser-start
# endpoint grants only to its exact initiating document, after live presence.
@{status='ready';contextKey=$ContextKey;presenceVerified=$true;accountState='signed_in';browserOpened=$false}|ConvertTo-Json -Compress
