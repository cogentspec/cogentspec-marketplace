[CmdletBinding()]
param(
    [ValidateSet('chatgpt')]
    [string]$Surface = 'chatgpt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

function Compare-CogentSpecVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    if ($Left -notmatch '^\d+\.\d+\.\d+$' -or $Right -notmatch '^\d+\.\d+\.\d+$') {
        throw 'CogentSpec returned an invalid package version.'
    }
    $leftParts = @($Left.Split('.') | ForEach-Object { [int]$_ })
    $rightParts = @($Right.Split('.') | ForEach-Object { [int]$_ })
    for ($index = 0; $index -lt 3; $index++) {
        if ($leftParts[$index] -lt $rightParts[$index]) { return -1 }
        if ($leftParts[$index] -gt $rightParts[$index]) { return 1 }
    }
    return 0
}

try {
    $pluginRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
    $manifestPath = Join-Path $pluginRoot '.codex-plugin\plugin.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'CogentSpec package identity is missing.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $pluginId = [string]$manifest.name
    $installedVersion = [string]$manifest.version
    if ($pluginId -notin @('cogentspec', 'cogentstack') -or $installedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'CogentSpec package identity is invalid.'
    }

    $serviceUrl = 'https://cogentspec.com'
    if ($env:COGENTSPEC_UPDATE_TEST_MODE -eq '1' -and $env:COGENTSPEC_UPDATE_TEST_SERVICE_URL -match '^http://127\.0\.0\.1:\d+$') {
        $serviceUrl = $env:COGENTSPEC_UPDATE_TEST_SERVICE_URL
    }
    $endpoint = "$serviceUrl/api/plugin-version?surface=$([Uri]::EscapeDataString($Surface))&pluginId=$([Uri]::EscapeDataString($pluginId))"
    $release = Invoke-RestMethod -Method Get -Uri $endpoint -Headers @{ Accept = 'application/json' } -TimeoutSec 10
    $expectedProtocolUrl = 'https://github.com/cogentspec/cogentspec-marketplace/blob/main/.agents/plugins/UPDATE.v1.md'
    $validRelease = [string]$release.protocol -eq 'cogentspec-plugin-release-v1' -and
        [string]$release.surface -eq $Surface -and
        [string]$release.pluginId -eq $pluginId -and
        [string]$release.updateProtocolUrl -eq $expectedProtocolUrl
    if (-not $validRelease) {
        throw 'CogentSpec returned an invalid update description.'
    }
    $availableVersion = [string]$release.availableVersion
    $comparison = Compare-CogentSpecVersion -Left $installedVersion -Right $availableVersion
    Write-CompactJson ([ordered]@{
        protocol = 'cogentspec-update-check-v1'
        status = if ($comparison -lt 0) { 'update_available' } else { 'current' }
        pluginId = $pluginId
        installedVersion = $installedVersion
        availableVersion = $availableVersion
        updateRequired = $comparison -lt 0
        updateProtocolUrl = $expectedProtocolUrl
    })
} catch {
    Write-CompactJson ([ordered]@{
        protocol = 'cogentspec-update-check-v1'
        status = 'check_unavailable'
        updateRequired = $false
        exactReason = [string]$_.Exception.Message
    })
}

