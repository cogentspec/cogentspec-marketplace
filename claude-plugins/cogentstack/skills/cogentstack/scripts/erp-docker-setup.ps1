[CmdletBinding()]
param([ValidateSet('Library','Run')][string]$Mode='Library',[ValidatePattern('^[a-f0-9-]{36}$')][string]$RequestId,[ValidateSet('install','start')][string]$Action='install')
# Merely loading this helper never installs, starts or reconfigures Docker.
function Get-ErpDockerRoot { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\erp-prerequisites\v1' }
function Get-ErpDockerStatePath([string]$Id) {
    if ($Id -notmatch '^[a-f0-9-]{36}$') { throw 'Invalid Docker setup request.' }
    $root=Get-ErpDockerRoot
    if ((Test-Path -LiteralPath $root) -and ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked setup folders are not supported.' }
    Join-Path $root ($Id+'.json')
}
function Write-ErpDockerState([string]$Id,[string]$Phase,[string]$Reason='') {
    $path=Get-ErpDockerStatePath $Id;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $temporary=$path+'.'+$PID+'.tmp'
    [IO.File]::WriteAllText($temporary,(@{id=$Id;phase=$Phase;reason=$Reason;processId=$PID;updatedAt=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}
function Get-ErpDockerPaths {
    $rows=@()
    if ($env:ProgramFiles) { $rows+=Join-Path $env:ProgramFiles 'Docker\Docker' }
    $rows+=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\DockerDesktop'
    $rows
}
function Find-ErpDockerCli {
    $command=Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach($root in @(Get-ErpDockerPaths)) {
        $file=Join-Path $root 'resources\bin\docker.exe'
        if(Test-Path -LiteralPath $file -PathType Leaf){return $file}
    }
    return ''
}
function Find-ErpDockerDesktop {
    foreach($root in @(Get-ErpDockerPaths)) {
        $file=Join-Path $root 'Docker Desktop.exe'
        if(Test-Path -LiteralPath $file -PathType Leaf){return $file}
    }
    return ''
}
function Invoke-ErpDockerProbeCommand([string]$Cli,[string]$Arguments) {
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$Cli;$start.Arguments=$Arguments
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try {
        [void]$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(8000)){$process.Kill();return ''}
        if($process.ExitCode -ne 0){return ''};return $output.GetAwaiter().GetResult().Trim()
    } finally {$process.Dispose()}
}
function Get-ErpDockerPrerequisite {
    $cli=Find-ErpDockerCli
    if(-not $cli){return @{status='missing'}}
    $engine=Invoke-ErpDockerProbeCommand $cli 'info --format {{.OSType}}'
    if(-not $engine){return @{status='stopped'}}
    if($engine -cne 'linux'){return @{status='windows_containers'}}
    if(-not (Invoke-ErpDockerProbeCommand $cli 'compose version --short')){return @{status='compose_missing'}}
    $bin=Split-Path -Parent $cli
    if(($env:PATH -split ';') -notcontains $bin){$env:PATH=$bin+';'+$env:PATH}
    return @{status='ready'}
}
function Read-ErpDockerSetup([string]$Id) {
    $path=Get-ErpDockerStatePath $Id
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked setup state is not supported.'}
    $state=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if($state.id -cne $Id){throw 'Docker setup identity changed.'}
    if($state.phase -in @('queued','downloading','installing','starting')) {
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.processId)" -ErrorAction SilentlyContinue
        if(-not $process -or -not $process.CommandLine -or -not $process.CommandLine.Contains('erp-docker-setup.ps1') -or -not $process.CommandLine.Contains($Id)) {
            $state.phase='awaiting_user';$state.reason='finish_setup'
        }
    }
    return $state
}
function Start-ErpDockerSetup([string]$Id,[string]$SetupAction) {
    if($SetupAction -notin @('install','start')){throw 'Invalid Docker setup action.'}
    $path=Get-ErpDockerStatePath $Id
    if(Test-Path -LiteralPath $path){return}
    Write-ErpDockerState $Id 'queued'
    $shell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $entry=Join-Path $PSScriptRoot 'erp-docker-setup.ps1'
    Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$entry+'"'),'-Mode','Run','-RequestId',$Id,'-Action',$SetupAction) -WindowStyle Hidden | Out-Null
}
function Save-ErpDockerInstaller([string]$Target) {
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request=[Net.HttpWebRequest]::Create('https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe')
    $request.AllowAutoRedirect=$false;$request.Timeout=30000
    $response=$null;$source=$null;$dest=$null
    try {
        $response=$request.GetResponse();$length=$response.ContentLength
        if($response.ResponseUri.Scheme -cne 'https' -or $response.ResponseUri.Host -cne 'desktop.docker.com' -or $length -lt 1 -or $length -gt 1610612736){throw 'download_failed'}
        $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Target))
        if($drive.AvailableFreeSpace -lt ($length+1073741824)){throw 'storage_required'}
        $source=$response.GetResponseStream();$source.ReadTimeout=30000;$dest=[IO.File]::Open($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536;$count=0
        while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){$count+=$read;if($count -gt $length -or $drive.AvailableFreeSpace -lt 536870912){throw 'storage_required'};$dest.Write($buffer,0,$read)}
        if($count -ne $length){throw 'download_failed'}
    } finally {if($dest){$dest.Dispose()};if($source){$source.Dispose()};if($response){$response.Dispose()}}
    Assert-ErpDockerInstallerSignature $Target
}
function Assert-ErpDockerInstallerSignature([string]$Target) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Target
    if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)(O|CN)=Docker Inc\.?(,|$)'){throw 'signature_invalid'}
}
function Invoke-ErpDockerSetup([string]$Id,[string]$SetupAction) {
    try {
        if((Get-ErpDockerPrerequisite).status -eq 'ready'){Write-ErpDockerState $Id 'ready';return}
        if($SetupAction -eq 'install') {
            if(-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -like 'ARM*'){throw 'unsupported_windows'}
            $folder=Join-Path (Get-ErpDockerRoot) $Id;[void][IO.Directory]::CreateDirectory($folder)
            if((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'download_failed'}
            $installer=Join-Path $folder 'Docker Desktop Installer.exe'
            Write-ErpDockerState $Id 'downloading';Save-ErpDockerInstaller $installer
            Write-ErpDockerState $Id 'installing'
            # Interactive vendor prompts handle terms, permissions and WSL.
            $process=Start-Process -FilePath $installer -ArgumentList @('install','--user','--backend=wsl-2') -WindowStyle Normal -PassThru
            try {$process.WaitForExit();$code=$process.ExitCode}finally{$process.Dispose()}
            if($code -in @(3010,1641)){Write-ErpDockerState $Id 'restart_required' 'restart_required';return}
            if($code -ne 0){Write-ErpDockerState $Id 'awaiting_user' 'finish_setup';return}
        }
        $desktop=Find-ErpDockerDesktop
        if(-not $desktop){Write-ErpDockerState $Id 'awaiting_user' 'finish_setup';return}
        Write-ErpDockerState $Id 'starting'
        Start-Process -FilePath $desktop -WindowStyle Normal | Out-Null
        Write-ErpDockerState $Id 'awaiting_user' 'finish_setup'
    } catch {
        $reason=if($_.Exception.Message -in @('storage_required','signature_invalid','unsupported_windows')){$_.Exception.Message}else{'download_failed'}
        Write-ErpDockerState $Id 'failed' $reason
    }
}
if($Mode -eq 'Run'){Invoke-ErpDockerSetup $RequestId $Action}
