Set-StrictMode -Version Latest
$script:ManagerProtocol = 'cogentspec-bridge-manager-v1'
$script:ManagerRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\bridge-manager\v1'
$script:ManagerExecution = [Guid]::NewGuid().ToString()
$script:ManagerVersion = '1.0.0'

function Get-ManagerHash([string]$Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Write-ManagerJson([string]$Path, $Value) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporary = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-ManagerProperty($Value, [string]$Name, $Default = $null) {
    if ($null -eq $Value) { return $Default }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}
function Test-ManagerDestination([string]$Surface, [string]$Experience) {
    return (($Surface -in @('chatgpt', 'claude-desktop') -and $Experience -in @('split-screen', 'web', 'popout', 'desktop-ui')) -or
        ($Surface -eq 'qwen-web' -and $Experience -eq 'web'))
}
function Test-ManagerPath([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $cursor = $full
    while ($cursor -and $cursor.Length -ge $root.TrimEnd('\').Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $true
}
function Get-ManagerCredentialFingerprint {
    $file = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Invoke-BridgeManagerApi($Body) {
    $file = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    $credential = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security }
    $bytes = $null; $token = $null
    try {
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$credential.token), $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token = [Text.Encoding]::UTF8.GetString($bytes)
        $Body.executionId = $script:ManagerExecution; $Body.version = $script:ManagerVersion
        return Invoke-RestMethod -Method Post -Uri 'https://cogentspec.com/api/bridge/manager/v1/worker' -MaximumRedirection 0 -TimeoutSec 6 `
            -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress -Depth 8)
    } finally { $token = $null; if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}
function Test-ManagerBinding($Binding, [switch]$SkipRuntimeHash) {
    try {
        if ($Binding.protocol -cne $script:ManagerProtocol -or $Binding.contextKey -cnotmatch '^ctx-[a-f0-9]{64}$' -or
            -not (Test-ManagerDestination $Binding.surface $Binding.experience) -or
            $Binding.pluginId -notin @('cogentspec', 'cogentstack') -or $Binding.pluginVersion -notmatch '^\d+\.\d+\.\d+$' -or
            $Binding.runtimeVersion -notmatch '^[a-f0-9]{24}$|^[a-f0-9]{64}$' -or $Binding.threadId -notmatch '^$|^[a-f0-9-]{36}$') { return $false }
        $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
        $expected = Join-Path $root ('bridge-runtime\' + $Binding.runtimeVersion)
        $digest = (Get-ManagerHash $Binding.contextKey).Substring(0, 24)
        $runtimeParent = Join-Path $root 'bridge-runtime'
        $state = Join-Path $root "bridge\$digest.json"
        $ready = Join-Path $root "bridge\$digest.ready.json"
        $watcher = 'watch-cogentstack-bridge.ps1'
        if ((Get-ManagerProperty $Binding 'workerKind' '') -eq 'web-v1') {
            if ($Binding.runtimeVersion -notmatch '^[a-f0-9]{64}$' -or $Binding.experience -ne 'web' -or $Binding.surface -notin @('chatgpt','claude-desktop')) { return $false }
            $runtimeParent = Join-Path $root 'web-command-v1\packages'
            $expected = Join-Path $runtimeParent ($Binding.runtimeVersion + '\runtime')
            $command = if ($Binding.surface -eq 'chatgpt') { 'gptweb' } else { 'claudeweb' }
            $digest = Get-ManagerHash $Binding.contextKey
            $state = Join-Path $root "web-command-v1\workers\$command\$digest.json"
            $ready = Join-Path $root "web-command-v1\workers\$command\$digest.ready.json"
            $watcher = 'watch-web-worker.ps1'
        }
        if ([IO.Path]::GetFullPath($Binding.runtimeRoot) -ine $expected -or -not (Test-ManagerPath $Binding.runtimeRoot $runtimeParent) -or
            [IO.Path]::GetFullPath($Binding.statePath) -ine $state -or
            [IO.Path]::GetFullPath($Binding.readyPath) -ine $ready -or
            $Binding.credentialFingerprint -cne (Get-ManagerCredentialFingerprint)) { return $false }
        $files = @($Binding.files.PSObject.Properties)
        if ($files.Count -lt 2 -or $files.Count -gt 80 -or $watcher -notin $files.Name) { return $false }
        foreach ($entry in $files) {
            if ($entry.Name -notmatch '^[a-z0-9-]+\.(ps1|mjs)$' -or [string]$entry.Value -notmatch '^[a-f0-9]{64}$') { return $false }
            $path = Join-Path $Binding.runtimeRoot $entry.Name
            if ($SkipRuntimeHash) { continue }
            if (-not (Test-ManagerPath $path $Binding.runtimeRoot) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.Value) { return $false }
        }
        return $true
    } catch { return $false }
}
function Get-ManagerBindings {
    $folder = Join-Path $script:ManagerRoot 'bindings'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @() }
    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.json' | Select-Object -First 32)) {
        try { $binding = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json; if (Test-ManagerBinding $binding -SkipRuntimeHash) { $result += $binding } } catch { }
    }
    return $result
}
function Get-ManagerWorkerCommand($Binding) {
    if ((Get-ManagerProperty $Binding 'workerKind' '') -eq 'web-v1') {
        $watcher = Join-Path $Binding.runtimeRoot 'watch-web-worker.ps1'
        $command = if ($Binding.surface -eq 'chatgpt') { 'gptweb' } else { 'claudeweb' }
        return "& '$($watcher.Replace("'", "''"))' -ContextKey '$($Binding.contextKey)' -PluginId 'cogentspec' -PluginVersion '$($Binding.pluginVersion)' -WebCommand '$command' -ReadyPath '$($Binding.readyPath.Replace("'", "''"))'"
    }
    $watcher = Join-Path $Binding.runtimeRoot 'watch-cogentstack-bridge.ps1'
    return "& '$($watcher.Replace("'", "''"))' -ContextKey '$($Binding.contextKey)' -PluginId '$($Binding.pluginId)' -PluginVersion '$($Binding.pluginVersion)' -ThreadId '$($Binding.threadId)' -ReadyPath '$($Binding.readyPath.Replace("'", "''"))'"
}
function Get-ManagerWorker($Binding) {
    if (-not (Test-Path -LiteralPath $Binding.statePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $Binding.statePath -Raw | ConvertFrom-Json
        $worker = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.processId)" -ErrorAction SilentlyContinue
        if (-not $worker) { return $null }
        $match = [regex]::Match([string]$worker.CommandLine, '(?i)-EncodedCommand\s+(?:"([A-Za-z0-9+/=]+)"|([A-Za-z0-9+/=]+))')
        $encoded = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if ([IO.Path]::GetFileName([string]$worker.ExecutablePath) -notmatch '^(powershell|pwsh)\.exe$' -or -not $match.Success) { return $null }
        $payload = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        if ($payload -cne (Get-ManagerWorkerCommand $Binding)) {
            # Windows can reuse a pre-reboot PID for an unrelated process.
            # Leave it alone and permit a fresh verified worker to start.
            if ($payload.Contains("-ContextKey '$($Binding.contextKey)'") -and $payload -match 'watch-(cogentstack-bridge|web-worker)\.ps1') { throw 'worker_identity_conflict' }
            return $null
        }
        return $worker
    } catch { if ($_.Exception.Message -eq 'worker_identity_conflict') { throw }; return $null }
}
function Start-ManagerWorker($Binding) {
    $updating = Join-Path $script:ManagerRoot 'updating.json'
    if (Test-Path -LiteralPath $updating) {
        $guard = Get-Content -LiteralPath $updating -Raw | ConvertFrom-Json
        if (([DateTime]$guard.expires).ToUniversalTime() -gt [DateTime]::UtcNow) { throw 'update_in_progress' }
    }
    if (-not (Test-ManagerBinding $Binding)) { throw 'runtime_changed' }
    $existing = Get-ManagerWorker $Binding
    if ($existing) { return @{ processId = [int]$existing.ProcessId; created = $false } }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-ManagerWorkerCommand $Binding)))
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [UInt16]0 }
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = ('"' + $powershell + '" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded)
        ProcessStartupInformation = $startup
    }
    if ([int]$created.ReturnValue -ne 0 -or [int]$created.ProcessId -le 0) { throw 'worker_unavailable' }
    $state = @{ processId = [int]$created.ProcessId; contextKey = $Binding.contextKey;
        runtimeVersion = $Binding.runtimeVersion; watcherScript = (Join-Path $Binding.runtimeRoot 'watch-cogentstack-bridge.ps1');
        readyPath = $Binding.readyPath; pluginId = $Binding.pluginId; pluginVersion = $Binding.pluginVersion; threadId = $Binding.threadId }
    if ((Get-ManagerProperty $Binding 'workerKind' '') -eq 'web-v1') {
        $state.watcher = Join-Path $Binding.runtimeRoot 'watch-web-worker.ps1'
        $state.command = if ($Binding.surface -eq 'chatgpt') { 'gptweb' } else { 'claudeweb' }
    }
    Write-ManagerJson $Binding.statePath $state
    return @{ processId = [int]$created.ProcessId; created = $true }
}
function Repair-ManagerRuntime($Binding) {
    if (-not (Test-ManagerBinding $Binding -SkipRuntimeHash)) { throw 'runtime_changed' }
    $backup = Join-Path $script:ManagerRoot ('worker-packages\' + $Binding.runtimeVersion)
    foreach ($entry in $Binding.files.PSObject.Properties) {
        $source = Join-Path $backup $entry.Name
        $target = Join-Path $Binding.runtimeRoot $entry.Name
        if (-not (Test-ManagerPath $source $backup) -or -not (Test-ManagerPath $target $Binding.runtimeRoot) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.Value) { throw 'runtime_changed' }
    }
    [void][IO.Directory]::CreateDirectory($Binding.runtimeRoot)
    foreach ($entry in $Binding.files.PSObject.Properties) {
        $target = Join-Path $Binding.runtimeRoot $entry.Name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.Value) {
            Copy-Item -LiteralPath (Join-Path $backup $entry.Name) -Destination $target -Force
        }
    }
    if (-not (Test-ManagerBinding $Binding)) { throw 'runtime_changed' }
}
function Test-ManagerReady($Binding) {
    try {
        $worker = Get-ManagerWorker $Binding
        if (-not $worker) { return $false }
        $ready = Get-Content -LiteralPath $Binding.readyPath -Raw | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - ([DateTime]$ready.acknowledgedAt).ToUniversalTime()).TotalSeconds
        return $ready.serverAcknowledged -ceq $true -and $ready.contextKey -ceq $Binding.contextKey -and
            [int]$ready.processId -eq [int]$worker.ProcessId -and $age -ge 0 -and $age -lt 10
    } catch { return $false }
}
function Stop-ManagerOwnedWorker($Binding, [int]$ProcessId) {
    $worker = Get-ManagerWorker $Binding
    if ($worker -and [int]$worker.ProcessId -eq $ProcessId) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
}
function Invoke-ManagerRequest($Request, $Bindings) {
    $binding = @($Bindings | Where-Object { $_.contextKey -ceq $Request.contextKey -and $_.surface -ceq $Request.surface -and $_.experience -ceq $Request.experience })
    $claimed = Invoke-BridgeManagerApi @{ operation = 'claim'; id = $Request.id }
    if ($claimed.status -cne 'claimed' -or $claimed.contextKey -cne $Request.contextKey -or $claimed.surface -cne $Request.surface -or
        $claimed.experience -cne $Request.experience) { return }
    $started = $null
    try {
        if ($binding.Count -ne 1) { throw 'binding_unavailable' }
        if ($Request.operation -eq 'repair') { Repair-ManagerRuntime $binding[0] }
        $suppressed = Join-Path $script:ManagerRoot ('suppressed\' + (Get-ManagerHash $Request.contextKey) + '.paused')
        Remove-Item -LiteralPath $suppressed -ErrorAction SilentlyContinue
        $started = Start-ManagerWorker $binding[0]
        $deadline = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Request.expiresAt).UtcDateTime
        if ($deadline -gt [DateTime]::UtcNow.AddSeconds(20)) { $deadline = [DateTime]::UtcNow.AddSeconds(20) }
        while ([DateTime]::UtcNow -lt $deadline) {
            # Re-claim is an idempotent liveness/cancellation check of this request.
            $active = Invoke-BridgeManagerApi @{ operation = 'claim'; id = $Request.id }
            if ($active.status -cne 'claimed') { throw 'request_cancelled' }
            if (Test-ManagerReady $binding[0]) {
                $done = Invoke-BridgeManagerApi @{ operation = 'complete'; id = $Request.id; status = 'ready' }
                if ($done.status -cne 'ready') { throw 'request_cancelled' }
                return
            }
            Start-Sleep -Milliseconds 350
        }
        throw 'worker_unavailable'
    } catch {
        if ($started -and $started.created -and $binding.Count -eq 1) { Stop-ManagerOwnedWorker $binding[0] ([int]$started.processId) }
        if ($binding.Count -eq 1) {
            $suppressed = Join-Path $script:ManagerRoot ('suppressed\' + (Get-ManagerHash $Request.contextKey) + '.paused')
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $suppressed))
            [IO.File]::WriteAllText($suppressed, 'paused')
        }
        $reason = if ($_.Exception.Message -in @('binding_unavailable', 'runtime_changed')) { $_.Exception.Message } else { 'worker_unavailable' }
        try { [void](Invoke-BridgeManagerApi @{ operation = 'complete'; id = $Request.id; status = 'failed'; reason = $reason }) } catch { }
    }
}
