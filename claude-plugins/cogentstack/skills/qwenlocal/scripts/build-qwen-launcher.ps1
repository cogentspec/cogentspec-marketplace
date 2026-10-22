[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoked by the installer through fixed Windows PowerShell 5 without a console.
# PowerShell 7 does not support WindowsApplication compilation.
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'The Windows framework compiler is required.' }
$env:PSModulePath = Join-Path $PSHOME 'Modules'
. (Join-Path $PSScriptRoot 'prepare-qwen-runtime.ps1')
$root = Split-Path -Parent $PSScriptRoot
$null = Assert-CogentQwenPackage $root
$source = Join-Path $PSScriptRoot 'qwen-windowless-launcher.cs'
$output = Join-Path $root 'CogentSpec-Qwen-Launcher.exe'
$receipt = Join-Path $root 'launcher-integrity.json'
if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $receipt)) { throw 'Existing launcher files were not replaced.' }
Add-Type -Path $source -OutputAssembly $output -OutputType WindowsApplication
[IO.File]::WriteAllText($receipt, ([ordered]@{sourceSha256=(Get-CogentQwenHash $source -Text);executableSha256=(Get-CogentQwenHash $output)}|ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
$null = Assert-CogentQwenLauncher $root
