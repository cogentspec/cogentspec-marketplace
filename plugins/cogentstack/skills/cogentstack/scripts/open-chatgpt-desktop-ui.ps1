[CmdletBinding()]
param(
    [switch]$StartNewChat,
    [switch]$PasteClipboard
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
        fallback = 'Open ChatGPT Desktop, start a new chat, then paste the copied request.'
    })
}

function Test-IsChatGptComposer($Element) {
    if ($null -eq $Element) { return $false }
    $name = [string]$Element.Current.Name
    return $name -in @('Work with ChatGPT', 'Ask ChatGPT anything locally', 'Ask ChatGPT anything')
}

function Get-ChatGptComposerText($Composer) {
    try {
        $valuePattern = $Composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($valuePattern) { return [string]$valuePattern.Current.Value }
    } catch { }
    try {
        $textPattern = $Composer.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($textPattern) { return [string]$textPattern.DocumentRange.GetText(-1) }
    } catch { }
    return ''
}

function Get-NormalizedComposerText($Composer) {
    $text = (Get-ChatGptComposerText -Composer $Composer) -replace '[\u200B-\u200D\uFEFF]', ''
    $normalized = $text.Trim()
    if ($normalized -ceq ([string]$Composer.Current.Name).Trim()) { return '' }
    return $normalized
}

function Find-ChatGptComposer([IntPtr]$Window) {
    if ($Window -eq [IntPtr]::Zero) { return $null }
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if (-not $root) { return $null }
    $editCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )
    $matches = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition) | Where-Object {
        Test-IsChatGptComposer -Element $_
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Set-ChatGptComposerFocus($Composer) {
    $Composer.SetFocus()
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        if ($Composer.Current.HasKeyboardFocus) { return $true }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-ForEmptyChatGptComposer([IntPtr]$Window) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $stableSince = $null
    do {
        $composer = Find-ChatGptComposer -Window $Window
        $ready = $composer -and $composer.Current.IsEnabled -and $composer.Current.IsKeyboardFocusable -and
            [string]::IsNullOrWhiteSpace((Get-NormalizedComposerText -Composer $composer))
        if ($ready) {
            if ($null -eq $stableSince) { $stableSince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge 800) { return $composer }
        } else {
            $stableSince = $null
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Enter-ChatGptFullView([IntPtr]$Window) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if (-not $root) { throw 'ChatGPT Desktop did not expose an accessible main window.' }
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button
        ),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            'Enter full view'
        )
    )
    $button = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $button) { return $false }
    $patternObject = $null
    if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObject)) {
        throw 'ChatGPT Desktop exposed full view without an accessible action.'
    }
    ([System.Windows.Automation.InvokePattern]$patternObject).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
        $button = if ($root) { $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition) } else { $null }
    } while ($button -and [DateTime]::UtcNow -lt $deadline)
    if ($button) { throw 'ChatGPT Desktop did not enter full view.' }
    return $true
}

function Start-NewChat([IntPtr]$Window) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if (-not $root) { throw 'ChatGPT Desktop did not expose an accessible main window.' }
    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
    $buttons = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition) | Where-Object {
        -not $_.Current.IsOffscreen -and $_.Current.IsEnabled -and [string]$_.Current.Name -in @('New chat', 'Start new chat')
    })
    if ($buttons.Count -ne 1) {
        throw "ChatGPT Desktop did not expose one verified New chat control (found $($buttons.Count))."
    }
    $patternObject = $null
    if (-not $buttons[0].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$patternObject)) {
        throw 'The verified ChatGPT New chat control did not expose an accessible action.'
    }
    ([System.Windows.Automation.InvokePattern]$patternObject).Invoke()
    $composer = Wait-ForEmptyChatGptComposer -Window $Window
    if (-not $composer) { throw 'ChatGPT Desktop did not confirm an empty composer in the new chat.' }
    return $composer
}

function Set-ChatGptComposerFromClipboard([IntPtr]$Window, $Composer) {
    $clipboardText = [string](Get-Clipboard -Raw -ErrorAction Stop)
    $validRequest = $clipboardText.Trim() -ceq '$cogentspec' -or
        $clipboardText.StartsWith('Update CogentSpec on this computer by following only Update Protocol v1:', [StringComparison]::Ordinal)
    if (-not $validRequest) { throw 'The clipboard no longer contains the verified CogentSpec connection or update request.' }
    if (-not [string]::IsNullOrWhiteSpace((Get-NormalizedComposerText -Composer $Composer))) {
        throw 'The new ChatGPT composer unexpectedly contains unsent text.'
    }
    if (-not (Set-ChatGptComposerFocus -Composer $Composer)) {
        throw 'ChatGPT Desktop did not give keyboard focus to the new-chat composer.'
    }
    Start-Sleep -Milliseconds 100
    if (-not [CogentSpec.ChatGptDesktopUiNative]::SendControlV()) {
        throw 'Windows could not paste the copied CogentSpec request.'
    }
    $expectedFirstLine = [string](@($clipboardText -split "`r?`n")[0]).Trim()
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 100
        $composerText = Get-ChatGptComposerText -Composer $Composer
    } while (($expectedFirstLine -and -not $composerText.Contains($expectedFirstLine)) -and [DateTime]::UtcNow -lt $deadline)
    if (-not $expectedFirstLine -or -not $composerText.Contains($expectedFirstLine)) {
        throw 'ChatGPT Desktop did not confirm that the CogentSpec request reached the new-chat composer.'
    }
    return $true
}

function Get-ChatGptProcesses {
    return @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
        try { [IO.Path]::GetFileName([string]$_.Path) -eq 'ChatGPT.exe' } catch { $false }
    })
}

function Start-ChatGptDesktop {
    $startApps = @(Get-StartApps | Where-Object {
        [string]$_.Name -eq 'ChatGPT' -and [string]$_.AppID -match '^OpenAI\.(?:ChatGPT|Codex)_[A-Za-z0-9]+!App$'
    })
    if ($startApps.Count -ne 1) { throw 'CogentSpec could not identify one installed ChatGPT Desktop application.' }
    Start-Process explorer.exe -ArgumentList ("shell:AppsFolder\" + [string]$startApps[0].AppID) -ErrorAction Stop
}

if (-not $StartNewChat) {
    Write-Failure -Status 'new_chat_required' -Reason 'Desktop UI Bridge requires an explicit new-chat request.'
    return
}
if (-not $PasteClipboard) {
    Write-Failure -Status 'composer_request_required' -Reason 'Desktop UI Bridge requires the verified request to be copied before launch.'
    return
}

$desktopLaunched = $false
$chatGptProcesses = Get-ChatGptProcesses
if ($chatGptProcesses.Count -eq 0) {
    try {
        Start-ChatGptDesktop
        $desktopLaunched = $true
    } catch {
        Write-Failure -Status 'chatgpt_launch_failed' -Reason $_.Exception.Message
        return
    }
    $processDeadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $chatGptProcesses = Get-ChatGptProcesses
    } while ($chatGptProcesses.Count -eq 0 -and [DateTime]::UtcNow -lt $processDeadline)
}
if ($chatGptProcesses.Count -eq 0) {
    Write-Failure -Status 'chatgpt_not_available' -Reason 'ChatGPT Desktop did not start.'
    return
}

$executablePaths = @($chatGptProcesses | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
if ($executablePaths.Count -ne 1) {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not identify one ChatGPT Desktop installation.'
    return
}
$signature = Get-AuthenticodeSignature -LiteralPath $executablePaths[0]
$signerSubject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
if ([string]$signature.Status -ne 'Valid' -or $signerSubject -notmatch '(?i)\bO="?OpenAI(?: OpCo)?,? LLC"?\b') {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not verify the ChatGPT Desktop publisher.'
    return
}

if ($null -eq ('CogentSpec.ChatGptDesktopUiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

namespace CogentSpec {
    public static class ChatGptDesktopUiNative {
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const ushort VK_CONTROL = 0x11;
        private const ushort VK_V = 0x56;
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOOLWINDOW = 0x00000080L;
        private const int SW_RESTORE = 9;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_SHOWWINDOW = 0x0040;

        private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT { public uint type; public InputUnion U; }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion { [FieldOffset(0)] public KEYBDINPUT keyboard; }

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

        private static INPUT Key(ushort virtualKey, uint flags) {
            return new INPUT {
                type = INPUT_KEYBOARD,
                U = new InputUnion {
                    keyboard = new KEYBDINPUT { virtualKey = virtualKey, flags = flags, extraInfo = UIntPtr.Zero }
                }
            };
        }

        public static bool SendControlV() {
            var inputs = new[] {
                Key(VK_CONTROL, 0), Key(VK_V, 0), Key(VK_V, KEYEVENTF_KEYUP), Key(VK_CONTROL, KEYEVENTF_KEYUP)
            };
            return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
        }

        public static IntPtr[] FindMainWindows(int[] processIds) {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr window, IntPtr parameter) {
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                bool matches = false;
                foreach (int candidate in processIds) {
                    if (processId == (uint)candidate) { matches = true; break; }
                }
                if (!matches || !IsWindowVisible(window)) return true;
                StringBuilder className = new StringBuilder(128);
                GetClassName(window, className, className.Capacity);
                if (!String.Equals(className.ToString(), "Chrome_WidgetWin_1", StringComparison.Ordinal)) return true;
                if ((GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) != 0) return true;
                windows.Add(window);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        public static bool ActivateWindow(IntPtr window) {
            if (window == IntPtr.Zero || !IsWindowVisible(window)) return false;
            if (IsIconic(window)) ShowWindowAsync(window, SW_RESTORE);
            if (GetForegroundWindow() == window) return true;
            IntPtr prior = GetForegroundWindow();
            uint currentThread = GetCurrentThreadId();
            uint ignored;
            uint priorThread = prior == IntPtr.Zero ? 0 : GetWindowThreadProcessId(prior, out ignored);
            uint windowThread = GetWindowThreadProcessId(window, out ignored);
            bool attachedPrior = false;
            bool attachedWindow = false;
            try {
                if (priorThread != 0 && priorThread != currentThread) attachedPrior = AttachThreadInput(currentThread, priorThread, true);
                if (windowThread != 0 && windowThread != currentThread) attachedWindow = AttachThreadInput(currentThread, windowThread, true);
                BringWindowToTop(window);
                SetForegroundWindow(window);
                SetFocus(window);
                if (GetForegroundWindow() != window) {
                    uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW;
                    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, flags);
                    SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
                    SetForegroundWindow(window);
                    SetFocus(window);
                }
            } finally {
                if (attachedWindow) AttachThreadInput(currentThread, windowThread, false);
                if (attachedPrior) AttachThreadInput(currentThread, priorThread, false);
            }
            return GetForegroundWindow() == window;
        }
    }
}
'@
}

$processIds = [int[]]@($chatGptProcesses | ForEach-Object { [int]$_.Id })
$windowDeadline = [DateTime]::UtcNow.AddSeconds(15)
$mainWindow = [IntPtr]::Zero
do {
    $windows = @([CogentSpec.ChatGptDesktopUiNative]::FindMainWindows($processIds))
    if ($windows.Count -eq 1) { $mainWindow = [IntPtr]$windows[0]; break }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $windowDeadline)
if ($mainWindow -eq [IntPtr]::Zero) {
    Write-Failure -Status 'desktop_window_not_ready' -Reason 'ChatGPT Desktop did not expose one full application window.' -Opened $desktopLaunched
    return
}
if (-not [CogentSpec.ChatGptDesktopUiNative]::ActivateWindow($mainWindow)) {
    Write-Failure -Status 'desktop_activation_failed' -Reason 'ChatGPT Desktop opened, but Windows could not activate its main window.' -Opened $true
    return
}

try {
    $fullViewEntered = Enter-ChatGptFullView -Window $mainWindow
    $composer = Start-NewChat -Window $mainWindow
    $composerPopulated = Set-ChatGptComposerFromClipboard -Window $mainWindow -Composer $composer
    Write-CompactJson ([ordered]@{
        status = 'opened'
        opened = $true
        publisherVerified = $true
        desktopWindowLaunched = $desktopLaunched
        fullViewEntered = [bool]$fullViewEntered
        newChatStarted = $true
        composerFocused = [bool]$composer.Current.HasKeyboardFocus
        composerPopulated = [bool]$composerPopulated
        messageSubmitted = $false
    })
} catch {
    Write-Failure -Status 'desktop_ui_failed' -Reason $_.Exception.Message -Opened $true
}
