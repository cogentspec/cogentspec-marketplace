param([string]$PolishContextKey='', [switch]$PolishRun, [switch]$PolishMaintainer, [string]$PolishMaintenanceRoot='', [string]$PolishOperatorTokenFile='', [string]$PolishServiceUrl='https://cogentspec.com')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Find-PolishExecutor {
    $command=Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    return ''
}
function Start-PolishAiWorker([string]$Key,[string]$BaseUrl='https://cogentspec.com') {
    if ($BaseUrl -notmatch '^https://cogentspec\.(com|app)/?$' -or $Key -notmatch '^ctx-[a-f0-9]{64}$' -or -not (Find-PolishExecutor)) { return }
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
}
if (-not $PolishRun) { return }
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
function Save-PolishRecovery($AssignedJob,$Process) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
    $json=@{id=$AssignedJob.id;caseId=$AssignedJob.caseId;claimToken=$AssignedJob.claimToken;pid=$Process.Id;startedTicks=$Process.StartTime.Ticks}|ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    try { $cipher=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[IO.File]::WriteAllText($receiptFile,[Convert]::ToBase64String($cipher),[Text.UTF8Encoding]::new($false)) }
    finally { [Array]::Clear($bytes,0,$bytes.Length);$json=$null }
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
        $process=$null;$job=$null;$ownedJob=$null
        try {
            if (Test-Path -LiteralPath $receiptFile) {
                if ((Get-Item -LiteralPath $receiptFile).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked receipt is not allowed.' }
                if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData } catch { Add-Type -AssemblyName System.Security } }
                $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([IO.File]::ReadAllText($receiptFile)),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
                try { $pending=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json } finally { [Array]::Clear($plain,0,$plain.Length) }
                $prior=Get-Process -Id $pending.pid -ErrorAction SilentlyContinue
                if ($prior -and $prior.StartTime.Ticks -eq $pending.startedTicks) { Stop-PolishProcess $prior }
                $ack=@{action='cancelled';id=$pending.id;claimToken=$pending.claimToken}
                if (-not $PolishMaintainer) { $ack.caseId=$pending.caseId }
                try { [void](Invoke-PolishApi Post $ack) }
                catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 409) { throw } }
                Remove-Item -LiteralPath $receiptFile -Force;$pending=$null
            }
            $executable=Find-PolishExecutor
            if (-not $executable) { break }
            $claimed=if($PolishMaintainer){Invoke-PolishApi Post @{action='claim'}}else{Invoke-PolishApi Get}
            if (-not $claimed.job) { Start-Sleep -Seconds 5; continue }
            $job=$claimed.job;$node=Get-Command node.exe,node -CommandType Application -ErrorAction Stop|Select-Object -First 1
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$node.Source;$info.Arguments='"'+(Join-Path $PSScriptRoot 'polish-ai-executor.mjs')+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $process=[Diagnostics.Process]::new();$process.StartInfo=$info;[void]$process.Start()
            $ownedJob=[CogentSpecPolishProcessJob]::new($process.Handle)
            Save-PolishRecovery $job $process
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $executionJson=@{job=$job;review=$claimed.review;executable=$executable;maintenanceRoot=$PolishMaintenanceRoot}|ConvertTo-Json -Depth 80 -Compress
            $process.StandardInput.Write($executionJson);$process.StandardInput.Close();$executionJson=$null;$claimed=$null
            $cancelled=$false;$deadline=[DateTime]::UtcNow.AddMinutes(45)
            while (-not $process.WaitForExit(3000)) {
                try { $reply=Invoke-PolishApi Post @{action='heartbeat';id=$job.id;caseId=$job.caseId;claimToken=$job.claimToken} }
                catch { $reply=@{shouldStop=$true} }
                if ($reply.shouldStop -or [DateTime]::UtcNow -ge $deadline) { $cancelled=$true;Stop-PolishProcess $process $ownedJob;break }
            }
            $body=@{action=$(if($cancelled){'cancelled'}elseif($process.ExitCode -eq 0){'finish'}else{'failed'});id=$job.id;caseId=$job.caseId;claimToken=$job.claimToken}
            if (-not $PolishMaintainer -and $body.action -eq 'finish' -and $stdout.Result.Length -lt 7000) { $result=$stdout.Result|ConvertFrom-Json;if($result.decision){$body.decision=$result.decision} }
            if ($PolishMaintainer) {
                $body.Remove('caseId')
                if ($body.action -eq 'finish' -and $stdout.Result.Length -lt 7000) { $result=$stdout.Result|ConvertFrom-Json;if($result.maintenanceProposal){$body.proposal=$result.maintenanceProposal} }
            }
            [void](Invoke-PolishApi Post $body)
            Remove-Item -LiteralPath $receiptFile -Force -ErrorAction SilentlyContinue
        } catch { Start-Sleep -Seconds 5 }
        finally { if ($process) { Stop-PolishProcess $process $ownedJob; $process.Dispose() };$job=$null }
    }
} finally { $mutex.ReleaseMutex();$mutex.Dispose() }
