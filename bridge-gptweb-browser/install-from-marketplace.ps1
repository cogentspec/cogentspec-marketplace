# Run once with the immutable revision and inventory hash supplied by the
# CogentSpec marketplace. This installs only the GPTWeb browser transport.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$Revision,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$InventorySha256)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$origin='https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+$Revision+'/bridge-gptweb-browser/'
$stage=Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-gptweb-marketplace-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $stage
function Get-VerifiedFile([string]$Relative,[string]$Digest) {
    if($Relative -cnotmatch '^[a-zA-Z0-9_./-]+$' -or $Relative.Contains('..') -or [IO.Path]::IsPathRooted($Relative)){throw 'Invalid GPTWeb artifact path.'}
    $target=Join-Path $stage $Relative
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
    Invoke-WebRequest -UseBasicParsing -Uri ($origin+$Relative) -MaximumRedirection 0 -TimeoutSec 20 -OutFile $target
    if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Digest){throw 'GPTWeb marketplace download failed its integrity check.'}
}
try {
    Get-VerifiedFile 'files.sha256' $InventorySha256
    foreach($line in (Get-Content -LiteralPath (Join-Path $stage 'files.sha256'))){
        if($line -cnotmatch '^([a-f0-9]{64})  ([a-zA-Z0-9_./-]+)$'){throw 'Invalid GPTWeb artifact inventory.'}
        Get-VerifiedFile $Matches[2] $Matches[1]
    }
    & (Join-Path $stage 'install.ps1')
} finally {
    # Resolve and check this exact generated directory before recursive cleanup.
    $full=[IO.Path]::GetFullPath($stage)
    if([IO.Path]::GetDirectoryName($full) -ceq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and
        [IO.Path]::GetFileName($full).StartsWith('cogentspec-gptweb-marketplace-',[StringComparison]::Ordinal)){
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
