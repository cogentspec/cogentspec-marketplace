[CmdletBinding()]
param(
    [ValidateSet('Install', 'Register', 'RegisterWeb', 'Run', 'Wake', 'Status')][string]$Mode = 'Wake',
    [string]$Uri = '', [string]$ContextKey = '', [string]$Surface = '', [string]$Experience = '',
    [string]$StatePath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bridge-manager-core.ps1')

function Start-Manager {
    $entry = Join-Path $script:ManagerRoot 'launch.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'manager_not_installed' }
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $entry + '"')) -WindowStyle Hidden | Out-Null
}
function Install-Manager {
    $currentFile = Join-Path $script:ManagerRoot 'current.json'
    if (Test-Path -LiteralPath $currentFile -PathType Leaf) {
        $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
        $currentVersion = [string](Get-ManagerProperty $current 'managerVersion' '0.0.0')
        if ($currentVersion -match '^\d+\.\d+\.\d+$' -and [version]$currentVersion -gt [version]$script:ManagerVersion) {
            if ($current.version -notmatch '^[a-f0-9]{24}$') { throw 'invalid_current_manager' }
            foreach ($name in @('bridge-manager.ps1','bridge-manager-core.ps1')) {
                $file = Join-Path $script:ManagerRoot ('packages\' + $current.version + '\' + $name)
                if (-not (Test-ManagerPath $file (Join-Path $script:ManagerRoot 'packages')) -or
                    (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $current.hashes.$name) { throw 'invalid_current_manager' }
            }
            Start-Manager
            return @{ protocol=$script:ManagerProtocol; status='installed'; startup='preserved'; managerVersion=$currentVersion }
        }
    }
    $files = @('bridge-manager.ps1', 'bridge-manager-core.ps1')
    $hashes = [ordered]@{}
    foreach ($name in $files) { $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
    $version = (Get-ManagerHash ($hashes.Values -join ':')).Substring(0, 24)
    $package = Join-Path $script:ManagerRoot "packages\$version"
    [void][IO.Directory]::CreateDirectory($package)
    foreach ($name in $files) {
        $target = Join-Path $package $name
        if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$name]) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force
        }
    }
    Write-ManagerJson (Join-Path $script:ManagerRoot 'current.json') @{ version = $version; hashes = $hashes; managerVersion = $script:ManagerVersion }
    # Stable launch path survives replacement of a versioned plugin cache.
    $launcher = @'
param([string]$Uri = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$current = Get-Content -LiteralPath (Join-Path $root 'current.json') -Raw | ConvertFrom-Json
if ($current.version -notmatch '^[a-f0-9]{24}$') { exit 1 }
$package = Join-Path $root ('packages\' + $current.version)
foreach ($name in @('bridge-manager.ps1','bridge-manager-core.ps1')) {
    if ((Get-FileHash -LiteralPath (Join-Path $package $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $current.hashes.$name) { exit 1 }
}
if ($Uri) { & (Join-Path $package 'bridge-manager.ps1') -Mode Wake -Uri $Uri }
else { & (Join-Path $package 'bridge-manager.ps1') -Mode Run }
'@
    [IO.File]::WriteAllText((Join-Path $script:ManagerRoot 'launch.ps1'), $launcher, [Text.UTF8Encoding]::new($false))
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $entry = Join-Path $script:ManagerRoot 'launch.ps1'
    $command = '"' + $powershell + '" -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $entry + '"'
    $key = 'HKCU:\Software\Classes\cogentspec-bridge'
    [void](New-Item -Path "$key\shell\open\command" -Force)
    Set-Item -LiteralPath $key -Value 'URL:CogentSpec Bridge'
    [void](New-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value '' -PropertyType String -Force)
    Set-Item -LiteralPath "$key\shell\open\command" -Value ($command + ' -Uri "%1"')
    # Per-user interactive task supplies a restart policy without elevation.
    $startup = 'scheduled-task'
    try {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $entry + '"')
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        [void](Register-ScheduledTask -TaskName ('CogentSpec Bridge ' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force)
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'CogentSpecBridgeManager' -ErrorAction SilentlyContinue
    } catch {
        [void](New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'CogentSpecBridgeManager' -Value $command -PropertyType String -Force)
        $startup = 'user-logon'
    }
    Start-Manager
    return @{ protocol = $script:ManagerProtocol; status = 'installed'; startup = $startup; managerVersion = $script:ManagerVersion }
}

if ($Mode -eq 'Install') { Install-Manager | ConvertTo-Json -Compress; return }
if ($Mode -eq 'Wake') {
    if ($Uri -and $Uri -cnotmatch '^cogentspec-bridge://(?:wake/?|reconnect/[a-f0-9-]{36}/?)$') { throw 'invalid_manager_uri' }
    # The URI cannot supply a context, executable, credential or file path.
    # Pending work is read only from the authenticated service.
    Start-Manager; return
}
if ($Mode -eq 'Status') {
    $file = Join-Path $script:ManagerRoot 'status.json'
    if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw }
    else { @{ protocol = $script:ManagerProtocol; status = 'not_running' } | ConvertTo-Json -Compress }
    return
}
if ($Mode -eq 'RegisterWeb') {
    if ($ContextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or $Surface -notin @('chatgpt','claude-desktop')) { throw 'invalid_manager_binding' }
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
    $package = Split-Path -Parent $PSScriptRoot
    $version = Split-Path -Leaf $package
    if ($version -notmatch '^[a-f0-9]{64}$' -or -not (Test-ManagerPath $package (Join-Path $root 'web-command-v1\packages'))) { throw 'invalid_web_runtime' }
    $manifestFile = Join-Path $package 'manifest.json'
    if ((Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $version) { throw 'invalid_web_runtime' }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    if ($manifest.protocol -cne 'cogentspec-web-runtime-v1') { throw 'invalid_web_runtime' }
    $command = if ($Surface -eq 'chatgpt') { 'gptweb' } else { 'claudeweb' }
    $digest = Get-ManagerHash $ContextKey
    $hashes = [ordered]@{}
    foreach ($entry in $manifest.files.PSObject.Properties) {
        if ($entry.Name -notmatch '^runtime/([a-z0-9-]+\.(ps1|mjs))$') { throw 'invalid_web_runtime' }
        $hashes[$Matches[1]] = [string]$entry.Value
    }
    $binding = [pscustomobject]@{ protocol=$script:ManagerProtocol; workerKind='web-v1'; contextKey=$ContextKey; surface=$Surface; experience='web';
        pluginId='cogentspec'; pluginVersion=$manifest.bridgeCompatibilityVersion; threadId=''; runtimeRoot=$PSScriptRoot; runtimeVersion=$version;
        statePath=(Join-Path $root "web-command-v1\workers\$command\$digest.json"); readyPath=(Join-Path $root "web-command-v1\workers\$command\$digest.ready.json");
        credentialFingerprint=(Get-ManagerCredentialFingerprint); files=[pscustomobject]$hashes }
    if (-not (Test-ManagerBinding $binding) -or -not (Test-ManagerReady $binding)) { throw 'unverified_manager_binding' }
    $backup = Join-Path $script:ManagerRoot ('worker-packages\' + $version)
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($name in $hashes.Keys) {
        $target = Join-Path $backup $name
        if (-not (Test-ManagerPath $target $backup)) { throw 'invalid_manager_backup' }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force
    }
    Write-ManagerJson (Join-Path $script:ManagerRoot ('bindings\' + (Get-ManagerHash "$ContextKey|$Surface|web") + '.json')) $binding
    [void](Install-Manager)
    return
}
if ($Mode -eq 'Register') {
    if ($ContextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or -not (Test-ManagerDestination $Surface $Experience)) { throw 'invalid_manager_binding' }
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
    $digest = (Get-ManagerHash $ContextKey).Substring(0, 24)
    if ([IO.Path]::GetFullPath($StatePath) -ine (Join-Path $root "bridge\$digest.json")) { throw 'invalid_manager_state' }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $runtime = Join-Path $root ('bridge-runtime\' + [string]$state.runtimeVersion)
    if ($state.contextKey -cne $ContextKey -or [string]$state.runtimeVersion -notmatch '^[a-f0-9]{24}$' -or -not (Test-ManagerPath $runtime (Join-Path $root 'bridge-runtime'))) { throw 'invalid_manager_runtime' }
    $hashes = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $runtime -File)) {
        if ($file.Name -notmatch '^[a-z0-9-]+\.(ps1|mjs)$') { throw 'invalid_runtime_file' }
        $hashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $binding = [pscustomobject]@{ protocol = $script:ManagerProtocol; contextKey = $ContextKey; surface = $Surface; experience = $Experience;
        pluginId = $state.pluginId; pluginVersion = $state.pluginVersion; threadId = [string](Get-ManagerProperty $state 'threadId' '');
        runtimeRoot = $runtime; runtimeVersion = $state.runtimeVersion; statePath = $StatePath; readyPath = (Join-Path $root "bridge\$digest.ready.json");
        credentialFingerprint = (Get-ManagerCredentialFingerprint); files = [pscustomobject]$hashes }
    if (-not (Test-ManagerBinding $binding) -or -not (Test-ManagerReady $binding)) { throw 'unverified_manager_binding' }
    $backup = Join-Path $script:ManagerRoot ('worker-packages\' + $state.runtimeVersion)
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($name in $hashes.Keys) {
        $target = Join-Path $backup $name
        if (-not (Test-ManagerPath $target $backup)) { throw 'invalid_manager_backup' }
        Copy-Item -LiteralPath (Join-Path $runtime $name) -Destination $target -Force
    }
    Write-ManagerJson (Join-Path $script:ManagerRoot ('bindings\' + (Get-ManagerHash "$ContextKey|$Surface|$Experience") + '.json')) $binding
    if (-not (Test-Path -LiteralPath (Join-Path $script:ManagerRoot 'launch.ps1'))) { [void](Install-Manager) } else { Start-Manager }
    return
}

$mutex = [Threading.Mutex]::new($false, 'Local\CogentSpecBridgeManager-v1')
$owned = $false; $tray = $null; $failures = 0; $restarts = @{}; $restartManager = $false
try {
    $owned = $mutex.WaitOne(0)
    if (-not $owned) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $tray = [Windows.Forms.NotifyIcon]::new()
    $tray.Icon = [Drawing.SystemIcons]::Application; $tray.Text = 'CogentSpec Bridge'; $tray.Visible = $true
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $statusItem = $menu.Items.Add('Starting Bridge...'); $statusItem.Enabled = $false
    $reconnect = $menu.Items.Add('Reconnect saved work areas')
    $reconnect.add_Click({
        $folder = Join-Path $script:ManagerRoot 'suppressed'
        if (Test-Path -LiteralPath $folder) { Get-ChildItem -LiteralPath $folder -File -Filter '*.paused' | Where-Object { $_.BaseName -match '^[a-f0-9]{64}$' } | Remove-Item -Force }
        Remove-Item -LiteralPath (Join-Path $script:ManagerRoot 'paused') -ErrorAction SilentlyContinue
        $script:nextPoll = [DateTime]::MinValue
    })
    $repair = $menu.Items.Add('Repair saved connections')
    $repair.add_Click({
        foreach ($binding in @(Get-ManagerBindings)) {
            try { Repair-ManagerRuntime $binding } catch { $statusItem.Text = 'Update Bridge to repair this connection' }
        }
        $script:nextPoll = [DateTime]::MinValue
    })
    $pause = $menu.Items.Add('Pause automatic reconnection')
    $pause.add_Click({ [IO.File]::WriteAllText((Join-Path $script:ManagerRoot 'paused'), 'paused') })
    $exitItem = $menu.Items.Add('Exit Bridge manager'); $script:managerExit = $false
    $exitItem.add_Click({ $script:managerExit = $true })
    $tray.ContextMenuStrip = $menu; $script:nextPoll = [DateTime]::MinValue
    while (-not $script:managerExit) {
        [Windows.Forms.Application]::DoEvents()
        if ([DateTime]::UtcNow -ge $script:nextPoll) {
            $updating = Join-Path $script:ManagerRoot 'updating.json'
            if (Test-Path -LiteralPath $updating) {
                try {
                    $guard = Get-Content -LiteralPath $updating -Raw | ConvertFrom-Json
                    if (([DateTime]$guard.expires).ToUniversalTime() -gt [DateTime]::UtcNow) {
                        $statusItem.Text = 'Updating Bridge...'; $script:nextPoll = [DateTime]::UtcNow.AddSeconds(1)
                        Start-Sleep -Milliseconds 200; continue
                    }
                } catch { }
            }
            $current = Get-Content -LiteralPath (Join-Path $script:ManagerRoot 'current.json') -Raw | ConvertFrom-Json
            if ($current.version -cne (Split-Path -Leaf $PSScriptRoot)) { $restartManager = $true; break }
            try {
                $bindings = @(Get-ManagerBindings)
                $reply = Invoke-BridgeManagerApi @{ operation = 'poll'; bindings = @($bindings | ForEach-Object { @{ contextKey = $_.contextKey; surface = $_.surface; experience = $_.experience } }) }
                if ($reply.protocol -cne $script:ManagerProtocol -or $reply.status -cne 'available') { throw 'manager_unavailable' }
                $failures = 0
                $paused = Test-Path -LiteralPath (Join-Path $script:ManagerRoot 'paused')
                $statusItem.Text = if ($paused) { 'Automatic reconnection paused' } else { 'Bridge manager available' }
                foreach ($request in @($reply.requests)) { Invoke-ManagerRequest $request $bindings }
                if (-not $paused) {
                    foreach ($binding in $bindings) {
                        if ($binding.contextKey -in @($reply.pausedContexts) -or (Test-Path -LiteralPath (Join-Path $script:ManagerRoot ('suppressed\' + (Get-ManagerHash $binding.contextKey) + '.paused')))) { continue }
                        $key = $binding.contextKey
                        if (-not $restarts.ContainsKey($key)) { $restarts[$key] = @() }
                        $restarts[$key] = @($restarts[$key] | Where-Object { $_ -gt [DateTime]::UtcNow.AddMinutes(-2) })
                        try {
                            if (-not (Get-ManagerWorker $binding) -and ($restarts[$key]).Count -lt 3) {
                                $restarts[$key] += [DateTime]::UtcNow
                                [void](Start-ManagerWorker $binding)
                            }
                        } catch { $statusItem.Text = 'A workspace needs connection repair' }
                    }
                }
                Write-ManagerJson (Join-Path $script:ManagerRoot 'status.json') @{ protocol = $script:ManagerProtocol; status = 'available'; paused = $paused; checkedAt = [DateTime]::UtcNow.ToString('o'); version = $script:ManagerVersion }
                $script:nextPoll = [DateTime]::UtcNow.AddSeconds(3)
            } catch {
                $failures++
                $response = Get-ManagerProperty $_.Exception 'Response'
                $code = if ($response) { [int](Get-ManagerProperty $response 'StatusCode' 0) } else { 0 }
                $statusItem.Text = if ($code -in @(401,403)) { 'Computer approval needs checking' } else { 'Waiting for connection to CogentSpec' }
                Write-ManagerJson (Join-Path $script:ManagerRoot 'status.json') @{ protocol = $script:ManagerProtocol; status = if ($code -in @(401,403)) { 'approval_required' } else { 'offline' }; checkedAt = [DateTime]::UtcNow.ToString('o') }
                $script:nextPoll = [DateTime]::UtcNow.AddSeconds([Math]::Min(30, [Math]::Pow(2, [Math]::Min(5,$failures))))
            }
        }
        Start-Sleep -Milliseconds 200
    }
} finally { if ($tray) { $tray.Visible = $false; $tray.Dispose() }; if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
if ($restartManager) { Start-Manager }
