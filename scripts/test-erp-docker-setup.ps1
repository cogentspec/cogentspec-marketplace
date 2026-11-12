param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Start-Process {throw 'Unexpected process during library load'}
. $SourcePath
$script:checks=0
function Find-ErpDockerCli {return $script:cli}
function Invoke-ErpDockerProbeCommand($Cli,$Arguments){if($Arguments -like 'info*'){return $script:engine};return $script:compose}
foreach($row in @(@('','', '', 'missing'),@('C:\fake\docker.exe','','','stopped'),@('C:\fake\docker.exe','windows','v2','windows_containers'),@('C:\fake\docker.exe','linux','','compose_missing'),@('C:\fake\docker.exe','linux','v2','ready'))){
 $script:cli=$row[0];$script:engine=$row[1];$script:compose=$row[2];Assert ((Get-ErpDockerPrerequisite).status -eq $row[3]) ('Wrong probe '+$row[3]);$script:checks++
}
function Get-AuthenticodeSignature {param($LiteralPath);return $script:signature}
foreach($row in @(@('NotSigned','CN=Docker Inc', $false),@('Valid','CN=Someone Else', $false),@('Valid','CN=Docker Inc., O=Docker Inc., C=US', $true))){
 $script:signature=@{Status=$row[0];SignerCertificate=@{Subject=$row[1]}};$valid=$true;try{Assert-ErpDockerInstallerSignature 'synthetic.exe'}catch{$valid=$false};Assert ($valid -eq $row[2]) 'Signature did not fail closed';$script:checks++
}
function Get-ErpDockerRoot {return $TestRoot}
$id='11111111-2222-4333-8444-555555555555'
$script:cli='';$script:states=@();$script:launches=@();$script:exitCode=0;$script:downloadError=''
function Write-ErpDockerState($Id,$Phase,$Reason=''){$script:states+=,@{phase=$Phase;reason=$Reason}}
function Save-ErpDockerInstaller($Target){if($script:downloadError){throw $script:downloadError}}
function Find-ErpDockerDesktop {return 'C:\synthetic\Docker Desktop.exe'}
function Start-Process {param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
 Assert ($WindowStyle -eq 'Normal') 'Vendor windows were hidden';$script:launches+=,@{file=$FilePath;arguments=$ArgumentList}
 $p=[pscustomobject]@{ExitCode=$script:exitCode};$p|Add-Member ScriptMethod WaitForExit {}; $p|Add-Member ScriptMethod Dispose {};return $p
}
foreach($code in @(3010,1641,1,0)){
 $script:exitCode=$code;$script:states=@();$script:launches=@();Invoke-ErpDockerSetup $id 'install'
 $phase=if($code -in @(3010,1641)){'restart_required'}else{'awaiting_user'}
 Assert ($script:states[-1].phase -eq $phase) ('Incorrect exit handling '+$code)
 Assert ($script:launches[0].arguments -contains '--user') 'Per-user installation lost'
 Assert (($script:launches[0].arguments -join ' ') -notmatch 'quiet|accept-license') 'Terms silently accepted'
 Assert ($script:launches.Count -eq $(if($code -eq 0){2}else{1})) 'Unexpected launch after cancellation or restart';$script:checks++
}
foreach($fixtureFailure in @('signature_invalid','storage_required','download_failed')){
 $script:downloadError=$fixtureFailure;$script:launches=@();Invoke-ErpDockerSetup $id 'install'
 Assert ($script:states[-1].phase -eq 'failed' -and $script:states[-1].reason -eq $fixtureFailure -and $script:launches.Count -eq 0) ('Unsafe failure '+$fixtureFailure);$script:checks++
}
$script:downloadError='';$script:cli='fake';$script:engine='linux';$script:compose='v2';$script:launches=@();Invoke-ErpDockerSetup $id 'install'
Assert ($script:states[-1].phase -eq 'ready' -and $script:launches.Count -eq 0) 'Ready Docker was changed';$script:checks++
# Use real durable state functions for restart and idempotency checks.
. $SourcePath
function Get-ErpDockerRoot {return $TestRoot}
[void][IO.Directory]::CreateDirectory($TestRoot)
Write-ErpDockerState $id 'installing'
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction);return $null}
Assert ((Read-ErpDockerSetup $id).phase -eq 'awaiting_user') 'Interrupted setup did not offer recovery';$script:checks++
function Start-Process {throw 'Duplicate setup process'}
Start-ErpDockerSetup $id 'install';$script:checks++
$rejected=$false;try{Start-ErpDockerSetup $id 'arbitrary'}catch{$rejected=$true};Assert $rejected 'Arbitrary action accepted';$script:checks++
$rejected=$false;try{Get-ErpDockerStatePath '../escape'}catch{$rejected=$true};Assert $rejected 'Invalid state path accepted';$script:checks++
@{passed=$true;checks=$script:checks;realInstallersStarted=$false;realDownloads=$false}|ConvertTo-Json -Compress
