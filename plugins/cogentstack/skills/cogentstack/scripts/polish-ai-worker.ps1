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
if (-not $PolishRun) { return }
function Invoke-PolishWorkerRuntime {
trap {
    if ($PolishRun -and -not $PolishMaintainer) { try { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'worker_start_failed' (Get-PolishToken) } catch { } }
    exit 1
}
if ($PolishServiceUrl -notmatch '^https://cogentspec\.(com|app)/?$' -and -not ($PolishMaintainer -and $PolishServiceUrl -match '^http://127\.0\.0\.1:\d{1,5}/?$')) { exit 1 }
if (-not $PolishMaintainer -and $PolishContextKey -notmatch '^ctx-[a-f0-9]{64}$') { exit 1 }
if ($PolishMaintainer -and (-not [IO.Path]::IsPathRooted($PolishMaintenanceRoot) -or -not [IO.Path]::IsPathRooted($PolishOperatorTokenFile))) { exit 1 }
$mutex=[Threading.Mutex]::new($false,('Local\CogentSpecPolish-'+$(if($PolishMaintainer){'maintainer'}else{$PolishContextKey})))
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
if ($null -eq ('CogentSpecPolishProcessJob' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'polish-process-job.cs') }
$receiptRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\PolishWorkers'
[void][IO.Directory]::CreateDirectory($receiptRoot)
if ((Get-Item -LiteralPath $receiptRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked worker state is not allowed.' }
$receiptFile=Join-Path $receiptRoot ($(if($PolishMaintainer){'maintainer'}else{$PolishContextKey})+'.receipt')
function Save-PolishRecovery($AssignedJob,$Process,$AttemptResult=$null) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
    $json=@{id=$AssignedJob.id;caseId=$AssignedJob.caseId;claimToken=$AssignedJob.claimToken;pid=$Process.Id;startedTicks=$Process.StartTime.Ticks;result=$AttemptResult}|ConvertTo-Json -Depth 12 -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $temporary=$receiptFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try { $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[IO.File]::WriteAllText($temporary,[Convert]::ToBase64String($cipher),[Text.UTF8Encoding]::new($false));if([IO.File]::Exists($receiptFile)){[IO.File]::Replace($temporary,$receiptFile,$null)}else{[IO.File]::Move($temporary,$receiptFile)} }
    finally { [Array]::Clear($bytes,0,$bytes.Length);$json=$null;if([IO.File]::Exists($temporary)){Remove-Item -LiteralPath $temporary -Force} }
}
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
function Stop-PolishProcess($Process,$OwnedJob=$null) {
    if ($OwnedJob) { $OwnedJob.Dispose() }
    if (-not $Process -or $Process.HasExited) { return }
    $kill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $kill /PID ([string]$Process.Id) /T /F 2>&1|Out-Null
    [void]$Process.WaitForExit(7000)
}
try {
    while ($true) {
        $process=$null;$job=$null;$ownedJob=$null;$body=$null
        try {
            if (Test-Path -LiteralPath $receiptFile) {
                if ((Get-Item -LiteralPath $receiptFile).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked receipt is not allowed.' }
                if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
                $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([IO.File]::ReadAllText($receiptFile)),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
                try { $pending=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json } finally { [Array]::Clear($plain,0,$plain.Length) }
                $prior=Get-Process -Id $pending.pid -ErrorAction SilentlyContinue
                if ($prior -and $prior.StartTime.Ticks -eq $pending.startedTicks) { Stop-PolishProcess $prior }
                $ack=@{action='cancelled';id=$pending.id;claimToken=$pending.claimToken}
                if ($pending.PSObject.Properties['result'] -and $pending.result) { $ack.result=$pending.result }
                if (-not $PolishMaintainer) { $ack.caseId=$pending.caseId }
                try { [void](Invoke-PolishApi Post $ack) }
                catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 409) { throw } }
                Remove-Item -LiteralPath $receiptFile -Force;$pending=$null
            }
            $executable=Find-PolishExecutor
            if (-not $executable) { if (-not $PolishMaintainer) { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'executor_missing' (Get-PolishToken) };break }
            $node=Get-Command node.exe,node -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
            if (-not $node) { if (-not $PolishMaintainer) { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'node_missing' (Get-PolishToken) };break }
            $claimed=if($PolishMaintainer){Invoke-PolishApi Post @{action='claim'}}else{Invoke-PolishApi Get}
            if (-not $claimed.job) { Start-Sleep -Seconds 5; continue }
            $job=$claimed.job
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$node.Source;$info.Arguments='"'+(Join-Path $PSScriptRoot 'polish-ai-executor.mjs')+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $process=[Diagnostics.Process]::new();$process.StartInfo=$info;[void]$process.Start()
            $ownedJob=[CogentSpecPolishProcessJob]::new($process.Handle)
            Save-PolishRecovery $job $process
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $executionJson=@{job=$job;review=$claimed.review;executable=$executable;maintenanceRoot=$PolishMaintenanceRoot}|ConvertTo-Json -Depth 80 -Compress
            $process.StandardInput.Write($executionJson);$process.StandardInput.Close();$executionJson=$null;$claimed=$null
            $cancelled=$false;$cancelReason='connection_lost';$deadline=[DateTime]::UtcNow.AddMinutes(45)
            while (-not $process.WaitForExit(3000)) {
                try { $reply=Invoke-PolishApi Post @{action='heartbeat';id=$job.id;caseId=$job.caseId;claimToken=$job.claimToken} }
                catch { $reply=@{shouldStop=$true} }
                if ($reply.shouldStop -or [DateTime]::UtcNow -ge $deadline) { $cancelled=$true;if([DateTime]::UtcNow -ge $deadline){$cancelReason='deadline'};Stop-PolishProcess $process $ownedJob;break }
            }
            $body=New-PolishExecutionReceipt -AssignedJob $job -OutputText $stdout.Result -ExitCode $process.ExitCode -Cancelled $cancelled -CancelReason $cancelReason -Maintainer:$PolishMaintainer
            # A network loss after the model exits must not discard its final
            # outcome. Replay only after the owned process has stopped.
            Save-PolishRecovery $job $process $body.result
            [void](Invoke-PolishApi Post $body)
            Remove-Item -LiteralPath $receiptFile -Force -ErrorAction SilentlyContinue
        } catch {
            if ($process) { Stop-PolishProcess $process $ownedJob }
            if ($job) { try { $ack=@{action='cancelled';id=$job.id;claimToken=$job.claimToken};if($body -and $body.ContainsKey('result')){$ack.result=$body.result};if(-not $PolishMaintainer){$ack.caseId=$job.caseId};[void](Invoke-PolishApi Post $ack) } catch { } }
            if (-not $PolishMaintainer) { try { Send-PolishStartupFailure $PolishContextKey $PolishServiceUrl 'worker_start_failed' (Get-PolishToken) } catch { } }
            Start-Sleep -Seconds 5
        }
        finally { if ($process) { Stop-PolishProcess $process $ownedJob; $process.Dispose() };$job=$null }
    }
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
}
Invoke-PolishWorkerRuntime
