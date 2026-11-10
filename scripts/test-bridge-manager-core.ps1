param([Parameter(Mandatory=$true)][string]$CorePath, [Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. $CorePath
$script:ManagerRoot = $TestRoot
$checks = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
foreach ($surface in @('chatgpt','claude-desktop')) {
    Assert (Test-ManagerDestination $surface 'split-screen') 'Snap destination missing'
    Assert (Test-ManagerDestination $surface 'web') 'Web destination missing'
}
Assert (Test-ManagerDestination 'qwen-web' 'web') 'Qwen destination missing'
Assert (-not (Test-ManagerDestination 'qwen-web' 'split-screen')) 'Qwen must retain its Web destination'
Assert (-not (Test-ManagerDestination 'unknown' 'web')) 'Unknown providers must fail closed'
Assert (-not (Test-ManagerPath (Join-Path $TestRoot '..\outside.ps1') $TestRoot)) 'Parent traversal accepted'
$record = Join-Path $TestRoot 'roundtrip.json'
Write-ManagerJson $record @{ status='fixture'; version='1.0.0' }
Assert ((Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).status -eq 'fixture') 'Atomic state write failed'

$context = 'ctx-' + ('a' * 64)
$base = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$digest = (Get-ManagerHash $context).Substring(0,24)
$binding = [pscustomobject]@{ protocol=$script:ManagerProtocol; contextKey=$context; surface='chatgpt'; experience='split-screen';
    pluginId='cogentspec'; pluginVersion='0.6.179'; threadId=''; runtimeVersion=('b' * 24);
    runtimeRoot=(Join-Path $base ('bridge-runtime\' + ('b' * 24))); statePath=(Join-Path $base "bridge\$digest.json");
    readyPath=(Join-Path $base "bridge\$digest.ready.json"); credentialFingerprint='fixture';
    files=[pscustomobject]@{'watch-cogentstack-bridge.ps1'=('c'*64);'project-context.ps1'=('d'*64)} }
function Get-ManagerCredentialFingerprint { return 'fixture' }
function Test-ManagerPath { return $true }
function Test-Path { param($LiteralPath, $Path, $PathType); return $true }
function Get-FileHash { param($LiteralPath,$Algorithm); return @{ Hash=if ($LiteralPath.EndsWith('project-context.ps1')) { 'd'*64 } else { 'c'*64 } } }
Assert (Test-ManagerBinding $binding) 'Verified synthetic runtime rejected'
$binding.files.'project-context.ps1' = 'e'*64
Assert (-not (Test-ManagerBinding $binding)) 'Changed runtime was accepted'
$binding.files.'project-context.ps1' = 'd'*64
$binding.credentialFingerprint = 'other-device'
Assert (-not (Test-ManagerBinding $binding)) 'Replaced credential accepted an old binding'
$binding.credentialFingerprint = 'fixture'
Remove-Item Function:\Test-Path

# Verify exact worker identity, including PID reuse, without touching a real process.
$binding.statePath = Join-Path $TestRoot 'worker.json'
Write-ManagerJson $binding.statePath @{processId=12345}
$expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-ManagerWorkerCommand $binding)))
$script:workerCommand = 'powershell.exe -NoProfile -EncodedCommand ' + $expected
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); return [pscustomobject]@{ProcessId=12345;ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine=$script:workerCommand} }
Assert ((Get-ManagerWorker $binding).ProcessId -eq 12345) 'Exact worker was not recognised'
$script:workerCommand = 'powershell.exe -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'another process'"))
Assert ($null -eq (Get-ManagerWorker $binding)) 'Reused process ID must not be adopted or terminated, or block cold-start recovery'

# Request cancellation is checked during startup and suppresses the watchdog.
$script:starts=0; $script:stops=0; $script:cancelled=$false; $script:claims=0
function Start-ManagerWorker { param($Binding); $script:starts++; return @{processId=12345;created=$true} }
function Stop-ManagerOwnedWorker { param($Binding,$ProcessId); Assert ($ProcessId -eq 12345) 'Cancellation targeted an unrelated process'; $script:stops++ }
function Test-ManagerReady { param($Binding); return $false }
function Invoke-BridgeManagerApi {
    param($Body)
    if($Body.operation -eq 'claim') {
        $script:claims++
        if($script:claims -gt 1){throw 'request_cancelled'}
        return @{status='claimed';contextKey=$context;surface='chatgpt';experience='split-screen'}
    }
    return @{status='failed'}
}
$request = [pscustomobject]@{id=[Guid]::NewGuid().ToString();contextKey=$context;surface='chatgpt';experience='split-screen';operation='reconnect';expiresAt=[DateTimeOffset]::UtcNow.AddSeconds(10).ToUnixTimeMilliseconds()}
Invoke-ManagerRequest $request @($binding)
Assert ($script:starts -eq 1 -and $script:stops -eq 1) 'Cancellation failed to stop only the newly started worker'
Assert (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $TestRoot ('suppressed\' + (Get-ManagerHash $context) + '.paused'))) 'Cancelled startup could be revived by automatic recovery'

# Exercise the real installer function with registry/task/process boundaries
# replaced by in-memory fakes. No real startup registration is changed.
$sourceRoot = Join-Path $TestRoot 'installer-source'
[void][IO.Directory]::CreateDirectory($sourceRoot)
foreach ($name in @('bridge-manager.ps1','bridge-manager-core.ps1','erp-worker.ps1','erp-installation-worker.ps1','install-erp-project.mjs','erp-delete-project.ps1','remove-erp-project.mjs','create-specification-project.ps1','fulfil-project.ps1','native-command.ps1','project-context.ps1','project-credential-worker.ps1','provision-project-credentials.mjs')) {
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $CorePath) $name) -Destination (Join-Path $sourceRoot $name)
}
function Get-FileHash {
    param($LiteralPath,$Algorithm)
    $reader=[IO.File]::OpenRead($LiteralPath);$sha=[Security.Cryptography.SHA256]::Create()
    try{return @{Hash=([BitConverter]::ToString($sha.ComputeHash($reader))).Replace('-','')}}finally{$reader.Dispose();$sha.Dispose()}
}
$source = Get-Content -LiteralPath (Join-Path $sourceRoot 'bridge-manager.ps1') -Raw
$tokens=$null;$parse=$null
$tree=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parse)
$definition=$tree.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-Manager'},$false).Extent.Text
$definition=$definition.Replace('$PSScriptRoot',("'"+$sourceRoot.Replace("'","''")+"'"))
. ([scriptblock]::Create($definition))
$script:registry=@();$script:taskFailed=$false;$script:launchCount=0
function New-Item {param($Path,[switch]$Force);return @{}}
function Set-Item {param($LiteralPath,$Value);$script:registry+=@{path=$LiteralPath;value=$Value}}
function New-ItemProperty {param($Path,$LiteralPath,$Name,$Value,$PropertyType,[switch]$Force);$script:registry+=@{path=if($Path){$Path}else{$LiteralPath};name=$Name;value=$Value};return @{}}
function Remove-ItemProperty {param($Path,$Name,$ErrorAction)}
function New-ScheduledTaskAction {param($Execute,$Argument);return @{execute=$Execute;arguments=$Argument}}
function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User);return @{atLogon=$AtLogOn;user=$User}}
function New-ScheduledTaskSettingsSet {param($RestartCount,$RestartInterval,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries);Assert ($RestartCount -eq 3 -and $MultipleInstances -eq 'IgnoreNew') 'Startup task lost recovery or single-instance policy';return @{}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);Assert ($RunLevel -eq 'Limited' -and $LogonType -eq 'Interactive') 'Manager requested elevation or a service account';return @{}}
function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force);if($script:taskFailed){throw 'fixture task permission denied'};return @{}}
function Start-Manager {$script:launchCount++}
$script:ManagerRoot=Join-Path $TestRoot 'installed-manager'
$installed=Install-Manager
Assert ($installed.status -eq 'installed' -and $installed.startup -eq 'scheduled-task') 'Per-user manager installation failed'
Assert ($script:launchCount -eq 1) 'Installer did not start the installed manager'
Assert (@($script:registry|Where-Object{$_.path -like '*shell\open\command' -and $_.value -like '*-Uri "%1"'}).Count -eq 1) 'Protocol handler did not use the validated installed launcher'
$script:taskFailed=$true
$fallback=Install-Manager
Assert ($fallback.startup -eq 'user-logon') 'Denied task registration did not retain a user-logon fallback'
Assert (@($script:registry|Where-Object{$_.path -like '*CurrentVersion\Run'}).Count -eq 1) 'Fallback wrote an unexpected startup entry'
$currentFile=Join-Path $script:ManagerRoot 'current.json'
$current=Get-Content -LiteralPath $currentFile -Raw|ConvertFrom-Json
$current.managerVersion='9.0.0';Write-ManagerJson $currentFile $current
$newer=Install-Manager
Assert ($newer.managerVersion -eq '9.0.0' -and $newer.startup -eq 'preserved') 'An older provider adapter downgraded the shared manager'
# The account-bound installer starts without an AI binding or conversation.
$script:erpStarts=0; $script:erpCommand=''; $script:erpEntry=''
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
    Assert ($WindowStyle -eq 'Hidden') 'ERP installer opened a visible shell'
    $script:erpStarts++; $script:erpEntry=[string]$ArgumentList[-1]
    $child=[pscustomobject]@{Id=76543}; $child|Add-Member ScriptMethod Dispose {}; return $child
}
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); return [pscustomobject]@{ProcessId=76543;CommandLine=$script:erpCommand} }
Start-ManagerErpWorker
Assert ($script:erpStarts -eq 1 -and $script:erpEntry -like '*erp-worker.ps1*') 'ERP installer depended on an AI binding'
$script:erpCommand='powershell.exe -File ' + $script:erpEntry
Start-ManagerErpWorker
Assert ($script:erpStarts -eq 1) 'Duplicate ERP installer started'
$script:erpCommand='powershell.exe unrelated.ps1'
Start-ManagerErpWorker
Assert ($script:erpStarts -eq 2) 'A reused PID blocked ERP recovery'
$package=Join-Path $script:ManagerRoot ('packages\'+$current.version)
[IO.File]::AppendAllText((Join-Path $package 'install-erp-project.mjs'),'// synthetic tamper')
$rejected=$false
try { Start-ManagerErpWorker } catch { $rejected=$true }
Assert ($rejected -and $script:erpStarts -eq 2) 'A changed ERP runtime was started'

. (Join-Path (Split-Path -Parent $CorePath) 'erp-installation-worker.ps1')
$script:ErpWorkDirectory='C:\Synthetic\projects';$script:erpCalls=@();$script:privateSetups=0;$script:inspectCount=0
$script:erpClaim=@{job=$null;installed=@(@{id='installed-job';claim='claim-a';context=$context;project=@{id='project-a'}})}
function Invoke-InitialCredentialSetup {param($Token); Assert ($contextQuery -eq ('context='+[Uri]::EscapeDataString($context))) 'Private setup used the wrong ERP context';$script:privateSetups++}
function Invoke-ErpProjectRunner {param($Project,[switch]$InspectOnly);Assert ($Project.id -eq 'project-a' -and $InspectOnly) 'Existing ERP data was reinitialised';$script:inspectCount++;return @{projectId=$Project.id}}
function Invoke-BridgeApi {param($Method,$Path,$Token,$Body);Assert ($Path -eq '/api/plugin/erp-installations') 'ERP worker used an AI endpoint';$script:erpCalls+=,$Body;if($Body.action -eq 'claim'){return $script:erpClaim};return @{}}
Invoke-ErpInstallationWork -Token 'synthetic-not-a-credential'
Assert ($script:privateSetups -eq 1 -and $script:inspectCount -eq 1) 'Installed ERP was not checked independently'
Assert ($script:erpCalls[0].workDirectory -eq $script:ErpWorkDirectory -and $script:erpCalls[1].action -eq 'verify') 'Installer availability or proof was not recorded'
$script:erpClaim=@{installed=@();job=@{id='job-a';claim='claim-b';context_key=$context;mode='check';project=@{id='project-a'}}}
Invoke-ErpInstallationWork -Token 'synthetic-not-a-credential'
Assert ($script:erpCalls[-1].action -eq 'complete' -and $script:inspectCount -eq 2) 'Check-only adoption failed'
function Invoke-ErpProjectRunner {param($Project,[switch]$InspectOnly);throw 'synthetic missing installation'}
Invoke-ErpInstallationWork -Token 'synthetic-not-a-credential'
Assert ($script:erpCalls[-1].action -eq 'fail') 'A missing native installation became an installed state'
$script:erpDeleted=@()
function Invoke-ErpDeletion {param($Deletion);$script:erpDeleted+=,$Deletion}
$script:erpClaim=[pscustomobject]@{installed=@();job=$null;deletions=@([pscustomobject]@{requestId='synthetic-approved-delete';contextKey=$context})}
Invoke-ErpInstallationWork -Token 'synthetic-not-a-credential'
Assert ($script:erpDeleted.Count -eq 1 -and $script:erpDeleted[0].requestId -eq 'synthetic-approved-delete') 'Approved ERP deletion required an AI binding'
Assert ($script:erpCalls[-1].protocol -eq 3) 'ERPNext installation and removal capability was not advertised'
@{status='passed';checks=$script:checks;realWorkersStarted=$false;credentialsRead=$false}|ConvertTo-Json -Compress
