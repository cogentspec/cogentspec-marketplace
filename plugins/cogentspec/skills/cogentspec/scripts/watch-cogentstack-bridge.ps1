[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContextKey,
    [Parameter(Mandatory = $true)][ValidateSet('cogentspec', 'cogentstack')][string]$PluginId,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$PluginVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
}

$serviceUrl = 'https://cogentspec.com'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$credentialPath = Join-Path $stateRoot 'desktop-credential.json'
$contextQuery = "context=$([Uri]::EscapeDataString($ContextKey))&pluginId=$([Uri]::EscapeDataString($PluginId))&pluginVersion=$([Uri]::EscapeDataString($PluginVersion))"
$contextHashAlgorithm = [Security.Cryptography.SHA256]::Create()
try {
    $contextHashBytes = $contextHashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($ContextKey))
} finally {
    $contextHashAlgorithm.Dispose()
}
$contextHash = ([BitConverter]::ToString($contextHashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$mutex = New-Object Threading.Mutex($false, "Local\CogentSpecBridge-$contextHash")
$ownsMutex = $false

function Unprotect-CogentSpecValue([string]$Value) {
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-DesktopToken {
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { return '' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    if (-not $credential.token) { return '' }
    return Unprotect-CogentSpecValue ([string]$credential.token)
}

function Invoke-BridgeApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$serviceUrl$Path"
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 20
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 6 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Invoke-ActionHelper($Request) {
    $scriptName = switch ([string]$Request.action) {
        'create_specification' { 'create-specification-project.ps1' }
        'delete_specification' { 'delete-specification-project.ps1' }
        'create_project' { 'fulfil-project.ps1' }
        'delete_project' { 'delete-project.ps1' }
        'preview_project' { 'generate-project-preview.ps1' }
        'refresh_project_git' { 'inspect-project-git.ps1' }
        'save_project_git' { 'save-project-version.ps1' }
        'restore_project_version' { 'restore-project-version.ps1' }
        default { throw "Unsupported Desktop Bridge action: $($Request.action)" }
    }
    $helperPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw "Desktop Bridge helper is missing: $scriptName" }
    $powershellCommand = Get-Command powershell.exe, pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $powershellCommand) { throw 'Windows PowerShell is required by Desktop Bridge.' }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helperPath)
    switch ([string]$Request.action) {
        'create_specification' { $arguments += @('-Mode', 'create', '-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'delete_specification' { $arguments += @('-Mode', 'delete', '-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'create_project' { $arguments += @('-Mode', 'create', '-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'delete_project' { $arguments += @('-Mode', 'delete', '-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'preview_project' { $arguments += @('-Mode', 'generate', '-ContextKey', $ContextKey) }
        'refresh_project_git' { $arguments += @('-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'save_project_git' { $arguments += @('-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
        'restore_project_version' { $arguments += @('-RequestId', [string]$Request.targetRequestId, '-ContextKey', $ContextKey) }
    }

    $output = @(& ([string]$powershellCommand.Source) @arguments 2>&1)
    $jsonLine = @($output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $jsonLine) { throw "Desktop Bridge helper returned no result for $($Request.action)." }
    $result = $jsonLine | ConvertFrom-Json
    $acceptedStatuses = switch ([string]$Request.action) {
        'create_specification' { @('specification_created') }
        'delete_specification' { @('deleted') }
        'create_project' { @('created') }
        'delete_project' { @('deleted') }
        'preview_project' { @('generated', 'already_running') }
        'refresh_project_git' { @('refreshed') }
        'save_project_git' { @('saved') }
        'restore_project_version' { @('restored') }
    }
    if ([string]$result.status -notin $acceptedStatuses) {
        $reason = if ($result.reason) { [string]$result.reason } elseif ($result.status) { [string]$result.status } else { 'unknown_failure' }
        if ([string]$Request.action -eq 'preview_project') { throw $reason }
        throw "Desktop Bridge could not complete $($Request.action): $reason"
    }
    if ([string]$Request.action -eq 'preview_project' -and $result.localUrl) {
        Start-Process ([string]$result.localUrl)
    }
    return $result
}

try {
    $ownsMutex = $mutex.WaitOne(0)
    if (-not $ownsMutex) { exit 0 }
    while ($true) {
        $token = Get-DesktopToken
        if (-not $token) { break }
        try {
            $listing = Invoke-BridgeApi -Method Get -Path "/api/plugin/desktop-actions?$contextQuery" -Token $token
            if (-not $listing.request) {
                Start-Sleep -Seconds 2
                continue
            }
            $request = $listing.request
            try {
                $claimed = Invoke-BridgeApi -Method Patch -Path "/api/plugin/desktop-actions?$contextQuery" -Token $token -Body @{
                    action = 'claim'
                    requestId = [string]$request.id
                }
            } catch {
                $claimStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($claimStatus -eq 409) { Start-Sleep -Milliseconds 500; continue }
                throw
            }

            try {
                $result = Invoke-ActionHelper $claimed.request
                $summary = switch ([string]$claimed.request.action) {
                    'create_specification' { 'Specification project folder created and verified.' }
                    'delete_specification' { 'Specification draft, folder, and saved state deleted.' }
                    'create_project' { 'Project foundation created and verified.' }
                    'delete_project' { 'Project, folder, and linked CogentSpec state deleted.' }
                    'preview_project' { "Verified project preview opened at $([string]$result.localUrl)" }
                    'refresh_project_git' { 'Project check completed.' }
                    'save_project_git' { 'Version saved on this computer.' }
                    'restore_project_version' { 'Selected version restored and saved as a new version.' }
                }
                Invoke-BridgeApi -Method Patch -Path "/api/plugin/desktop-actions?$contextQuery" -Token $token -Body @{
                    action = 'complete'
                    requestId = [string]$claimed.request.id
                    statusMessage = $summary
                } | Out-Null
            } catch {
                $failure = $_.Exception.Message
                try {
                    Invoke-BridgeApi -Method Patch -Path "/api/plugin/desktop-actions?$contextQuery" -Token $token -Body @{
                        action = 'fail'
                        requestId = [string]$claimed.request.id
                        statusMessage = $failure
                    } | Out-Null
                } catch { }
            }
        } catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -eq 401 -or $statusCode -eq 403) { break }
            Start-Sleep -Seconds 5
        }
    }
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
