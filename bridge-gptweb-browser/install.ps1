# One-time setup of the browser transport inside the existing CogentSpec
# marketplace installation. No account replacement, worker startup or app UI.
[CmdletBinding()]
param([switch]$CheckOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-PlainPath([string]$Path) {
    for ($current=[IO.Path]::GetFullPath($Path); $current; $current=[IO.Path]::GetDirectoryName($current)) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'GPTWeb setup cannot use linked paths.' }
        }
    }
}
$manifestPath=Join-Path $PSScriptRoot 'files.sha256'
$manifest=Get-Content -LiteralPath $manifestPath
if (-not $manifest.Count) { throw 'GPTWeb source inventory is missing.' }
foreach ($line in $manifest) {
    if ($line -cnotmatch '^([a-f0-9]{64})  ([a-zA-Z0-9_./-]+)$') { throw 'Invalid GPTWeb source inventory.' }
    $expected=$Matches[1];$relative=$Matches[2]
    if ($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)) { throw 'Invalid GPTWeb source path.' }
    $path=Join-Path $PSScriptRoot $relative
    Assert-PlainPath $path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw 'GPTWeb marketplace source integrity check failed.' }
    if ([IO.Path]::GetExtension($path) -ceq '.ps1') {
        $parseTokens=$null;$parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$parseTokens,[ref]$parseErrors)
        if ($parseErrors) { throw ('GPTWeb marketplace script syntax check failed: '+$relative) }
    }
}
if ($CheckOnly) { @{status='verified';command='$gptweb';workerStarted=$false}|ConvertTo-Json -Compress;return }
$credentialPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'Complete the existing CogentSpec account/device setup before enabling GPTWeb on this PC.' }
$digest=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$base=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\gptweb-browser-host'
$target=Join-Path $base $digest
Assert-PlainPath $target
$key='HKCU:\Software\Classes\cogentspec-gptweb'
$old=Get-ItemProperty -LiteralPath ($key+'\shell\open\command') -ErrorAction SilentlyContinue
if ($old -and -not ([string]$old.'(default)').StartsWith('"'+$base+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The GPTWeb browser handler belongs to another installation; it was not replaced.'
}
$null=New-Item -ItemType Directory -Path $target -Force
foreach ($line in $manifest) {
    $relative=$line.Substring(66);$destination=Join-Path $target $relative
    Assert-PlainPath $destination
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $destination -Force
}
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $target 'files.sha256') -Force
$executable=Join-Path $target 'GPTWebBrowserHost.exe'
Assert-PlainPath $executable
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows C# compiler required for the GPTWeb background handler is unavailable.' }
$output=& $compiler /nologo /target:winexe ("/out:"+$executable) (Join-Path $target 'GptWebBrowserHost.cs') 2>&1
if ($LASTEXITCODE -ne 0) { throw ('GPTWeb handler compilation failed: '+($output -join ' ')) }
$null=New-Item -Path ($key+'\shell\open\command') -Force
Set-Item -LiteralPath $key -Value 'URL:CogentSpec GPTWeb browser connection'
$null=New-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value '' -PropertyType String -Force
Set-Item -LiteralPath ($key+'\shell\open\command') -Value ('"'+$executable+'" "%1"')
@{status='installed';command='$gptweb';protocol='cogentspec-gptweb';workerStarted=$false;browserOpened=$false;accountChanged=$false}|ConvertTo-Json -Compress
