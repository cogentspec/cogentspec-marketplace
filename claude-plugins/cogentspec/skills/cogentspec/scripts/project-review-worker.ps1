Set-StrictMode -Version Latest

function Stop-OwnedReviewProcess($Process) {
    if ($Process.HasExited) { return }
    try { $Process.Kill($true) } catch {
        $stop = [Diagnostics.ProcessStartInfo]::new()
        $stop.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
        $stop.Arguments = "/PID $($Process.Id) /T /F"
        $stop.UseShellExecute = $false; $stop.CreateNoWindow = $true
        $stop.RedirectStandardOutput = $true; $stop.RedirectStandardError = $true
        $killer = [Diagnostics.Process]::new(); $killer.StartInfo = $stop
        try { [void]$killer.Start(); $out = $killer.StandardOutput.ReadToEndAsync(); $err = $killer.StandardError.ReadToEndAsync(); [void]$killer.WaitForExit(5000) } finally { $killer.Dispose() }
    }
    if (-not $Process.WaitForExit(5000)) { throw 'Owned review process stop could not be confirmed.' }
}

function Invoke-ReviewProcess($Run,[string]$Token,[string]$Executable,[string[]]$Arguments,[string]$Directory,[string]$InputText,[string]$CancelFile) {
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = $Executable
    $info.WorkingDirectory = $Directory; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($info.PSObject.Properties.Name -contains 'ArgumentList') { foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) } }
    else { $info.Arguments = (@($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ') }
    # This child never receives platform credentials or the user's application
    # environment. The tested app is a further, separately sanitised child.
    $preserved = @{}; foreach ($name in @('PATH','Path','SystemRoot','WINDIR','TEMP','TMP','COMSPEC','PATHEXT','LOCALAPPDATA','APPDATA','USERPROFILE','HOME','NUMBER_OF_PROCESSORS','ProgramFiles','ProgramFiles(x86)')) { $value = [Environment]::GetEnvironmentVariable($name); if ($value) { $preserved[$name] = $value } }
    $info.EnvironmentVariables.Clear(); foreach ($name in $preserved.Keys) { $info.EnvironmentVariables[$name] = $preserved[$name] }
    $info.EnvironmentVariables['PLAYWRIGHT_BROWSERS_PATH'] = Join-Path $Directory 'browsers'
    $info.EnvironmentVariables['npm_config_cache'] = Join-Path $Directory 'npm-cache'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $cancelled = $false; $started = $false
    try {
        [void]$process.Start(); $started = $true; $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }; $process.StandardInput.Close()
        $deadline = [DateTime]::UtcNow.AddMinutes(9)
        while (-not $process.WaitForExit(2000)) {
            try { $receipt = Invoke-BridgeApi -Method Post -Path "/api/plugin/project-review-runs?$contextQuery" -Token $Token -Body @{action='heartbeat';id=[string]$Run.id;claimToken=[string]$Run.claimToken} }
            catch { $receipt = @{shouldStop=$true} }
            if ($receipt.shouldStop -or [DateTime]::UtcNow -gt $deadline) {
                $cancelled = $true
                [IO.File]::WriteAllText($CancelFile, 'stop', [Text.UTF8Encoding]::new($false))
                if (-not $process.WaitForExit(7000)) { Stop-OwnedReviewProcess $process }
                break
            }
        }
        if ($cancelled) { return @{cancelled=$true;exitCode=$process.ExitCode;output=''} }
        if ($stdout.Result.Length -gt 9000000) { throw 'Review result too large.' }
        return @{cancelled=$false;exitCode=$process.ExitCode;output=$stdout.Result}
    } finally { if ($started -and -not $process.HasExited) { Stop-OwnedReviewProcess $process }; $process.Dispose() }
}

function Invoke-ProjectReviewRuns([string]$Token) {
    $listing = Invoke-BridgeApi -Method Get -Path "/api/plugin/project-review-runs?$contextQuery&runnerProtocol=2" -Token $Token
    if (-not $listing.run) { return }; $run = $listing.run
    $body = @{id=[string]$run.id;claimToken=[string]$run.claimToken;action='failed';failure='background_checks_failed'}
    try {
        if ([string]$run.id -notmatch '^[a-f0-9-]{36}$') { throw 'Invalid run identity.' }
        $node = Get-Command node.exe,node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $node) { throw 'Node is unavailable.' }
        $lockFile = Join-Path $PSScriptRoot 'project-review-runtime-lock.json'
        $digest = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $base = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
        $runtimeBase = Join-Path $base 'ReviewRuntime'; $runtime = Join-Path $runtimeBase $digest
        $jobs = Join-Path $base 'ReviewJobs'; $job = Join-Path $jobs ([string]$run.id)
        foreach ($directory in @($base,$runtimeBase,$runtime,$jobs,$job)) {
            if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
            if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked review runtime paths are not allowed.' }
        }
        $cancel = Join-Path $job 'cancel'
        if (Test-Path -LiteralPath $cancel) { throw 'This run has already been stopped.' }
        $package = Join-Path $runtime 'package.json'; $lock = Join-Path $runtime 'package-lock.json'
        # Concurrent work areas share the same pinned browser runtime. Only one
        # installer may modify it; keep the review lease alive while waiting.
        $installationLock = $null; $lockDeadline = [DateTime]::UtcNow.AddMinutes(2)
        try {
        while (-not $installationLock) {
            try { $installationLock = [IO.File]::Open((Join-Path $runtime '.install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch [IO.IOException] {
                $heartbeat = Invoke-BridgeApi -Method Post -Path "/api/plugin/project-review-runs?$contextQuery" -Token $Token -Body @{action='heartbeat';id=[string]$run.id;claimToken=[string]$run.claimToken}
                if ($heartbeat.shouldStop) { $body.action='cancelled'; return }
                if ([DateTime]::UtcNow -gt $lockDeadline) { $body.failure='browser_setup_required'; throw 'Review runtime setup is busy.' }
                Start-Sleep -Milliseconds 1000
            }
        }
        $ready = Join-Path $runtime '.ready'
        if (-not (Test-Path -LiteralPath $ready -PathType Leaf) -or [IO.File]::ReadAllText($ready) -ne $digest) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'project-review-runtime-package.json') -Destination $package -Force
            Copy-Item -LiteralPath $lockFile -Destination $lock -Force
            $npm = Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $npmCli = Join-Path (Split-Path -Parent $npm.Source) 'node_modules\npm\bin\npm-cli.js'
            if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) { throw 'Review runtime setup is unavailable.' }
            $install = Invoke-ReviewProcess $run $Token $node.Source @($npmCli,'ci','--no-audit','--no-fund') $runtime '' $cancel
            if ($install.cancelled) { $body.action='cancelled'; return }
            if ($install.exitCode -ne 0) { $body.failure='browser_setup_required'; throw 'Review dependencies could not be prepared.' }
            $chrome = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
            if (-not (Test-Path -LiteralPath $chrome -PathType Leaf)) {
                $browser = Invoke-ReviewProcess $run $Token $node.Source @((Join-Path $runtime 'node_modules\playwright\cli.js'),'install','chromium') $runtime '' $cancel
                if ($browser.cancelled) { $body.action='cancelled'; return }
                if ($browser.exitCode -ne 0) { $body.failure='browser_setup_required'; throw 'The background browser could not be prepared.' }
            }
            [IO.File]::WriteAllText((Join-Path $runtime '.ready'),$digest,[Text.UTF8Encoding]::new($false))
        }
        } finally { if ($installationLock) { $installationLock.Dispose() } }
        $payload = @{id=[string]$run.id;projectId=[string]$run.projectId;runtimeId=[string]$run.runtimeId;targetPath=[string]$run.targetPath;contractChecksum=[string]$run.contractChecksum;taskBlueprintChecksum=[string]$run.taskBlueprintChecksum;packId=[string]$run.packId;packVersion=[string]$run.packVersion;runtimeRoot=$runtime;plan=$run.plan;cancelFile=$cancel} | ConvertTo-Json -Depth 30 -Compress
        $execution = Invoke-ReviewProcess $run $Token $node.Source @((Join-Path $PSScriptRoot 'project-review-runner.mjs')) $runtime $payload $cancel
        if ($execution.cancelled) { $body.action='cancelled' }
        else { $result = $execution.output | ConvertFrom-Json
            if ($execution.exitCode -eq 0 -and $result.result) { $body.action='complete'; $body.result=$result.result; $body.Remove('failure') }
            elseif ($result.failure) { $body.failure=[string]$result.failure }
        }
    } catch { } finally {
        Invoke-BridgeApi -Method Post -Path "/api/plugin/project-review-runs?$contextQuery" -Token $Token -Body $body | Out-Null
    }
}
