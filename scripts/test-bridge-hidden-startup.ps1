[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$fixture = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-no-console-' + [Guid]::NewGuid().ToString('N'))))
if ([IO.Path]::GetDirectoryName($fixture) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($fixture) -notmatch '^cogentspec-no-console-[a-f0-9]{32}$') { throw 'Unsafe fixture directory' }
[void](New-Item -ItemType Directory -Path $fixture)
$watcher = Join-Path $fixture "watcher's console check.ps1"
$workerSource = @'
param([string]$ContextKey,[string]$PluginId,[string]$PluginVersion,[string]$ThreadId,[string]$ReadyPath)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FixtureConsole {
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr handle);
}
"@
$handle = [FixtureConsole]::GetConsoleWindow()
[ordered]@{ pid=$PID; consoleHandle=$handle.ToInt64(); visible=($handle -ne [IntPtr]::Zero -and [FixtureConsole]::IsWindowVisible($handle)); context=$ContextKey; plugin=$PluginId; version=$PluginVersion; thread=$ThreadId } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ReadyPath -Encoding UTF8
Start-Sleep -Seconds 45
'@
$workerSource | Set-Content -LiteralPath $watcher -Encoding UTF8
$runtimes = @((Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'))
$pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pwsh) { $runtimes += $pwsh.Source }
$results = @()
$owned = @()
$launcherDefinitions = @{}
try {
    foreach ($plugin in @('cogentspec','cogentstack')) {
        $starter = Join-Path $repository "plugins\$plugin\skills\$plugin\scripts\start-cogentstack-bridge.ps1"
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($starter, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'Launcher parse failed' }
        $definitions = foreach ($name in @('Get-BridgeWatcherCommand','Start-DetachedBridgeWatcher')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if (-not $definition) { throw "Missing launcher function: $name" }
            $definition.Extent.Text
        }
        $launcherDefinitions[$plugin] = @($definitions)
        foreach ($runtime in $runtimes) {
            $case = $plugin + '-' + [IO.Path]::GetFileNameWithoutExtension($runtime)
            $ready = Join-Path $fixture ($case + '.json')
            $parent = Join-Path $fixture ($case + '-parent.ps1')
            $escape = { param([string]$value) $value.Replace("'", "''") }
            $body = "$($definitions -join "`r`n")`r`n" + "`$worker = Start-DetachedBridgeWatcher -PowerShellExecutable '$(& $escape $runtime)' -WatcherScript '$(& $escape $watcher)' -WatcherContextKey 'ctx-fixture' -WatcherPluginId '$plugin' -WatcherPluginVersion '0.0.1' -WatcherThreadId 'fixture-thread' -WatcherReadyPath '$(& $escape $ready)'`r`n`$worker.Id"
            $body | Set-Content -LiteralPath $parent -Encoding UTF8
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $runtime
            $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $parent + '"'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($info)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'Fixture parent timed out' }
                if ($process.ExitCode -ne 0) { throw ('Fixture parent failed: ' + $stderr.GetAwaiter().GetResult()) }
                $workerId = [int]$stdout.GetAwaiter().GetResult().Trim()
                $owned += $workerId
                $deadline = [DateTime]::UtcNow.AddSeconds(12)
                while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
                $state = Get-Content -Raw -LiteralPath $ready -Encoding UTF8 | ConvertFrom-Json
                if ([int]$state.pid -ne $workerId -or [bool]$state.visible) { throw 'Worker displayed a console' }
                if ($state.context -cne 'ctx-fixture' -or $state.plugin -cne $plugin -or $state.version -cne '0.0.1' -or $state.thread -cne 'fixture-thread') { throw 'Worker argument contract changed' }
                if (-not (Get-Process -Id $workerId -ErrorAction SilentlyContinue)) { throw 'Detached worker did not survive caller exit' }
                $results += [ordered]@{ plugin=$plugin; runtime=[IO.Path]::GetFileName($runtime); visible=$false; survivedCallerExit=$true; quotedArgumentsPreserved=$true }
                Stop-Process -Id $workerId -Force
                $owned = @($owned | Where-Object { $_ -ne $workerId })
            } finally { $process.Dispose() }
        }
    }
    # This console program never calls ShowWindow or reads PowerShell flags.
    # Its first instruction measures visibility, so hiding later in PowerShell
    # cannot make a startup flash pass this regression check.
    $nativeReady = Join-Path $fixture 'native-birth.json'
    $nativeExe = Join-Path $fixture 'native-console.exe'
    $nativeReadyEscaped = $nativeReady.Replace('"', '""')
    $nativeSource = @"
using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class NativeBirthVisibility {
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr handle);
 public static void Main(string[] args) {
  bool visible=IsWindowVisible(GetConsoleWindow());
  File.WriteAllText(@"$nativeReadyEscaped", "{\"pid\":"+Process.GetCurrentProcess().Id+",\"visible\":"+visible.ToString().ToLowerInvariant()+"}");
  System.Threading.Thread.Sleep(45000);
 }
}
"@
    Add-Type -TypeDefinition $nativeSource -OutputAssembly $nativeExe -OutputType ConsoleApplication
    foreach ($plugin in @('cogentspec','cogentstack')) {
        foreach ($definition in $launcherDefinitions[$plugin]) { . ([ScriptBlock]::Create($definition)) }
        if (Test-Path -LiteralPath $nativeReady) { Remove-Item -LiteralPath $nativeReady }
        $worker = Start-DetachedBridgeWatcher -PowerShellExecutable $nativeExe -WatcherScript $watcher -WatcherContextKey 'ctx-fixture' -WatcherPluginId $plugin -WatcherPluginVersion '0.0.1' -WatcherThreadId 'fixture-thread' -WatcherReadyPath $nativeReady
        $owned += $worker.Id
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $nativeReady) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $state = Get-Content -LiteralPath $nativeReady -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$state.pid -ne $worker.Id -or [bool]$state.visible) { throw 'Native console was visible before any script could hide it' }
        $results += [ordered]@{ plugin=$plugin; runtime='native-console.exe'; visible=$false; hiddenBeforeScriptExecution=$true }
        Stop-Process -Id $worker.Id -Force
        $owned = @($owned | Where-Object { $_ -ne $worker.Id })
        $worker.Dispose()
    }
    [ordered]@{ status='valid'; cases=$results.Count; results=$results; realBridgeStarted=$false; browserOpened=$false } | ConvertTo-Json -Compress -Depth 5
} finally {
    foreach ($workerId in $owned) { Stop-Process -Id $workerId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
