[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-licence-command-' + [Guid]::NewGuid().ToString('N'))))
$cases = 0
Add-Type -AssemblyName System.Security
Add-Type @'
public class BridgeLicenceFixtureResponse {
    public int StatusCode { get; private set; }
    private string body;
    public BridgeLicenceFixtureResponse(int status, string json) { StatusCode = status; body = json; }
    public System.IO.Stream GetResponseStream() { return new System.IO.MemoryStream(System.Text.Encoding.UTF8.GetBytes(body)); }
}
public class BridgeLicenceFixtureException : System.Exception {
    public BridgeLicenceFixtureResponse Response { get; private set; }
    public BridgeLicenceFixtureException(int status, string json) : base("Fixture HTTP failure") { Response = new BridgeLicenceFixtureResponse(status, json); }
}
'@
function Assert-Licence([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fail-Http([int]$Status, [string]$Code, [switch]$StreamOnly) {
    $json = @{ code = $Code; error = 'PRIVATE_FIXTURE_ERROR' } | ConvertTo-Json -Compress
    $exception = New-Object BridgeLicenceFixtureException($Status, $json)
    $record = New-Object Management.Automation.ErrorRecord($exception, 'FixtureHttp', ([Management.Automation.ErrorCategory]::InvalidOperation), $null)
    if (-not $StreamOnly) { $record.ErrorDetails = New-Object Management.Automation.ErrorDetails($json) }
    throw $record
}
try {
    $roots = @(
        (Join-Path $repositoryRoot 'plugins/cogentspec/skills/cogentspec'),
        (Join-Path $repositoryRoot 'plugins/cogentstack/skills/cogentstack'),
        (Join-Path $repositoryRoot 'claude-plugins/cogentspec/skills/cogentspec'),
        (Join-Path $repositoryRoot 'claude-plugins/cogentstack/skills/cogentstack'),
        (Join-Path (Split-Path -Parent $repositoryRoot) 'CogentSpec/plugins/cogentspec/skills/cogentspec'),
        (Join-Path (Split-Path -Parent $repositoryRoot) 'CogentSpec/plugins/cogentstack/skills/cogentstack')
    )
    foreach ($skillRoot in $roots) {
        # A standalone marketplace checkout need not contain the website mirrors.
        if (-not (Test-Path -LiteralPath $skillRoot)) { continue }
        $root = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $root -Force)
        $source = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'scripts/connect-cogentstack.ps1')
        $source = $source.Replace(". (Join-Path `$PSScriptRoot 'native-command.ps1')", 'function Get-CogentSpecExecutionPermissionFailure { return $null }')
        $stateStatement = "`$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'"
        Assert-Licence ($source.Contains($stateStatement)) 'Credential fixture injection no longer matches source.'
        $source = $source.Replace($stateStatement, "`$stateRoot = '$($root.Replace("'", "''"))'")
        $connector = [scriptblock]::Create($source)
        $credentialFile = Join-Path $root 'desktop-credential.json'
        $fixtureCredential = [ordered]@{ connectedAt = '2026-01-01T00:00:00Z'; installationBound = $true; deviceLeaseId = 'fixture-lease' }
        foreach ($field in @('token', 'renewalToken')) {
            $fixtureCredential[$field] = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes("PRIVATE_FIXTURE_$field"), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        }
        function Start-Process { throw 'A licence check must never open a browser.' }
        function Invoke-RestMethod {
            param($Method, $Uri, $ContentType, $Headers, $Body, $TimeoutSec)
            Assert-Licence ($TimeoutSec -eq 6) 'Access request lost its bounded transport timeout.'
            $script:requests.Add("$Method $Uri")
            if ($Method -eq 'Get' -and $Uri -eq 'https://cogentspec.com/api/device-authorization/token') {
                if ($script:scenario -eq 'licence') { Fail-Http 403 'licence_required' }
                if ($script:scenario -eq 'licence-stream') { Fail-Http 403 'licence_required' -StreamOnly }
                if ($script:scenario -like 'renewal-*') { Fail-Http 401 '' }
                if ($script:scenario -eq 'forbidden') { Fail-Http 403 '' }
                if ($script:scenario -eq 'server') { Fail-Http 503 '' }
                if ($script:scenario -eq 'throttled') { Fail-Http 429 '' }
                if ($script:scenario -eq 'network') { throw 'PRIVATE_FIXTURE_NETWORK' }
                return [pscustomobject]@{ subscriber = [pscustomobject]@{email = 'fixture@example.invalid'; plan = 'desktop'} }
            }
            if ($Uri -eq 'https://cogentspec.com/api/device-authorization/renew') {
                if ($script:scenario -eq 'renewal-inactive') { Fail-Http 403 'subscription_inactive' }
                if ($script:scenario -eq 'renewal-forbidden') { Fail-Http 403 '' }
                if ($script:scenario -eq 'renewal-server') { Fail-Http 503 '' }
                if ($script:scenario -eq 'renewal-revoked') { Fail-Http 401 'installation_replaced_or_revoked' }
                throw 'Unexpected renewal fixture.'
            }
            if ($Uri -eq 'https://cogentspec.com/api/device-authorization/browser-grant') {
                if ($script:scenario -eq 'grant-licence') { Fail-Http 403 'licence_required' }
                if ($script:scenario -eq 'grant-server') { Fail-Http 503 '' }
                return [pscustomobject]@{ chatgptWorkspaceCode = 'cgw_fixture_chat'; chatgptExpiresAt = '2099-01-01T00:00:00Z'; webWorkspaceCode = 'cgw_fixture_web'; webExpiresAt = '2099-01-01T00:00:00Z' }
            }
            throw 'Access check attempted approval, installation or an unexpected endpoint.'
        }
        foreach ($script:scenario in @('licence', 'licence-stream', 'renewal-inactive', 'forbidden', 'renewal-forbidden', 'server', 'renewal-server', 'throttled', 'network', 'grant-licence', 'grant-server', 'renewal-revoked', 'active')) {
            $fixtureCredential | ConvertTo-Json | Set-Content -LiteralPath $credentialFile -Encoding UTF8
            $before = [IO.File]::ReadAllText($credentialFile)
            $script:requests = [Collections.Generic.List[string]]::new()
            $json = & $connector -Mode status -WorkspaceGrant -ContextKey ('ctx-' + ('a' * 64)) -Surface chatgpt -RequestTimeoutSeconds 6
            $result = $json | ConvertFrom-Json
            $expected = if ($script:scenario -eq 'active') { 'connected' } elseif ($script:scenario -eq 'renewal-revoked') { 'signed_out' } elseif ($script:scenario -in @('licence', 'licence-stream', 'renewal-inactive', 'grant-licence')) { 'licence_required' } else { 'licence_verification_unavailable' }
            Assert-Licence ($result.status -eq $expected) "Wrong access classification for $script:scenario."
            Assert-Licence ($json -notmatch 'PRIVATE_FIXTURE|\/install|\/activate|approvalUrl|recoveryUrl') 'Access result exposed secrets or a reconnect route.'
            if ($script:scenario -eq 'renewal-revoked') {
                Assert-Licence (-not (Test-Path -LiteralPath $credentialFile)) 'Revoked installation retained its credential.'
            } else {
                Assert-Licence ([IO.File]::ReadAllText($credentialFile) -ceq $before) 'Access check changed saved credentials.'
            }
            if ($expected -in @('licence_required', 'licence_verification_unavailable')) {
                Assert-Licence ($result.credentialPreserved -and -not $result.browserOpened -and $result.userMessage) 'Access denial lost its safe user contract.'
                Assert-Licence ($json -notmatch 'cgw_|workspaceCode') 'Access denial exposed a workspace grant.'
            }
            $expectedRequests = if ($script:scenario -like 'renewal-*' -or $script:scenario -like 'grant-*' -or $script:scenario -eq 'active') { 2 } else { 1 }
            Assert-Licence ($script:requests.Count -eq $expectedRequests) 'Access check performed unexpected operations.'
            $cases++
        }
    }
    [ordered]@{status = 'passed'; cases = $cases; realAccountAccessed = $false; browserOpened = $false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Path]::GetDirectoryName($fixtureRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($fixtureRoot) -notmatch '^cogentspec-licence-command-[a-f0-9]{32}$') { throw 'Unsafe licence fixture cleanup target.' }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
