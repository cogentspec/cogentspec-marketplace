[CmdletBinding()]
param(
    [ValidateSet('cogentspec', 'cogentstack')]
    [string]$PluginId = 'cogentspec',

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$PluginVersion,

    [string]$ReadyPath = '',

    [ValidateRange(250, 10000)]
    [int]$PollMilliseconds = 1500,

    [ValidateRange(1000, 60000)]
    [int]$MaximumRetryMilliseconds = 30000,

    [string]$ServiceUrl = 'https://cogentspec.com',

    [string]$TestToken = '',

    [string]$TestHelperPath = '',

    [ValidateRange(0, 100)]
    [int]$MaxPolls = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ReadyMarker([bool]$ServerAcknowledged, [string]$Status = 'ready', [string]$LastError = '') {
    if (-not $ReadyPath) { return }
    $parent = Split-Path -Parent $ReadyPath
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [ordered]@{
        processId = $PID
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        serverAcknowledged = $ServerAcknowledged
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
        status = $Status
        lastError = $LastError
    } | ConvertTo-Json | Set-Content -LiteralPath $ReadyPath -Encoding UTF8
}

function Unprotect-CogentSpecValue([string]$Value) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-DesktopUiApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = $ServiceUrl.TrimEnd('/') + $Path
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 12
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Compress
    }
    return Invoke-RestMethod @parameters
}

function Read-DesktopToken {
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'Desktop Bridge is not connected to an account.' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    return Unprotect-CogentSpecValue ([string]$credential.token)
}

function Get-HttpStatusCode($Failure) {
    $responseProperty = $Failure.Exception.PSObject.Properties['Response']
    if (-not $responseProperty -or $null -eq $responseProperty.Value) { return 0 }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if (-not $statusProperty -or $null -eq $statusProperty.Value) { return 0 }
    try { return [int]$statusProperty.Value } catch { return 0 }
}

if ($TestToken) {
    if ($ServiceUrl -notmatch '^https?://(localhost|127\.0\.0\.1)(:\d+)?$' -or -not $TestHelperPath) {
        throw 'Test tokens are restricted to a loopback service and an explicit helper.'
    }
    $token = $TestToken
    $desktopUiHelper = $TestHelperPath
} else {
    if ($ServiceUrl -ne 'https://cogentspec.com') { throw 'The production Desktop UI Bridge only connects to CogentSpec.' }
    $token = Read-DesktopToken
    $desktopUiHelper = Join-Path $PSScriptRoot 'open-chatgpt-desktop-ui.ps1'
}

if (-not (Test-Path -LiteralPath $desktopUiHelper -PathType Leaf)) { throw 'The verified ChatGPT Desktop UI helper is missing.' }
$query = '?pluginId=' + [Uri]::EscapeDataString($PluginId) + '&pluginVersion=' + [Uri]::EscapeDataString($PluginVersion)
$polls = 0
$consecutiveFailures = 0

try {
    while ($true) {
        try {
            $listing = Invoke-DesktopUiApi -Method Get -Path "/api/plugin/desktop-ui-actions$query" -Token $token
            $consecutiveFailures = 0
            Write-ReadyMarker -ServerAcknowledged $true -Status 'ready'
            $request = $listing.request
            if ($request) {
                $claimed = Invoke-DesktopUiApi -Method Patch -Path "/api/plugin/desktop-ui-actions$query" -Token $token -Body @{
                    requestId = [string]$request.id
                    action = 'claim'
                }
                if ($claimed.request) {
                    $completed = $false
                    $message = 'ChatGPT Desktop UI could not be opened.'
                    try {
                        $target = [string]$claimed.request.targetRequestId
                        if ($target -notin @('chatgpt-desktop-ui:connect', 'chatgpt-desktop-ui:update')) {
                            throw 'Desktop UI Bridge rejected an unsupported target.'
                        }
                        $helperOutput = @(& $desktopUiHelper -StartNewChat -PasteClipboard 2>&1)
                        $helperJson = @($helperOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
                        if (-not $helperJson) { throw 'The verified ChatGPT Desktop UI helper returned no result.' }
                        $result = $helperJson | ConvertFrom-Json
                        $completed = [string]$result.status -eq 'opened' -and [bool]$result.opened -and
                            [bool]$result.newChatStarted -and [bool]$result.composerPopulated -and -not [bool]$result.messageSubmitted
                        $message = if ($completed) {
                            if ($target -eq 'chatgpt-desktop-ui:update') {
                                'A new ChatGPT Desktop chat opened with the verified update request ready to send.'
                            } else {
                                'A new ChatGPT Desktop chat opened with $cogentspec ready to send.'
                            }
                        } elseif ($result.reason) { [string]$result.reason }
                        else { 'ChatGPT Desktop UI could not be opened safely.' }
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [void](Invoke-DesktopUiApi -Method Patch -Path "/api/plugin/desktop-ui-actions$query" -Token $token -Body @{
                        requestId = [string]$request.id
                        action = if ($completed) { 'complete' } else { 'fail' }
                        statusMessage = $message
                    })
                }
            }
        } catch {
            $consecutiveFailures++
            $statusCode = Get-HttpStatusCode -Failure $_
            $authorizationFailure = $statusCode -eq 401 -or $statusCode -eq 403
            $errorKind = if ($authorizationFailure) { 'authorization_failure' }
                elseif ($statusCode -gt 0) { "http_$statusCode" }
                else { 'transport_failure' }
            Write-ReadyMarker -ServerAcknowledged $false -Status 'retrying' -LastError $errorKind
            if ($authorizationFailure -and -not $TestToken) {
                try { $token = Read-DesktopToken } catch { }
            }
        }
        $polls++
        if ($MaxPolls -gt 0 -and $polls -ge $MaxPolls) { break }
        $retryExponent = [Math]::Min(5, [Math]::Max(0, $consecutiveFailures - 1))
        $retryMilliseconds = if ($consecutiveFailures -gt 0) {
            [Math]::Min($MaximumRetryMilliseconds, [int]($PollMilliseconds * [Math]::Pow(2, $retryExponent)))
        } else { $PollMilliseconds }
        Start-Sleep -Milliseconds $retryMilliseconds
    }
} finally {
    $token = $null
}
