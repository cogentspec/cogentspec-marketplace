Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-CogentQwenDirectPath([string]$Target) {
    $cursor = [IO.Path]::GetFullPath($Target)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The browser command path contains a link.' }
        $next = Split-Path -Parent $cursor
        if ($next -eq $cursor) { break }; $cursor = $next
    }
}
function Get-CogentQwenHash([string]$Target, [switch]$Text) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        if ($Text) { $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Target).Replace("`r`n", "`n")) }
        else { $bytes = [IO.File]::ReadAllBytes($Target) }
        return ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $hasher.Dispose() }
}
function Get-CogentQwenNode([switch]$Prepare) {
    $version = '22.23.4'
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $hashes = @{ x64 = 'cbc74b5e0982c9dbb41525fd8fb5dcd32fbee237863f7829072f4639a1ce5f20'; arm64 = 'a8b8cd79cbbb3062435f449591d98dd63730bbbf30ce2d7cc3a6376c236cb111' }
    if (-not $hashes.ContainsKey($architecture) -or -not $env:LOCALAPPDATA) { throw 'Windows x64 or arm64 is required.' }
    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'CogentSpecBrowserRuntime'
    Assert-CogentQwenDirectPath $runtimeRoot
    $name = "node-v$version-win-$architecture"
    $nodeRoot = Join-Path $runtimeRoot $name
    $node = Join-Path $nodeRoot 'node.exe'
    Assert-CogentQwenDirectPath $node
    if (-not (Test-Path -LiteralPath $node)) {
        if (-not $Prepare) { throw 'Complete Qwen setup to prepare its background connection.' }
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($runtimeRoot))
        if ($drive.AvailableFreeSpace -lt 536870912) { throw 'At least 512 MiB free runtime storage is required, separately from model and project storage.' }
        New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        $download = Join-Path $runtimeRoot ('setup-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $download | Out-Null
        $archive = Join-Path $download ($name + '.zip')
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -Uri "https://nodejs.org/dist/v$version/$name.zip" -OutFile $archive
        if ((Get-CogentQwenHash $archive) -cne $hashes[$architecture]) { throw 'Official Node archive checksum mismatch. Nothing was executed.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $download)
        if (Test-Path -LiteralPath $nodeRoot) { throw 'An incomplete runtime exists and was not overwritten.' }
        $extracted = Join-Path $download $name
        Assert-CogentQwenDirectPath $extracted
        Move-Item -LiteralPath $extracted -Destination $nodeRoot
        Remove-Item -LiteralPath $archive
        Remove-Item -LiteralPath $download
    }
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    $signature = Get-AuthenticodeSignature -LiteralPath $node
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenJS Foundation') { throw 'Official Node publisher verification failed.' }
    if ((& $node --version) -cne "v$version" -or -not (Test-Path -LiteralPath (Join-Path $nodeRoot 'node_modules/npm/bin/npm-cli.js'))) { throw 'The verified Node/npm runtime is incomplete.' }
    return $node
}
function Assert-CogentQwenPackage([string]$Root) {
    Assert-CogentQwenDirectPath $Root
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'command.json') -Raw | ConvertFrom-Json
    if ($manifest.schema -cne 'cogentspec-git-command-v1' -or $manifest.command -cne '$qwenlocal' -or $manifest.version -cne '1.0.0' -or $manifest.source -cne 'https://github.com/cogentspec/cogentspec-marketplace.git') { throw 'Unrecognised Qwen command package.' }
    $required = @('SKILL.md', 'scripts/install-qwenlocal.ps1', 'scripts/prepare-qwen-runtime.ps1', 'scripts/start-qwenlocal.ps1', 'scripts/qwen-runtime.mjs')
    if (@($manifest.files.PSObject.Properties).Count -ne $required.Count) { throw 'The Qwen command manifest is incomplete.' }
    foreach ($relative in $required) {
        $entry = $manifest.files.PSObject.Properties[$relative]
        if (-not $entry -or $entry.Value -cnotmatch '^[a-f0-9]{64}$') { throw 'The Qwen command file is not verified.' }
        $full = Join-Path $Root $relative
        Assert-CogentQwenDirectPath $full
        if ((Get-CogentQwenHash $full -Text) -cne $entry.Value) { throw 'The installed Qwen command was modified. Update it through the trusted marketplace.' }
    }
    return $manifest
}
