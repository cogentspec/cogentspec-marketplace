param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference='Stop'
. $SourcePath
$script:checks=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Get-ErpDockerStorageRoot {return $script:dockerDrive}
function Get-ErpDriveFreeBytes([string]$Root){return $script:free[$Root]}
function Get-ErpDockerAllocatedStorage([string]$DockerRoot,[bool]$DockerReady){if($DockerReady){return $script:snapshot};return $null}
$script:dockerDrive='C:\';$script:free=@{'C:\'=[long](19.2*1GB);'D:\'=[long](1.5*1GB)}
$script:snapshot=@{allocatedBytes=[long](27*1GB);usedBytes=[long](24*1GB);availableBytes=[long](1000*1GB)}
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'ready') 'Reusable committed Docker space did not satisfy the unchanged 20 GiB allowance'
Assert ($script:ErpStorageReport.dockerReusableBytes -eq 2GB) 'Metadata reserve was not subtracted'
Assert ($script:ErpStorageReport.requiredDockerBytes -eq 20GB) 'The installation allowance was weakened'
$script:snapshot=@{allocatedBytes=[long](24*1GB);usedBytes=[long](24*1GB);availableBytes=[long](1000*1GB)}
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'low') 'Unallocated virtual free space was counted as reusable Windows capacity'
Assert ($script:ErpStorageReport.dockerReusableBytes -eq 0) 'A full committed disk received space credit'
$script:snapshot=@{allocatedBytes=[long](27*1GB);usedBytes=[long](24*1GB);availableBytes=[long](10*1GB)};$script:free['C:\']=40GB
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'low') 'A full guest filesystem was ignored'
$script:snapshot=$null
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'ready') 'A supported engine without a verified WSL disk lost its host-only fallback'
$script:free['C:\']=[long](19.2*1GB)
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'low') 'Unknown reuse measurement bypassed the host-space requirement'
$script:snapshot=@{allocatedBytes=[long](27*1GB);usedBytes=[long](24*1GB);availableBytes=[long](1000*1GB)}
Assert ((Get-ErpStorageCheck 'D:\Synthetic' $true) -eq 'low') 'Docker reuse paid for a different installation drive'
$script:free['C:\']=[long](0.5*1GB);$script:snapshot.allocatedBytes=50GB
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'low') 'Docker reuse bypassed the Windows setup-tools reserve'
$script:free['C:\']=2GB;$script:snapshot=@{allocatedBytes=[long](43*1GB);usedBytes=[long](24*1GB);availableBytes=[long](1000*1GB)}
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $true) -eq 'ready') 'Shared drives incorrectly added their allowances'
Assert ((Get-ErpStorageCheck 'C:\Synthetic' $false) -eq 'low') 'An unavailable Docker engine received reuse credit'
Assert ((Get-ErpReusableDockerBytes @{allocatedBytes=-1;usedBytes=0;availableBytes=100TB}) -eq 0) 'Invalid allocation measurements received credit'
$usage=ConvertFrom-ErpDockerDiskUsage "Filesystem 1-blocks Used Available Capacity Mounted on`n/dev/sdd 1081101176832 25061634048 1001047187456 2% /mnt/docker-desktop-disk"
Assert ($usage.usedBytes -eq 25061634048 -and $usage.availableBytes -eq 1001047187456) 'Docker BusyBox disk measurements were misread'
Assert ($null -eq (ConvertFrom-ErpDockerDiskUsage '/dev/sdd 100 200 300 2% /mnt/docker-desktop-disk')) 'Impossible filesystem measurements passed'
Assert ($null -eq (ConvertFrom-ErpDockerDiskUsage '/dev/sdd 1000 20 900 2% /other-disk')) 'An unrelated mount was accepted'
@{passed=$true;checks=$script:checks;syntheticOnly=$true;dockerStopped=$false;resourcesDeleted=$false}|ConvertTo-Json -Compress
