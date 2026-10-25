[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$RequestId,
    [Parameter(Mandatory=$true)][ValidateSet('$gptweb','$claudeweb')][string]$Command,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$Revision,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ManifestSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSVersion.Major -le 5){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$timer=[Diagnostics.Stopwatch]::StartNew();$installed=$false;$lock=$null;$locked=$false
function Remaining {if($timer.Elapsed.TotalSeconds -gt 120){throw 'setup_timeout'}}
function Plain([string]$Path){
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'unsafe_runtime_path'}}
        $parent=Split-Path -Parent $cursor;if(-not $parent -or $parent -eq $cursor){break};$cursor=$parent
    }
}
function Verify([string]$Directory){
    Plain $Directory
    $manifest=Join-Path $Directory 'manifest.json'
    if((Get-Item -LiteralPath $manifest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'runtime_integrity_failed'}
    if((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestSha256){throw 'runtime_integrity_failed'}
    $data=Get-Content -Raw -LiteralPath $manifest|ConvertFrom-Json
    if($data.protocol -cne 'cogentspec-web-runtime-v1' -or $data.version -cne '1.0.0' -or $data.commands.Count -ne 2 -or
        $data.commands[0] -cne '$gptweb' -or $data.commands[1] -cne '$claudeweb'){throw 'runtime_integrity_failed'}
    $allowed=@('manifest.json')
    foreach($file in $data.files.PSObject.Properties){
        if($file.Name -cnotmatch '^runtime/[a-z0-9-]+\.(ps1|mjs)$' -or [string]$file.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'runtime_integrity_failed'}
        $path=Join-Path $Directory $file.Name;Plain (Split-Path -Parent $path)
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.Value){throw 'runtime_integrity_failed'}
        $allowed+=$file.Name
    }
    $actual=@()
    foreach($item in Get-ChildItem -LiteralPath $Directory -Force){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'runtime_integrity_failed'}
        if($item.PSIsContainer){if($item.Name -cne 'runtime'){throw 'runtime_integrity_failed'}
            foreach($child in Get-ChildItem -LiteralPath $item.FullName -Force){
                if($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'runtime_integrity_failed'}
                $actual+='runtime/'+$child.Name
            }
        }else{$actual+=$item.Name}
    }
    if(@(Compare-Object @($allowed|Sort-Object) @($actual|Sort-Object)).Count){throw 'runtime_integrity_failed'}
}
try{
    if($env:OS -ne 'Windows_NT'){throw 'windows_execution_required'}
    $root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\web-command-v1\packages'
    Plain $root;[void][IO.Directory]::CreateDirectory($root)
    $destination=Join-Path $root $ManifestSha256
    $lock=New-Object Threading.Mutex($false,('Local\CogentSpecWebInstallV1-'+$ManifestSha256))
    $locked=$lock.WaitOne(15000);if(-not $locked){throw 'setup_busy'}
    if(-not (Test-Path -LiteralPath $destination)){
        $stage=Join-Path $root ('stage-'+[Guid]::NewGuid().ToString('N'));Plain $stage
        [void][IO.Directory]::CreateDirectory((Join-Path $stage 'runtime'))
        $source='https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+$Revision+'/web-bridge/v1/'
        $manifest=Join-Path $stage 'manifest.json'
        Invoke-WebRequest -UseBasicParsing -Uri ($source+'manifest.json') -OutFile $manifest -MaximumRedirection 0 -TimeoutSec 10
        if((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestSha256){throw 'runtime_integrity_failed'}
        $data=Get-Content -Raw -LiteralPath $manifest|ConvertFrom-Json
        foreach($file in $data.files.PSObject.Properties){
            Remaining
            if($file.Name -cnotmatch '^runtime/[a-z0-9-]+\.(ps1|mjs)$' -or [string]$file.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'runtime_integrity_failed'}
            Invoke-WebRequest -UseBasicParsing -Uri ($source+$file.Name) -OutFile (Join-Path $stage $file.Name) -MaximumRedirection 0 -TimeoutSec 10
        }
        Verify $stage
        if(-not ([IO.Path]::GetFullPath($stage)).StartsWith([IO.Path]::GetFullPath($root)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe_runtime_path'}
        Move-Item -LiteralPath $stage -Destination $destination;$installed=$true
    }
    Verify $destination;Remaining
    # Release the install lock before the bounded page handshake.
    $lock.ReleaseMutex();$locked=$false
    $reply=& (Join-Path $destination 'runtime\connect-web.ps1') -RequestId $RequestId -Command $Command
    $result=$reply|ConvertFrom-Json
    $result|Add-Member -NotePropertyName runtimeInstalled -NotePropertyValue $installed -Force
    $result|ConvertTo-Json -Depth 5 -Compress
}catch{
    [ordered]@{protocol='cogentspec-web-command-v1';status='not_connected';reason='setup_failed';
        userMessage='The Git marketplace Web helper could not be installed or verified. No unverified helper was started.';
        runtimeInstalled=$installed;pluginInstalled=$false;workspaceConnected=$false;acknowledgementVerified=$false;browserOpened=$false;browserControlled=$false}|ConvertTo-Json -Compress
}finally{if($locked){$lock.ReleaseMutex()};if($lock){$lock.Dispose()}}
