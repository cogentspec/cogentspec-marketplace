[CmdletBinding()]
param([Alias('Mode')][ValidateSet('Library','Run')][string]$ComputerMode='Library',[Alias('RequestId')][ValidatePattern('^[a-f0-9-]{36}$')][string]$SetupRequestId)
. (Join-Path $PSScriptRoot 'erp-docker-setup.ps1')
$script:ComputerSetupEntry=Join-Path $PSScriptRoot 'erp-computer-setup.ps1'
$script:ComputerFactsKey='';$script:ComputerFactsCache=$null;$script:ComputerFactsAt=[DateTime]::MinValue
function Get-ErpComputerRoot {Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\tools\v1'}
function Assert-ErpComputerPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'verification_failed'};$parent=Split-Path -Parent $cursor;if(-not $parent -or $parent -eq $cursor){break};$cursor=$parent}
}
function Get-ErpComputerStatePath([string]$Id){if($Id -notmatch '^[a-f0-9-]{36}$'){throw 'Invalid setup request.'};$path=Join-Path (Get-ErpComputerRoot) ($Id+'.json');Assert-ErpComputerPath $path;return $path}
function Write-ErpComputerState([string]$Id,[string]$Phase,[string]$Reason=''){
    $path=Get-ErpComputerStatePath $Id;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));$temporary=$path+'.'+$PID+'.tmp'
    [IO.File]::WriteAllText($temporary,(@{id=$Id;phase=$Phase;reason=$Reason;processId=$PID}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $path -Force
}
function Read-ErpComputerSetup([string]$Id){
    $path=Get-ErpComputerStatePath $Id;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null};$state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    if($state.id -cne $Id){throw 'verification_failed'}
    if($state.phase -in @('queued','downloading','installing')){$process=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.processId)" -ErrorAction SilentlyContinue;if(-not $process -or -not $process.CommandLine -or -not $process.CommandLine.Contains('erp-computer-setup.ps1') -or -not $process.CommandLine.Contains($Id)){$state.phase='awaiting_user';$state.reason='finish_setup'}}
    return $state
}
function Start-ErpComputerSetup([string]$Id){
    $path=Get-ErpComputerStatePath $Id;if(Test-Path -LiteralPath $path){return};Write-ErpComputerState $Id 'queued'
    Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$script:ComputerSetupEntry+'"'),'-Mode','Run','-RequestId',$Id) -WindowStyle Hidden|Out-Null
}
function Add-ErpManagedTools {
    $root=Get-ErpComputerRoot;$marker=Join-Path $root 'current.json';Assert-ErpComputerPath $marker;if(-not(Test-Path -LiteralPath $marker)){return}
    $current=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
    foreach($entry in @($current.tools)){
        if($entry.path -notmatch '^packages/[a-f0-9-]{36}/(node|git)/[a-zA-Z0-9/_.-]+\.exe$' -or $entry.sha256 -notmatch '^[a-f0-9]{64}$'){throw 'verification_failed'}
        $path=Join-Path $root $entry.path;Assert-ErpComputerPath $path
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'verification_failed'}
        $bin=Split-Path -Parent $path;if(($env:PATH -split ';') -notcontains $bin){$env:PATH=$bin+';'+$env:PATH}
    }
}
function Get-ErpToolChecks {
    try{Add-ErpManagedTools}catch{return @{node='unknown';git='unknown'}}
    $node=Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    $git=Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    $result=@{node='missing';git='missing'}
    if($node){
        $version=Invoke-ErpDockerProbeCommand $node.Source '--version'
        if($version -match '^v(\d+\.\d+\.\d+)$'){
            $result.node=if([version]$Matches[1] -ge [version]'22.13.0'){'ready'}else{'outdated'}
            $bin=Split-Path -Parent $node.Source;$npm=Join-Path $bin 'node_modules\npm\bin\npm-cli.js'
            if(-not(Test-Path -LiteralPath (Join-Path $bin 'npm.cmd')) -or -not(Test-Path -LiteralPath $npm) -or (Invoke-ErpDockerProbeCommand $node.Source ('"'+$npm+'" --version')) -notmatch '^\d+\.'){$result.node='missing'}
        }else{$result.node='unknown'}
    }
    if($git){$result.git=if((Invoke-ErpDockerProbeCommand $git.Source '--version') -match '^git version \d+\.'){'ready'}else{'unknown'}}
    return $result
}
function Get-ErpMachineFacts {
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop;$system=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop;$processor=Get-CimInstance Win32_Processor -ErrorAction Stop|Select-Object -First 1
    return @{build=[int]$os.BuildNumber;client=([int]$os.ProductType -eq 1);x64=($processor.Architecture -eq 9);memory=[double]$system.TotalPhysicalMemory;virtualisation=([bool]$system.HypervisorPresent -or [bool]$processor.VirtualizationFirmwareEnabled)}
}
function Get-ErpWslCheck {
    $wsl=Join-Path ([Environment]::SystemDirectory) 'wsl.exe';if(-not(Test-Path -LiteralPath $wsl)){return 'missing'}
    $text=(Invoke-ErpDockerProbeCommand $wsl '--version').Replace([string][char]0,'')
    if($text -match '(\d+\.\d+\.\d+)'){return $(if([version]$Matches[1] -ge [version]'2.1.5'){'ready'}else{'outdated'})};return 'missing'
}
function Test-ErpHttps([string]$Url){
    $response=$null;try{$request=[Net.HttpWebRequest]::Create($Url);$request.Method='HEAD';$request.AllowAutoRedirect=$false;$request.Timeout=4000;$response=$request.GetResponse();return ([int]$response.StatusCode -eq 200)}catch{return $false}finally{if($response){$response.Dispose()}}
}
function Get-ErpDockerStorageRoot {
    $fallback=[IO.Path]::GetPathRoot([Environment]::GetFolderPath('LocalApplicationData'))
    $settings=Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Docker\settings-store.json'
    if(Test-Path -LiteralPath $settings -PathType Leaf){
        Assert-ErpComputerPath $settings;$json=Get-Content -LiteralPath $settings -Raw|ConvertFrom-Json
        foreach($key in @('dataFolder','diskImageLocation')){$property=$json.PSObject.Properties[$key];if($property -and $property.Value -is [string] -and $property.Value -match '^[A-Za-z]:[\\/]'){Assert-ErpComputerPath $property.Value;return [IO.Path]::GetPathRoot($property.Value)}}
    }
    return $fallback
}
function Get-ErpDriveFreeBytes([string]$Root){return (New-Object IO.DriveInfo $Root).AvailableFreeSpace}
function Get-ErpStorageCheck([string]$WorkDirectory){
    # A conservative installation allowance, not a guarantee for future business data.
    $systemRoot=[IO.Path]::GetPathRoot([Environment]::GetFolderPath('LocalApplicationData'));$projectRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkDirectory))
    $dockerRoot=Get-ErpDockerStorageRoot
    if((Get-ErpDriveFreeBytes $dockerRoot) -lt 21474836480 -or (Get-ErpDriveFreeBytes $systemRoot) -lt 1073741824 -or (Get-ErpDriveFreeBytes $projectRoot) -lt 2147483648){return 'low'};return 'ready'
}
function Test-ErpWritableDirectory([string]$WorkDirectory){
    $parent=[IO.Path]::GetFullPath($WorkDirectory);Assert-ErpComputerPath $parent
    while(-not(Test-Path -LiteralPath $parent -PathType Container)){$parent=Split-Path -Parent $parent;if(-not $parent){return $false}}
    $file=Join-Path $parent ('.cogent-write-probe-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose);try{$stream.WriteByte(0);return $true}finally{$stream.Dispose()}
}
function Get-ErpComputerPrerequisite([string]$WorkDirectory,[bool]$DockerReady){
    $checks=Get-ErpToolChecks;$cacheKey=$WorkDirectory+'|'+$checks.node+'|'+$checks.git
    if($cacheKey -cne $script:ComputerFactsKey -or -not $script:ComputerFactsCache -or ([DateTime]::UtcNow-$script:ComputerFactsAt).TotalSeconds -ge 30){
        $static=@{windows='unknown';virtualisation='unknown';wsl='unknown';memory='unknown';storage='unknown';directory='unknown';network='unknown'}
        try{$facts=Get-ErpMachineFacts;$static.windows=if($facts.client -and $facts.x64 -and (($facts.build -ge 19045 -and $facts.build -lt 22000) -or $facts.build -ge 22631)){'ready'}else{'unsupported'};$static.virtualisation=if($facts.virtualisation){'ready'}else{'unavailable'};$static.memory=if($facts.memory -ge 8053063680){'ready'}else{'low'}}catch{}
        try{$static.wsl=Get-ErpWslCheck}catch{}
        try{$static.storage=Get-ErpStorageCheck $WorkDirectory}catch{}
        try{$static.directory=if(Test-ErpWritableDirectory $WorkDirectory){'ready'}else{'unavailable'}}catch{$static.directory='unavailable'}
        $urls=@('https://cogentspec.com/downloads/erpnext/releases/1.0.6/manifest.json');if($checks.node -ne 'ready'){$urls+='https://nodejs.org/dist/v22.23.4/SHASUMS256.txt'};if($checks.git -ne 'ready'){$urls+='https://github.com/git-for-windows/git/releases'}
        $connected=$true;foreach($url in $urls){if(-not(Test-ErpHttps $url)){$connected=$false}};$static.network=if($connected){'ready'}else{'unavailable'}
        $script:ComputerFactsCache=$static;$script:ComputerFactsKey=$cacheKey;$script:ComputerFactsAt=[DateTime]::UtcNow
    }
    foreach($key in $script:ComputerFactsCache.Keys){$checks[$key]=$script:ComputerFactsCache[$key]}
    # A running Linux engine also qualifies supported Hyper-V installations.
    if($DockerReady){$checks.wsl='ready';$checks.virtualisation='ready'}
    return @{checks=$checks}
}
function Save-ErpToolArchive([string]$Url,[string]$Target,[string]$Sha256){
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $response=$null;$source=$null;$dest=$null
    try{
        for($redirect=0;$redirect -le 3;$redirect++){
            $uri=[Uri]$Url;if($uri.Scheme -cne 'https' -or $uri.Host -notin @('nodejs.org','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')){throw 'verification_failed'}
            $request=[Net.HttpWebRequest]::Create($uri);$request.AllowAutoRedirect=$false;$request.Timeout=30000;$response=$request.GetResponse()
            if([int]$response.StatusCode -in @(301,302,303,307,308)){$Url=([Uri]::new($uri,$response.Headers['Location'])).AbsoluteUri;$response.Dispose();$response=$null;continue};break
        }
        if(-not $response -or [int]$response.StatusCode -ne 200 -or $response.ContentLength -lt 1 -or $response.ContentLength -gt 83886080){throw 'download_failed'}
        $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Target));if($drive.AvailableFreeSpace -lt ($response.ContentLength+536870912)){throw 'storage_required'}
        $source=$response.GetResponseStream();$source.ReadTimeout=30000;$dest=[IO.File]::Open($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$buffer=New-Object byte[] 65536;$total=0
        while(($count=$source.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt $response.ContentLength -or $drive.AvailableFreeSpace -lt 268435456){throw 'storage_required'};$dest.Write($buffer,0,$count)}
        if($total -ne $response.ContentLength){throw 'download_failed'}
    }finally{if($dest){$dest.Dispose()};if($source){$source.Dispose()};if($response){$response.Dispose()}}
    Assert-ErpToolDigest $Target $Sha256
}
function Assert-ErpToolDigest([string]$Target,[string]$Sha256){if((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Sha256){throw 'verification_failed'}}
function Expand-ErpToolArchive([string]$Archive,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression;Add-Type -AssemblyName System.IO.Compression.FileSystem;Assert-ErpComputerPath $Destination;[void][IO.Directory]::CreateDirectory($Destination)
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\';$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        $total=0;foreach($entry in $zip.Entries){$name=$entry.FullName.Replace('\','/');$total+=$entry.Length
            if($zip.Entries.Count -gt 20000 -or $total -gt 536870912 -or $name -match '(^/|(^|/)\.\.(/|$)|:)' -or ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960)){throw 'verification_failed'}
            $path=[IO.Path]::GetFullPath((Join-Path $Destination $name));if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'verification_failed'}
        }
        foreach($entry in $zip.Entries){$path=Join-Path $Destination $entry.FullName;if(-not $entry.Name){[void][IO.Directory]::CreateDirectory($path);continue};[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)}
    }finally{$zip.Dispose()}
}
function Invoke-ErpComputerSetup([string]$Id){
    $ErrorActionPreference='Stop'
    [AppContext]::SetSwitch('Switch.System.IO.UseLegacyPathHandling',$false);[AppContext]::SetSwitch('Switch.System.IO.BlockLongPaths',$false)
    try{
        $facts=Get-ErpMachineFacts;if(-not $facts.client -or -not $facts.x64){throw 'verification_failed'}
        $checks=Get-ErpToolChecks;$root=Get-ErpComputerRoot;Assert-ErpComputerPath $root
        $packages=Join-Path $root ('packages\'+$Id);Assert-ErpComputerPath $packages;[void][IO.Directory]::CreateDirectory($packages)
        $marker=Join-Path $root 'current.json';$tools=@();if(Test-Path -LiteralPath $marker){$tools=@((Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json).tools)}
        $definitions=@(
            @{key='node';url='https://nodejs.org/dist/v22.23.4/node-v22.23.4-win-x64.zip';sha256='cbc74b5e0982c9dbb41525fd8fb5dcd32fbee237863f7829072f4639a1ce5f20';entry='node-v22.23.4-win-x64/node.exe'},
            @{key='git';url='https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/MinGit-2.56.1-64-bit.zip';sha256='4a92850b6e917da4fd010669b614b55dccf5b0ec333a534cc4be4700dfefdafd';entry='cmd/git.exe'})
        foreach($definition in $definitions){if($checks[$definition.key] -eq 'ready'){continue}
            Write-ErpComputerState $Id 'downloading';$archive=Join-Path $packages ($definition.key+'.zip');Save-ErpToolArchive $definition.url $archive $definition.sha256
            Write-ErpComputerState $Id 'installing';$destination=Join-Path $packages $definition.key;Expand-ErpToolArchive $archive $destination
            $path=Join-Path $destination $definition.entry;Assert-ErpComputerPath $path;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'verification_failed'}
            $tools=@($tools|Where-Object{$_.name -ne $definition.key});$tools+=@{name=$definition.key;path=('packages/'+$Id+'/'+$definition.key+'/'+$definition.entry);sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        $temporary=$marker+'.'+$Id+'.tmp';[IO.File]::WriteAllText($temporary,(@{tools=$tools}|ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $marker -Force
        $checks=Get-ErpToolChecks;if($checks.node -ne 'ready' -or $checks.git -ne 'ready'){throw 'verification_failed'};Write-ErpComputerState $Id 'ready'
    }catch{$reason=if($_.Exception.Message -in @('storage_required','verification_failed')){$_.Exception.Message}else{'download_failed'};Write-ErpComputerState $Id 'failed' $reason}
}
if($ComputerMode -eq 'Run'){Invoke-ErpComputerSetup $SetupRequestId}
