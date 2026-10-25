[CmdletBinding()]
param([ValidatePattern('^$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$RequestId = '')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$temporary=$null
try {
    if(-not $RequestId){throw 'copied_request_required'}
    if($env:OS -ne 'Windows_NT'){throw 'windows_execution_required'}
    $release=Invoke-RestMethod -Uri 'https://cogentspec.app/api/bridge/web/v1/release' -MaximumRedirection 0 -TimeoutSec 10
    if($release.protocol -cne 'cogentspec-web-release-v1' -or $release.repository -cne 'https://github.com/cogentspec/cogentspec-marketplace.git' -or
        $release.revision -cnotmatch '^[a-f0-9]{40}$' -or $release.manifestSha256 -cnotmatch '^[a-f0-9]{64}$' -or $release.bootstrapSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $release.commands.Count -ne 2 -or $release.commands[0] -cne '$gptweb' -or $release.commands[1] -cne '$claudeweb'){throw 'invalid_web_release'}
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-web-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+$release.revision+'/web-bridge/v1/bootstrap.ps1') -OutFile $temporary -MaximumRedirection 0 -TimeoutSec 10
    if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.bootstrapSha256){throw 'invalid_bootstrap_hash'}
    & $temporary -RequestId $RequestId -Command '$gptweb' -Revision $release.revision -ManifestSha256 $release.manifestSha256
} catch {
    [ordered]@{protocol='cogentspec-web-command-v1';status='not_connected';workspaceConnected=$false;acknowledgementVerified=$false;browserOpened=$false;browserControlled=$false;
        userMessage='GPTWeb could not verify and run its Git marketplace setup. Check that this AI session has permitted Windows execution.'}|ConvertTo-Json -Compress
} finally {if($temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -Force}}
