[CmdletBinding()]
param(
    [ValidateSet('inspect', 'open')]
    [string]$Mode = 'open'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

function Write-Failure([string]$Status, [string]$Reason) {
    Write-CompactJson ([ordered]@{
        status = $Status
        opened = $false
        reason = $Reason
        manualShortcut = 'Ctrl+Shift+Space'
    })
}

$chatGptProcesses = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    try { [IO.Path]::GetFileName([string]$_.Path) -eq 'ChatGPT.exe' } catch { $false }
})
if ($chatGptProcesses.Count -eq 0) {
    Write-Failure -Status 'chatgpt_not_available' -Reason 'Open ChatGPT Desktop, then press Ctrl + Shift + Space.'
    return
}
$executablePaths = @($chatGptProcesses | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
if ($executablePaths.Count -ne 1) {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not identify one ChatGPT Desktop installation. Press Ctrl + Shift + Space.'
    return
}

$chatGpt = @($chatGptProcesses | Sort-Object Id)[0]
$executablePath = $executablePaths[0]
$signature = Get-AuthenticodeSignature -LiteralPath $executablePath
$signerSubject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
if ([string]$signature.Status -ne 'Valid' -or $signerSubject -notmatch '(?i)\bO="?OpenAI(?: OpCo)?,? LLC"?\b') {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not verify the ChatGPT Desktop publisher. Press Ctrl + Shift + Space.'
    return
}

if ($null -eq ('CogentSpec.ChatGptPopupNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace CogentSpec {
    public static class ChatGptPopupNative {
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const ushort VK_CONTROL = 0x11;
        private const ushort VK_SHIFT = 0x10;
        private const ushort VK_SPACE = 0x20;
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOPMOST = 0x00000008L;
        private const long WS_EX_TOOLWINDOW = 0x00000080L;
        private const long WS_EX_LAYERED = 0x00080000L;
        private const int SW_SHOW = 5;
        private const int SW_RESTORE = 9;

        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT {
            public uint type;
            public InputUnion U;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion {
            [FieldOffset(0)] public MOUSEINPUT mouse;
            [FieldOffset(0)] public KEYBDINPUT keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint flags;
            public uint time;
            public UIntPtr extraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT {
            public ushort virtualKey;
            public ushort scanCode;
            public uint flags;
            public uint time;
            public UIntPtr extraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder text, int count);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);

        private static INPUT Key(ushort virtualKey, uint flags) {
            return new INPUT {
                type = INPUT_KEYBOARD,
                U = new InputUnion {
                    keyboard = new KEYBDINPUT {
                        virtualKey = virtualKey,
                        scanCode = 0,
                        flags = flags,
                        time = 0,
                        extraInfo = UIntPtr.Zero
                    }
                }
            };
        }

        public static bool SendControlShiftSpace() {
            var inputs = new[] {
                Key(VK_CONTROL, 0),
                Key(VK_SHIFT, 0),
                Key(VK_SPACE, 0),
                Key(VK_SPACE, KEYEVENTF_KEYUP),
                Key(VK_SHIFT, KEYEVENTF_KEYUP),
                Key(VK_CONTROL, KEYEVENTF_KEYUP)
            };
            return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
        }

        public static IntPtr FindPopupWindow(int[] processIds) {
            IntPtr popupWindow = IntPtr.Zero;
            EnumWindows(delegate(IntPtr window, IntPtr parameter) {
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                bool matchesProcess = false;
                foreach (int candidateProcessId in processIds) {
                    if (processId == (uint)candidateProcessId) {
                        matchesProcess = true;
                        break;
                    }
                }
                if (!matchesProcess) return true;

                StringBuilder className = new StringBuilder(128);
                GetClassName(window, className, className.Capacity);
                if (!String.Equals(className.ToString(), "Chrome_WidgetWin_1", StringComparison.Ordinal)) return true;

                StringBuilder title = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                if (!String.Equals(title.ToString(), "ChatGPT", StringComparison.Ordinal)) return true;

                long extendedStyle = GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64();
                bool isPopupToolWindow = (extendedStyle & WS_EX_TOOLWINDOW) != 0
                    && (extendedStyle & WS_EX_TOPMOST) == 0
                    && (extendedStyle & WS_EX_LAYERED) == 0;
                if (!isPopupToolWindow) return true;

                popupWindow = window;
                return false;
            }, IntPtr.Zero);
            return popupWindow;
        }

        public static bool IsVisible(IntPtr window) {
            return window != IntPtr.Zero && IsWindowVisible(window);
        }

        public static bool ActivatePopupWindow(IntPtr window) {
            if (window == IntPtr.Zero) return false;
            if (IsIconic(window)) {
                ShowWindowAsync(window, SW_RESTORE);
            } else if (!IsWindowVisible(window)) {
                ShowWindowAsync(window, SW_SHOW);
            }
            BringWindowToTop(window);
            SetForegroundWindow(window);
            return IsWindowVisible(window);
        }
    }
}
'@
}

$chatGptProcessIds = [int[]]@($chatGptProcesses | ForEach-Object { [int]$_.Id })
$popupWindow = [CogentSpec.ChatGptPopupNative]::FindPopupWindow($chatGptProcessIds)

if ($Mode -eq 'inspect') {
    Write-CompactJson ([ordered]@{
        status = 'ready'
        opened = $false
        processId = [int]$chatGpt.Id
        windowTitle = [string]$chatGpt.MainWindowTitle
        publisherVerified = $true
        popupDetected = ($popupWindow -ne [IntPtr]::Zero)
        popupVisible = [CogentSpec.ChatGptPopupNative]::IsVisible($popupWindow)
        manualShortcut = 'Ctrl+Shift+Space'
    })
    return
}

if ($popupWindow -ne [IntPtr]::Zero) {
    $popupWasVisible = [CogentSpec.ChatGptPopupNative]::IsVisible($popupWindow)
    if (-not [CogentSpec.ChatGptPopupNative]::ActivatePopupWindow($popupWindow)) {
        Write-Failure -Status 'popup_activation_failed' -Reason 'CogentSpec found the ChatGPT popout but could not bring it forward. Press Ctrl + Shift + Space.'
        return
    }
    Write-CompactJson ([ordered]@{
        status = 'opened'
        opened = $true
        processId = [int]$chatGpt.Id
        publisherVerified = $true
        shortcutSent = $false
        activatedExisting = $true
        restoredHidden = (-not $popupWasVisible)
        popupVerified = $true
    })
    return
}

if (-not [CogentSpec.ChatGptPopupNative]::SendControlShiftSpace()) {
    Write-Failure -Status 'shortcut_failed' -Reason 'CogentSpec could not send the popout shortcut. Press Ctrl + Shift + Space.'
    return
}

$popupDeadline = [DateTime]::UtcNow.AddSeconds(3)
do {
    Start-Sleep -Milliseconds 100
    $popupWindow = [CogentSpec.ChatGptPopupNative]::FindPopupWindow($chatGptProcessIds)
} while ($popupWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $popupDeadline)

if ($popupWindow -eq [IntPtr]::Zero -or -not [CogentSpec.ChatGptPopupNative]::ActivatePopupWindow($popupWindow)) {
    Write-Failure -Status 'popup_not_opened' -Reason 'CogentSpec sent the popout shortcut, but ChatGPT did not expose a popout window. Press Ctrl + Shift + Space.'
    return
}

Write-CompactJson ([ordered]@{
    status = 'opened'
    opened = $true
    processId = [int]$chatGpt.Id
    publisherVerified = $true
    shortcutSent = $true
    activatedExisting = $false
    restoredHidden = $false
    popupVerified = $true
    shortcut = 'Ctrl+Shift+Space'
})
