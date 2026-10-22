[CmdletBinding()]
param([switch]$RegisterBrowserCommand, [switch]$ValidateOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required for the browser command registration.' }
. (Join-Path $PSScriptRoot 'prepare-qwen-runtime.ps1')
$sourceRoot = Split-Path -Parent $PSScriptRoot
$manifest = Assert-CogentQwenPackage $sourceRoot
if ($ValidateOnly) { [ordered]@{status='validated';command='$qwenlocal';source=$manifest.source;version=$manifest.version}|ConvertTo-Json -Compress; return }
if (-not $RegisterBrowserCommand) { throw 'Explicit browser command registration approval is required.' }
$node = Get-CogentQwenNode -Prepare
$root = Join-Path $env:LOCALAPPDATA 'CogentSpec\browser-commands'
$destination = Join-Path $root $manifest.version
Assert-CogentQwenDirectPath $destination
$registry = 'HKCU:\Software\Classes\cogentspec-browser'
if (Test-Path -LiteralPath $registry) {
    $existing = (Get-Item -LiteralPath $registry).GetValue('')
    $existingCommand = (Get-Item -LiteralPath "$registry\shell\open\command" -ErrorAction Stop).GetValue('')
    if ($existing -cne 'URL:CogentSpec browser commands' -or -not $existingCommand.Contains($root)) { throw 'An unrelated browser protocol registration exists. It was not replaced.' }
}
if (Test-Path -LiteralPath $destination) { $null = Assert-CogentQwenPackage $destination }
else {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $stage = Join-Path $root ('staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null
    foreach ($relative in @('command.json') + @($manifest.files.PSObject.Properties.Name)) { Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination (Join-Path $stage $relative) }
    $null = Assert-CogentQwenPackage $stage
    Move-Item -LiteralPath $stage -Destination $destination
}
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$entrypoint = Join-Path $destination 'scripts\start-qwenlocal.ps1'
$command = '"' + $powershell + '" -NoProfile -WindowStyle Hidden -File "' + $entrypoint + '" -Uri "%1"'
New-Item -Path "$registry\shell\open\command" -Force | Out-Null
Set-Item -LiteralPath $registry -Value 'URL:CogentSpec browser commands'
New-ItemProperty -LiteralPath $registry -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
Set-Item -LiteralPath "$registry\shell\open\command" -Value $command
[ordered]@{status='installed';command='$qwenlocal';source=$manifest.source;version=$manifest.version;browserCommandRegistered=$true;runtimeReady=$true;legacyDesktopUsed=$false}|ConvertTo-Json -Compress
