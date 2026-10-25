# First-time account permission stays in the existing CogentSpec web tab. This
# step never starts a worker, claims a tab, or replaces an existing credential.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,[switch]$ResumeApproval,
    [ValidatePattern('^$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$StartupRequest='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    $connection=Join-Path $PSScriptRoot 'connect-cogentstack.ps1'
    $arguments=@{Surface='chatgpt';ContextKey=$ContextKey;Experience='web';RequestTimeoutSeconds=6}
    if($StartupRequest){$arguments.StartupRequest=$StartupRequest}
    if($ResumeApproval){$arguments.Mode='complete';$arguments.BrowserApproval=$true}else{$arguments.Mode='status'}
    $result=(& $connection @arguments)|ConvertFrom-Json
    if($result.status -cin @('connected','authorized')) {
        @{protocol='cogentspec-gptweb-native-v1';status='enrolled';workspaceConnected=$false;browserOpened=$false}|ConvertTo-Json -Compress
        return
    }
    if(-not $ResumeApproval){
        $arguments.Mode='start';$arguments.BrowserApproval=$true
        $result=(& $connection @arguments)|ConvertFrom-Json
    }
    if($result.status -ceq 'approval_pending') {
        $arguments.Mode='start'
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
