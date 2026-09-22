[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-McpConnectionTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\ensure-cogentspec-mcp.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("cogentspec-mcp-connection-" + [Guid]::NewGuid().ToString('N'))
$fakeCodex = Join-Path $fixtureRoot 'codex-fixture.ps1'
$authorizationState = Join-Path $fixtureRoot 'authorized.txt'
$originalCodexPath = $env:CODEX_CLI_PATH
$originalStatePath = $env:COGENTSPEC_MCP_TEST_STATE

try {
    [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$commandLine = $Arguments -join ' '
if ($commandLine -eq 'mcp list') {
    $auth = if (Test-Path -LiteralPath $env:COGENTSPEC_MCP_TEST_STATE) { 'OAuth' } else { 'Not logged in' }
    "cogentspec           https://cogentspec.com/mcp         -                     enabled  $auth"
    exit 0
}
if ($commandLine -eq 'mcp login cogentspec') {
    'authorized' | Set-Content -LiteralPath $env:COGENTSPEC_MCP_TEST_STATE -Encoding ascii
    'Successfully connected CogentSpec.'
    exit 0
}
exit 1
'@ | Set-Content -LiteralPath $fakeCodex -Encoding UTF8

    $env:CODEX_CLI_PATH = $fakeCodex
    $env:COGENTSPEC_MCP_TEST_STATE = $authorizationState

    $first = @(& $helper -Surface chatgpt 2>&1) | Select-Object -Last 1 | ConvertFrom-Json
    Assert-McpConnectionTest ([string]$first.status -eq 'ready') 'The first connection did not become ready.'
    Assert-McpConnectionTest ([string]$first.connection -eq 'authorized') 'The first connection did not complete authorization.'
    Assert-McpConnectionTest (Test-Path -LiteralPath $authorizationState -PathType Leaf) 'The authorization command was not invoked.'
    Assert-McpConnectionTest ([string]$first.userMessage -eq 'CogentSpec is ready.') 'The first user message was not plain language.'

    $second = @(& $helper -Surface chatgpt 2>&1) | Select-Object -Last 1 | ConvertFrom-Json
    Assert-McpConnectionTest ([string]$second.status -eq 'ready') 'The existing connection did not remain ready.'
    Assert-McpConnectionTest ([string]$second.connection -eq 'already_connected') 'The existing connection tried to authorize again.'
    Assert-McpConnectionTest ([string]$second.userMessage -notmatch 'MCP|OAuth|plugin|tool') 'The user message exposed an implementation detail.'

    [ordered]@{
        status = 'valid'
        firstConnection = [string]$first.connection
        repeatedConnection = [string]$second.connection
        userMessage = [string]$second.userMessage
    } | ConvertTo-Json -Compress
} finally {
    if ($null -eq $originalCodexPath) { Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue } else { $env:CODEX_CLI_PATH = $originalCodexPath }
    if ($null -eq $originalStatePath) { Remove-Item Env:\COGENTSPEC_MCP_TEST_STATE -ErrorAction SilentlyContinue } else { $env:COGENTSPEC_MCP_TEST_STATE = $originalStatePath }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
