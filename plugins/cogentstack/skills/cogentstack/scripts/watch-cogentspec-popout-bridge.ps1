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

    [string]$ServiceUrl = 'https://cogentspec.com',

    [string]$TestToken = '',

    [string]$TestHelperPath = '',

    [ValidateRange(0, 100)]
    [int]$MaxPolls = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ReadyMarker([bool]$ServerAcknowledged) {
    if (-not $ReadyPath) { return }
    $parent = Split-Path -Parent $ReadyPath
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [ordered]@{
        processId = $PID
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        serverAcknowledged = $ServerAcknowledged
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
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

function Invoke-PopoutApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
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

if ($TestToken) {
    if ($ServiceUrl -notmatch '^https?://(localhost|127\.0\.0\.1)(:\d+)?$' -or -not $TestHelperPath) {
        throw 'Test tokens are restricted to a loopback service and an explicit helper.'
    }
    $token = $TestToken
    $popupHelper = $TestHelperPath
} else {
    if ($ServiceUrl -ne 'https://cogentspec.com') { throw 'The production standalone Popout Bridge only connects to CogentSpec.' }
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'Desktop Bridge is not connected to an account.' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $token = Unprotect-CogentSpecValue ([string]$credential.token)
    $popupHelper = Join-Path $PSScriptRoot 'open-chatgpt-popup.ps1'
}

if (-not (Test-Path -LiteralPath $popupHelper -PathType Leaf)) { throw 'The verified ChatGPT Popout helper is missing.' }
$query = '?pluginId=' + [Uri]::EscapeDataString($PluginId) + '&pluginVersion=' + [Uri]::EscapeDataString($PluginVersion)
$polls = 0

try {
    while ($true) {
        try {
            $listing = Invoke-PopoutApi -Method Get -Path "/api/plugin/desktop-popout-actions$query" -Token $token
            Write-ReadyMarker -ServerAcknowledged $true
            $request = $listing.request
            if ($request) {
                $claimed = Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                    requestId = [string]$request.id
                    action = 'claim'
                }
                if ($claimed.request) {
                    $completed = $false
                    $message = 'The standalone ChatGPT Popout could not be opened.'
                    try {
                        $target = [string]$claimed.request.targetRequestId
                        if ($target -notin @('chatgpt-desktop-popup', 'chatgpt-desktop-popup:connect', 'chatgpt-desktop-popup:update')) {
                            throw 'Standalone Popout Bridge rejected an unsupported target.'
                        }
                        $composerRequired = $target -ne 'chatgpt-desktop-popup'
                        $helperOutput = if ($composerRequired) {
                            @(& $popupHelper -Mode open -UseRetainedChat -PasteClipboard 2>&1)
                        } else {
                            @(& $popupHelper -Mode open -UseRetainedChat 2>&1)
                        }
                        $helperJson = @($helperOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
                        if (-not $helperJson) { throw 'The verified ChatGPT Popout helper returned no result.' }
                        $result = $helperJson | ConvertFrom-Json
                        $completed = [string]$result.status -eq 'opened' -and [bool]$result.opened -and
                            (-not $composerRequired -or [bool]$result.composerPopulated)
                        $message = if ($completed) {
                            if ($composerRequired) { 'Standalone ChatGPT Popout opened with the composer filled.' }
                            else { 'Standalone ChatGPT Popout opened.' }
                        } elseif ($result.reason) { [string]$result.reason }
                        else { 'The standalone ChatGPT Popout could not be opened.' }
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [void](Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                        requestId = [string]$request.id
                        action = if ($completed) { 'complete' } else { 'fail' }
                        statusMessage = $message
                    })
                }
            }
        } catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -eq 401 -or $statusCode -eq 403) { break }
        }
        $polls++
        if ($MaxPolls -gt 0 -and $polls -ge $MaxPolls) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
} finally {
    $token = $null
}
