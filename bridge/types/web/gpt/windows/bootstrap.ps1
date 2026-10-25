# GPTWeb native setup v1; separate from every AI plugin and legacy bootstrap.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [ValidatePattern('^$|^[a-f0-9-]{36}$')][string]$StartupRequest='',
    [switch]$PrepareOnly,
    [switch]$EnrollOnly,
    [switch]$ResumeApproval
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -le 5) { $env:PSModulePath=Join-Path $PSHOME 'Modules' }
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$clock=[Diagnostics.Stopwatch]::StartNew()
function Safe-Directory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while($cursor) {
        if(Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe_directory' }
        }
        $parent=Split-Path -Parent $cursor
        if(-not $parent -or $parent -eq $cursor) { break };$cursor=$parent
    }
    return $full
}
function Download([string]$Url,[string]$Path,[string]$Hash) {
    if($clock.ElapsedMilliseconds -ge 150000) { throw 'setup_timeout' }
    $request=[Net.HttpWebRequest]::Create($Url);$request.AllowAutoRedirect=$false;$request.Timeout=30000;$request.ReadWriteTimeout=30000
    $response=$request.GetResponse()
    try {
        if([int]$response.StatusCode -ne 200) { throw 'download_failed' }
        $input=$response.GetResponseStream();$output=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose();$input.Dispose() }
    } finally { $response.Dispose() }
    if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash) { throw 'download_hash_mismatch' }
}
try {
    if($env:OS -cne 'Windows_NT') { throw 'windows_required' }
    $release=Invoke-RestMethod -Uri 'https://cogentspec.app/api/bridge/gptweb/native-release' -MaximumRedirection 0 -TimeoutSec 10
    if($release.protocol -cne 'cogentspec-gptweb-native-release-v1' -or $release.runtimeRevision -cnotmatch '^[a-f0-9]{40}$' -or
        $release.runtimeManifestSha256 -cnotmatch '^[a-f0-9]{64}$' -or $release.command -cne '$gptweb') { throw 'invalid_release' }
    $root=Safe-Directory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\gptweb-native')
    [void][IO.Directory]::CreateDirectory($root)
    $packages=Safe-Directory (Join-Path $root 'packages');[void][IO.Directory]::CreateDirectory($packages)
    $package=Join-Path $packages $release.runtimeManifestSha256
    if(-not (Test-Path -LiteralPath $package)) {
        $temporary=Safe-Directory (Join-Path $packages ('stage-'+[Guid]::NewGuid().ToString('N')))
        [void][IO.Directory]::CreateDirectory((Join-Path $temporary 'scripts'))
        $base='https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+$release.runtimeRevision+'/bridge-runtime/gptweb/'
        Download ($base+'runtime.json') (Join-Path $temporary 'runtime.json') $release.runtimeManifestSha256
        $manifest=Get-Content -LiteralPath (Join-Path $temporary 'runtime.json') -Raw|ConvertFrom-Json
        if($manifest.protocol -cne 'cogentspec-standalone-web-runtime-v1' -or $manifest.command -cne '$gptweb' -or
            $manifest.pluginRequired -cne $false -or $manifest.codexRequired -cne $false) { throw 'invalid_package' }
        foreach($file in $manifest.files.PSObject.Properties) {
            if($file.Name -cnotmatch '^scripts/[a-z0-9-]+\.(ps1|mjs)$' -or [string]$file.Value -cnotmatch '^[a-f0-9]{64}$') { throw 'unsafe_package_file' }
            Download ($base+$file.Name) (Join-Path $temporary $file.Name.Replace('/','\')) ([string]$file.Value)
        }
        if(-not $manifest.files.PSObject.Properties['scripts/start-gptweb-native.ps1']) { throw 'native_entry_missing' }
        # Both resolved paths are direct children of the fixed package root.
        if((Split-Path -Parent (Safe-Directory $temporary)) -cne $packages -or (Split-Path -Parent ([IO.Path]::GetFullPath($package))) -cne $packages) { throw 'unsafe_promotion' }
        Move-Item -LiteralPath $temporary -Destination $package
    }
    $null=Safe-Directory $package
    $null=Safe-Directory (Join-Path $package 'scripts')
    $manifestPath=Join-Path $package 'runtime.json'
    if((Get-Item -LiteralPath $manifestPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'unsafe_manifest' }
    if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.runtimeManifestSha256) { throw 'manifest_changed' }
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    $expected=@('runtime.json')
    foreach($file in $manifest.files.PSObject.Properties) {
        if($file.Name -cnotmatch '^scripts/[a-z0-9-]+\.(ps1|mjs)$' -or [string]$file.Value -cnotmatch '^[a-f0-9]{64}$') { throw 'unsafe_package_file' }
        $path=Join-Path $package $file.Name.Replace('/','\');$item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.Value) { throw 'package_changed' }
        $expected+=$file.Name
    }
    $actual=@(Get-ChildItem -LiteralPath $package -File -Force|ForEach-Object{$_.Name})+@(Get-ChildItem -LiteralPath (Join-Path $package 'scripts') -File -Force|ForEach-Object{'scripts/'+$_.Name})
    foreach($item in @(Get-ChildItem -LiteralPath $package -Directory -Force)) {
        if($item.Name -cne 'scripts' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unexpected_package_directory' }
    }
    if(@(Get-ChildItem -LiteralPath (Join-Path $package 'scripts') -Directory -Force).Count) { throw 'unexpected_package_directory' }
    if(@(Compare-Object @($expected|Sort-Object) @($actual|Sort-Object)).Count) { throw 'unexpected_package_file' }
    $nodeRoot=Safe-Directory (Join-Path $root 'node\v22.23.2');[void][IO.Directory]::CreateDirectory($nodeRoot)
    $node=Join-Path $nodeRoot 'node.exe'
    $nodeHash='0d0f5e39f9f3d9587bc19f73eab3c2c9c4903fd02d6dbf9c853dd81b3d95fad4'
    if(-not (Test-Path -LiteralPath $node)) { Download 'https://nodejs.org/dist/v22.23.2/win-x64/node.exe' $node $nodeHash }
    if(((Get-Item -LiteralPath $node -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant() -cne $nodeHash) { throw 'node_changed' }
    $env:PATH=$nodeRoot+';'+$env:PATH
    if($PrepareOnly) { @{protocol='cogentspec-gptweb-native-v1';status='prepared';workspaceConnected=$false}|ConvertTo-Json -Compress;return }
    if($EnrollOnly) {
        & (Join-Path $package 'scripts\setup-gptweb-device.ps1') -ContextKey $ContextKey -ResumeApproval:$ResumeApproval
        return
    }
    if(-not $StartupRequest) { throw 'request_missing' }
    $arguments=@{ContextKey=$ContextKey;StartupRequest=$StartupRequest}
    if($ResumeApproval) { $arguments.ResumeApproval=$true }
    & (Join-Path $package 'scripts\start-gptweb-native.ps1') @arguments
} catch {
    @{protocol='cogentspec-gptweb-native-v1';status='not_ready';workspaceConnected=$false;browserOpened=$false;
        userMessage='GPTWeb could not verify or prepare its Windows helper. No AI plugin was installed and no existing worker was replaced.'}|ConvertTo-Json -Compress
}
