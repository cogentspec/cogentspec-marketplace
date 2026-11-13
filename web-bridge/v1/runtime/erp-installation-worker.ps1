. (Join-Path $PSScriptRoot "erp-docker-setup.ps1")
. (Join-Path $PSScriptRoot 'erp-computer-setup.ps1')
$script:LastComputerSetupId=''
$script:LastDockerSetupId=''
function Invoke-ErpInstallationWork([string]$Token) {
    $docker=Get-ErpDockerPrerequisite
    if($script:LastDockerSetupId){
        try {
            $setup=Read-ErpDockerSetup $script:LastDockerSetupId
            if($setup){$docker.requestId=$setup.id;$docker.phase=$setup.phase;$docker.reason=$setup.reason}
        } catch {$docker.requestId=$script:LastDockerSetupId;$docker.phase='failed';$docker.reason='finish_setup'}
    }
    $computer=Get-ErpComputerPrerequisite $script:ErpWorkDirectory ($docker.status -eq 'ready')
    if($script:LastComputerSetupId){
        try{$setup=Read-ErpComputerSetup $script:LastComputerSetupId;if($setup){$computer.requestId=$setup.id;$computer.phase=$setup.phase;$computer.reason=$setup.reason}}catch{$computer.requestId=$script:LastComputerSetupId;$computer.phase='failed';$computer.reason='finish_setup'}
    }
    $claimed = Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'claim'; protocol = 6; workDirectory = $script:ErpWorkDirectory; docker=$docker;computer=$computer }
    if($claimed.PSObject.Properties['cancellations']){foreach($cancellation in @($claimed.cancellations)){Complete-ErpInstallationCancellation $cancellation $Token}}
    if($claimed.PSObject.Properties['computerSetup'] -and $claimed.computerSetup){$script:LastComputerSetupId=[string]$claimed.computerSetup.id;Start-ErpComputerSetup $script:LastComputerSetupId}
    if($claimed.PSObject.Properties['dockerSetup'] -and $claimed.dockerSetup){
        $script:LastDockerSetupId=[string]$claimed.dockerSetup.id
        Start-ErpDockerSetup $script:LastDockerSetupId ([string]$claimed.dockerSetup.action)
    }
    if ($claimed.PSObject.Properties['deletions']) {
        foreach ($deletion in @($claimed.deletions)) {
            # Only server-approved ERP deletions bound to this computer are returned.
            Invoke-ErpDeletion -Deletion $deletion
        }
    }
    foreach ($installed in @($claimed.installed)) {
        # Credential work remains in its existing protected, project-bound transport.
        $contextQuery = "context=$([Uri]::EscapeDataString([string]$installed.context))"
        try { Invoke-InitialCredentialSetup -Token $Token } catch { }
        try {
            $proof = Invoke-ErpProjectRunner -Project $installed.project -InspectOnly
            Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'verify'; id = $installed.id; claim = $installed.claim; proof = $proof } | Out-Null
        } catch { }
    }
    if (-not $claimed.job) { return }
    $job = $claimed.job
    try {
        $contextQuery = "context=$([Uri]::EscapeDataString([string]$job.context_key))"
        if ($job.mode -in @('reconnect','check')) {
            $proof = Invoke-ErpProjectRunner -Project $job.project -InspectOnly:($job.mode -eq 'check')
            Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'complete'; id = $job.id; claim = $job.claim; proof = $proof } | Out-Null
            return
        }
        $project = $job.project
        if (-not $project -or $project.status -ne 'created') {
            if ($job.draft.folderStatus -ne 'ready') {
                $folder = Invoke-ErpPreparationScript 'create-specification-project.ps1' ([string]$job.draft_id) ([string]$job.context_key) $job $Token
                $folderResult = ($folder -join "`n") | ConvertFrom-Json
                if ($folderResult.status -ne 'specification_created') { throw 'The approved project folder is not ready.' }
            }
            $prepared = Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'foundation'; id = $job.id; claim = $job.claim }
            $project = $prepared.project
            $job.project=$project
            $foundation = Invoke-ErpPreparationScript 'fulfil-project.ps1' ([string]$project.id) ([string]$job.context_key) $job $Token
            $foundationResult = ($foundation -join "`n") | ConvertFrom-Json
            if ($foundationResult.status -ne 'created') { throw 'The approved ERP foundation is not ready.' }
        }
        Assert-ErpInstallationActive $job $Token
        $proof = Invoke-ErpProjectRunner -Project $project -InstallationJob $job -Token $Token
        Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'complete'; id = $job.id; claim = $job.claim; proof = $proof } | Out-Null
    } catch {
        if($job.mode -eq 'install'){
            # A stopped CLI can leave server-side Docker work alive. Always stop
            # this unverified installation's own resources before reporting failure.
            $stopped=if($job.project){Invoke-ErpProjectRunner -Project $job.project -StopOnly}else{@{stopped=$true;dataKept=$true}}
            $status=Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{action='status';id=$job.id;claim=$job.claim}
            if($status.cancelRequested){Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{action='cancelled';id=$job.id;claim=$job.claim;proof=$stopped}|Out-Null;return}
        }
        Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{ action = 'fail'; id = $job.id; claim = $job.claim } | Out-Null
    }
}

function Assert-ErpInstallationActive($Job,[string]$Token){
    if(-not $Job){return}
    $progress=if($Job.PSObject.Properties['progress']){$Job.progress}else{$null}
    $status=Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{action='status';id=$Job.id;claim=$Job.claim;progress=$progress}
    if($status.cancelRequested -or $status.state -ne 'installing'){throw 'ERP installation cancelled.'}
}
function New-ErpInstallationProcessJob($Process){
    if(-not ('CogentErpInstallationProcessJob' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class CogentErpInstallationProcessJob : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Basic { public long A,B;public uint Flags;public UIntPtr C,D;public uint E;public UIntPtr F;public uint G,H; }
 [StructLayout(LayoutKind.Sequential)] struct Io { public ulong A,B,C,D,E,F; }
 [StructLayout(LayoutKind.Sequential)] struct Limits { public Basic Basic;public Io Io;public UIntPtr A,B,C,D; }
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref Limits info,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 IntPtr handle;
 public CogentErpInstallationProcessJob(IntPtr process){handle=CreateJobObject(IntPtr.Zero,null);if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());var info=new Limits();info.Basic.Flags=0x2000;if(!SetInformationJobObject(handle,9,ref info,(uint)Marshal.SizeOf(typeof(Limits)))||!AssignProcessToJobObject(handle,process)){int error=Marshal.GetLastWin32Error();Dispose();throw new Win32Exception(error);}}
 public void Release(){var info=new Limits();if(!SetInformationJobObject(handle,9,ref info,(uint)Marshal.SizeOf(typeof(Limits))))throw new Win32Exception(Marshal.GetLastWin32Error());Dispose();}
 public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}GC.SuppressFinalize(this);}
 ~CogentErpInstallationProcessJob(){Dispose();}
}
'@
    }
    return [CogentErpInstallationProcessJob]::new($Process.Handle)
}
function Read-ErpInstallationProgress($Job,[string]$Path,$Started){
    if(-not $Job -or -not $Path){return}
    try{
        $file=Get-Item -LiteralPath $Path -ErrorAction Stop
        if($file.Length -gt 4096 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){return}
        $sample=Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
        if($sample.projectId -eq $Job.project.id -and ([DateTime]$sample.updatedAt).ToUniversalTime() -ge $Started.ToUniversalTime()){$Job|Add-Member -NotePropertyName progress -NotePropertyValue $sample -Force}
    }catch{}
}
function Invoke-ErpControlledProcess($Start,[string]$InputText,$Job,[string]$Token,[int]$Deadline=2400000,[string]$ProgressPath=''){
    $process=$null;$guard=$null
    try{
        Assert-ErpInstallationActive $Job $Token
        $process=New-Object Diagnostics.Process;$process.StartInfo=$Start;[void]$process.Start()
        # No assignment is written to stdin until the whole process tree is owned.
        $guard=New-ErpInstallationProcessJob $process
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText);$process.StandardInput.Close()
        $timer=[Diagnostics.Stopwatch]::StartNew();$lastPoll=0
        while(-not $process.WaitForExit(1000)){
            if($timer.ElapsedMilliseconds -ge $Deadline){throw 'Installation timed out.'}
            if($Job -and $timer.ElapsedMilliseconds-$lastPoll -ge 5000){Read-ErpInstallationProgress $Job $ProgressPath $process.StartTime;Assert-ErpInstallationActive $Job $Token;$lastPoll=$timer.ElapsedMilliseconds}
        }
        Read-ErpInstallationProgress $Job $ProgressPath $process.StartTime
        Assert-ErpInstallationActive $Job $Token
        if($process.ExitCode -ne 0){throw 'Installation failed.'}
        $output=$outTask.GetAwaiter().GetResult();[void]$errTask.GetAwaiter().GetResult()
        $guard.Release();return $output
    }finally{
        if($guard){$guard.Dispose()}
        if($process){try{if(-not $process.HasExited){$process.Kill()}}catch{};$process.Dispose()}
    }
}
function Invoke-ErpPreparationScript([string]$Name,[string]$RequestId,[string]$Context,$Job,[string]$Token){
    if($Name -notin @('create-specification-project.ps1','fulfil-project.ps1') -or $RequestId -notmatch '^[a-f0-9-]{36}$' -or $Context -notmatch '^ctx-[a-f0-9]{64}$'){throw 'Invalid installation preparation identity.'}
    $entry=(Join-Path $PSScriptRoot $Name).Replace("'","''")
    $command="[void][Console]::ReadLine(); & '$entry' -Mode create -RequestId '$RequestId' -ContextKey '$Context'"
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    return Invoke-ErpControlledProcess $start "go`n" $Job $Token
}
function Complete-ErpInstallationCancellation($Job,[string]$Token){
    $proof=if($Job.project){Invoke-ErpProjectRunner -Project $Job.project -StopOnly}else{@{stopped=$true;dataKept=$true}}
    Invoke-BridgeApi -Method Post -Path '/api/plugin/erp-installations' -Token $Token -Body @{action='cancelled';id=$Job.id;claim=$Job.claim;proof=$proof}|Out-Null
}
function Invoke-ErpProjectRunner($Project, [switch]$InspectOnly,[switch]$StopOnly,$InstallationJob=$null,[string]$Token='') {
        $node = Get-Command node.exe, node -ErrorAction Stop | Select-Object -First 1
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $node.Source
        $start.Arguments = '"' + (Join-Path $PSScriptRoot 'install-erp-project.mjs') + '"'
        if ($InspectOnly) { $start.Arguments += ' --inspect' }
        if ($StopOnly) { $start.Arguments += ' --stop' }
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $installationDeadline = if ($Project.projectType -eq 'erpnext_business_app') { 7200000 } else { 1200000 }
        if($StopOnly){$installationDeadline=120000}
        $progressPath=if($InstallationJob){Join-Path $Project.targetPath '.coge\runtime\installation-progress.json'}else{''}
        $output=Invoke-ErpControlledProcess $start ($Project|ConvertTo-Json -Depth 8 -Compress) $InstallationJob $Token $installationDeadline $progressPath
        return ($output|ConvertFrom-Json)
}

function Invoke-ErpDeletion($Deletion) {
    if ([string]$Deletion.requestId -notmatch '^[a-f0-9-]{36}$' -or [string]$Deletion.contextKey -notmatch '^(ctx-[a-f0-9]{64}|default)$') { throw 'The approved ERP deletion identity is invalid.' }
    $process = $null
    try {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $entry = Join-Path $PSScriptRoot 'erp-delete-project.ps1'
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $entry + '" -Mode delete -RequestId "' + $Deletion.requestId + '" -ContextKey "' + $Deletion.contextKey + '"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process; $process.StartInfo = $start; [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(900000)) { $process.Kill(); throw 'ERP removal was interrupted and requires confirmation before retrying.' }
        if ($process.ExitCode -ne 0) { throw 'ERP removal could not finish.' }
    } finally { if ($process) { $process.Dispose() } }
}
