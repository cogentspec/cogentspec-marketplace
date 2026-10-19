[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateSet('inspect', 'pin', 'unpin')][string]$Mode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ClaudeVisibilityResult($Value) {
    $Value | ConvertTo-Json -Depth 5 -Compress
}
function Write-ClaudeVisibilityFailure([string]$Status, [string]$Reason) {
    Write-ClaudeVisibilityResult ([ordered]@{ status = $Status; reason = $Reason; focusChanged = $false; moved = $false; resized = $false })
}

$claudeProcesses = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object {
    try { [IO.Path]::GetFileName([string]$_.Path) -ieq 'Claude.exe' } catch { $false }
})
if ($claudeProcesses.Count -eq 0) {
    Write-ClaudeVisibilityFailure 'claude_not_available' 'Open the main Claude Desktop window before changing its visibility.'
    return
}
$paths = @($claudeProcesses | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
if ($paths.Count -ne 1) {
    Write-ClaudeVisibilityFailure 'claude_identity_unverified' 'CogentSpec could not identify one Claude Desktop installation.'
    return
}
$signature = Get-AuthenticodeSignature -LiteralPath $paths[0]
$subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
if ([string]$signature.Status -ne 'Valid' -or $subject -notmatch '(?i)(?:^|,\s*)O=(?:"Anthropic,? PBC"|Anthropic(?:,)? PBC)(?:,|$)') {
    Write-ClaudeVisibilityFailure 'claude_identity_unverified' 'CogentSpec could not verify the Claude Desktop publisher.'
    return
}

if ($null -eq ('CogentSpec.ClaudeDesktopWindowNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
namespace CogentSpec {
    public static class ClaudeDesktopWindowNative {
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOOLWINDOW = 0x80L, WS_EX_TOPMOST = 0x08L;
        private const uint GW_OWNER = 4;
        private const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010;
        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

        private static bool IsCandidate(IntPtr window, int[] processIds) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            bool matches = false;
            foreach (int candidate in processIds) if (processId == (uint)candidate) { matches = true; break; }
            if (!matches || !IsWindowVisible(window) || IsIconic(window) || GetWindow(window, GW_OWNER) != IntPtr.Zero) return false;
            StringBuilder className = new StringBuilder(128);
            GetClassName(window, className, className.Capacity);
            return String.Equals(className.ToString(), "Chrome_WidgetWin_1", StringComparison.Ordinal)
                && (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) == 0;
        }
        public static IntPtr[] FindMainWindows(int[] processIds) {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr window, IntPtr parameter) {
                if (IsCandidate(window, processIds)) windows.Add(window);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
        public static bool IsTopmost(IntPtr window) {
            return window != IntPtr.Zero && (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;
        }
        public static bool SetTopmost(IntPtr window, int[] processIds, bool enabled) {
            if (!IsCandidate(window, processIds)) return false;
            return SetWindowPos(window, new IntPtr(enabled ? -1 : -2), 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) && IsTopmost(window) == enabled;
        }
    }
}
'@
}

$processIds = [int[]]@($claudeProcesses | ForEach-Object { [int]$_.Id })
$windows = @([CogentSpec.ClaudeDesktopWindowNative]::FindMainWindows($processIds))
if ($windows.Count -ne 1) {
    Write-ClaudeVisibilityFailure 'claude_window_unverified' 'Open or restore one main Claude Desktop window. CogentSpec will not choose between multiple windows.'
    return
}
$mainWindow = [IntPtr]$windows[0]
if ($Mode -eq 'inspect') {
    Write-ClaudeVisibilityResult ([ordered]@{ status = 'ready'; publisherVerified = $true; windowVerified = $true; pinned = [CogentSpec.ClaudeDesktopWindowNative]::IsTopmost($mainWindow); focusChanged = $false; moved = $false; resized = $false })
    return
}
$shouldPin = $Mode -eq 'pin'
if (-not [CogentSpec.ClaudeDesktopWindowNative]::SetTopmost($mainWindow, $processIds, $shouldPin)) {
    Write-ClaudeVisibilityFailure 'claude_pin_failed' 'Windows could not apply the requested Claude Desktop visibility setting.'
    return
}
Write-ClaudeVisibilityResult ([ordered]@{
    status = if ($shouldPin) { 'pinned' } else { 'unpinned' }
    publisherVerified = $true
    windowVerified = $true
    pinned = [CogentSpec.ClaudeDesktopWindowNative]::IsTopmost($mainWindow)
    focusChanged = $false
    moved = $false
    resized = $false
})
