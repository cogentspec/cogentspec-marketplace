# Account enrollment is part of the explicit one-time GUI setup. It never starts
# a worker or claims a browser tab, so an expired browser job cannot block setup.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,[switch]$ResumeApproval)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    $connection=Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
    $arguments=@{Surface='chatgpt';ContextKey=$ContextKey;Experience='web';RequestTimeoutSeconds=6}
    if($ResumeApproval){$arguments.Mode='complete';$arguments.BrowserApproval=$true}else{$arguments.Mode='status'}
    $result=(& $connection @arguments)|ConvertFrom-Json
    if($result.status -ceq 'connected') {
        @{protocol='cogentspec-gptweb-native-v1';status='enrolled';workspaceConnected=$false;browserOpened=$false}|ConvertTo-Json -Compress
        return
    }
    if(-not $ResumeApproval){
        $arguments.Mode='start';$arguments.BrowserApproval=$true
        $result=(& $connection @arguments)|ConvertFrom-Json
    }
    if($result.status -ceq 'approval_required') {
        $uri=[Uri][string]$result.approvalUrl
        if($uri.GetLeftPart([UriPartial]::Authority) -cne 'https://cogentspec.com' -or $uri.AbsolutePath -cne '/activate'){throw 'invalid_approval'}
        @{protocol='cogentspec-gptweb-native-v1';status='approval_required';approvalUrl=$uri.AbsoluteUri;workspaceConnected=$false;browserOpened=$false}|ConvertTo-Json -Compress
        return
    }
    throw 'enrollment_unavailable'
} catch {
    @{protocol='cogentspec-gptweb-native-v1';status='not_ready';workspaceConnected=$false;browserOpened=$false}|ConvertTo-Json -Compress
}
