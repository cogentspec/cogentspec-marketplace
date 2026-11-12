param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
$script:checks=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Start-Process {throw 'Unexpected real process'}
. $SourcePath
function Get-ErpComputerRoot {return $TestRoot}
function Get-ErpMachineFacts {return @{client=$true;x64=$true;build=22631;memory=17179869184;virtualisation=$true}}
function Get-ErpToolChecks {return @{node=$script:node;git=$script:git}}
function Get-ErpWslCheck {return $script:wsl}
function Get-ErpStorageCheck($WorkDirectory){return $script:storage}
function Test-ErpWritableDirectory($WorkDirectory){return $script:writable}
function Test-ErpHttps($Url){return $script:online}
$script:node='missing';$script:git='missing';$script:wsl='missing';$script:storage='ready';$script:writable=$true;$script:online=$true
$report=Get-ErpComputerPrerequisite 'C:\Synthetic' $false
Assert ($report.checks.node -eq 'missing' -and $report.checks.git -eq 'missing' -and $report.checks.wsl -eq 'missing') 'Missing dependencies were hidden'
$report=Get-ErpComputerPrerequisite 'C:\Synthetic' $true
Assert ($report.checks.wsl -eq 'ready' -and $report.checks.virtualisation -eq 'ready') 'Working Hyper-V Docker was rejected'
$script:ComputerFactsCache=$null;$script:storage='low';$script:online=$false;$script:writable=$false
$report=Get-ErpComputerPrerequisite 'D:\Synthetic' $false
Assert ($report.checks.storage -eq 'low' -and $report.checks.network -eq 'unavailable' -and $report.checks.directory -eq 'unavailable') 'Capacity or network failures were hidden'
function Get-ErpMachineFacts {return @{client=$false;x64=$false;build=17763;memory=4294967296;virtualisation=$false}}
$script:ComputerFactsCache=$null;$report=Get-ErpComputerPrerequisite 'C:\Synthetic' $false
Assert ($report.checks.windows -eq 'unsupported' -and $report.checks.memory -eq 'low' -and $report.checks.virtualisation -eq 'unavailable') 'Unsupported hardware passed'
[void][IO.Directory]::CreateDirectory($TestRoot)
Add-Type -AssemblyName System.IO.Compression;Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=Join-Path $TestRoot ('text-'+[Guid]::NewGuid().ToString('N')+'.zip')
$zip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
try{$entry=$zip.CreateEntry('notes/readme.txt');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('Harmless archive fixture')}finally{$writer.Dispose()}}finally{$zip.Dispose()}
$destination=Join-Path $TestRoot ('text-'+[Guid]::NewGuid().ToString('N'));Expand-ErpToolArchive $archive $destination
Assert ([IO.File]::ReadAllText((Join-Path $destination 'notes/readme.txt')) -ceq 'Harmless archive fixture') 'Verified archive extraction failed'
$rejected=$false;try{Assert-ErpToolDigest $archive ('0'*64)}catch{$rejected=$true};Assert $rejected 'Changed archive was accepted'
Assert-ErpToolDigest $archive (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();Assert $true 'Verified archive rejected'
function Get-ErpMachineFacts {return @{client=$true;x64=$true;build=22631;memory=17179869184;virtualisation=$true}}
$script:node='ready';$script:git='ready'
$id='11111111-2222-4333-8444-555555555555';Invoke-ErpComputerSetup $id
Assert ((Read-ErpComputerSetup $id).phase -eq 'ready') 'Ready tools did not pass without download'
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction);return $null}
Write-ErpComputerState $id 'installing';Assert ((Read-ErpComputerSetup $id).phase -eq 'awaiting_user') 'Interrupted setup did not recover'
Start-ErpComputerSetup $id;Assert $true 'Duplicate setup launched a process'
function Get-ErpToolChecks {return @{node='missing';git='missing'}}
function Save-ErpToolArchive($Url,$Target,$Sha256){throw 'storage_required'}
$second='22222222-3333-4444-8555-666666666666';$marker=Join-Path $TestRoot 'current.json';$before=[IO.File]::ReadAllText($marker);Invoke-ErpComputerSetup $second
Assert ((Read-ErpComputerSetup $second).phase -eq 'failed' -and (Read-ErpComputerSetup $second).reason -eq 'storage_required') 'Storage failure was not retained'
Assert ([IO.File]::ReadAllText($marker) -ceq $before) 'Failed setup replaced existing tools'
$rejected=$false;try{Get-ErpComputerStatePath 'invalid'}catch{$rejected=$true};Assert $rejected 'Invalid identity accepted'
@{passed=$true;checks=$script:checks;realDownloads=$false;realSoftwareExecuted=$false;globalToolsChanged=$false}|ConvertTo-Json -Compress
