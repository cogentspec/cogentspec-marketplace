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
        manualShortcut = 'Ctrl+P'
    })
}

$windows = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match '(?i)ChatGPT|Codex'
})
if ($windows.Count -eq 0) {
    Write-Failure -Status 'chatgpt_not_available' -Reason 'Open ChatGPT Desktop, then press Ctrl+P.'
    return
}
if ($windows.Count -ne 1) {
    Write-Failure -Status 'chatgpt_window_ambiguous' -Reason 'More than one ChatGPT Desktop window is available. Press Ctrl+P in the window you want to use.'
    return
}

$chatGpt = $windows[0]
$executablePath = [string]$chatGpt.Path
if (-not $executablePath -or [IO.Path]::GetFileName($executablePath) -ne 'ChatGPT.exe') {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not verify the ChatGPT Desktop application. Press Ctrl+P in ChatGPT Desktop.'
    return
}
$signature = Get-AuthenticodeSignature -LiteralPath $executablePath
$signerSubject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
if ([string]$signature.Status -ne 'Valid' -or $signerSubject -notmatch '(?i)\bO="?OpenAI(?: OpCo)?,? LLC"?\b') {
    Write-Failure -Status 'chatgpt_identity_unverified' -Reason 'CogentSpec could not verify the ChatGPT Desktop publisher. Press Ctrl+P in ChatGPT Desktop.'
    return
}

if ($Mode -eq 'inspect') {
    Write-CompactJson ([ordered]@{
        status = 'ready'
        opened = $false
        processId = [int]$chatGpt.Id
        windowTitle = [string]$chatGpt.MainWindowTitle
        publisherVerified = $true
        manualShortcut = 'Ctrl+P'
    })
    return
}

if ($null -eq ('CogentSpec.ChatGptPopupNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CogentSpec {
    public static class ChatGptPopupNative {
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const ushort VK_CONTROL = 0x11;
        private const ushort VK_P = 0x50;

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT {
            public uint type;
            public InputUnion U;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion {
            [FieldOffset(0)] public KEYBDINPUT keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT {
            public ushort virtualKey;
            public ushort scanCode;
            public uint flags;
            public uint time;
            public UIntPtr extraInfo;
        }

        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

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

        public static uint ForegroundProcessId() {
            uint processId;
            GetWindowThreadProcessId(GetForegroundWindow(), out processId);
            return processId;
        }

        public static bool SendControlP() {
            var inputs = new[] {
                Key(VK_CONTROL, 0),
                Key(VK_P, 0),
                Key(VK_P, KEYEVENTF_KEYUP),
                Key(VK_CONTROL, KEYEVENTF_KEYUP)
            };
            return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
        }
    }
}
'@
}

$windowHandle = [IntPtr]$chatGpt.MainWindowHandle
[void][CogentSpec.ChatGptPopupNative]::ShowWindowAsync($windowHandle, 9)
$activated = $false
try {
    $shell = New-Object -ComObject WScript.Shell
    $activated = [bool]$shell.AppActivate([int]$chatGpt.Id)
} catch { }
if (-not $activated) {
    $activated = [CogentSpec.ChatGptPopupNative]::SetForegroundWindow($windowHandle)
}

$focused = $false
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    if ([CogentSpec.ChatGptPopupNative]::ForegroundProcessId() -eq [uint32]$chatGpt.Id) {
        $focused = $true
        break
    }
    Start-Sleep -Milliseconds 50
}
if (-not $focused) {
    Write-Failure -Status 'chatgpt_focus_failed' -Reason 'CogentSpec could not safely focus ChatGPT Desktop. Press Ctrl+P in ChatGPT Desktop.'
    return
}
if (-not [CogentSpec.ChatGptPopupNative]::SendControlP()) {
    Write-Failure -Status 'shortcut_failed' -Reason 'CogentSpec could not send the popup shortcut. Press Ctrl+P in ChatGPT Desktop.'
    return
}

Write-CompactJson ([ordered]@{
    status = 'opened'
    opened = $true
    processId = [int]$chatGpt.Id
    publisherVerified = $true
    shortcut = 'Ctrl+P'
})
