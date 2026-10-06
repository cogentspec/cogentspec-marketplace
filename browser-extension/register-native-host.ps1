[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-p]{32}$')][string]$ExtensionId,
    [ValidateSet('Chrome', 'Edge')][string]$Browser = 'Chrome'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Join-Path $env:LOCALAPPDATA 'CogentSpec\browser-lifecycle'
$origin = "chrome-extension://$ExtensionId/"
$processName = if ($Browser -eq 'Chrome') { 'chrome' } else { 'msedge' }
$registration = Join-Path $taskRoot 'registration.json'
if (Test-Path -LiteralPath $registration) {
    $previous = Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json
    if ($previous.origin -ne $origin -or $previous.processName -ne $processName) {
        throw 'A different browser/profile is registered. Unregister it explicitly before replacing its ownership.'
    }
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework compiler is unavailable.' }
[void](New-Item -ItemType Directory -Path $taskRoot -Force)
$exe = Join-Path $taskRoot 'cogentspec-browser-host-0.1.0.exe'
if (Test-Path -LiteralPath $exe) { throw 'Host 0.1.0 already exists. Do not overwrite a running host; inspect the existing installation.' }
& $compiler /nologo /target:exe "/out:$exe" /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'NativeHost.cs')
if ($LASTEXITCODE -ne 0) { throw 'Native host compilation failed.' }
@{origin=$origin; processName=$processName; version='0.1.0'} | ConvertTo-Json | Set-Content -LiteralPath $registration -Encoding UTF8
$hostManifest = Join-Path $taskRoot 'com.cogentspec.popout_lifecycle.json'
@{name='com.cogentspec.popout_lifecycle'; description='CogentSpec local workspace tab lifecycle'; path=$exe;
    type='stdio'; allowed_origins=@($origin)} | ConvertTo-Json | Set-Content -LiteralPath $hostManifest -Encoding UTF8
$registry = if ($Browser -eq 'Chrome') { 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.cogentspec.popout_lifecycle' }
    else { 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.cogentspec.popout_lifecycle' }
[void](New-Item -Path $registry -Force)
Set-Item -LiteralPath $registry -Value $hostManifest
@{status='registered'; browser=$Browser; extensionId=$ExtensionId; hostManifest=$hostManifest; credentialsRead=$false} | ConvertTo-Json
