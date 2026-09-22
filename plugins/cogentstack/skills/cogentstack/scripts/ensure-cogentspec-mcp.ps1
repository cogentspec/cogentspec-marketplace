[CmdletBinding()]
param(
    [ValidateSet('chatgpt', 'claude-desktop')]
    [string]$Surface = 'chatgpt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-command.ps1')

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

if ($Surface -ne 'chatgpt') {
    Write-CompactJson ([ordered]@{
        status = 'ready'
        connection = 'not_required'
        userMessage = 'CogentSpec is ready.'
    })
    return
}

$codexCommand = $null
if ($env:CODEX_CLI_PATH -and (Test-Path -LiteralPath $env:CODEX_CLI_PATH -PathType Leaf)) {
    $codexCommand = [string]$env:CODEX_CLI_PATH
} else {
    $resolvedCommand = @(Get-Command codex.cmd, codex.exe, codex -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($resolvedCommand) { $codexCommand = [string]$resolvedCommand.Source }
}

if (-not $codexCommand) {
    Write-CompactJson ([ordered]@{
        status = 'connection_required'
        connection = 'unavailable'
        userMessage = 'CogentSpec could not finish connecting. Restart Codex and run CogentSpec again.'
    })
    return
}

function Read-CogentSpecConnection {
    $result = Invoke-CogentSpecNativeCommand -FilePath $codexCommand -ArgumentList @('mcp', 'list')
    if ($result.ExitCode -ne 0) { return 'unavailable' }
    $line = @($result.Output -split "`r?`n" | Where-Object {
        $_ -match '^\s*cogentspec\s+https://cogentspec\.com/mcp\s+'
    } | Select-Object -Last 1)
    if (-not $line) { return 'unavailable' }
    if ($line -match '\sOAuth\s*$') { return 'connected' }
    if ($line -match '\sNot logged in\s*$') { return 'authorization_required' }
    return 'unavailable'
}

$connection = Read-CogentSpecConnection
if ($connection -eq 'connected') {
    Write-CompactJson ([ordered]@{
        status = 'ready'
        connection = 'already_connected'
        userMessage = 'CogentSpec is ready.'
    })
    return
}

if ($connection -eq 'authorization_required') {
    $login = Invoke-CogentSpecNativeCommand -FilePath $codexCommand -ArgumentList @('mcp', 'login', 'cogentspec')
    if ($login.ExitCode -eq 0 -and (Read-CogentSpecConnection) -eq 'connected') {
        Write-CompactJson ([ordered]@{
            status = 'ready'
            connection = 'authorized'
            userMessage = 'CogentSpec is ready.'
        })
        return
    }
}

Write-CompactJson ([ordered]@{
    status = 'connection_required'
    connection = 'authorization_incomplete'
    userMessage = 'CogentSpec needs permission to continue. Complete the connection window, then run CogentSpec again.'
})
