[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-BridgeLauncherTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-TextSha256([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
    finally { $algorithm.Dispose() }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("cogentspec-bridge-launcher-" + [Guid]::NewGuid().ToString('N'))
$fixturePlugin = Join-Path $fixtureRoot 'cogentspec'
$fixtureScripts = Join-Path $fixturePlugin 'skills\cogentspec\scripts'
$contextDigest = ([BitConverter]::ToString((Get-TextSha256 $fixtureRoot))).Replace('-', '').ToLowerInvariant()
$contextKey = "ctx-$contextDigest"
$contextHash = ([BitConverter]::ToString((Get-TextSha256 $contextKey))).Replace('-', '').ToLowerInvariant().Substring(0, 24)
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\bridge'
$statePath = Join-Path $stateRoot "$contextHash.json"
$readyPath = Join-Path $stateRoot "$contextHash.ready.json"
$connectorProcessPath = Join-Path $fixtureRoot 'connector-process.txt'
$runtimeRoot = ''
$workerProcessId = 0
$launcherProcessId = 0
$launcherProcess = $null
$originalConnectorProcessPath = $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH
$originalThreadId = $env:CODEX_THREAD_ID
$fixtureThreadId = [Guid]::NewGuid().ToString()

try {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec') -Destination $fixturePlugin -Recurse -Force

    $connectionFixture = @'
param(
    [string]$Mode,
    [string]$Surface,
    [string]$ContextKey,
    [switch]$WorkspaceGrant,
    [int]$RequestTimeoutSeconds
)
if ($Mode -ne 'status' -or -not $WorkspaceGrant -or $RequestTimeoutSeconds -ne 8) {
    throw 'The launcher did not make the bounded direct status request.'
}
[string]$PID | Set-Content -LiteralPath $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH -Encoding ascii
[ordered]@{
    status = 'connected'
    webWorkspaceCode = 'cgw_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    chatgptWorkspaceCode = 'cgw_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'connect-cogentstack.ps1') -Value $connectionFixture -Encoding UTF8

    $projectDataConnectionFixture = @'
param([string]$Surface)
[ordered]@{
    status = 'ready'
    connection = 'already_connected'
    userMessage = 'CogentSpec is ready.'
} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'ensure-cogentspec-mcp.ps1') -Value $projectDataConnectionFixture -Encoding UTF8

$watcherFixture = @'
param(
    [string]$ContextKey,
    [string]$PluginId,
    [string]$PluginVersion,
    [string]$ThreadId,
    [string]$ReadyPath
)
Start-Sleep -Milliseconds 700
for ($heartbeat = 0; $heartbeat -lt 15; $heartbeat += 1) {
    [ordered]@{
        processId = $PID
        contextKey = $ContextKey
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        threadId = $ThreadId
        serverAcknowledged = $true
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ReadyPath -Encoding UTF8
    Start-Sleep -Seconds 2
}
'@
    Set-Content -LiteralPath (Join-Path $fixtureScripts 'watch-cogentstack-bridge.ps1') -Value $watcherFixture -Encoding UTF8

    $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH = $connectorProcessPath
    $env:CODEX_THREAD_ID = $fixtureThreadId
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $launcherCommand = "& '$((Join-Path $fixtureScripts 'start-cogentstack-bridge.ps1').Replace("'", "''"))' -ContextKey '$contextKey' -Surface chatgpt"
    $encodedLauncherCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcherCommand))
    $launcherStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $launcherStartInfo.FileName = $powerShellExecutable
    $launcherStartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedLauncherCommand"
    $launcherStartInfo.UseShellExecute = $false
    $launcherStartInfo.CreateNoWindow = $true
    $launcherStartInfo.RedirectStandardOutput = $true
    $launcherStartInfo.RedirectStandardError = $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $launcherProcess = [Diagnostics.Process]::Start($launcherStartInfo)
    $stdoutTask = $launcherProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $launcherProcess.StandardError.ReadToEndAsync()
    $launcherProcessId = $launcherProcess.Id
    if (-not $launcherProcess.WaitForExit(10000)) {
        Stop-Process -Id $launcherProcessId -Force -ErrorAction SilentlyContinue
        throw 'The Bridge launcher exceeded the ten-second process limit.'
    }
    $timer.Stop()
    $launcherExitCode = $launcherProcess.ExitCode
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $launcherProcess.Dispose()
    $launcherProcess = $null
    $output = @($stdoutText, $stderrText) -split "`r?`n" | Where-Object { $_ }
    Assert-BridgeLauncherTest ($launcherExitCode -eq 0) ("The Bridge launcher process failed: {0}" -f ($output -join ' '))
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    Assert-BridgeLauncherTest ([bool]$jsonLine) 'The Bridge launcher returned no JSON result.'
    $result = $jsonLine | ConvertFrom-Json

    Assert-BridgeLauncherTest ([string]$result.status -eq 'ready') 'The Bridge launcher did not become ready.'
    Assert-BridgeLauncherTest ([string]$result.bridge -eq 'started') 'The Bridge launcher did not start the fixture worker.'
    Assert-BridgeLauncherTest ([bool]$result.presenceVerified) 'The Bridge launcher reported ready before server presence was verified.'
    Assert-BridgeLauncherTest ([string]$result.mcpState -eq 'ready') 'The secure project-data connection was not ready.'
    Assert-BridgeLauncherTest (
        [int]$result.launcherElapsedMs -ge 500 -and [int]$result.launcherElapsedMs -lt 8000
    ) ("The Bridge launcher did not wait for the delayed server acknowledgement within its eight-second in-process limit. Observed launcherElapsedMs={0}." -f [int]$result.launcherElapsedMs)
    Assert-BridgeLauncherTest ($timer.ElapsedMilliseconds -lt 10000) 'The Bridge launcher exceeded the ten-second cold-process fixture limit.'
    Assert-BridgeLauncherTest ([string]$result.webWorkspaceUrl -match '#desktop-web=') 'The web workspace handoff is missing.'
    Assert-BridgeLauncherTest ([string]$result.chatgptWorkspaceUrl -match '#desktop-chatgpt=') 'The ChatGPT workspace handoff is missing.'
    Assert-BridgeLauncherTest ([string]$result.webWorkspaceUrl -match '&open=web&nav=[a-f0-9]{32}#desktop-web=') 'The web link does not force a fresh normal-click navigation.'
    Assert-BridgeLauncherTest ([string]$result.chatgptWorkspaceUrl -match '&open=chatgpt&nav=[a-f0-9]{32}#desktop-chatgpt=') 'The ChatGPT link does not force a fresh normal-click navigation.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath $connectorProcessPath -PathType Leaf) 'The fixture connector did not record its process.'
    $connectorProcessId = [int](Get-Content -Raw -LiteralPath $connectorProcessPath)
    Assert-BridgeLauncherTest ($connectorProcessId -eq $launcherProcessId) 'The account check was launched in a nested PowerShell process.'

    $workerProcessId = [int]$result.processId
    Assert-BridgeLauncherTest ($workerProcessId -ne $launcherProcessId) 'The fixture worker incorrectly reused the launcher process.'
    Assert-BridgeLauncherTest ($workerProcessId -gt 0 -and [bool](Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue)) 'The fixture worker is not running.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath $readyPath -PathType Leaf) 'The server acknowledgement marker was not written.'
    $readyMarker = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
    Assert-BridgeLauncherTest ([int]$readyMarker.processId -eq $workerProcessId -and [bool]$readyMarker.serverAcknowledged) 'The server acknowledgement marker does not identify the verified worker.'
    Assert-BridgeLauncherTest ([string]$readyMarker.threadId -ceq $fixtureThreadId) 'The verified worker is not bound to the invoking ChatGPT task.'

    $reuseOutput = @(& (Join-Path $fixtureScripts 'start-cogentstack-bridge.ps1') -ContextKey $contextKey -Surface chatgpt 2>&1)
    $reuseJsonLine = @($reuseOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    Assert-BridgeLauncherTest ([bool]$reuseJsonLine) 'The reused Bridge launcher returned no JSON result.'
    $reuseResult = $reuseJsonLine | ConvertFrom-Json
    Assert-BridgeLauncherTest ([string]$reuseResult.status -eq 'ready' -and [string]$reuseResult.bridge -eq 'already_running') 'The Bridge launcher did not reuse the verified worker.'
    Assert-BridgeLauncherTest ([bool]$reuseResult.presenceVerified -and [int]$reuseResult.processId -eq $workerProcessId) 'The reused Bridge worker was reported ready without verified context presence.'

    $previousWorkerProcessId = $workerProcessId
    $replacementThreadId = [Guid]::NewGuid().ToString()
    $env:CODEX_THREAD_ID = $replacementThreadId
    $replacementOutput = @(& (Join-Path $fixtureScripts 'start-cogentstack-bridge.ps1') -ContextKey $contextKey -Surface chatgpt 2>&1)
    $replacementJsonLine = @($replacementOutput | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    Assert-BridgeLauncherTest ([bool]$replacementJsonLine) 'The task-rebound Bridge launcher returned no JSON result.'
    $replacementResult = $replacementJsonLine | ConvertFrom-Json
    $workerProcessId = [int]$replacementResult.processId
    Assert-BridgeLauncherTest ([string]$replacementResult.status -eq 'ready' -and [string]$replacementResult.bridge -eq 'started') 'The Bridge launcher reused a worker owned by another ChatGPT task.'
    Assert-BridgeLauncherTest ($workerProcessId -gt 0 -and $workerProcessId -ne $previousWorkerProcessId) 'The Bridge launcher did not replace the stale task-owned worker.'
    $replacementMarker = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
    Assert-BridgeLauncherTest ([string]$replacementMarker.threadId -ceq $replacementThreadId) 'The replacement Bridge worker is not bound to the new ChatGPT task.'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $runtimeRoot = Split-Path -Parent ([string]$state.watcherScript)
    }
    Assert-BridgeLauncherTest ([bool]$runtimeRoot -and (Test-Path -LiteralPath (Join-Path $runtimeRoot 'create-specification-project.ps1') -PathType Leaf)) 'The protected Bridge runtime omitted the specification project helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'inspect-project-git.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic project check helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'restore-project-version.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic version restore helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'save-project-version.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the automatic version save helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'prepare-development-handoff.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the development handoff helper.'
    Assert-BridgeLauncherTest (Test-Path -LiteralPath (Join-Path $runtimeRoot 'ensure-cogentspec-mcp.ps1') -PathType Leaf) 'The protected Bridge runtime omitted the project-data connection helper.'

    $connectorText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\connect-cogentstack.ps1')
    Assert-BridgeLauncherTest (-not $connectorText.Contains('exit 0')) 'The account helper can still terminate its calling launcher process.'
    $saveHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\save-project-version.ps1')
    Assert-BridgeLauncherTest ($saveHelperText.Contains("request.action -ne 'commit'")) 'The automatic version save helper does not require an exact commit request.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("manifest.project.requestId -ne")) 'The automatic version save helper does not verify the protected project identity.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("@('add', '--all', '--', '.')")) 'The automatic version save helper does not stage the complete approved project state.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("@('commit', '--quiet', '-m', `$message.Trim())")) 'The automatic version save helper does not use the approved version description.'
    Assert-BridgeLauncherTest ($saveHelperText.Contains("status = 'saved'")) 'The automatic version save helper does not report a verified saved result.'
    Assert-BridgeLauncherTest (-not $saveHelperText.Contains('Start-Process')) 'The automatic version save helper must not open another application.'
    $restoreHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\restore-project-version.ps1')
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("request.action -ne 'revert'")) 'The automatic version restore helper does not require an exact restore request.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('merge-base', '--is-ancestor'")) 'The automatic version restore helper does not constrain the target to current project history.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('status', '--porcelain=v1', '--untracked-files=all')")) 'The automatic version restore helper does not require a clean worktree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("@('read-tree', '--reset', '-u', `$targetHash)")) 'The automatic version restore helper does not restore the exact selected tree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("'HEAD^{tree}'")) 'The automatic version restore helper does not verify the restored tree.'
    Assert-BridgeLauncherTest ($restoreHelperText.Contains("status = 'restored'")) 'The automatic version restore helper does not report a verified restored result.'
    Assert-BridgeLauncherTest (-not $restoreHelperText.Contains('Start-Process')) 'The automatic version restore helper must not open another application.'
    $popupHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-popup.ps1')
    Assert-BridgeLauncherTest ($popupHelperText.Contains('Add-Type -AssemblyName UIAutomationClient')) 'The ChatGPT popout helper does not use the accessible composer surface.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('function Test-IsChatGptComposer')) 'The ChatGPT popout helper does not centralize the verified composer identities.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("'Work with ChatGPT', 'Ask ChatGPT anything locally', 'Ask ChatGPT anything'")) 'The ChatGPT popout helper does not recognize project and standalone composers.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[System.Windows.Automation.ValuePattern]::Pattern')) 'The ChatGPT popout helper does not inspect whether an existing draft must be preserved.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('$valuePattern.SetValue(')) 'The ChatGPT popout helper can still insert text into the composer.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$placeholderValue = $currentValue.TrimEnd("`r", "`n")')) "The ChatGPT popout helper does not recognize Chromium's empty-composer placeholder value."
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$placeholderValue -ceq [string]$composer.Current.Name')) 'The ChatGPT popout helper does not bind its empty-composer check to the verified accessible name.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('function Invoke-PopupActivation')) 'The ChatGPT popout helper does not absorb transient Windows foreground-lock failures within one click.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[DateTime]::UtcNow.AddSeconds(1)')) 'The ChatGPT popout activation retry is not bounded.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('FindPopupWindows(int[] processIds)')) 'The ChatGPT popout helper cannot inspect every signed ChatGPT tool window.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('function Find-VerifiedChatGptPopupWindow')) 'The ChatGPT popout helper does not select the exact accessible composer window.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('RevealPopupWindow')) 'The ChatGPT popout helper can expose a host-dismissed native window without reopening it through ChatGPT.'
    $desktopUiHelperText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-desktop-ui.ps1')
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('function Start-ChatGptDesktop')) 'The independent Desktop UI helper cannot launch ChatGPT Desktop.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('function Start-NewChat')) 'The independent Desktop UI helper does not create a new chat.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains("'New chat', 'Start new chat'")) 'The Desktop UI helper does not bind the verified new-chat action.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('[switch]$StartNewChat')) 'The Desktop UI helper does not require an explicit new-chat request.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('[switch]$PasteClipboard')) 'The Desktop UI helper cannot populate the new-chat composer.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('newChatStarted = $true')) 'The Desktop UI helper does not report verified new-chat creation.'
    Assert-BridgeLauncherTest ($desktopUiHelperText.Contains('messageSubmitted = $false')) 'The Desktop UI helper does not prove it left submission to the user.'
    Assert-BridgeLauncherTest (-not $desktopUiHelperText.Contains('codex://threads/')) 'The Desktop UI helper still depends on a Codex task deep link.'
    Assert-BridgeLauncherTest (-not $desktopUiHelperText.Contains('VK_RETURN')) 'The Desktop UI helper must not submit composer text.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('desktopWindowLaunched = $false')) 'The ChatGPT popout helper does not report that it preserved the existing desktop window.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('ownerThreadReopened = $false')) 'The ChatGPT popout helper still reports reopening the owning task.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('function Wait-ForChatGptTaskOwner')) 'The ChatGPT popout helper does not wait for the owning task window to become ready.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('FindMainWindows(int[] processIds)')) 'The ChatGPT popout helper cannot distinguish the main task owner from its tool-window popout.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('ActivatePopupWindow($mainWindow)')) 'The ChatGPT popout helper can still bring the full desktop task window to the foreground.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('ownerTaskActivated = $false')) 'The ChatGPT popout helper does not report that the existing task stayed in the background.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$requiredStableMilliseconds = 2000')) 'The ChatGPT popout helper does not require a stable task owner before opening the follower window.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("Status 'task_owner_not_ready'")) 'The ChatGPT popout helper does not fail closed when the task owner is unavailable.'
    $ownerReadyIndex = $popupHelperText.IndexOf('$taskOwner = Wait-ForChatGptTaskOwner')
    $shortcutLoopIndex = $popupHelperText.IndexOf('for ($attempt = 1; $attempt -le 2; $attempt++)')
    Assert-BridgeLauncherTest ($ownerReadyIndex -ge 0 -and $shortcutLoopIndex -gt $ownerReadyIndex) 'The ChatGPT popout helper can open a follower before the main task owner is ready.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('popupFollowerSettleMilliseconds = 1200')) 'The ChatGPT popout helper does not report its follower snapshot settling interval.'
    $followerSettleIndex = $popupHelperText.IndexOf('Start-Sleep -Milliseconds 1200', $shortcutLoopIndex)
    $popupComposerIndex = $popupHelperText.IndexOf('$composer = Focus-ChatGptComposer', $shortcutLoopIndex)
    Assert-BridgeLauncherTest ($followerSettleIndex -gt $shortcutLoopIndex -and $popupComposerIndex -gt $followerSettleIndex) 'The ChatGPT popout helper can focus the follower composer before its owner snapshot settles.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('popup_owner_refresh_failed')) 'The ChatGPT popout helper can still reuse an unreleased popout owner.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('$restoredHidden = ($null -ne $popupWasVisible -and -not $popupWasVisible)')) 'The ChatGPT popout helper does not report a hidden popout reopened through the host shortcut.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("ValidateSet('inspect', 'open', 'desktop', 'dismiss', 'pin', 'unpin')")) 'The ChatGPT helper does not expose separate desktop, popout, dismiss, and pin modes.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('SetPopupTopmost(IntPtr window, bool enabled)')) 'The ChatGPT popout helper does not use verified native always-on-top control.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('SWP_NOACTIVATE')) 'The ChatGPT popout pin can steal keyboard focus.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;')) 'The ChatGPT popout pin incorrectly forces a hidden window visible.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("status = if (`$shouldPin) { 'pinned' } else { 'unpinned' }")) 'The ChatGPT popout helper does not report the verified pin state.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('draftPreserved = $draftPresent')) 'The ChatGPT popout helper does not report that an existing draft was preserved.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[switch]$PasteClipboard')) 'The ChatGPT popout helper cannot distinguish the update-composer flow.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[switch]$UseRetainedChat')) 'The ChatGPT popout helper cannot explicitly reconnect the chat retained by the popout.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('Set-ChatGptComposerFromClipboard')) 'The ChatGPT popout helper cannot populate the verified update composer.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('The ChatGPT composer already contains unsent text.')) 'The ChatGPT popout helper can overwrite an unrelated draft.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('composerPreloaded = $composerPopulated')) 'The ChatGPT popout helper does not report verified update preloading.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('RequestClosePopup(IntPtr window)')) 'The ChatGPT popout helper cannot close a frozen verified popout after failed recovery.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("if (`$Mode -eq 'dismiss')")) 'The ChatGPT popout helper does not expose bounded verified dismissal recovery.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('composerDraftPreserved = [bool]$composer.draftPreserved')) 'The ChatGPT popout helper does not expose its non-destructive draft result.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("`$normalizedExistingText -eq '`$cogentspec'")) 'The ChatGPT popout helper does not safely replace its own previous connection command.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('if ($popupWasVisible -and $UseRetainedChat)')) 'The explicit connection flow still dismisses a visible retained popout before reconnecting it.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('AllowNativeRetainedFallback')) 'The retained-popout lookup can still mistake the full ChatGPT Desktop UI for an unverified Popout.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('if ($UseRetainedChat -and -not $activatedExisting -and -not $OpenWithShortcut)')) 'The retained-popout update path can still fall through to the global shortcut without an explicit connection opt-in.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("Write-Failure -Status 'retained_popup_not_visible'")) 'The retained-popout path does not fail safely into the manual Popout flow.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('for ($attempt = 1; $attempt -le 2; $attempt++)')) 'The ChatGPT popout helper does not make one bounded retry when the host only foregrounds itself on the first shortcut.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('shortcutAttempts = $shortcutAttempts')) 'The ChatGPT popout helper does not report how many shortcut attempts were required.'
    Assert-BridgeLauncherTest ($popupHelperText.IndexOf('$shortcutAttempts = 0') -lt $popupHelperText.IndexOf("if (`$Mode -eq 'inspect')")) 'The ChatGPT popout helper does not initialize its shortcut-attempt result for an already-open popout.'
    $composerFocusIndex = $popupHelperText.IndexOf('$composer = Focus-ChatGptComposer')
    Assert-BridgeLauncherTest ($composerFocusIndex -ge 0 -and $popupHelperText.IndexOf('Invoke-PopupActivation -PopupWindow $popupWindow', $composerFocusIndex) -gt $composerFocusIndex) 'The ChatGPT popout helper does not restore verified foreground activation after focusing the composer.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('Set-ChatGptComposerFocus -Composer $composer')) 'The ChatGPT popout helper does not give keyboard focus to the empty or existing composer.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('[System.Windows.Automation.AutomationElement]::NameProperty') -and $popupHelperText.Contains("'Dismiss Popout Window'")) 'The ChatGPT popout helper does not identify the exact host dismiss control before clearing its stale hover.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('CancelPopupInteraction(IntPtr window)')) 'The ChatGPT popout helper does not release the host interaction state after an X-button hide.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("SetPopupTopmost(`$popupWindow, `$false)")) 'The ChatGPT popout helper does not temporarily release a frozen pinned window.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains("SetPopupTopmost(`$popupWindow, `$true)")) 'The ChatGPT popout helper does not restore the requested pinned state after interaction recovery.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('topmostCycleReset = $topmostCycleReset')) 'The ChatGPT popout helper does not report pinned-window recovery.'
    Assert-BridgeLauncherTest ($popupHelperText.Contains('composerFocused = [bool]$composer.focused')) 'The ChatGPT popout helper does not report verified composer focus.'
    Assert-BridgeLauncherTest (-not $popupHelperText.Contains('VK_RETURN')) 'The ChatGPT popout helper must not submit composer text.'
    $popupParityPaths = @(
        'plugins\cogentstack\skills\cogentstack\scripts\open-chatgpt-popup.ps1',
        'claude-plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-popup.ps1',
        'claude-plugins\cogentstack\skills\cogentstack\scripts\open-chatgpt-popup.ps1'
    )
    foreach ($relativePath in $popupParityPaths) {
        $candidateText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot $relativePath)
        Assert-BridgeLauncherTest ($candidateText -ceq $popupHelperText) "The ChatGPT popout helper is inconsistent at $relativePath."
    }
    foreach ($scriptName in @('open-chatgpt-desktop-ui.ps1', 'start-cogentspec-desktop-ui-bridge.ps1', 'watch-cogentspec-desktop-ui-bridge.ps1')) {
        $canonicalDesktopUiText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "plugins\cogentspec\skills\cogentspec\scripts\$scriptName")
        $compatibilityDesktopUiText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "plugins\cogentstack\skills\cogentstack\scripts\$scriptName")
        Assert-BridgeLauncherTest ($compatibilityDesktopUiText -ceq $canonicalDesktopUiText) "The independent Desktop UI script is inconsistent at $scriptName."
    }
    $watcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\watch-cogentstack-bridge.ps1')
    Assert-BridgeLauncherTest ($watcherText.Contains('ChatGPT popout shown with its composer ready')) 'The Bridge does not report the ready ChatGPT composer.'
    Assert-BridgeLauncherTest ($watcherText.Contains("targetRequestId -in @('chatgpt-desktop-popup:connect', 'chatgpt-desktop-popup:update')")) 'The Bridge does not distinguish the popout connection and update composer actions.'
    Assert-BridgeLauncherTest ($watcherText.Contains("targetRequestId -in @('chatgpt-desktop-ui:connect', 'chatgpt-desktop-ui:update')")) 'The legacy project worker no longer preserves its existing Desktop UI compatibility branches.'
    Assert-BridgeLauncherTest ($watcherText.Contains("if (`$desktopUiRequest) { 'desktop' } else { 'open' }")) 'The legacy project worker no longer preserves its existing helper-mode separation.'
    Assert-BridgeLauncherTest ($watcherText.Contains("'-ThreadId', `$ThreadId")) 'The Bridge does not bind ChatGPT actions to the invoking task identity.'
    Assert-BridgeLauncherTest ($watcherText.Contains("`$arguments += '-PasteClipboard'")) 'The Bridge does not request update-composer population.'
    Assert-BridgeLauncherTest ($watcherText.Contains("`$arguments += '-UseRetainedChat'")) 'The Bridge does not request explicit reconnection of the retained popout chat.'
    Assert-BridgeLauncherTest ($watcherText.Contains("if ([string]`$Request.targetRequestId -eq 'chatgpt-desktop-popup:connect')")) 'The Bridge does not isolate the Popout connection action from the update action.'
    Assert-BridgeLauncherTest ($watcherText.Contains("`$arguments += @('-UseRetainedChat', '-OpenWithShortcut')")) 'The Popout connection action does not opt into the Ctrl+Shift+Space shortcut.'
    Assert-BridgeLauncherTest ($watcherText.Contains("} elseif ([string]`$Request.targetRequestId -eq 'chatgpt-desktop-popup:update') {")) 'The Popout update action is not kept on its fail-closed retained-window path.'
    Assert-BridgeLauncherTest ($watcherText.Contains('ChatGPT popout shown and its verified composer populated with the copied update request.')) 'The Bridge does not report verified update-composer population.'
    Assert-BridgeLauncherTest ($watcherText.Contains('ChatGPT popout shown with $cogentspec ready to send in the retained chat.')) 'The Bridge does not report the explicit connection command preload.'

    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\start-cogentstack-bridge.ps1')
    Assert-BridgeLauncherTest ($launcherText.Contains('function Confirm-StandalonePopoutConnection')) 'A successful $cogentspec invocation cannot confirm the retained Popout chat.'
    Assert-BridgeLauncherTest (($launcherText.Split('Confirm-StandalonePopoutConnection').Count - 1) -ge 3) 'The Popout confirmation is not applied to both reused and newly started task Bridge workers.'
    Assert-BridgeLauncherTest ($launcherText.Contains('popoutConnectionConfirmed = $popoutConnectionConfirmed')) 'The task Bridge does not report whether it confirmed a waiting Popout connection.'
    $desktopUiWatcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-desktop-ui-bridge.ps1')
    Assert-BridgeLauncherTest ($desktopUiWatcherText.Contains('/api/plugin/desktop-ui-actions')) 'The independent Desktop UI worker does not poll its account-level queue.'
    Assert-BridgeLauncherTest ($desktopUiWatcherText.Contains("@('chatgpt-desktop-ui:connect', 'chatgpt-desktop-ui:update')")) 'The Desktop UI worker does not restrict its two supported requests.'
    Assert-BridgeLauncherTest ($desktopUiWatcherText.Contains('-StartNewChat -PasteClipboard')) 'The Desktop UI worker does not request a new chat with a filled composer.'
    Assert-BridgeLauncherTest ($desktopUiWatcherText.Contains('A new ChatGPT Desktop chat opened with $cogentspec ready to send.')) 'The Desktop UI worker does not report the new connection chat.'
    Assert-BridgeLauncherTest ($desktopUiWatcherText.Contains('A new ChatGPT Desktop chat opened with the verified update request ready to send.')) 'The Desktop UI worker does not report the new update chat.'
    Assert-BridgeLauncherTest ($watcherText.Contains("'set_chatgpt_popup_topmost' { 'open-chatgpt-popup.ps1' }")) 'The Bridge does not route ChatGPT popout pin requests through the verified helper.'
    Assert-BridgeLauncherTest ($watcherText.Contains("'chatgpt-desktop-popup:pinned' { 'pin' }")) 'The Bridge does not validate the ChatGPT popout pin target.'
    Assert-BridgeLauncherTest ($watcherText.Contains("'chatgpt-desktop-popup:unpinned' { 'unpin' }")) 'The Bridge does not validate the ChatGPT popout unpin target.'
    Assert-BridgeLauncherTest ($watcherText.IndexOf('Write-BridgePresenceReady', $watcherText.IndexOf('Invoke-BridgeApi -Method Get')) -gt $watcherText.IndexOf('Invoke-BridgeApi -Method Get')) 'The Bridge does not record readiness after the server acknowledges context presence.'
    Assert-BridgeLauncherTest ($watcherText.Contains('serverAcknowledged = $true')) 'The Bridge readiness marker does not record server acknowledgement.'
    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'plugins\cogentspec\skills\cogentspec\scripts\start-cogentstack-bridge.ps1')
    Assert-BridgeLauncherTest ($launcherText.Contains('function Wait-BridgePresenceReady')) 'The Bridge launcher does not wait for server-acknowledged context presence.'
    Assert-BridgeLauncherTest ($launcherText.Contains('presenceVerified = $true')) 'The Bridge launcher does not expose verified context presence.'
    Assert-BridgeLauncherTest ($launcherText.Contains('$env:CODEX_THREAD_ID')) 'The Bridge launcher does not capture the invoking ChatGPT task identity.'
    Assert-BridgeLauncherTest ($launcherText.Contains('$sameThread')) 'The Bridge launcher can reuse a worker owned by a different ChatGPT task.'
    $bridgeParityRoots = @(
        'plugins\cogentstack\skills\cogentstack\scripts',
        'claude-plugins\cogentspec\skills\cogentspec\scripts',
        'claude-plugins\cogentstack\skills\cogentstack\scripts'
    )
    foreach ($relativeRoot in $bridgeParityRoots) {
        $candidateLauncherText = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $repositoryRoot $relativeRoot) 'start-cogentstack-bridge.ps1')
        $candidateWatcherText = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $repositoryRoot $relativeRoot) 'watch-cogentstack-bridge.ps1')
        Assert-BridgeLauncherTest ($candidateLauncherText -ceq $launcherText) "The Bridge launcher is inconsistent at $relativeRoot."
        Assert-BridgeLauncherTest ($candidateWatcherText -ceq $watcherText) "The Bridge watcher is inconsistent at $relativeRoot."
    }

    [ordered]@{
        status = 'valid'
        bridge = [string]$result.bridge
        launcherElapsedMs = [int]$result.launcherElapsedMs
        observedElapsedMs = [int]$timer.ElapsedMilliseconds
        directAccountCheck = $true
        boundedAccountCheckSeconds = 8
        projectDataConnection = 'ready'
        presenceVerified = [bool]$result.presenceVerified
        reuseVerified = [bool]$reuseResult.presenceVerified
        taskRebindVerified = [string]$replacementMarker.threadId -ceq $replacementThreadId
        workspaceLinksReturned = 2
    } | ConvertTo-Json -Compress
} finally {
    if ($launcherProcess) { $launcherProcess.Dispose() }
    if ($workerProcessId -gt 0 -and $workerProcessId -ne $PID) {
        $workerProcess = Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue
        if ($workerProcess) {
            Stop-Process -Id $workerProcessId -Force -ErrorAction SilentlyContinue
            [void]$workerProcess.WaitForExit(2000)
        }
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Remove-Item -LiteralPath $statePath -Force }
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) { Remove-Item -LiteralPath $readyPath -Force }
    if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    if ($null -eq $originalConnectorProcessPath) {
        Remove-Item Env:\COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH -ErrorAction SilentlyContinue
    } else {
        $env:COGENTSPEC_LAUNCHER_TEST_CONNECTOR_PROCESS_PATH = $originalConnectorProcessPath
    }
    if ($null -eq $originalThreadId) {
        Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_THREAD_ID = $originalThreadId
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
