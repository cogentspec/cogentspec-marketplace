[CmdletBinding()]
param([string]$HelperPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $HelperPath) { $HelperPath = Join-Path $repositoryRoot 'plugins/cogentspec/skills/cogentspec/scripts/open-claude-desktop-ui.ps1' }
$source = Get-Content -LiteralPath $HelperPath -Raw
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Claude visibility helper has PowerShell syntax errors.' }
$nativeSource = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $nativeSource) { throw 'Claude visibility helper has no native implementation.' }
Add-Type -TypeDefinition ($nativeSource.Replace('namespace CogentSpec {', 'namespace CogentSpec.CompileOnly {'))
foreach ($required in @('SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE', "Get-Process -Name 'Claude'", 'Get-AuthenticodeSignature', 'GetWindow(window, GW_OWNER)', 'IsIconic(window)')) {
    if (-not $source.Contains($required)) { throw "Missing Claude safety check: $required" }
}
foreach ($forbidden in @('SetForegroundWindow', 'SendInput', 'SetFocus(', 'Start-Process', 'Get-Clipboard')) {
    if ($source.Contains($forbidden)) { throw "Claude visibility helper can launch or change focus/input: $forbidden" }
}
# All behavior below uses a fake native class and mocked processes/signatures.
# It never starts Claude or invokes real window APIs.
Add-Type -TypeDefinition @'
using System;
namespace CogentSpec {
    public static class ClaudeDesktopWindowNative {
        public static int WindowCount = 1;
        public static int Calls = 0;
        public static bool Pinned = false;
        public static bool ApplyAllowed = true;
        public static IntPtr[] FindMainWindows(int[] processIds) {
            var windows = new IntPtr[WindowCount];
            for (int i = 0; i < WindowCount; ++i) windows[i] = new IntPtr(i + 1);
            return windows;
        }
        public static bool IsTopmost(IntPtr window) { return Pinned; }
        public static bool SetTopmost(IntPtr window, int[] processIds, bool enabled) {
            Calls++;
            if (!ApplyAllowed) return false;
            Pinned = enabled; return true;
        }
    }
}
'@
$checks = 0
foreach ($case in @(
    @{ Name = 'closed'; Mode = 'pin'; Expected = 'claude_not_available'; NativeCalls = 0 },
    @{ Name = 'wrong-file'; Mode = 'pin'; Expected = 'claude_not_available'; NativeCalls = 0 },
    @{ Name = 'two-installs'; Mode = 'pin'; Expected = 'claude_identity_unverified'; NativeCalls = 0 },
    @{ Name = 'unsigned'; Mode = 'pin'; Expected = 'claude_identity_unverified'; NativeCalls = 0 },
    @{ Name = 'wrong-publisher'; Mode = 'pin'; Expected = 'claude_identity_unverified'; NativeCalls = 0 },
    @{ Name = 'no-window'; Mode = 'pin'; Expected = 'claude_window_unverified'; NativeCalls = 0 },
    @{ Name = 'two-windows'; Mode = 'pin'; Expected = 'claude_window_unverified'; NativeCalls = 0 },
    @{ Name = 'inspect'; Mode = 'inspect'; Expected = 'ready'; NativeCalls = 0 },
    @{ Name = 'pin'; Mode = 'pin'; Expected = 'pinned'; NativeCalls = 1 },
    @{ Name = 'unpin'; Mode = 'unpin'; Expected = 'unpinned'; NativeCalls = 1 },
    @{ Name = 'windows-denied'; Mode = 'pin'; Expected = 'claude_pin_failed'; NativeCalls = 1 }
)) {
    [CogentSpec.ClaudeDesktopWindowNative]::WindowCount = if ($case.Name -eq 'no-window') { 0 } elseif ($case.Name -eq 'two-windows') { 2 } else { 1 }
    [CogentSpec.ClaudeDesktopWindowNative]::Calls = 0
    [CogentSpec.ClaudeDesktopWindowNative]::Pinned = $case.Name -eq 'unpin'
    [CogentSpec.ClaudeDesktopWindowNative]::ApplyAllowed = $case.Name -ne 'windows-denied'
    $result = & {
        function Get-Process {
            [CmdletBinding()] param([string]$Name)
            if ($Name -ne 'Claude') { throw 'Helper targeted another application.' }
            if ($case.Name -eq 'closed') { return }
            [pscustomobject]@{ Id = 123; Path = if ($case.Name -eq 'wrong-file') { 'C:\Fixture\Other.exe' } else { 'C:\Fixture\Claude.exe' } }
            if ($case.Name -eq 'two-installs') { [pscustomobject]@{ Id = 456; Path = 'C:\OtherFixture\Claude.exe' } }
        }
        function Get-AuthenticodeSignature {
            [CmdletBinding()] param([string]$LiteralPath)
            [pscustomobject]@{
                Status = if ($case.Name -eq 'unsigned') { 'NotSigned' } else { 'Valid' }
                SignerCertificate = [pscustomobject]@{ Subject = if ($case.Name -eq 'wrong-publisher') { 'CN=Untrusted, O=Untrusted' } else { 'CN="Anthropic, PBC", O="Anthropic, PBC", C=US' } }
            }
        }
        & $HelperPath -Mode $case.Mode | ConvertFrom-Json
    }
    if ($result.status -ne $case.Expected) { throw ("Unexpected status for {0}: {1}" -f $case.Name, $result.status) }
    if ([CogentSpec.ClaudeDesktopWindowNative]::Calls -ne $case.NativeCalls) { throw "Unexpected native change for $($case.Name)" }
    if ($result.focusChanged -or $result.moved -or $result.resized) { throw 'Claude visibility changed focus or geometry.' }
    if ($case.Name -eq 'pin' -and -not $result.pinned) { throw 'Pin was not verified.' }
    if ($case.Name -eq 'unpin' -and $result.pinned) { throw 'Unpin was not verified.' }
    $checks += 1
}
[ordered]@{ status = 'valid'; cases = $checks; nativeSyntaxVerified = $true; realWindowsChanged = $false } | ConvertTo-Json -Compress
