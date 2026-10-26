[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Install','Watch')][string]$Mode,
    [ValidatePattern('^$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$RequestId='',
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:OS -ne 'Windows_NT'){throw 'GPTWeb setup must be opened on your Windows computer.'}
if($PSVersionTable.PSVersion.Major -le 5){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
try{Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop}catch{Add-Type -AssemblyName System.Security -ErrorAction Stop}
$base=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$root=Join-Path $base 'gptweb-setup-v1'
$package=Join-Path $root $ExpectedSha256
$installed=Join-Path $package 'helper.ps1'
$revision='50cd5a71e5a0a91b6b311b45d0314e97fc79bf8b'
$manifestHash='961b201d312906acf68f996204facd70f957a4f367245c7fea9d56473f142037'
$bootstrapHash='4e28082aea6032fd5c459726d8fbb7862fa9635224a5b27aaaabb10b9681cca6'
$runtime=Join-Path $base ('web-command-v1\packages\'+$manifestHash)
$service='https://cogentspec.app/api/bridge/gptweb/setup/helper'
function Plain([string]$Path){
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'GPTWeb setup cannot use a redirected path.'}}
        $parent=Split-Path -Parent $cursor;if(-not $parent -or $parent -eq $cursor){break};$cursor=$parent
    }
}
function Verify([string]$Path,[string]$Hash){
    Plain $Path
    if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash){throw 'GPTWeb file verification failed.'}
}
function Token {
    $credential=Join-Path $base 'desktop-credential.json'
    if(-not (Test-Path -LiteralPath $credential -PathType Leaf)){throw 'Authorize this computer in your CogentSpec account, then open GPTWeb setup again.'}
    $data=Get-Content -Raw -LiteralPath $credential|ConvertFrom-Json
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$data.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Api([string]$Method='Get',$Body=$null){
    $token=Token
    try{
        $parameters=@{Uri=$service;Method=$Method;MaximumRedirection=0;TimeoutSec=10;Headers=@{Authorization="Bearer $token";Accept='application/json'}}
        if($null -ne $Body){$parameters.ContentType='application/json';$parameters.Body=$Body|ConvertTo-Json -Compress}
        return Invoke-RestMethod @parameters
    }finally{$token=$null}
}
function Worker {
    return "& '$($installed.Replace("'","''"))' -Mode Watch -ExpectedSha256 '$ExpectedSha256'"
}
Verify $PSCommandPath $ExpectedSha256
if($Mode -ceq 'Install'){
    if(-not $RequestId){throw 'Use Set up GPTWeb in your existing work area to obtain a current setup file.'}
    $feed=Api
    if(-not ($feed.requests|Where-Object{$_.id -ceq $RequestId})){throw 'This GPTWeb setup request expired or belongs to a different computer. Use Set up GPTWeb again.'}
    Plain $package;[void][IO.Directory]::CreateDirectory($package)
    if([IO.Path]::GetFullPath($PSCommandPath) -cne [IO.Path]::GetFullPath($installed)){
        $temporary=Join-Path $package ('helper-'+[Guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllBytes($temporary,[IO.File]::ReadAllBytes($PSCommandPath));Verify $temporary $ExpectedSha256
        Move-Item -LiteralPath $temporary -Destination $installed -Force
    }
    Verify $installed $ExpectedSha256
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Worker)))
    $command='"'+$powershell+'" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded
    # Per-user startup; no elevation, service installation or other connector key.
    $run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if(-not (Test-Path -LiteralPath $run)){[void](New-Item -Path $run -Force)}
    Set-ItemProperty -LiteralPath $run -Name 'CogentSpecGPTWebV1' -Value $command
    $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[UInt16]0}
    $started=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;ProcessStartupInformation=$startup}
    if([int]$started.ReturnValue -ne 0){throw 'The GPTWeb background helper could not start.'}
    Write-Host 'GPTWeb setup installed. Your existing work area will confirm the connection.'
    return
}
$mutex=New-Object Threading.Mutex($false,'Local\CogentSpecGPTWebSetupV1')
$locked=$false
try{
    $locked=$mutex.WaitOne(0);if(-not $locked){return}
    @{processId=$PID;helper=$installed}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $root 'agent.json')
    $attempted=@{};$restored=@{}
    while($true){
        try{
            Verify $installed $ExpectedSha256
            $feed=Api
            if($feed.protocol -cne 'cogentspec-gptweb-setup-v1'){throw 'Invalid GPTWeb helper response.'}
            foreach($item in $feed.requests){
                if([string]$item.id -cnotmatch '^[a-f0-9-]{36}$' -or [string]$item.contextKey -cnotmatch '^ctx-[a-f0-9]{64}$'){continue}
                if($item.status -ceq 'pending' -and -not $attempted.ContainsKey([string]$item.id)){
                    $attempted[[string]$item.id]=$true
                    try{
                        $bootstrap=Join-Path $package 'bootstrap.ps1'
                        if(-not (Test-Path -LiteralPath $bootstrap)){
                            $stage=Join-Path $package ('bootstrap-'+[Guid]::NewGuid().ToString('N')+'.tmp')
                            Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/cogentspec/cogentspec-marketplace/'+$revision+'/web-bridge/v1/bootstrap.ps1') -OutFile $stage -MaximumRedirection 0 -TimeoutSec 15
                            Verify $stage $bootstrapHash;Move-Item -LiteralPath $stage -Destination $bootstrap -Force
                        }
                        Verify $bootstrap $bootstrapHash
                        $reply=& $bootstrap -RequestId ([string]$item.id) -Command '$gptweb' -Revision $revision -ManifestSha256 $manifestHash
                        $result=$reply|ConvertFrom-Json
                        if($result.status -cne 'connected' -or $result.acknowledgementVerified -cne $true){
                            $null=Api 'Post' @{id=$item.id;status='not_connected';reason=$result.reason}
                        }
                    }catch{$null=Api 'Post' @{id=$item.id;status='not_connected';reason='setup_failed'}}
                }elseif($item.status -ceq 'connected' -and (Test-Path -LiteralPath $runtime) -and
                    (-not $restored.ContainsKey([string]$item.contextKey) -or ([DateTime]::UtcNow-$restored[[string]$item.contextKey]).TotalSeconds -gt 20)){
                    Verify (Join-Path $runtime 'manifest.json') $manifestHash
                    $manifest=Get-Content -Raw -LiteralPath (Join-Path $runtime 'manifest.json')|ConvertFrom-Json
                    foreach($file in $manifest.files.PSObject.Properties){Verify (Join-Path $runtime $file.Name) ([string]$file.Value)}
                    & (Join-Path $runtime 'runtime\start-web-worker.ps1') -ContextKey ([string]$item.contextKey) -Command '$gptweb'
                    $restored[[string]$item.contextKey]=[DateTime]::UtcNow
                }
            }
        }catch{
            # Network loss never authorizes a different computer, account or tab.
        }
        Start-Sleep -Seconds 3
    }
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
