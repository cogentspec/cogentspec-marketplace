param(
    [ValidateSet('claim', 'start', 'complete', 'status', 'disconnect')]
    [string]$Mode = 'start',

    [string]$InstallationRequest = '',

    [ValidateSet('chatgpt', 'claude-desktop')]
    [string]$Surface = 'chatgpt',

    [string]$ContextKey = '',

    [switch]$WorkspaceGrant,

    [ValidateRange(3, 20)]
    [int]$RequestTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
    } catch {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
}

$serviceUrl = 'https://cogentspec.com'
$workspaceOrigin = 'https://cogentspec.app'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$pendingPath = Join-Path $stateRoot 'desktop-authorization.json'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'

function Protect-CogentSpecValue([string]$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protected)
}

function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Compress | Write-Output
}

function Save-CogentSpecCredential($Result) {
    if (-not $Result.token -or -not $Result.renewalToken -or -not $Result.deviceLeaseId) {
        throw 'CogentSpec returned an incomplete account-bound Desktop credential.'
    }
    [ordered]@{
        token = Protect-CogentSpecValue ([string]$Result.token)
        renewalToken = Protect-CogentSpecValue ([string]$Result.renewalToken)
        email = [string]$Result.subscriber.email
        plan = [string]$Result.subscriber.plan
        connectedAt = [string]$Result.createdAt
        deviceLeaseId = [string]$Result.deviceLeaseId
        installationBound = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $credentialPath -Encoding UTF8
}

function New-CogentSpecWorkspaceGrant([string]$Token, [string]$GrantContextKey, [string]$GrantSurface) {
    return Invoke-RestMethod `
        -Method Post `
        -Uri "$serviceUrl/api/device-authorization/browser-grant" `
        -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json'; Authorization = "Bearer $Token" } `
        -Body (@{ contextKey = $GrantContextKey; surface = $GrantSurface } | ConvertTo-Json -Compress) `
        -TimeoutSec $RequestTimeoutSeconds
}

if ($Mode -eq 'status') {
    if (Test-Path -LiteralPath $credentialPath) {
        $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
        $token = Unprotect-CogentSpecValue ([string]$credential.token)
        try {
            $connection = Invoke-RestMethod `
                -Method Get `
                -Uri "$serviceUrl/api/device-authorization/token" `
                -Headers @{ Accept = 'application/json'; Authorization = "Bearer $token" } `
                -TimeoutSec $RequestTimeoutSeconds
            $statusResult = [ordered]@{
                status = 'connected'
                email = $connection.subscriber.email
                plan = $connection.subscriber.plan
                connectedAt = $credential.connectedAt
            }
            if ($WorkspaceGrant) {
                $grant = New-CogentSpecWorkspaceGrant $token $ContextKey $Surface
                $statusResult.workspaceCode = [string]$grant.chatgptWorkspaceCode
                $statusResult.workspaceCodeExpiresAt = [string]$grant.chatgptExpiresAt
                $statusResult.webWorkspaceCode = [string]$grant.webWorkspaceCode
                $statusResult.webWorkspaceCodeExpiresAt = [string]$grant.webExpiresAt
                $statusResult.chatgptWorkspaceCode = [string]$grant.chatgptWorkspaceCode
                $statusResult.chatgptWorkspaceCodeExpiresAt = [string]$grant.chatgptExpiresAt
            }
            Write-CompactJson $statusResult
        } catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -eq 401) {
                $hasRenewal = $credential.PSObject.Properties.Name -contains 'renewalToken'
                if ($hasRenewal -and $credential.renewalToken) {
                    $renewalToken = Unprotect-CogentSpecValue ([string]$credential.renewalToken)
                    try {
                        $renewed = Invoke-RestMethod `
                            -Method Post `
                            -Uri "$serviceUrl/api/device-authorization/renew" `
                            -ContentType 'application/json' `
                            -Headers @{ Accept = 'application/json' } `
                            -Body (@{ renewalToken = $renewalToken } | ConvertTo-Json -Compress) `
                            -TimeoutSec $RequestTimeoutSeconds
                        Save-CogentSpecCredential $renewed
                        $statusResult = [ordered]@{
                            status = 'connected'
                            email = $renewed.subscriber.email
                            plan = $renewed.subscriber.plan
                            connectedAt = $renewed.createdAt
                            renewed = $true
                            installationBound = $true
                        }
                        if ($WorkspaceGrant) {
                            $grant = New-CogentSpecWorkspaceGrant ([string]$renewed.token) $ContextKey $Surface
                            $statusResult.workspaceCode = [string]$grant.chatgptWorkspaceCode
                            $statusResult.workspaceCodeExpiresAt = [string]$grant.chatgptExpiresAt
                            $statusResult.webWorkspaceCode = [string]$grant.webWorkspaceCode
                            $statusResult.webWorkspaceCodeExpiresAt = [string]$grant.webExpiresAt
                            $statusResult.chatgptWorkspaceCode = [string]$grant.chatgptWorkspaceCode
                            $statusResult.chatgptWorkspaceCodeExpiresAt = [string]$grant.chatgptExpiresAt
                        }
                        Write-CompactJson $statusResult
                        return
                    } catch {
                        $renewStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                        if ($renewStatus -eq 428) {
                            Remove-Item -LiteralPath $credentialPath -Force
                            Write-CompactJson ([ordered]@{ status = 'signed_out'; reason = 'legal_update_required' })
                            return
                        }
                        if ($renewStatus -eq 401 -or $renewStatus -eq 403) {
                            Remove-Item -LiteralPath $credentialPath -Force
                            Write-CompactJson ([ordered]@{ status = 'signed_out'; reason = 'installation_replaced_revoked_or_inactive' })
                            return
                        }
                        throw
                    } finally {
                        $renewalToken = $null
                    }
                }
                Remove-Item -LiteralPath $credentialPath -Force
                Write-CompactJson ([ordered]@{ status = 'signed_out'; reason = 'legacy_connection_not_bound_to_installation' })
                return
            }
            throw
        }
    } else {
        Write-CompactJson ([ordered]@{ status = 'signed_out' })
    }
    return
}

if ($Mode -eq 'disconnect') {
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        Write-CompactJson ([ordered]@{ status = 'signed_out' })
        return
    }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $token = Unprotect-CogentSpecValue ([string]$credential.token)
    try {
        Invoke-RestMethod `
            -Method Delete `
            -Uri "$serviceUrl/api/device-authorization/token" `
            -Headers @{ Accept = 'application/json'; Authorization = "Bearer $token" } `
            -TimeoutSec $RequestTimeoutSeconds | Out-Null
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -ne 401) { throw }
    } finally {
        Remove-Item -LiteralPath $credentialPath -Force
    }
    Write-CompactJson ([ordered]@{ status = 'signed_out' })
    return
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

if ($Mode -eq 'claim') {
    if ($InstallationRequest -notmatch '^cgb_[A-Za-z0-9_-]{40,}$') {
        throw 'The account-bound installation request is missing or invalid. Copy a fresh request from https://cogentspec.com/install.'
    }
    try {
        $result = Invoke-RestMethod `
            -Method Post `
            -Uri "$serviceUrl/api/plugin/bootstrap" `
            -ContentType 'application/json' `
            -Headers @{ Accept = 'application/json' } `
            -Body (@{ code = $InstallationRequest; deviceName = 'ChatGPT Desktop on Windows' } | ConvertTo-Json -Compress) `
            -TimeoutSec $RequestTimeoutSeconds
    } finally {
        $InstallationRequest = ''
    }
    Save-CogentSpecCredential $result
    if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath -Force }
    Write-CompactJson ([ordered]@{
        status = 'connected'
        accountBound = $true
        installationBound = $true
        plan = [string]$result.subscriber.plan
        replacedExistingDevice = [bool]$result.replacedExistingDevice
    })
    return
}

if ($Mode -eq 'start') {
    $requestBody = @{ deviceName = 'ChatGPT Desktop on Windows' } | ConvertTo-Json -Compress
    $authorization = Invoke-RestMethod `
        -Method Post `
        -Uri "$serviceUrl/api/device-authorization" `
        -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json' } `
        -Body $requestBody `
        -TimeoutSec $RequestTimeoutSeconds

    [ordered]@{
        deviceCode = Protect-CogentSpecValue ([string]$authorization.deviceCode)
        userCode = [string]$authorization.userCode
        expiresAt = [string]$authorization.expiresAt
        intervalSeconds = [int]$authorization.intervalSeconds
    } | ConvertTo-Json | Set-Content -LiteralPath $pendingPath -Encoding UTF8

    Start-Process ([string]$authorization.verificationUriComplete)
    Write-CompactJson ([ordered]@{
        status = 'approval_required'
        expiresAt = [string]$authorization.expiresAt
        pollAfterSeconds = [int]$authorization.intervalSeconds
    })
    return
}

if (-not (Test-Path -LiteralPath $pendingPath)) {
    Write-CompactJson ([ordered]@{ status = 'not_started' })
    return
}

$pending = Get-Content -Raw -LiteralPath $pendingPath | ConvertFrom-Json
if ([DateTimeOffset]::Parse([string]$pending.expiresAt) -le [DateTimeOffset]::UtcNow) {
    Remove-Item -LiteralPath $pendingPath -Force
    Write-CompactJson ([ordered]@{ status = 'expired' })
    return
}

$deviceCode = Unprotect-CogentSpecValue ([string]$pending.deviceCode)
$tokenBody = @{ deviceCode = $deviceCode } | ConvertTo-Json -Compress
try {
    $result = Invoke-RestMethod `
        -Method Post `
        -Uri "$serviceUrl/api/device-authorization/token" `
        -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json' } `
        -Body $tokenBody `
        -TimeoutSec $RequestTimeoutSeconds
} catch {
    $statusCode = [int]$_.Exception.Response.StatusCode
    if ($statusCode -eq 410) {
        Remove-Item -LiteralPath $pendingPath -Force
        Write-CompactJson ([ordered]@{ status = 'expired' })
        return
    }
    throw
}

if ([string]$result.status -eq 'authorization_pending') {
    Write-CompactJson ([ordered]@{
        status = 'approval_pending'
        expiresAt = [string]$pending.expiresAt
        pollAfterSeconds = [int]$pending.intervalSeconds
    })
    return
}

if ([string]$result.status -ne 'authorized' -or -not $result.token -or -not $result.browserCode) {
    throw 'CogentSpec returned an incomplete Desktop authorization.'
}

Save-CogentSpecCredential $result
Remove-Item -LiteralPath $pendingPath -Force

$workspaceUrl = "$workspaceOrigin/stack?surface=$([Uri]::EscapeDataString($Surface))#desktop=$([Uri]::EscapeDataString([string]$result.browserCode))"
Write-CompactJson ([ordered]@{
    status = 'authorized'
    email = [string]$result.subscriber.email
    plan = [string]$result.subscriber.plan
    replacedExistingDevice = [bool]$result.replacedExistingDevice
    workspaceUrl = $workspaceUrl
})
