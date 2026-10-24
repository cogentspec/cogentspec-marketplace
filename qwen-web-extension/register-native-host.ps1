[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-p]{32}$')][string]$ExtensionId,
    [Parameter(Mandatory)][string]$PluginRoot,
    [ValidateSet('Chrome','Edge')][string]$Browser = 'Chrome',
    [switch]$Update
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PluginRoot).Path
$manifestPath = @((Join-Path $package '.codex-plugin\plugin.json'),(Join-Path $package '.claude-plugin\plugin.json')) | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if (-not $manifestPath) { throw 'Choose the installed CogentSpec plugin root.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.name -notin @('cogentspec','cogentstack')) { throw 'Invalid CogentSpec package identity.' }
$helper = (Resolve-Path -LiteralPath (Join-Path $package 'skills\qwenweb\scripts\start-qwenweb.ps1')).Path
$candidates = if ($Browser -eq 'Chrome') {
    @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
} else { @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe","${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") }
$browserPath = $candidates | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if (-not $browserPath) { throw 'The selected browser executable was not found.' }
$signature = Get-AuthenticodeSignature -LiteralPath $browserPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $(if($Browser -eq 'Chrome'){'O=Google LLC'}else{'O=Microsoft Corporation'})) { throw 'The selected browser signature could not be verified.' }
$taskRoot = Join-Path $env:LOCALAPPDATA 'CogentSpec\qwen-web'
$origin = "chrome-extension://$ExtensionId/"
$registration = Join-Path $taskRoot 'registration.json'
if (Test-Path -LiteralPath $registration) {
    $existing=Get-Content -LiteralPath $registration -Raw | ConvertFrom-Json
    if ($existing.origin -cne $origin -or $existing.browserPath -ine $browserPath) { throw 'Another connector owns this registration. Remove it explicitly before replacing it.' }
    if (-not $Update) { throw 'Already registered. Use -Update explicitly to refresh the pinned helper.' }
}
[void](New-Item -ItemType Directory -Path $taskRoot -Force)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe=Join-Path $taskRoot ('cogentspec-qwen-web-'+[Guid]::NewGuid().ToString('N')+'.exe')
& $compiler /nologo /target:exe "/out:$exe" /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'NativeHost.cs')
if ($LASTEXITCODE -ne 0) {throw 'Qwen Web native connector compilation failed.'}
@{origin=$origin;browserPath=$browserPath;helperPath=$helper;helperSha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content -LiteralPath $registration -Encoding UTF8
$hostManifest=Join-Path $taskRoot 'com.cogentspec.qwen_web.json'
@{name='com.cogentspec.qwen_web';description='CogentSpec Qwen Web command connector';path=$exe;type='stdio';allowed_origins=@($origin)} | ConvertTo-Json | Set-Content -LiteralPath $hostManifest -Encoding UTF8
$vendor=if($Browser -eq 'Chrome'){'Google\Chrome'}else{'Microsoft\Edge'}
$registry="HKCU:\Software\$vendor\NativeMessagingHosts\com.cogentspec.qwen_web"
[void](New-Item -Path $registry -Force)
Set-Item -LiteralPath $registry -Value $hostManifest
@{status='registered';browser=$Browser;extensionId=$ExtensionId;credentialsRead=$false;browserOpened=$false} | ConvertTo-Json -Compress
