[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-snap-approval-' + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
$contextA = 'ctx-' + ('a' * 64)
$contextB = 'ctx-' + ('b' * 64)
$cases = 0
function Assert-Approval([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    foreach ($plugin in @('cogentspec', 'cogentstack')) {
        $root = Join-Path $fixtureRoot $plugin
        [void](New-Item -ItemType Directory -Path $root -Force)
        $source = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "plugins/$plugin/skills/$plugin/scripts/connect-cogentstack.ps1")
        $source = $source.Replace(". (Join-Path `$PSScriptRoot 'native-command.ps1')", 'function Get-CogentSpecExecutionPermissionFailure { return $null }')
        $source = $source.Replace("`$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'", "`$stateRoot = '$($root.Replace("'", "''"))'")
        $connector = [scriptblock]::Create($source)
        $script:starts = 0
        $script:polls = 0
        $script:approved = $false
        function Start-Process { throw 'The connector must leave browser delivery to the host.' }
        function Invoke-RestMethod {
            param($Method, $Uri, $ContentType, $Headers, $Body, $TimeoutSec)
            Assert-Approval ($TimeoutSec -eq 6) 'Unbounded approval HTTP request.'
            if ($Uri -eq 'https://cogentspec.com/api/device-authorization') {
                $script:starts++
                return [pscustomobject]@{ deviceCode = 'cgd_fixture_only'; userCode = 'TEST-CODE'; verificationUriComplete = 'https://cogentspec.com/activate?code=TEST-CODE'; expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o'); intervalSeconds = 5 }
            }
            if ($Uri -eq 'https://cogentspec.com/api/device-authorization/token') {
                $script:polls++
                Assert-Approval (($Body | ConvertFrom-Json).deviceCode -eq 'cgd_fixture_only') 'Wrong protected pending request.'
                if (-not $script:approved) { return [pscustomobject]@{status = 'authorization_pending'} }
                return [pscustomobject]@{status = 'authorized'; token = 'fixture-access-only'; renewalToken = 'fixture-renewal-only'; deviceLeaseId = 'fixture-lease'; browserCode = 'fixture-browser'; subscriber = [pscustomobject]@{email = 'fixture@example.invalid'; plan = 'desktop'}; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); replacedExistingDevice = $false}
            }
            throw 'Unexpected authorization operation.'
        }
        $start = & $connector -Mode start -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($start.status -eq 'approval_required' -and $start.approvalUrl -eq 'https://cogentspec.com/activate?code=TEST-CODE&experience=split-screen') 'Start did not prepare browser approval.'
        $repeat = & $connector -Mode start -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($repeat.requestReused -and $script:starts -eq 1) 'Repeated command created another server request.'
        $conflict = & $connector -Mode start -BrowserApproval -ContextKey $contextB -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($conflict.status -eq 'approval_context_conflict' -and $script:starts -eq 1) 'Another context replaced the pending request.'
        $wrongComplete = & $connector -Mode complete -BrowserApproval -ContextKey $contextB -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($wrongComplete.status -eq 'approval_context_conflict' -and $script:polls -eq 0) 'Another context consumed the approval.'
        $pending = & $connector -Mode complete -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($pending.status -eq 'approval_pending' -and -not (Test-Path (Join-Path $root 'desktop-credential.json'))) 'Pending approval created credentials.'
        $script:approved = $true
        $completeJson = & $connector -Mode complete -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6
        $complete = $completeJson | ConvertFrom-Json
        Assert-Approval ($complete.status -eq 'authorized' -and $complete.browserAuthorizationCompleted -and $script:starts -eq 1) 'Approved request did not complete once.'
        Assert-Approval ($completeJson -notmatch 'fixture-access|fixture-renewal|fixture-browser|Run the requested') 'Approval exposed secrets or requested another command.'
        $saved = Get-Content -Raw (Join-Path $root 'desktop-credential.json') | ConvertFrom-Json
        Assert-Approval ($saved.installationBound -and $saved.token -ne 'fixture-access-only' -and $saved.renewalToken -ne 'fixture-renewal-only') 'Credential was not protected.'
        Assert-Approval (-not (Test-Path (Join-Path $root 'gptsnap-authorization.json'))) 'Consumed request was retained.'
        $empty = & $connector -Mode complete -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($empty.status -eq 'not_started') 'A consumed request was replayed.'
        $null = & $connector -Mode start -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6
        $expiredPath = Join-Path $root 'gptsnap-authorization.json'
        $expired = Get-Content -Raw $expiredPath | ConvertFrom-Json
        $expired.expiresAt = '2000-01-01T00:00:00Z'
        $expired | ConvertTo-Json | Set-Content -LiteralPath $expiredPath -Encoding UTF8
        $pollsBeforeExpiry = $script:polls
        $expiredResult = & $connector -Mode complete -BrowserApproval -ContextKey $contextA -Surface chatgpt -RequestTimeoutSeconds 6 | ConvertFrom-Json
        Assert-Approval ($expiredResult.status -eq 'expired' -and $script:polls -eq $pollsBeforeExpiry -and -not (Test-Path $expiredPath)) 'Expired approval was submitted or retained.'
        $cases += 10
    }
    [ordered]@{status = 'passed'; cases = $cases; realAccountClaimAttempted = $false; browserOpened = $false} | ConvertTo-Json -Compress
} finally {
    if ([IO.Path]::GetDirectoryName($fixtureRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($fixtureRoot) -notmatch '^cogentspec-snap-approval-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup target.' }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
