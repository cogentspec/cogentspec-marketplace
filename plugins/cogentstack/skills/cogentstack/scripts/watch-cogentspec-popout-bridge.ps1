[CmdletBinding()]
param(
    [ValidateSet('cogentspec', 'cogentstack')]
    [string]$PluginId = 'cogentspec',

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$PluginVersion,

    [string]$ReadyPath = '',

    [ValidateRange(250, 10000)]
    [int]$PollMilliseconds = 1500,

    [ValidateRange(1000, 60000)]
    [int]$MaximumRetryMilliseconds = 30000,

    [string]$ServiceUrl = 'https://cogentspec.com',

    [string]$TestToken = '',

    [string]$TestHelperPath = '',

    [ValidateRange(0, 100)]
    [int]$MaxPolls = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PinHotkeyReady = $false
$script:PinHotkeyError = ''
$script:VerifiedPopupVisible = $false
$script:CurrentConversationState = 'unknown'
$script:CurrentConversationKey = ''
$script:ActiveChatFingerprint = ''
$script:CurrentPopupWindowHandle = 0
# Separate from the keyboard hook: no key synthesis, no process termination.
function Initialize-PopoutWorkspaceLifecycle {
    if ($null -ne ('CogentSpec.PopoutWorkspaceLifecycle' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace CogentSpec {
 // Pure decision model: regression tests do not call native UI APIs.
 public sealed class PopoutLifecycleModel {
  public bool ControllerHidden, ManualReveal;
  long closedSince = -1;
  public string Decide(string state, bool associated, bool exists, bool visible, bool popupForeground, bool ownerGone, long now) {
   if (!associated || !exists) { ControllerHidden = false; closedSince = -1; return "none"; }
   if (state == "closed" || ownerGone) {
    if (closedSince < 0) closedSince = now;
    return now - closedSince >= 15000 ? "dismiss" : "none";
   }
   closedSince = -1;
   if (state == "unknown" || state == "unmanaged") return "none";
   if (state == "active") {
    ManualReveal = false;
    if (ControllerHidden && !visible) return "restore";
    if (visible) ControllerHidden = false;
    return "none";
   }
   if (ControllerHidden && visible) { ControllerHidden = false; ManualReveal = true; }
   if (popupForeground || ManualReveal) return "none";
   if ((state == "hidden" || state == "blurred") && visible) {
    ControllerHidden = true; return "hide";
   }
   return "none";
  }
 }
 public static class PopoutWorkspaceLifecycle {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int command);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
  static readonly object gate = new object();
  static IntPtr popup;
  static uint popupPid;
  static PopoutLifecycleModel model = new PopoutLifecycleModel();
  static string sessionPath;
  static int ownerPid;
  static long ownerStartedAt, sequence;
  static bool closing;
  static DateTime actionAt;
  static Thread thread;
  static volatile bool running;
  public static string LastAction = "none", State = "unmanaged", Authority = "awaiting_extension";
  static string Root {get {return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CogentSpec", "browser-lifecycle");}}
  static bool MatchesPopup() {
   uint actual;
   return popup != IntPtr.Zero && IsWindow(popup) && GetWindowThreadProcessId(popup, out actual) != 0 && actual == popupPid;
  }
  static bool OwnerAlive() {
   try {using (var process = Process.GetProcessById(ownerPid)) return process.StartTime.ToUniversalTime().Ticks == ownerStartedAt && !process.HasExited;}
   catch {return false;}
  }
  public static void Observe(long handle, int pid) {
   lock(gate) {
    uint actual; var h = new IntPtr(handle);
    if (h == IntPtr.Zero || !IsWindow(h) || GetWindowThreadProcessId(h, out actual) == 0 || actual != (uint)pid) return;
    if (h != popup || popupPid != actual) {
     // A new instance requires a new active workspace association. Never carry
     // the old chat proof or an old close command onto a replacement window.
     model = new PopoutLifecycleModel(); sessionPath = null; sequence = 0; closing = false;
     LastAction = "none"; Authority = "awaiting_association";
    }
    popup = h; popupPid = actual;
   }
  }
  public static bool IsControllerHidden(long handle) {
   lock(gate) {return popup.ToInt64() == handle && model.ControllerHidden && MatchesPopup() && !IsWindowVisible(popup) && !closing;}
  }
  static string[] Read(string path) {
   var fields = File.ReadAllText(path).Split('|');
   Guid id; long n, ticks, started; int pid;
   if (fields.Length != 7 || fields[0] != "1" || !Guid.TryParseExact(fields[1], "D", out id)
    || !Int64.TryParse(fields[2], out n) || n < 1 || !Int64.TryParse(fields[4], out ticks)
    || ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks
    || !Int32.TryParse(fields[5], out pid) || pid <= 0 || !Int64.TryParse(fields[6], out started)) return null;
   if (fields[3] != "active" && fields[3] != "hidden" && fields[3] != "blurred" && fields[3] != "closed" && fields[3] != "disconnected") return null;
   if (Path.GetFileNameWithoutExtension(path) != id.ToString()) return null;
   return fields;
  }
  static bool Fresh(string[] fields) {
   double age = (DateTime.UtcNow - new DateTime(Int64.Parse(fields[4]), DateTimeKind.Utc)).TotalSeconds;
   return age >= -1 && age <= 10 && fields[3] != "disconnected";
  }
  static void Bind(IntPtr foreground) {
   uint pid; GetWindowThreadProcessId(foreground, out pid);
   var title = new StringBuilder(512); GetWindowText(foreground, title, title.Capacity);
   if (title.ToString().IndexOf("CogentSpec", StringComparison.OrdinalIgnoreCase) < 0) return;
   using (var process = Process.GetProcessById((int)pid)) {
    if (process.ProcessName != "chrome" && process.ProcessName != "msedge") return;
    string chosen = null; string[] choice = null;
    foreach (var path in Directory.GetFiles(Root, "*.state")) {
     var f = Read(path);
     if (f == null || !Fresh(f) || f[3] != "active" || Int32.Parse(f[5]) != (int)pid
      || Int64.Parse(f[6]) != process.StartTime.ToUniversalTime().Ticks) continue;
     if (chosen != null) {Authority = "ambiguous_browser_session"; return;}
     chosen = path; choice = f;
    }
    if (chosen != null) {
     sessionPath = chosen; ownerPid = (int)pid; ownerStartedAt = Int64.Parse(choice[6]);
     sequence = 0; Authority = "local_extension";
    }
   }
  }
  public static void Tick(string ignoredServerState) {
   lock(gate) {
    if (!Directory.Exists(Root)) {Authority = "awaiting_extension"; State = "unmanaged"; return;}
    var foreground = GetForegroundWindow();
    if (!MatchesPopup()) {
     if (closing) LastAction = "dismiss_confirmed";
     model.ControllerHidden = false; return;
    }
    if (sessionPath == null && foreground != popup) Bind(foreground);
    bool associated = sessionPath != null;
    if (!associated) {State = "unmanaged"; return;}
    bool ownerGone = !OwnerAlive();
    State = "unknown";
    try {
     var fields = Read(sessionPath);
     if (fields != null && Int32.Parse(fields[5]) == ownerPid && Int64.Parse(fields[6]) == ownerStartedAt
      && Int64.Parse(fields[2]) >= sequence && Fresh(fields)) {
      sequence = Int64.Parse(fields[2]); State = fields[3];
     }
    } catch {}
    if (closing) {
     if ((DateTime.UtcNow-actionAt).TotalSeconds >= 5) LastAction = "dismiss_unconfirmed";
     return;
    }
    bool visible = IsWindowVisible(popup);
    // ShowWindowAsync is asynchronous. Wait for the outcome before allowing
    // the model to interpret a still-visible window as a manual reopen.
    if (LastAction == "hide_requested" && visible) {
     if ((DateTime.UtcNow-actionAt).TotalSeconds < 3) return;
     model.ControllerHidden = false; LastAction = "hide_failed"; return;
    }
    if (LastAction == "hide_requested" && !visible) LastAction = "hide_confirmed";
    if (LastAction == "restore_requested" && !visible) {
     if ((DateTime.UtcNow-actionAt).TotalSeconds < 3) return;
     LastAction = "restore_failed"; return;
    }
    if (LastAction == "restore_requested" && visible) LastAction = "restore_confirmed";
    string action = model.Decide(State, associated, true, visible, foreground == popup, ownerGone, DateTime.UtcNow.Ticks/TimeSpan.TicksPerMillisecond);
    if (action == "hide" || action == "restore") {
     // SW_HIDE and SW_SHOWNOACTIVATE preserve HWND and topmost style. No keys,
     // activation, window replacement, main-window close or process termination.
     bool requested = ShowWindowAsync(popup, action == "hide" ? 0 : 4);
     actionAt = DateTime.UtcNow;
     LastAction = action + (requested ? "_requested" : "_failed");
     if (!requested && action == "hide") model.ControllerHidden = false;
    } else if (action == "dismiss") {
     closing = PostMessage(popup, 0x0010, IntPtr.Zero, IntPtr.Zero);
     actionAt = DateTime.UtcNow; LastAction = closing ? "dismiss_requested" : "dismiss_failed";
    }
   }
  }
  public static void Start() {
   lock(gate) {
    if (running) return;
    running = true;
    thread = new Thread(delegate() {
     while(running) {try {Tick(null);} catch {Authority = "local_controller_error";} Thread.Sleep(250);}
    }); thread.IsBackground = true; thread.Start();
   }
  }
  public static void Stop() {running = false; if (thread != null) thread.Join(1000);}
 }
}
'@
}
$script:WorkspaceLifecycleState = 'unmanaged'
$script:WorkspaceLifecycleSeenAt = [DateTime]::MinValue
if (-not $TestToken) {
    Initialize-PopoutWorkspaceLifecycle
    [CogentSpec.PopoutWorkspaceLifecycle]::Start()
}

function Write-ReadyMarker([bool]$ServerAcknowledged, [string]$Status = 'ready', [string]$LastError = '') {
    if (-not $ReadyPath) { return }
    $parent = Split-Path -Parent $ReadyPath
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [ordered]@{
        processId = $PID
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        serverAcknowledged = $ServerAcknowledged
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
        status = $Status
        lastError = $LastError
        pinHotkey = 'Ctrl+Shift+Y'
        pinHotkeyReady = [bool]$script:PinHotkeyReady
        pinHotkeyScope = 'verified_foreground_chatgpt_popout'
        pinHotkeyError = [string]$script:PinHotkeyError
        popupVisible = [bool]$script:VerifiedPopupVisible
        conversationState = [string]$script:CurrentConversationState
        currentConversationKey = [string]$script:CurrentConversationKey
        connectedChatMarkerFound = [bool]$script:ActiveChatFingerprint
        popupWindowHandle = [long]$script:CurrentPopupWindowHandle
        workspaceLifecycleState = if ($TestToken) { [string]$script:WorkspaceLifecycleState } else { [CogentSpec.PopoutWorkspaceLifecycle]::State }
        workspaceLifecycleAction = if ($TestToken) { 'test' } else { [CogentSpec.PopoutWorkspaceLifecycle]::LastAction }
        workspaceLifecycleAuthority = if ($TestToken) { 'test' } else { [CogentSpec.PopoutWorkspaceLifecycle]::Authority }
    } | ConvertTo-Json | Set-Content -LiteralPath $ReadyPath -Encoding UTF8
}

function Unprotect-CogentSpecValue([string]$Value) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-PopoutApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = $ServiceUrl.TrimEnd('/') + $Path
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 12
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Compress
    }
    return Invoke-RestMethod @parameters
}

function Read-DesktopToken {
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'Desktop Bridge is not connected to an account.' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    return Unprotect-CogentSpecValue ([string]$credential.token)
}

function Get-HttpStatusCode($Failure) {
    $responseProperty = $Failure.Exception.PSObject.Properties['Response']
    if (-not $responseProperty -or $null -eq $responseProperty.Value) { return 0 }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if (-not $statusProperty -or $null -eq $statusProperty.Value) { return 0 }
    try { return [int]$statusProperty.Value } catch { return 0 }
}

function Initialize-PopupPinHotkey {
    if ($TestToken) { return }
    try {
        if ($null -eq ('CogentSpec.ChatGptPopupPinHotkey' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace CogentSpec {
    public static class ChatGptPopupPinHotkey {
        private const int WH_KEYBOARD_LL = 13;
        private const uint WM_KEYDOWN = 0x0100;
        private const uint WM_KEYUP = 0x0101;
        private const uint WM_SYSKEYDOWN = 0x0104;
        private const uint WM_SYSKEYUP = 0x0105;
        private const uint WM_QUIT = 0x0012;
        private const int VK_CONTROL = 0x11;
        private const int VK_SHIFT = 0x10;
        private const int VK_MENU = 0x12;
        private const int VK_Y = 0x59;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOPMOST = 0x00000008L;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

        private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardData {
            public uint virtualKey;
            public uint scanCode;
            public uint flags;
            public uint time;
            public UIntPtr extraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Point {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Message {
            public IntPtr window;
            public uint message;
            public UIntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public Point point;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int hookId, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out Message message, IntPtr window, uint minimum, uint maximum);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref Message message);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref Message message);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        private static readonly object Sync = new object();
        private static ManualResetEvent ready;
        private static Thread hookThread;
        private static LowLevelKeyboardProc callback;
        private static IntPtr hook;
        private static uint hookThreadId;
        private static long verifiedPopupWindow;
        private static int verifiedProcessId;
        private static int capturedY;
        private static int started;
        private static string lastToggleStatus = "idle";
        private static int lastTogglePinned;
        private static long lastToggleUtcTicks;

        public static bool Start() {
            lock (Sync) {
                if (started != 0) return hook != IntPtr.Zero;
                started = 1;
                ready = new ManualResetEvent(false);
                hookThread = new Thread(HookThreadMain);
                hookThread.IsBackground = true;
                hookThread.Name = "CogentSpec ChatGPT Popout pin hotkey";
                hookThread.SetApartmentState(ApartmentState.STA);
                hookThread.Start();
            }
            ready.WaitOne(3000);
            if (hook != IntPtr.Zero) return true;
            Stop();
            return false;
        }

        public static void Stop() {
            Thread thread;
            uint threadId;
            lock (Sync) {
                thread = hookThread;
                threadId = hookThreadId;
            }
            SetVerifiedPopup(0, 0);
            if (threadId != 0) PostThreadMessage(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            if (thread != null && thread != Thread.CurrentThread) thread.Join(2000);
            lock (Sync) {
                hookThread = null;
                hookThreadId = 0;
                started = 0;
                capturedY = 0;
            }
        }

        public static void SetVerifiedPopup(long windowHandle, int processId) {
            Interlocked.Exchange(ref verifiedPopupWindow, 0);
            Interlocked.Exchange(ref verifiedProcessId, processId);
            Interlocked.Exchange(ref verifiedPopupWindow, windowHandle);
        }

        public static bool IsRunning { get { return hook != IntPtr.Zero; } }
        public static string LastToggleStatus { get { return lastToggleStatus; } }
        public static bool LastTogglePinned { get { return lastTogglePinned != 0; } }
        public static long LastToggleUtcTicks { get { return Interlocked.Read(ref lastToggleUtcTicks); } }

        private static void HookThreadMain() {
            callback = HookCallback;
            hookThreadId = GetCurrentThreadId();
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, callback, GetModuleHandle(null), 0);
            ready.Set();
            if (hook == IntPtr.Zero) return;
            Message message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }

        private static bool IsPressed(int virtualKey) {
            return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        }

        private static bool IsTopmost(IntPtr window) {
            return window != IntPtr.Zero && (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;
        }

        private static bool IsVerifiedForegroundPopup(IntPtr window) {
            long expectedWindow = Interlocked.Read(ref verifiedPopupWindow);
            int expectedProcess = Interlocked.CompareExchange(ref verifiedProcessId, 0, 0);
            if (expectedWindow == 0 || expectedProcess <= 0 || window.ToInt64() != expectedWindow) return false;
            if (!IsWindow(window) || !IsWindowVisible(window)) return false;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            return processId == (uint)expectedProcess;
        }

        private static void ToggleTopmost(IntPtr window) {
            bool shouldPin = !IsTopmost(window);
            IntPtr position = shouldPin ? HWND_TOPMOST : HWND_NOTOPMOST;
            uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            bool applied = SetWindowPos(window, position, 0, 0, 0, 0, flags);
            bool finalPinned = IsTopmost(window);
            lastTogglePinned = finalPinned ? 1 : 0;
            lastToggleStatus = applied && finalPinned == shouldPin
                ? (finalPinned ? "pinned" : "unpinned")
                : "pin_failed";
            Interlocked.Exchange(ref lastToggleUtcTicks, DateTime.UtcNow.Ticks);
        }

        private static IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                KeyboardData data = (KeyboardData)Marshal.PtrToStructure(lParam, typeof(KeyboardData));
                uint message = unchecked((uint)wParam.ToInt64());
                bool keyDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                bool keyUp = message == WM_KEYUP || message == WM_SYSKEYUP;
                if (data.virtualKey == VK_Y && (keyDown || keyUp)) {
                    if (keyUp && Interlocked.Exchange(ref capturedY, 0) != 0) return new IntPtr(1);
                    if (keyDown && Interlocked.CompareExchange(ref capturedY, 0, 0) != 0) return new IntPtr(1);
                    if (keyDown && IsPressed(VK_CONTROL) && IsPressed(VK_SHIFT) &&
                        !IsPressed(VK_MENU) && !IsPressed(VK_LWIN) && !IsPressed(VK_RWIN)) {
                        IntPtr foreground = GetForegroundWindow();
                        if (IsVerifiedForegroundPopup(foreground)) {
                            Interlocked.Exchange(ref capturedY, 1);
                            ToggleTopmost(foreground);
                            return new IntPtr(1);
                        }
                    }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
'@ -ErrorAction Stop
        }
        $script:PinHotkeyReady = [CogentSpec.ChatGptPopupPinHotkey]::Start()
        if (-not $script:PinHotkeyReady) { $script:PinHotkeyError = 'keyboard_hook_unavailable' }
    } catch {
        $script:PinHotkeyReady = $false
        $script:PinHotkeyError = 'keyboard_hook_initialization_failed'
    }
}

function Update-PopupPinHotkeyTarget {
    # Only the same verified, controller-hidden native instance can retain its
    # previous exact-chat proof. It cannot be interacted with while hidden.
    # Once visible, normal inspection runs before the next server presence POST.
    if (-not $TestToken -and $script:CurrentPopupWindowHandle -ne 0 -and
        [CogentSpec.PopoutWorkspaceLifecycle]::IsControllerHidden([long]$script:CurrentPopupWindowHandle)) {
        $script:VerifiedPopupVisible = $false
        if ($script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup(0, 0) }
        return
    }
    try {
        $inspectionArguments = @{ Mode = 'inspect' }
        if ($script:CurrentPopupWindowHandle -ne 0) {
            $inspectionArguments.PreferredWindowHandle = [long]$script:CurrentPopupWindowHandle
        }
        $inspectionOutput = @(& $popupHelper @inspectionArguments 2>&1)
        $inspectionJson = @($inspectionOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if (-not $inspectionJson) { throw 'The verified ChatGPT Popout helper returned no inspection result.' }
        $inspection = $inspectionJson | ConvertFrom-Json
        $verified = [string]$inspection.status -eq 'ready' -and [bool]$inspection.publisherVerified -and
            [bool]$inspection.popupVerified -and
            [long]$inspection.popupWindowHandle -ne 0 -and [int]$inspection.popupProcessId -gt 0
        $visible = $verified -and [bool]$inspection.popupVisible
        if ($verified -and -not $TestToken) {
            [CogentSpec.PopoutWorkspaceLifecycle]::Observe([long]$inspection.popupWindowHandle, [int]$inspection.popupProcessId)
        }
        $conversationState = if ($verified -and $inspection.PSObject.Properties['conversationState'] -and
            [string]$inspection.conversationState -in @('blank', 'identified')) { [string]$inspection.conversationState } else { 'unknown' }
        $currentConversationKey = if ($verified -and $inspection.PSObject.Properties['currentConversationKey'] -and
            [string]$inspection.currentConversationKey -match '^[a-f0-9]{64}$') { [string]$inspection.currentConversationKey } else { '' }
        $fingerprint = if ($inspection.PSObject.Properties['chatFingerprint'] -and
            [string]$inspection.chatFingerprint -match '^[a-f0-9]{64}$') { [string]$inspection.chatFingerprint } else { '' }
        $script:VerifiedPopupVisible = $visible
        $missingClientNotice = ($verified -and $inspection.PSObject.Properties['clientUnavailable'] -and [bool]$inspection.clientUnavailable)
        if ($missingClientNotice -and $currentConversationKey) { $script:UnavailableConversationKey = $currentConversationKey }
        # Dismissing a toast is not client recovery. Only a different/new command
        # turn can release the affected identity; a blank/unknown chat stays red.
        $script:ClientUnavailable = $missingClientNotice -or ($currentConversationKey -and
            (Get-Variable -Name UnavailableConversationKey -Scope Script -ErrorAction SilentlyContinue) -and
            $script:UnavailableConversationKey -eq $currentConversationKey)
        if ($script:ClientUnavailable) { $conversationState = 'unknown' }
        $script:CurrentConversationState = $conversationState
        $script:CurrentConversationKey = $currentConversationKey
        $script:ActiveChatFingerprint = if ($verified) { $fingerprint } else { '' }
        $script:CurrentPopupWindowHandle = if ($verified) { [long]$inspection.popupWindowHandle } else { 0 }
        if ($script:PinHotkeyReady) {
            if ($visible) {
                [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup([long]$inspection.popupWindowHandle, [int]$inspection.popupProcessId)
            } else {
                [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup(0, 0)
            }
        }
    } catch {
        $script:VerifiedPopupVisible = $false
        $script:ClientUnavailable = $false
        $script:CurrentConversationState = 'unknown'
        $script:CurrentConversationKey = ''
        $script:ActiveChatFingerprint = ''
        $script:CurrentPopupWindowHandle = 0
        if ($script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup(0, 0) }
    }
}

if ($TestToken) {
    if ($ServiceUrl -notmatch '^https?://(localhost|127\.0\.0\.1)(:\d+)?$' -or -not $TestHelperPath) {
        throw 'Test tokens are restricted to a loopback service and an explicit helper.'
    }
    $token = $TestToken
    $popupHelper = $TestHelperPath
} else {
    if ($ServiceUrl -ne 'https://cogentspec.com') { throw 'The production standalone Popout Bridge only connects to CogentSpec.' }
    $token = Read-DesktopToken
    $popupHelper = Join-Path $PSScriptRoot 'open-chatgpt-popup.ps1'
}

if (-not (Test-Path -LiteralPath $popupHelper -PathType Leaf)) { throw 'The verified ChatGPT Popout helper is missing.' }
$query = '?pluginId=' + [Uri]::EscapeDataString($PluginId) + '&pluginVersion=' + [Uri]::EscapeDataString($PluginVersion)
$polls = 0
$consecutiveFailures = 0
Initialize-PopupPinHotkey
Update-PopupPinHotkeyTarget

try {
    while ($true) {
        try {
            $presenceQuery = $query + '&popupVisible=' + $script:VerifiedPopupVisible.ToString().ToLowerInvariant()
            $presenceQuery += '&conversationState=' + [Uri]::EscapeDataString($script:CurrentConversationState)
            if ($script:CurrentConversationKey) {
                $presenceQuery += '&currentConversationKey=' + [Uri]::EscapeDataString($script:CurrentConversationKey)
            }
            if ($script:ActiveChatFingerprint) {
                $presenceQuery += '&chatFingerprint=' + [Uri]::EscapeDataString($script:ActiveChatFingerprint)
            }
            $listing = Invoke-PopoutApi -Method Get -Path "/api/plugin/desktop-popout-actions$presenceQuery" -Token $token
            $consecutiveFailures = 0
            if ($listing.PSObject.Properties['workspaceLifecycle']) {
                $script:WorkspaceLifecycleState = [string]$listing.workspaceLifecycle.state
                $script:WorkspaceLifecycleSeenAt = [DateTime]::UtcNow
            } else { $script:WorkspaceLifecycleState = 'unmanaged' }
            if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Tick($script:WorkspaceLifecycleState) }
            Write-ReadyMarker -ServerAcknowledged $true -Status 'ready'
            $request = $listing.request
            if ($request) {
                $claimed = Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                    requestId = [string]$request.id
                    action = 'claim'
                }
                if ($claimed.request) {
                    $completed = $false
                    $message = 'The standalone ChatGPT Popout could not be opened.'
                    try {
                        $target = [string]$claimed.request.targetRequestId
                        if ($target -notin @('chatgpt-desktop-popup', 'chatgpt-desktop-popup:connect', 'chatgpt-desktop-popup:update')) {
                            throw 'Standalone Popout Bridge rejected an unsupported target.'
                        }
                        $composerRequired = $target -ne 'chatgpt-desktop-popup'
                        # Refresh before dispatch: a user may have switched chats
                        # after the web request. Do not recover a different chat.
                        $requestConversationKey = if ($claimed.request.PSObject.Properties['recoveryChatFingerprint']) { [string]$claimed.request.recoveryChatFingerprint } else { '' }
                        Update-PopupPinHotkeyTarget
                        $recoverThreadId = if ($claimed.request.PSObject.Properties['recoveryThreadId']) { [string]$claimed.request.recoveryThreadId } else { '' }
                        if ($script:ClientUnavailable -and ($target -ne 'chatgpt-desktop-popup:connect' -or
                            -not $requestConversationKey -or $requestConversationKey -ne $script:CurrentConversationKey -or
                            $recoverThreadId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) {
                            throw 'This retained Popout has no desktop client. Open the original saved chat from the desktop chat list and send $cogentspec there. No verified thread is available for automatic recovery; no new chat was substituted.'
                        }
                        $helperOutput = if ($script:ClientUnavailable -and $target -eq 'chatgpt-desktop-popup:connect' -and
                            $requestConversationKey -and $requestConversationKey -eq $script:CurrentConversationKey -and
                            $recoverThreadId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                            @(& $popupHelper -Mode recover -ThreadId $recoverThreadId 2>&1)
                        } elseif ($target -eq 'chatgpt-desktop-popup:connect') {
                            @(& $popupHelper -Mode open -UseRetainedChat -OpenWithShortcut -KeepPinned -PasteClipboard 2>&1)
                        } elseif ($target -eq 'chatgpt-desktop-popup:update') {
                            @(& $popupHelper -Mode open -UseRetainedChat -KeepPinned -PasteClipboard 2>&1)
                        } else {
                            @(& $popupHelper -Mode open -UseRetainedChat -KeepPinned 2>&1)
                        }
                        $helperJson = @($helperOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
                        if (-not $helperJson) { throw 'The verified ChatGPT Popout helper returned no result.' }
                        $result = $helperJson | ConvertFrom-Json
                        $completed = [string]$result.status -eq 'opened' -and [bool]$result.opened -and
                            (-not $composerRequired -or [bool]$result.composerPopulated)
                        $message = if ($completed) {
                            if ($composerRequired) { 'Standalone ChatGPT Popout opened, pinned, and filled.' }
                            else { 'Standalone ChatGPT Popout opened and pinned.' }
                        } elseif ($result.reason) { [string]$result.reason }
                        else { 'The standalone ChatGPT Popout could not be opened.' }
                    } catch {
                        $message = $_.Exception.Message
                    }
                    Update-PopupPinHotkeyTarget
                    [void](Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                        requestId = [string]$request.id
                        action = if ($completed) { 'complete' } else { 'fail' }
                        statusMessage = $message
                    })
                }
            }
        } catch {
            $consecutiveFailures++
            $statusCode = Get-HttpStatusCode -Failure $_
            $authorizationFailure = $statusCode -eq 401 -or $statusCode -eq 403
            $errorKind = if ($authorizationFailure) { 'authorization_failure' }
                elseif ($statusCode -gt 0) { "http_$statusCode" }
                else { 'transport_failure' }
            Write-ReadyMarker -ServerAcknowledged $false -Status 'retrying' -LastError $errorKind
            if ($authorizationFailure -and -not $TestToken) {
                try { $token = Read-DesktopToken } catch { }
            }
        }
        $polls++
        if ($MaxPolls -gt 0 -and $polls -ge $MaxPolls) { break }
        $retryExponent = [Math]::Min(5, [Math]::Max(0, $consecutiveFailures - 1))
        $retryMilliseconds = if ($consecutiveFailures -gt 0) {
            [Math]::Min($MaximumRetryMilliseconds, [int]($PollMilliseconds * [Math]::Pow(2, $retryExponent)))
        } else { $PollMilliseconds }
        $waitDeadline = [DateTime]::UtcNow.AddMilliseconds($retryMilliseconds)
        do {
            $remainingMilliseconds = [int][Math]::Max(0, ($waitDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min(1500, $remainingMilliseconds))
            Update-PopupPinHotkeyTarget
            if (([DateTime]::UtcNow - $script:WorkspaceLifecycleSeenAt).TotalSeconds -gt 90) {
                $script:WorkspaceLifecycleState = 'unknown'
            }
            if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Tick($script:WorkspaceLifecycleState) }
        } while ([DateTime]::UtcNow -lt $waitDeadline)
    }
} finally {
    if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Stop() }
    if ($script:PinHotkeyReady) {
        [CogentSpec.ChatGptPopupPinHotkey]::Stop()
        $script:PinHotkeyReady = $false
    }
    $token = $null
}
