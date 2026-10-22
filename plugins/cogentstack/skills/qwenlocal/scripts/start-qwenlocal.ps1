[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Uri)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# The browser may inherit a different PowerShell host's module path. Use the
# built-in Windows modules for this process only; never change system policy.
if ($PSVersionTable.PSVersion.Major -le 5) { $env:PSModulePath = Join-Path $PSHOME 'Modules' }
. (Join-Path $PSScriptRoot 'prepare-qwen-runtime.ps1')
try {
    $root = Split-Path -Parent $PSScriptRoot
    $manifest = Assert-CogentQwenPackage $root
    if ($Uri -cnotmatch '^cogentspec-browser://qwenlocal/([a-f0-9]{64})$') { throw 'Invalid Qwen browser command.' }
    $ticket = $Matches[1]
    $node = Get-CogentQwenNode
    $reply = Invoke-RestMethod -Method Post -Uri 'https://cogentspec.app/api/qwen/command/claim' -MaximumRedirection 0 -TimeoutSec 10 -ContentType 'application/json' -Body (@{ticket=$ticket}|ConvertTo-Json -Compress)
    $ticket = ''; $Uri = ''
    if ($reply.command -cne '$qwenlocal' -or $reply.source -cne $manifest.source -or $reply.version -cne $manifest.version -or $reply.context -cnotmatch '^ctx-[a-f0-9]{64}$' -or $reply.code -cnotmatch '^[a-f0-9]{32}$' -or $reply.project -cnotmatch '^[a-zA-Z]:\\' -or $reply.project.Length -gt 400) { throw 'The Qwen command request could not be verified.' }
    $state = Join-Path $env:LOCALAPPDATA 'CogentSpec\browser-commands\state'
    Assert-CogentQwenDirectPath $state
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $id = [Guid]::NewGuid().ToString('N')
    $config = Join-Path $state ($id + '.json')
    [IO.File]::WriteAllText($config, (@{project=$reply.project;context=$reply.context;code=$reply.code;managed=$true}|ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    $env:PATH = (Split-Path -Parent $node) + ';' + $env:PATH
    $module = Join-Path $PSScriptRoot 'qwen-runtime.mjs'
    # Ticket/code are never command-line arguments or log output. The native
    # process consumes and deletes its one-use configuration before listening.
    $arguments = @(('"' + $module + '"'), '--launch-config', ('"' + $config + '"'))
    Start-Process -FilePath $node -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $state ($id + '.out.log')) -RedirectStandardError (Join-Path $state ($id + '.error.log')) | Out-Null
} catch {
    # No credentials, handoff URI, project source or raw network errors in logs.
    Write-Error 'Qwen could not connect. Return to Qwen setup to check its installed browser command.' -ErrorAction Continue
    exit 1
}
