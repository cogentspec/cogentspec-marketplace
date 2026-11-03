param([string]$PolishContextKey='', [switch]$PolishRun, [switch]$PolishMaintainer, [string]$PolishMaintenanceRoot='', [string]$PolishOperatorTokenFile='', [string]$PolishServiceUrl='https://cogentspec.com')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Resolve-PolishNpmExecutor([string]$Shim,[string]$Architecture=$env:PROCESSOR_ARCHITECTURE) {
    # Never run a .cmd through a shell. Resolve only the official installed
    # package's native binary, using the layouts supported by its CLI loader.
    if (-not [IO.Path]::IsPathRooted($Shim) -or [IO.Path]::GetFileName($Shim) -ine 'codex.cmd' -or -not (Test-Path -LiteralPath $Shim -PathType Leaf)) { return '' }
    $target='';$platform=''
    if ($Architecture -match '^(AMD64|x64)$') { $target='x86_64-pc-windows-msvc';$platform='codex-win32-x64' }
    elseif ($Architecture -eq 'ARM64') { $target='aarch64-pc-windows-msvc';$platform='codex-win32-arm64' }
    else { return '' }
    try {
        $packageRoot=Join-Path (Split-Path -Parent $Shim) 'node_modules\@openai\codex'
        $manifest=Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'package.json')|ConvertFrom-Json
        if ($manifest.name -ne '@openai/codex' -or $manifest.bin.codex -ne 'bin/codex.js' -or -not (Test-Path -LiteralPath (Join-Path $packageRoot 'bin\codex.js') -PathType Leaf)) { return '' }
        $vendors=@((Join-Path $packageRoot ('node_modules\@openai\'+$platform+'\vendor')),(Join-Path (Split-Path -Parent $packageRoot) ($platform+'\vendor')),(Join-Path $packageRoot 'vendor'))
        foreach ($vendor in $vendors) { foreach ($layout in @('bin','codex')) {
            $candidate=Join-Path $vendor ($target+'\'+$layout+'\codex.exe')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $item=Get-Item -LiteralPath $candidate
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [string]$item.FullName }
            }
        } }
    } catch { }
    return ''
}
function Find-PolishExecutor {
    $command=Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    $shim=Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shim) { return Resolve-PolishNpmExecutor ([string]$shim.Source) }
    return ''
}
function Send-PolishStartupFailure([string]$Key,[string]$BaseUrl,[string]$Reason,[string]$Token) {
    if (-not $Token -or $BaseUrl -notmatch '^https://cogentspec\.(com|app)/?$' -or $Key -notmatch '^ctx-[a-f0-9]{64}$' -or $Reason -notin @('executor_missing','node_missing','worker_start_failed')) { return }
    try { [void](Invoke-RestMethod -Method Post -Uri ($BaseUrl.TrimEnd('/')+'/api/plugin/polish-work?context='+[Uri]::EscapeDataString($Key)+'&executorProtocol=1') -Headers @{Authorization='Bearer '+$Token;Accept='application/json'} -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes((@{action='startup_failed';reason=$Reason}|ConvertTo-Json -Compress))) -TimeoutSec 6 -MaximumRedirection 0) } catch { }
}
function Start-PolishAiWorker([string]$Key,[string]$BaseUrl='https://cogentspec.com',[string]$Token='') {
    if ($BaseUrl -notmatch '^https://cogentspec\.(com|app)/?$' -or $Key -notmatch '^ctx-[a-f0-9]{64}$') { return }
    if (-not (Find-PolishExecutor)) { Send-PolishStartupFailure $Key $BaseUrl 'executor_missing' $Token;return }
    if (-not (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)) { Send-PolishStartupFailure $Key $BaseUrl 'node_missing' $Token;return }
    try {
    $base=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\PolishWorkers'
    [void][IO.Directory]::CreateDirectory($base)
    if ((Get-Item -LiteralPath $base).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    $file=Join-Path $base ($Key+'.json')
    if (Test-Path -LiteralPath $file) {
        try { $state=Get-Content -Raw -LiteralPath $file|ConvertFrom-Json; $prior=Get-Process -Id $state.pid -ErrorAction SilentlyContinue; if ($prior -and $prior.StartTime.Ticks -eq $state.startedTicks) { return } } catch { }
    }
    $script=Join-Path $PSScriptRoot 'polish-ai-worker.ps1'
    $command="& '"+$script.Replace("'","''")+"' -PolishRun -PolishContextKey '"+$Key+"' -PolishServiceUrl '"+$BaseUrl+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $ps=(Get-Process -Id $PID).Path
    $worker=Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    [IO.File]::WriteAllText($file,(@{pid=$worker.Id;startedTicks=$worker.StartTime.Ticks;startedAt=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    } catch { Send-PolishStartupFailure $Key $BaseUrl 'worker_start_failed' $Token }
}
function Get-PolishToken {
    if ($PolishMaintainer) { return [IO.File]::ReadAllText($PolishOperatorTokenFile).Trim() }
    $file=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
    $record=Get-Content -Raw -LiteralPath $file|ConvertFrom-Json
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($record.token),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes,0,$bytes.Length);$record=$null }
}
function New-PolishExecutionReceipt($AssignedJob,[string]$OutputText,[int]$ExitCode,[bool]$Cancelled=$false,[string]$CancelReason='connection_lost',[switch]$Maintainer) {
    $body=@{action=$(if($Cancelled){'cancelled'}elseif($ExitCode -eq 0){'finish'}else{'failed'});id=$AssignedJob.id;caseId=$AssignedJob.caseId;claimToken=$AssignedJob.claimToken}
    $result=$null
    if (-not $Cancelled -and $OutputText.Length -lt 10000) { try { $candidate=$OutputText|ConvertFrom-Json;if(@('protocol','outcome','reason','summary','nextStep','exitCode','checkpoint','decision','maintenanceProposal')|Where-Object{-not $candidate.PSObject.Properties[$_]}){throw 'Incomplete result.'};$result=$candidate } catch { } }
    if ($result -and $result.protocol -eq 1) {
        $body.result=@{protocol=1;outcome=$result.outcome;reason=$result.reason;summary=$result.summary;nextStep=$result.nextStep;exitCode=$result.exitCode;checkpoint=$result.checkpoint}
        if ($result.outcome -eq 'failed') { $body.action='failed' }
        if ($result.outcome -eq 'cancelled') { $body.action='cancelled' }
        if (-not $Maintainer -and $body.action -eq 'finish' -and $result.decision) { $body.decision=$result.decision }
        if ($Maintainer -and $body.action -eq 'finish' -and $result.maintenanceProposal) { $body.proposal=$result.maintenanceProposal }
    } else {
        $body.result=@{protocol=1;outcome=$(if($Cancelled){'cancelled'}else{'failed'});reason=$(if($Cancelled){$CancelReason}else{'invalid_result'});summary='The worker stopped before a structured result was recorded.';nextStep='Check the retained project changes before continuing.';exitCode=$ExitCode;checkpoint=$null}
        if (-not $Cancelled) { $body.action='failed' }
    }
    if ($Maintainer) { $body.Remove('caseId') }
    return $body
}
function Save-PolishRecovery([string]$ReceiptFile,$AssignedJob,$ProcessIdentity,$Delivery=$null) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
    if ([IO.File]::Exists($ReceiptFile) -and ((Get-Item -LiteralPath $ReceiptFile).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked receipt is not allowed.' }
    $json=@{id=$AssignedJob.id;caseId=$AssignedJob.caseId;claimToken=$AssignedJob.claimToken;pid=$ProcessIdentity.pid;startedTicks=$ProcessIdentity.startedTicks;delivery=$Delivery}|ConvertTo-Json -Depth 12 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $temporary=$ReceiptFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    # A PowerShell $null binds to an empty string here. Use a typed null for
    # File.Replace's optional backup filename in both Windows PS 5 and PS 7.
    try { $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[IO.File]::WriteAllText($temporary,[Convert]::ToBase64String($cipher),[Text.UTF8Encoding]::new($false));if([IO.File]::Exists($ReceiptFile)){[IO.File]::Replace($temporary,$ReceiptFile,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$ReceiptFile)} }
    finally { [Array]::Clear($bytes,0,$bytes.Length);$json=$null;if([IO.File]::Exists($temporary)){Remove-Item -LiteralPath $temporary -Force} }
}
function Read-PolishRecovery([string]$ReceiptFile) {
    $item=Get-Item -LiteralPath $ReceiptFile
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536) { throw 'Invalid private receipt.' }
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([IO.File]::ReadAllText($ReceiptFile)),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json } finally { [Array]::Clear($plain,0,$plain.Length) }
}
function Stop-PolishProcess($Process,$OwnedJob=$null) {
    if ($OwnedJob) { $OwnedJob.Dispose() }
    try { $processId=[int]$Process.Id } catch { return }
    if ($processId -le 0) { return }
    if (-not $Process -or $Process.HasExited) { return }
    $kill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $kill /PID ([string]$processId) /T /F 2>&1|Out-Null
    if (-not $Process.WaitForExit(7000)) { throw 'Worker shutdown is not confirmed.' }
}
function Restore-PolishRecovery([string]$ReceiptFile,[scriptblock]$SendApi,[switch]$Maintainer) {
    if (-not [IO.File]::Exists($ReceiptFile)) { return }
    $pending=Read-PolishRecovery $ReceiptFile
    $prior=$null
    if ($pending.pid -gt 0) { $prior=Get-Process -Id $pending.pid -ErrorAction SilentlyContinue }
    if ($prior -and $prior.StartTime.Ticks -eq $pending.startedTicks) { Stop-PolishProcess $prior }
    $ack=@{action='cancelled';id=$pending.id;claimToken=$pending.claimToken}
    if (-not $Maintainer) { $ack.caseId=$pending.caseId }
    if ($pending.PSObject.Properties['delivery'] -and $pending.delivery) {
        $ack.action='recover';$ack.result=$pending.delivery.result
        foreach ($name in @('decision','proposal')) { if ($pending.delivery.PSObject.Properties[$name]) { $ack[$name]=$pending.delivery.$name } }
    } elseif ($pending.PSObject.Properties['result'] -and $pending.result) { $ack.result=$pending.result }
    $reply=& $SendApi Post $ack
    if (-not (($reply.PSObject.Properties['receiptSettled'] -and $reply.receiptSettled) -or ($reply.PSObject.Properties['receiptExpired'] -and $reply.receiptExpired))) { throw 'The saved result has not been acknowledged.' }
    Remove-Item -LiteralPath $ReceiptFile -Force
}
# One claimed attempt, shared by the production loop and the Windows lifecycle
# test. The runtime below supplies only its fixed service API and bundled executor.
function Read-PolishExecutionOutput($State,[switch]$UntilClosed) {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while (-not $State.closed) {
        if (-not $State.pending.IsCompleted) {
            if (-not $UntilClosed) { return }
            if ([DateTime]::UtcNow -ge $deadline -or -not $State.pending.Wait(1000)) { if([DateTime]::UtcNow -ge $deadline){throw 'Execution output did not close.'};continue }
        }
        $line=$State.pending.Result
        if ($null -eq $line) { $State.closed=$true;return }
        $State.pending=$State.reader.ReadLineAsync()
        if (-not $line -or $line.Length -gt 12000) { continue }
        try {
            $entry=$line|ConvertFrom-Json
            if ($entry.PSObject.Properties['type'] -and $entry.type -eq 'polish_activity') {
                $activity=$entry.activity
                $allowed=@('protocol','sequence','sampledAt','currentTask','currentTaskStartedAt','lastCompleted','lastMeaningfulAt','completedSteps','failedSteps','checksSucceeded','checksFailed','sourceUpdates','sourceChangedAt','outputsUpdated','outputsUpdatedAt')
                if($activity.protocol -eq 1 -and $activity.sequence -gt 0 -and -not @($activity.PSObject.Properties.Name|Where-Object{$_ -notin $allowed}).Count -and (-not $State.activity -or $activity.sequence -gt $State.activity.sequence)){$State.activity=$activity}
            } elseif ($entry.PSObject.Properties['protocol'] -and $entry.PSObject.Properties['outcome']) { $State.finalText=$line }
        } catch { } # Optional observation data cannot replace the final result.
    }
}
function Invoke-PolishAssignment($Claimed,[string]$Executable,[string]$Node,[string]$ExecutorPath,[string]$ReceiptFile,[scriptblock]$SendApi,[string]$MaintenanceRoot='',[switch]$Maintainer) {
    $process=$null;$ownedJob=$null;$identity=@{pid=0;startedTicks=0};$body=$null;$job=$Claimed.job
    try {
        if ($null -eq ('CogentSpecPolishProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'polish-process-job.cs') }
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Node;$info.Arguments='"'+$ExecutorPath+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info;[void]$process.Start()
        $identity=@{pid=$process.Id;startedTicks=$process.StartTime.Ticks}
        $ownedJob=[CogentSpecPolishProcessJob]::new($process.Handle)
        Save-PolishRecovery $ReceiptFile $job $identity
        $outputState=@{reader=$process.StandardOutput;pending=$process.StandardOutput.ReadLineAsync();closed=$false;activity=$null;finalText=''};$stderr=$process.StandardError.ReadToEndAsync()
        $executionJson=@{job=$job;review=$Claimed.review;executable=$Executable;maintenanceRoot=$MaintenanceRoot}|ConvertTo-Json -Depth 80 -Compress
        $process.StandardInput.Write($executionJson);$process.StandardInput.Close();$executionJson=$null
        $cancelled=$false;$cancelReason='connection_lost';$deadline=[DateTime]::UtcNow.AddMinutes(45)
        while (-not $process.WaitForExit(3000)) {
            Read-PolishExecutionOutput $outputState
            try { $heartbeat=@{action='heartbeat';id=$job.id;caseId=$job.caseId;claimToken=$job.claimToken};if($outputState.activity){$heartbeat.activity=$outputState.activity};$reply=& $SendApi Post $heartbeat }
            catch { $reply=@{shouldStop=$true} }
            if ($reply.shouldStop -or [DateTime]::UtcNow -ge $deadline) { $cancelled=$true;if([DateTime]::UtcNow -ge $deadline){$cancelReason='deadline'};Stop-PolishProcess $process $ownedJob;break }
        }
        Stop-PolishProcess $process $ownedJob
        Read-PolishExecutionOutput $outputState -UntilClosed
        if($outputState.activity){try{[void](& $SendApi Post @{action='heartbeat';id=$job.id;caseId=$job.caseId;claimToken=$job.claimToken;activity=$outputState.activity})}catch{}}
        $body=New-PolishExecutionReceipt -AssignedJob $job -OutputText $outputState.finalText -ExitCode $process.ExitCode -Cancelled $cancelled -CancelReason $cancelReason -Maintainer:$Maintainer
        # Persist the entire delivery, including a question/proposal, before HTTP.
        Save-PolishRecovery $ReceiptFile $job $identity $body
        $receipt=& $SendApi Post $body
        # HTTP 200 can still mean "stop, lease expired" without recording the
        # result. Keep the final receipt until the controller confirms settlement.
        if (-not $receipt.PSObject.Properties['state']) { throw 'The execution result has not been recorded.' }
        Remove-Item -LiteralPath $ReceiptFile -Force
    } catch {
        if ($process) { Stop-PolishProcess $process $ownedJob }
        if (-not $body) {
            $failure=New-PolishExecutionReceipt -AssignedJob $job -OutputText '' -ExitCode 1 -Cancelled $true -CancelReason 'worker_error' -Maintainer:$Maintainer
            Save-PolishRecovery $ReceiptFile $job $identity $failure
        }
        # Keep the receipt for delivery recovery. An executed attempt is never
        # relabelled as a startup failure, nor followed by a new claim here.
        throw
    } finally { if ($process) { Stop-PolishProcess $process $ownedJob;$process.Dispose() } }
}
if (-not $PolishRun) { return }
function Invoke-PolishWorkerRuntime {
if ($PolishServiceUrl -notmatch '^https://cogentspec\.(com|app)/?$' -and -not ($PolishMaintainer -and $PolishServiceUrl -match '^http://127\.0\.0\.1:\d{1,5}/?$')) { exit 1 }
if (-not $PolishMaintainer -and $PolishContextKey -notmatch '^ctx-[a-f0-9]{64}$') { exit 1 }
if ($PolishMaintainer -and (-not [IO.Path]::IsPathRooted($PolishMaintenanceRoot) -or -not [IO.Path]::IsPathRooted($PolishOperatorTokenFile))) { exit 1 }
$mutex=[Threading.Mutex]::new($false,('Local\CogentSpecPolish-'+$(if($PolishMaintainer){'maintainer'}else{$PolishContextKey})))
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$receiptRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\PolishWorkers'
[void][IO.Directory]::CreateDirectory($receiptRoot)
if ((Get-Item -LiteralPath $receiptRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked worker state is not allowed.' }
$receiptFile=Join-Path $receiptRoot ($(if($PolishMaintainer){'maintainer'}else{$PolishContextKey})+'.receipt')
function Invoke-PolishApi([string]$Method,$Body=$null) {
    $token=Get-PolishToken
    if (-not $token) { throw 'AI connection unavailable.' }
    $uri=if($PolishMaintainer){$PolishServiceUrl+'/api/internal/polish-maintenance'}else{$PolishServiceUrl+'/api/plugin/polish-work?context='+[Uri]::EscapeDataString($PolishContextKey)+'&executorProtocol=1'}
    $headers=@{Authorization='Bearer '+$token;Accept='application/json'}
    try {
        if ($null -eq $Body) { return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec 15 -MaximumRedirection 0 }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 12 -Compress))) -TimeoutSec 15 -MaximumRedirection 0
    } finally { $token=$null;$headers=$null }
}
try {
    while ($true) {
        $job=$null
        try {
            Restore-PolishRecovery $receiptFile ${function:Invoke-PolishApi} -Maintainer:$PolishMaintainer
            $executable=Find-PolishExecutor
            if (-not $executable) { if (-not $PolishMaintainer) { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'executor_missing' (Get-PolishToken) };break }
            $node=Get-Command node.exe,node -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
            if (-not $node) { if (-not $PolishMaintainer) { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'node_missing' (Get-PolishToken) };break }
            $claimed=if($PolishMaintainer){Invoke-PolishApi Post @{action='claim'}}else{Invoke-PolishApi Get}
            if (-not $claimed.job) { Start-Sleep -Seconds 5; continue }
            $job=$claimed.job
            Invoke-PolishAssignment -Claimed $claimed -Executable $executable -Node $node.Source -ExecutorPath (Join-Path $PSScriptRoot 'polish-ai-executor.mjs') -ReceiptFile $receiptFile -SendApi ${function:Invoke-PolishApi} -MaintenanceRoot $PolishMaintenanceRoot -Maintainer:$PolishMaintainer
        } catch {
            # Only pre-claim failures are startup failures. Once claimed, the
            # protected receipt owns recovery and must settle before a new claim.
            if (-not $job -and -not [IO.File]::Exists($receiptFile) -and -not $PolishMaintainer) { try { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'worker_start_failed' (Get-PolishToken) } catch { } }
            Start-Sleep -Seconds 5
        } finally { $job=$null;$claimed=$null }
    }
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
}
Invoke-PolishWorkerRuntime
