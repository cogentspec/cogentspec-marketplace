[CmdletBinding()]
param(
    [ValidateSet('inspect', 'open', 'pin', 'unpin')]
    [string]$Mode = 'open'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CompactJson($Value) {
    $Value | ConvertTo-Json -Depth 5 -Compress | Write-Output
}

function Write-Failure([string]$Status, [string]$Reason, [bool]$Opened = $false) {
    Write-CompactJson ([ordered]@{
        status = $Status
        opened = $Opened
        reason = $Reason
        manualShortcut = 'Ctrl+Shift+Space'
    })
}

function Set-ChatGptComposerFocus($Composer) {
    $Composer.SetFocus()
    $deadline = [DateTime]::UtcNow.AddSeconds(1)
    do {
        if ($Composer.Current.HasKeyboardFocus) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'ChatGPT did not give keyboard focus to the popout composer.'
}

function Set-ChatGptComposerText([IntPtr]$PopupWindow, [string]$Text) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($PopupWindow)
        if (-not $root) { throw 'The verified popout did not expose an accessible window.' }

        $composer = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        $editCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit
        )
        do {
            $matches = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition) | Where-Object {
                [string]$_.Current.Name -eq 'Work with ChatGPT'
            })
            if ($matches.Count -eq 1) { $composer = $matches[0]; break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $composer) { throw 'CogentSpec could not identify one ChatGPT composer in the verified popout.' }
        if (-not $composer.Current.IsEnabled -or -not $composer.Current.IsKeyboardFocusable) {
            throw 'The ChatGPT composer is not ready for input.'
        }

        $patternObject = $null
        if (-not $composer.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$patternObject)) {
            throw 'The ChatGPT composer does not expose safe text input.'
        }
        $valuePattern = [System.Windows.Automation.ValuePattern]$patternObject
        if ($valuePattern.Current.IsReadOnly) { throw 'The ChatGPT composer is read-only.' }

        $currentValue = [string]$valuePattern.Current.Value
        $placeholderValue = $currentValue.TrimEnd("`r", "`n")
        if ($placeholderValue -ceq [string]$composer.Current.Name) {
            $currentValue = ''
        }
        if ($currentValue -eq $Text) {
            Set-ChatGptComposerFocus -Composer $composer
            return [ordered]@{ status = 'preloaded'; preloaded = $true; alreadyPreloaded = $true; focused = $true }
        }
        if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
            return [ordered]@{ status = 'draft_exists'; preloaded = $false; alreadyPreloaded = $false }
        }

        Set-ChatGptComposerFocus -Composer $composer
        $valuePattern.SetValue($Text)
        Start-Sleep -Milliseconds 100
        if ([string]$valuePattern.Current.Value -ne $Text) {
            throw 'ChatGPT did not retain the preloaded CogentSpec command.'
        }
        Set-ChatGptComposerFocus -Composer $composer
        return [ordered]@{ status = 'preloaded'; preloaded = $true; alreadyPreloaded = $false; focused = $true }
    } catch {
        return [ordered]@{
            status = 'preload_failed'
            preloaded = $false
            alreadyPreloaded = $false
            reason = $_.Exception.Message
        }
    }
}

function Reset-ChatGptPopupInteraction([IntPtr]$PopupWindow) {
    try {
        if (-not [CogentSpec.ChatGptPopupNative]::CancelPopupInteraction($PopupWindow)) {
            throw 'Windows did not release the previous popout interaction state.'
        }

        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($PopupWindow)
        if (-not $root) { throw 'The verified popout did not expose an accessible window.' }

        $dismissCondition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button
            ),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'Dismiss Popout Window'
            )
        )
        $dismissButton = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $dismissCondition)
        $hoverCleared = $false
        if ($dismissButton) {
            $cursor = [CogentSpec.ChatGptPopupNative]::GetCursorPosition()
            $buttonBounds = $dismissButton.Current.BoundingRectangle
            $cursorOnDismiss = $cursor.X -ge $buttonBounds.Left -and $cursor.X -lt $buttonBounds.Right -and
                $cursor.Y -ge $buttonBounds.Top -and $cursor.Y -lt $buttonBounds.Bottom
            if ($cursorOnDismiss) {
                $rootBounds = $root.Current.BoundingRectangle
                $targetX = [int][Math]::Min($rootBounds.Right - 8, $buttonBounds.Right + 48)
                $targetY = [int][Math]::Max($rootBounds.Top + 8, [Math]::Min($rootBounds.Bottom - 8, $buttonBounds.Top + ($buttonBounds.Height / 2)))
                if (-not [CogentSpec.ChatGptPopupNative]::SetCursorPosition($targetX, $targetY)) {
                    throw 'Windows did not clear the stale popout close-button hover.'
                }
                $hoverCleared = $true
                Start-Sleep -Milliseconds 100
            }
        }

        return [ordered]@{ status = 'reset'; reset = $true; dismissHoverCleared = $hoverCleared }
    } catch {
        return [ordered]@{ status = 'reset_failed'; reset = $false; dismissHoverCleared = $false; reason = $_.Exception.Message }
    }
}

function Invoke-PopupActivation([IntPtr]$PopupWindow) {
    $deadline = [DateTime]::UtcNow.AddSeconds(1)
    do {
        if ([CogentSpec.ChatGptPopupNative]::ActivatePopupWindow($PopupWindow)) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
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
using System.Collections.Generic;
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
        private const int SW_RESTORE = 9;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;
        private const uint WM_CANCELMODE = 0x001F;

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

        [StructLayout(LayoutKind.Sequential)]
        public struct CursorPoint {
            public int X;
            public int Y;
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

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint attachThreadId, uint attachToThreadId, bool attach);

        [DllImport("user32.dll")]
        private static extern IntPtr SetFocus(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out CursorPoint point);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

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

        public static IntPtr[] FindPopupWindows(int[] processIds) {
            List<IntPtr> popupWindows = new List<IntPtr>();
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
                    && (extendedStyle & WS_EX_LAYERED) == 0;
                if (!isPopupToolWindow) return true;

                popupWindows.Add(window);
                return true;
            }, IntPtr.Zero);
            return popupWindows.ToArray();
        }

        public static bool IsVisible(IntPtr window) {
            return window != IntPtr.Zero && IsWindowVisible(window);
        }

        public static bool IsForeground(IntPtr window) {
            return window != IntPtr.Zero && GetForegroundWindow() == window;
        }

        public static bool IsTopmost(IntPtr window) {
            return window != IntPtr.Zero && (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;
        }

        public static bool SetPopupTopmost(IntPtr window, bool enabled) {
            if (window == IntPtr.Zero) return false;
            uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            IntPtr position = enabled ? HWND_TOPMOST : HWND_NOTOPMOST;
            return SetWindowPos(window, position, 0, 0, 0, 0, flags) && IsTopmost(window) == enabled;
        }

        public static bool CancelPopupInteraction(IntPtr window) {
            return window != IntPtr.Zero && PostMessage(window, WM_CANCELMODE, IntPtr.Zero, IntPtr.Zero);
        }

        public static CursorPoint GetCursorPosition() {
            CursorPoint point;
            if (!GetCursorPos(out point)) throw new InvalidOperationException("Windows did not expose the current pointer position.");
            return point;
        }

        public static bool SetCursorPosition(int x, int y) {
            return SetCursorPos(x, y);
        }

        public static bool ActivatePopupWindow(IntPtr window) {
            if (window == IntPtr.Zero || !IsWindowVisible(window)) return false;
            bool wasTopmost = IsTopmost(window);
            if (IsIconic(window)) {
                ShowWindowAsync(window, SW_RESTORE);
            }

            if (GetForegroundWindow() == window) return true;

            IntPtr priorForeground = GetForegroundWindow();
            uint currentThreadId = GetCurrentThreadId();
            uint ignoredProcessId;
            uint foregroundThreadId = priorForeground == IntPtr.Zero
                ? 0
                : GetWindowThreadProcessId(priorForeground, out ignoredProcessId);
            uint popupThreadId = GetWindowThreadProcessId(window, out ignoredProcessId);
            bool attachedForeground = false;
            bool attachedPopup = false;

            try {
                if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId) {
                    attachedForeground = AttachThreadInput(currentThreadId, foregroundThreadId, true);
                }
                if (popupThreadId != 0 && popupThreadId != currentThreadId) {
                    attachedPopup = AttachThreadInput(currentThreadId, popupThreadId, true);
                }

                BringWindowToTop(window);
                SetForegroundWindow(window);
                SetFocus(window);

                if (GetForegroundWindow() != window) {
                    uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW;
                    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, flags);
                    if (!wasTopmost) SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
                    SetForegroundWindow(window);
                    SetFocus(window);
                }
            } finally {
                if (attachedPopup) AttachThreadInput(currentThreadId, popupThreadId, false);
                if (attachedForeground) AttachThreadInput(currentThreadId, foregroundThreadId, false);
            }

            return IsWindowVisible(window) && GetForegroundWindow() == window;
        }
    }
}
'@
}

function Find-VerifiedChatGptPopupWindow([int[]]$ProcessIds) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    $editCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )
    $verified = @([CogentSpec.ChatGptPopupNative]::FindPopupWindows($ProcessIds) | Where-Object {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($_)
            $matches = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition) | Where-Object {
                [string]$_.Current.Name -eq 'Work with ChatGPT'
            })
            $matches.Count -eq 1
        } catch { $false }
    })
    if ($verified.Count -eq 1) { return [IntPtr]$verified[0] }
    return [IntPtr]::Zero
}

$chatGptProcessIds = [int[]]@($chatGptProcesses | ForEach-Object { [int]$_.Id })
$popupWindow = Find-VerifiedChatGptPopupWindow -ProcessIds $chatGptProcessIds
$popupWasVisible = $null
$shortcutSent = $false
$shortcutAttempts = 0
$activatedExisting = $false
$restoredHidden = $false

if ($Mode -eq 'inspect') {
    Write-CompactJson ([ordered]@{
        status = 'ready'
        opened = $false
        processId = [int]$chatGpt.Id
        windowTitle = [string]$chatGpt.MainWindowTitle
        publisherVerified = $true
        popupDetected = ($popupWindow -ne [IntPtr]::Zero)
        popupVisible = [CogentSpec.ChatGptPopupNative]::IsVisible($popupWindow)
        popupTopmost = [CogentSpec.ChatGptPopupNative]::IsTopmost($popupWindow)
        manualShortcut = 'Ctrl+Shift+Space'
    })
    return
}

if ($Mode -in @('pin', 'unpin')) {
    if ($popupWindow -eq [IntPtr]::Zero) {
        Write-Failure -Status 'popup_not_open' -Reason 'Open the ChatGPT popout, then try the pin again.'
        return
    }
    $shouldPin = $Mode -eq 'pin'
    if (-not [CogentSpec.ChatGptPopupNative]::SetPopupTopmost($popupWindow, $shouldPin)) {
        Write-Failure -Status 'popup_pin_failed' -Reason 'Windows did not accept the ChatGPT popout pin change.' -Opened $true
        return
    }
    Write-CompactJson ([ordered]@{
        status = if ($shouldPin) { 'pinned' } else { 'unpinned' }
        opened = $true
        processId = [int]$chatGpt.Id
        publisherVerified = $true
        popupVerified = $true
        pinned = [CogentSpec.ChatGptPopupNative]::IsTopmost($popupWindow)
    })
    return
}

if ($popupWindow -ne [IntPtr]::Zero) {
    $popupWasVisible = [CogentSpec.ChatGptPopupNative]::IsVisible($popupWindow)
    if ($popupWasVisible -and -not (Invoke-PopupActivation -PopupWindow $popupWindow)) {
        Write-Failure -Status 'popup_activation_failed' -Reason 'CogentSpec found the ChatGPT popout but could not bring it forward. Press Ctrl + Shift + Space.'
        return
    }
    if ($popupWasVisible) {
        $activatedExisting = $true
    }
}

if (-not $activatedExisting) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not [CogentSpec.ChatGptPopupNative]::SendControlShiftSpace()) {
            Write-Failure -Status 'shortcut_failed' -Reason 'CogentSpec could not send the popout shortcut. Press Ctrl + Shift + Space.'
            return
        }
        $shortcutSent = $true
        $shortcutAttempts = $attempt

        $popupDeadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            Start-Sleep -Milliseconds 100
            $popupWindow = Find-VerifiedChatGptPopupWindow -ProcessIds $chatGptProcessIds
            $popupVisible = [CogentSpec.ChatGptPopupNative]::IsVisible($popupWindow)
        } while (($popupWindow -eq [IntPtr]::Zero -or -not $popupVisible) -and [DateTime]::UtcNow -lt $popupDeadline)

        if ($popupWindow -ne [IntPtr]::Zero -and $popupVisible) { break }
    }

    if ($popupWindow -eq [IntPtr]::Zero -or -not $popupVisible -or -not (Invoke-PopupActivation -PopupWindow $popupWindow)) {
        Write-Failure -Status 'popup_not_opened' -Reason 'CogentSpec sent the popout shortcut, but ChatGPT did not expose a popout window. Press Ctrl + Shift + Space.'
        return
    }
    $restoredHidden = ($null -ne $popupWasVisible -and -not $popupWasVisible)
}

$interaction = Reset-ChatGptPopupInteraction -PopupWindow $popupWindow
if (-not $interaction.reset) {
    Write-Failure -Status ([string]$interaction.status) -Reason ([string]$interaction.reason) -Opened $true
    return
}
$dismissHoverCleared = [bool]$interaction.dismissHoverCleared
$topmostCycleReset = $false
$topmostRestored = $true

$composer = Set-ChatGptComposerText -PopupWindow $popupWindow -Text '$cogentspec'
if (-not $composer.preloaded -and [string]$composer.status -eq 'preload_failed' -and
    [string]$composer.reason -eq 'ChatGPT did not give keyboard focus to the popout composer.' -and
    [CogentSpec.ChatGptPopupNative]::IsTopmost($popupWindow)) {
    if (-not [CogentSpec.ChatGptPopupNative]::SetPopupTopmost($popupWindow, $false)) {
        Write-Failure -Status 'popup_interaction_recovery_failed' -Reason 'Windows did not release the pinned ChatGPT popout for interaction recovery.' -Opened $true
        return
    }
    $topmostCycleReset = $true
    Start-Sleep -Milliseconds 100

    $recoveryInteraction = Reset-ChatGptPopupInteraction -PopupWindow $popupWindow
    $dismissHoverCleared = $dismissHoverCleared -or [bool]$recoveryInteraction.dismissHoverCleared
    if ($recoveryInteraction.reset) {
        $composer = Set-ChatGptComposerText -PopupWindow $popupWindow -Text '$cogentspec'
    }

    $topmostRestored = [CogentSpec.ChatGptPopupNative]::SetPopupTopmost($popupWindow, $true)
    if (-not $topmostRestored) {
        Write-Failure -Status 'popup_interaction_recovery_failed' -Reason 'CogentSpec recovered the ChatGPT popout but Windows did not restore its pinned state.' -Opened $true
        return
    }
    if (-not $recoveryInteraction.reset) {
        Write-Failure -Status ([string]$recoveryInteraction.status) -Reason ([string]$recoveryInteraction.reason) -Opened $true
        return
    }
    if ($composer.preloaded) {
        $composer = Set-ChatGptComposerText -PopupWindow $popupWindow -Text '$cogentspec'
    }
}
if (-not $composer.preloaded) {
    $reason = if ([string]$composer.status -eq 'draft_exists') {
        'ChatGPT already contains text in the composer. CogentSpec left that draft unchanged.'
    } else {
        [string]$composer.reason
    }
    Write-Failure -Status ([string]$composer.status) -Reason $reason -Opened $true
    return
}

if (-not (Invoke-PopupActivation -PopupWindow $popupWindow)) {
    Write-Failure -Status 'popup_activation_failed' -Reason 'CogentSpec prepared the ChatGPT popout but could not make it ready for keyboard input. Click the composer once to continue.' -Opened $true
    return
}

Write-CompactJson ([ordered]@{
    status = 'opened'
    opened = $true
    processId = [int]$chatGpt.Id
    publisherVerified = $true
    shortcutSent = $shortcutSent
    shortcutAttempts = $shortcutAttempts
    activatedExisting = $activatedExisting
    restoredHidden = $restoredHidden
    popupVerified = $true
    foregroundVerified = [CogentSpec.ChatGptPopupNative]::IsForeground($popupWindow)
    interactionReset = [bool]$interaction.reset
    dismissHoverCleared = $dismissHoverCleared
    topmostCycleReset = $topmostCycleReset
    topmostRestored = $topmostRestored
    composerPreloaded = $true
    composerAlreadyPreloaded = [bool]$composer.alreadyPreloaded
    composerFocused = [bool]$composer.focused
    composerText = '$cogentspec'
    shortcut = 'Ctrl+Shift+Space'
})
