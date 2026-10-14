[CmdletBinding()]
param(
    [ValidateSet('Widget', 'Inspect', 'Apply', 'Restore')]
    [string]$Mode = 'Widget',

    [ValidateRange(320, 3840)]
    [int]$Width = 900,

    [ValidateRange(240, 2160)]
    [int]$Height = 600,

    [ValidateSet('gptdesktop', 'claudedesktop', 'both')]
    [string]$Target = 'both',

    [switch]$AllowClaudeCandidate,

    [switch]$CompactOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq ('CogentSpec.PopoutWindowNormalizerNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CogentSpec {
    public static class PopoutWindowNormalizerNative {
        public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Point {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WindowPlacement {
            public int Length;
            public int Flags;
            public int ShowCommand;
            public Point MinimumPosition;
            public Point MaximumPosition;
            public Rect NormalPosition;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct MonitorInfo {
            public int Size;
            public Rect Monitor;
            public Rect Work;
            public int Flags;
        }

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr window, StringBuilder text, int count);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr window, out Rect rect);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);

        [DllImport("user32.dll")]
        public static extern bool GetWindowPlacement(IntPtr window, ref WindowPlacement placement);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr window);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        public static IntPtr[] VisibleWindows() {
            var windows = new List<IntPtr>();
            EnumWindows((window, parameter) => {
                if (IsWindowVisible(window)) windows.Add(window);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
    }
}
'@
}

[void][CogentSpec.PopoutWindowNormalizerNative]::SetProcessDpiAwarenessContext([IntPtr](-4))

$script:StatePath = Join-Path $env:LOCALAPPDATA 'CogentSpec\desktop-window-normalizer-state.json'
$script:SetWindowFlags = [uint32](0x0004 -bor 0x0010 -bor 0x0200) # SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER
$script:CompactOverrideFlag = [uint32]0x0400 # SWP_NOSENDCHANGING
$script:PublisherCache = @{}

function Convert-RectToObject {
    param($Rect)
    [ordered]@{
        x = $Rect.Left
        y = $Rect.Top
        width = $Rect.Right - $Rect.Left
        height = $Rect.Bottom - $Rect.Top
    }
}

function Get-WindowTitle {
    param([IntPtr]$Window)
    $text = [Text.StringBuilder]::new(512)
    [void][CogentSpec.PopoutWindowNormalizerNative]::GetWindowText($Window, $text, $text.Capacity)
    return $text.ToString()
}

function Get-WindowClass {
    param([IntPtr]$Window)
    $text = [Text.StringBuilder]::new(256)
    [void][CogentSpec.PopoutWindowNormalizerNative]::GetClassName($Window, $text, $text.Capacity)
    return $text.ToString()
}

function Get-WindowGeometry {
    param([IntPtr]$Window)

    $outer = New-Object CogentSpec.PopoutWindowNormalizerNative+Rect
    if (-not [CogentSpec.PopoutWindowNormalizerNative]::GetWindowRect($Window, [ref]$outer)) {
        throw 'Windows could not read the target window rectangle.'
    }

    $frame = New-Object CogentSpec.PopoutWindowNormalizerNative+Rect
    $frameResult = [CogentSpec.PopoutWindowNormalizerNative]::DwmGetWindowAttribute(
        $Window,
        9,
        [ref]$frame,
        [Runtime.InteropServices.Marshal]::SizeOf([type]'CogentSpec.PopoutWindowNormalizerNative+Rect')
    )
    if ($frameResult -ne 0) { $frame = $outer }

    return [pscustomobject]@{ outer = $outer; frame = $frame }
}

function Get-WindowPlacementState {
    param([IntPtr]$Window)
    $placement = New-Object CogentSpec.PopoutWindowNormalizerNative+WindowPlacement
    $placement.Length = [Runtime.InteropServices.Marshal]::SizeOf([type]'CogentSpec.PopoutWindowNormalizerNative+WindowPlacement')
    if (-not [CogentSpec.PopoutWindowNormalizerNative]::GetWindowPlacement($Window, [ref]$placement)) {
        throw 'Windows could not read the target window placement.'
    }
    return $placement
}

function Test-WindowTopmost {
    param([IntPtr]$Window)
    return ([CogentSpec.PopoutWindowNormalizerNative]::GetWindowLongPtr($Window, -20).ToInt64() -band 0x8) -ne 0
}

function Test-Publisher {
    param(
        [string]$Path,
        [ValidateSet('OpenAI', 'Anthropic')]
        [string]$Publisher
    )
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    $pattern = if ($Publisher -eq 'OpenAI') { '(?i)\bO="?OpenAI(?: OpCo)?,? LLC"?\b' } else { '(?i)\bO="?Anthropic,? PBC"?\b' }
    return [string]$signature.Status -eq 'Valid' -and $subject -match $pattern
}

function Get-NormalizerWindows {
    $processes = @{}
    foreach ($name in @('ChatGPT', 'claude')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                $path = [string]$process.Path
                $publisher = if ($name -eq 'ChatGPT') { 'OpenAI' } else { 'Anthropic' }
                $publisherKey = "$publisher|$path"
                if (-not $script:PublisherCache.ContainsKey($publisherKey)) {
                    $script:PublisherCache[$publisherKey] = Test-Publisher -Path $path -Publisher $publisher
                }
                $processes[$process.Id] = [pscustomobject]@{
                    process = $process
                    path = $path
                    publisherVerified = [bool]$script:PublisherCache[$publisherKey]
                }
            } catch {}
        }
    }

    $mainChatGptHandles = @($processes.Values | Where-Object { $_.process.ProcessName -eq 'ChatGPT' } | ForEach-Object {
        $_.process.MainWindowHandle.ToInt64()
    } | Where-Object { $_ -ne 0 })
    $mainClaudeHandles = @($processes.Values | Where-Object { $_.process.ProcessName -eq 'claude' } | ForEach-Object {
        $_.process.MainWindowHandle.ToInt64()
    } | Where-Object { $_ -ne 0 })

    $rows = @()
    foreach ($window in [CogentSpec.PopoutWindowNormalizerNative]::VisibleWindows()) {
        [uint32]$processId = 0
        [void][CogentSpec.PopoutWindowNormalizerNative]::GetWindowThreadProcessId($window, [ref]$processId)
        if (-not $processes.ContainsKey([int]$processId)) { continue }
        $processEntry = $processes[[int]$processId]
        if (-not $processEntry.publisherVerified) { continue }
        if ((Get-WindowClass -Window $window) -ne 'Chrome_WidgetWin_1') { continue }

        $title = Get-WindowTitle -Window $window
        $placement = Get-WindowPlacementState -Window $window
        if ($placement.ShowCommand -notin @(1, 3)) { continue }
        $geometry = Get-WindowGeometry -Window $window
        $frameObject = Convert-RectToObject $geometry.frame
        $isGptDesktop = $processEntry.process.ProcessName -eq 'ChatGPT' -and
            $title -eq 'ChatGPT' -and
            $mainChatGptHandles -contains $window.ToInt64()
        $isClaudeDesktop = $processEntry.process.ProcessName -eq 'claude' -and
            $mainClaudeHandles -contains $window.ToInt64() -and
            -not [string]::IsNullOrWhiteSpace($title) -and
            $frameObject.width -ge 320 -and
            $frameObject.height -ge 240
        if (-not $isGptDesktop -and -not $isClaudeDesktop) { continue }

        $rows += [pscustomobject]@{
            name = if ($isGptDesktop) { 'gptdesktop' } else { 'claudedesktop' }
            identity = if ($isGptDesktop) { 'verified_gpt_codex_desktop_main_window' } else { 'single_signed_claude_desktop_main_window' }
            window = [IntPtr]$window
            processId = [int]$processId
            processPath = $processEntry.path
            dpi = [CogentSpec.PopoutWindowNormalizerNative]::GetDpiForWindow($window)
            geometry = $geometry
            showCommand = [int]$placement.ShowCommand
            topmost = Test-WindowTopmost -Window $window
        }
    }
    return @($rows)
}

function Resolve-NormalizerTargets {
    param(
        [ValidateSet('gptdesktop', 'claudedesktop', 'both')]
        [string]$RequestedTarget
    )

    $rows = @(Get-NormalizerWindows)
    $targets = @()
    if ($RequestedTarget -in @('gptdesktop', 'both')) {
        $matches = @($rows | Where-Object { $_.name -eq 'gptdesktop' })
        if ($matches.Count -ne 1) { throw "Expected one verified GPT/Codex Desktop main window, found $($matches.Count)." }
        $targets += $matches[0]
    }
    if ($RequestedTarget -in @('claudedesktop', 'both')) {
        $matches = @($rows | Where-Object { $_.name -eq 'claudedesktop' })
        if ($matches.Count -ne 1) { throw "Expected one signed visible Claude Desktop main window, found $($matches.Count)." }
        $targets += $matches[0]
    }
    return @($targets)
}

function Get-NormalizedOuterRequest {
    param(
        $Outer,
        $Frame,
        $WorkArea,
        [int]$TargetWidth,
        [int]$TargetHeight
    )

    $leftInset = $Frame.Left - $Outer.Left
    $topInset = $Frame.Top - $Outer.Top
    $rightInset = $Outer.Right - $Frame.Right
    $bottomInset = $Outer.Bottom - $Frame.Bottom
    $frameX = [Math]::Max($WorkArea.Left, [Math]::Min($Frame.Left, $WorkArea.Right - $TargetWidth))
    $frameY = [Math]::Max($WorkArea.Top, [Math]::Min($Frame.Top, $WorkArea.Bottom - $TargetHeight))
    return [ordered]@{
        x = $frameX - $leftInset
        y = $frameY - $topInset
        width = $TargetWidth + $leftInset + $rightInset
        height = $TargetHeight + $topInset + $bottomInset
    }
}

function Save-NormalizerState {
    param([object[]]$Targets)
    $directory = Split-Path -Parent $script:StatePath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $payload = [ordered]@{
        protocol = 'cogentspec-desktop-normalizer-state-v1'
        savedAt = [DateTime]::UtcNow.ToString('o')
        windows = @($Targets | ForEach-Object {
            [ordered]@{
                name = $_.name
                identity = $_.identity
                processId = $_.processId
                processPath = $_.processPath
                hwnd = $_.window.ToInt64()
                outer = Convert-RectToObject $_.geometry.outer
                frame = Convert-RectToObject $_.geometry.frame
                showCommand = $_.showCommand
                topmost = $_.topmost
            }
        })
    }
    [IO.File]::WriteAllText($script:StatePath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Invoke-NormalizeWindows {
    param(
        [object[]]$Targets,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [bool]$UseCompactOverride = $false
    )

    Save-NormalizerState -Targets $Targets
    $foregroundBefore = [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
    $results = @()
    foreach ($target in $Targets) {
        if ($target.showCommand -ne 1) {
            if (-not [CogentSpec.PopoutWindowNormalizerNative]::ShowWindowAsync($target.window, 4)) {
                throw "Windows could not restore $($target.name) without activation before sizing."
            }
            Start-Sleep -Milliseconds 350
            $target.geometry = Get-WindowGeometry -Window $target.window
        }
        $monitor = [CogentSpec.PopoutWindowNormalizerNative]::MonitorFromWindow($target.window, 2)
        $monitorInfo = New-Object CogentSpec.PopoutWindowNormalizerNative+MonitorInfo
        $monitorInfo.Size = [Runtime.InteropServices.Marshal]::SizeOf([type]'CogentSpec.PopoutWindowNormalizerNative+MonitorInfo')
        if (-not [CogentSpec.PopoutWindowNormalizerNative]::GetMonitorInfo($monitor, [ref]$monitorInfo)) {
            throw "Windows could not resolve the monitor for $($target.name)."
        }
        $request = Get-NormalizedOuterRequest -Outer $target.geometry.outer -Frame $target.geometry.frame -WorkArea $monitorInfo.Work -TargetWidth $TargetWidth -TargetHeight $TargetHeight
        if (-not [CogentSpec.PopoutWindowNormalizerNative]::SetWindowPos(
            $target.window,
            [IntPtr]::Zero,
            $request.x,
            $request.y,
            $request.width,
            $request.height,
            $script:SetWindowFlags
        )) {
            throw "Windows rejected the size request for $($target.name): $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        Start-Sleep -Milliseconds 350
        $actual = Get-WindowGeometry -Window $target.window
        $actualTopmost = Test-WindowTopmost -Window $target.window
        if ($actualTopmost -ne $target.topmost) { throw "The topmost state changed unexpectedly for $($target.name)." }
        $actualFrame = Convert-RectToObject $actual.frame
        $clamped = $actualFrame.width -ne $TargetWidth -or $actualFrame.height -ne $TargetHeight
        $overrideAttempted = $false
        if ($clamped -and $UseCompactOverride) {
            $overrideAttempted = $true
            if (-not [CogentSpec.PopoutWindowNormalizerNative]::SetWindowPos(
                $target.window,
                [IntPtr]::Zero,
                $request.x,
                $request.y,
                $request.width,
                $request.height,
                [uint32]($script:SetWindowFlags -bor $script:CompactOverrideFlag)
            )) {
                throw "Windows rejected the compact override for $($target.name): $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
            }
            Start-Sleep -Milliseconds 800
            $actual = Get-WindowGeometry -Window $target.window
            $actualFrame = Convert-RectToObject $actual.frame
            $clamped = $actualFrame.width -ne $TargetWidth -or $actualFrame.height -ne $TargetHeight
        }
        $actualTopmost = Test-WindowTopmost -Window $target.window
        if ($actualTopmost -ne $target.topmost) { throw "The topmost state changed unexpectedly for $($target.name)." }
        $results += [ordered]@{
            name = $target.name
            identity = $target.identity
            requestedFrame = [ordered]@{ width = $TargetWidth; height = $TargetHeight }
            acceptedFrame = $actualFrame
            status = if ($clamped) { 'clamped_by_application' }
                elseif ($overrideAttempted) { 'applied_with_compact_override' }
                else { 'applied' }
            compactOverrideAttempted = $overrideAttempted
            topmostPreserved = $true
        }
    }
    $acceptedCount = @($results | Where-Object { $_.status -in @('applied', 'applied_with_compact_override') }).Count
    $overallStatus = if ($results.Count -eq 0) { 'no_targets' }
        elseif ($acceptedCount -eq $results.Count) { 'applied' }
        elseif ($acceptedCount -eq 0) { 'clamped_by_application' }
        else { 'partial' }
    return [ordered]@{
        status = $overallStatus
        foregroundPreserved = $foregroundBefore -eq [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
        statePath = $script:StatePath
        results = $results
    }
}

function Invoke-MaintainNormalizedWindows {
    param(
        [object[]]$TrackedTargets,
        [int]$TargetWidth,
        [int]$TargetHeight
    )

    $foregroundBefore = [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
    $current = @(Get-NormalizerWindows)
    $results = @()
    foreach ($tracked in $TrackedTargets) {
        $target = @($current | Where-Object {
            $_.name -eq $tracked.name -and
            $_.window.ToInt64() -eq $tracked.window.ToInt64() -and
            $_.processId -eq $tracked.processId -and
            $_.processPath -eq $tracked.processPath
        })
        if ($target.Count -ne 1) {
            $results += [ordered]@{ name = $tracked.name; status = 'target_no_longer_available' }
            continue
        }

        $placement = Get-WindowPlacementState -Window $target[0].window
        if ($placement.ShowCommand -ne 1) {
            $results += [ordered]@{ name = $tracked.name; status = 'paused_while_window_not_normal' }
            continue
        }

        $geometry = Get-WindowGeometry -Window $target[0].window
        $frame = Convert-RectToObject $geometry.frame
        if ($frame.width -eq $TargetWidth -and $frame.height -eq $TargetHeight) {
            $results += [ordered]@{ name = $tracked.name; status = 'unchanged'; frame = $frame }
            continue
        }

        $topmostBefore = Test-WindowTopmost -Window $target[0].window
        $monitor = [CogentSpec.PopoutWindowNormalizerNative]::MonitorFromWindow($target[0].window, 2)
        $monitorInfo = New-Object CogentSpec.PopoutWindowNormalizerNative+MonitorInfo
        $monitorInfo.Size = [Runtime.InteropServices.Marshal]::SizeOf([type]'CogentSpec.PopoutWindowNormalizerNative+MonitorInfo')
        if (-not [CogentSpec.PopoutWindowNormalizerNative]::GetMonitorInfo($monitor, [ref]$monitorInfo)) {
            $results += [ordered]@{ name = $tracked.name; status = 'monitor_unavailable' }
            continue
        }
        $request = Get-NormalizedOuterRequest -Outer $geometry.outer -Frame $geometry.frame -WorkArea $monitorInfo.Work -TargetWidth $TargetWidth -TargetHeight $TargetHeight
        if (-not [CogentSpec.PopoutWindowNormalizerNative]::SetWindowPos(
            $target[0].window,
            [IntPtr]::Zero,
            $request.x,
            $request.y,
            $request.width,
            $request.height,
            [uint32]($script:SetWindowFlags -bor $script:CompactOverrideFlag)
        )) {
            $results += [ordered]@{ name = $tracked.name; status = 'correction_rejected' }
            continue
        }

        $actual = Get-WindowGeometry -Window $target[0].window
        $actualFrame = Convert-RectToObject $actual.frame
        $topmostPreserved = (Test-WindowTopmost -Window $target[0].window) -eq $topmostBefore
        $results += [ordered]@{
            name = $tracked.name
            status = if ($actualFrame.width -eq $TargetWidth -and $actualFrame.height -eq $TargetHeight) { 'corrected' } else { 'correction_pending' }
            frame = $actualFrame
            topmostPreserved = $topmostPreserved
        }
    }

    $correctionCount = @($results | Where-Object { $_.status -eq 'corrected' }).Count
    return [ordered]@{
        status = 'maintaining_compact_size'
        corrections = $correctionCount
        foregroundPreserved = $foregroundBefore -eq [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
        results = $results
    }
}

function Restore-NormalizerWindows {
    $foregroundBefore = [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
    if (-not (Test-Path -LiteralPath $script:StatePath)) { throw 'No saved Desktop Window Normalizer state exists.' }
    $state = Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
    if ($state.protocol -ne 'cogentspec-desktop-normalizer-state-v1') { throw 'The saved normalizer state is not recognized.' }
    $current = @(Get-NormalizerWindows)
    $results = @()
    foreach ($saved in @($state.windows)) {
        $target = @($current | Where-Object {
            $_.name -eq $saved.name -and
            $_.window.ToInt64() -eq [long]$saved.hwnd -and
            $_.processId -eq [int]$saved.processId -and
            $_.processPath -eq [string]$saved.processPath
        })
        if ($target.Count -ne 1) {
            $results += [ordered]@{ name = $saved.name; status = 'original_window_no_longer_available' }
            continue
        }
        $currentPlacement = Get-WindowPlacementState -Window $target[0].window
        if ($currentPlacement.ShowCommand -ne 1) {
            [void][CogentSpec.PopoutWindowNormalizerNative]::ShowWindowAsync($target[0].window, 4)
            Start-Sleep -Milliseconds 250
        }
        if (-not [CogentSpec.PopoutWindowNormalizerNative]::SetWindowPos(
            $target[0].window,
            [IntPtr]::Zero,
            [int]$saved.outer.x,
            [int]$saved.outer.y,
            [int]$saved.outer.width,
            [int]$saved.outer.height,
            $script:SetWindowFlags
        )) {
            throw "Windows rejected the restore request for $($saved.name)."
        }
        # SW_SHOWMAXIMIZED activates the window. Restore geometry only and
        # report deferred maximization rather than stealing the foreground.
        $maximizeDeferred = [int]$saved.showCommand -eq 3
        Start-Sleep -Milliseconds 250
        $actual = Get-WindowGeometry -Window $target[0].window
        $results += [ordered]@{
            name = $saved.name
            status = if ($maximizeDeferred) { 'geometry_restored_maximize_deferred' } else { 'restored' }
            frame = Convert-RectToObject $actual.frame
            userMessage = if ($maximizeDeferred) { 'Geometry restored without activation. Maximize this window manually to restore its original maximized state.' } else { $null }
        }
    }
    return [ordered]@{
        status = if (@($results | Where-Object { $_.status -ne 'restored' }).Count) { 'restore_partial' } else { 'restore_complete' }
        foregroundPreserved = $foregroundBefore -eq [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
        results = $results
    }
}

function Get-NormalizerInspection {
    $rows = @(Get-NormalizerWindows)
    return [ordered]@{
        status = 'inspected'
        windows = @($rows | ForEach-Object {
            [ordered]@{
                name = $_.name
                identity = $_.identity
                processId = $_.processId
                dpi = $_.dpi
                frame = Convert-RectToObject $_.geometry.frame
                windowState = if ($_.showCommand -eq 3) { 'maximized' } else { 'normal' }
                topmost = $_.topmost
            }
        })
    }
}

function Show-NormalizerWidget {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'Desktop Window Normalizer'
    $form.Width = 470
    $form.Height = 430
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.TopMost = $true

    $widthLabel = [Windows.Forms.Label]::new()
    $widthLabel.Text = 'Width'
    $widthLabel.SetBounds(20, 20, 80, 24)
    $widthInput = [Windows.Forms.NumericUpDown]::new()
    $widthInput.Minimum = 320
    $widthInput.Maximum = 3840
    $widthInput.Value = $Width
    $widthInput.SetBounds(105, 18, 110, 28)

    $heightLabel = [Windows.Forms.Label]::new()
    $heightLabel.Text = 'Height'
    $heightLabel.SetBounds(235, 20, 70, 24)
    $heightInput = [Windows.Forms.NumericUpDown]::new()
    $heightInput.Minimum = 240
    $heightInput.Maximum = 2160
    $heightInput.Value = $Height
    $heightInput.SetBounds(305, 18, 110, 28)

    $gptCheck = [Windows.Forms.CheckBox]::new()
    $gptCheck.Text = 'GPT/Codex Desktop main window'
    $gptCheck.Checked = $Target -in @('gptdesktop', 'both')
    $gptCheck.SetBounds(20, 60, 390, 28)

    $claudeCheck = [Windows.Forms.CheckBox]::new()
    $claudeCheck.Text = 'Claude Desktop main window'
    $claudeCheck.Checked = $Target -in @('claudedesktop', 'both')
    $claudeCheck.SetBounds(20, 90, 420, 28)

    $compactCheck = [Windows.Forms.CheckBox]::new()
    $compactCheck.Text = 'Maintain compact size while this widget is open'
    $compactCheck.Checked = $CompactOverride.IsPresent
    $compactCheck.SetBounds(20, 120, 420, 28)

    $statusBox = [Windows.Forms.TextBox]::new()
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $statusBox.ScrollBars = 'Vertical'
    $statusBox.SetBounds(20, 155, 415, 155)

    $refreshButton = [Windows.Forms.Button]::new()
    $refreshButton.Text = 'Refresh'
    $refreshButton.SetBounds(20, 327, 90, 32)
    $applyButton = [Windows.Forms.Button]::new()
    $applyButton.Text = 'Apply'
    $applyButton.SetBounds(120, 327, 90, 32)
    $restoreButton = [Windows.Forms.Button]::new()
    $restoreButton.Text = 'Restore'
    $restoreButton.SetBounds(220, 327, 90, 32)
    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = 'Close'
    $closeButton.SetBounds(345, 327, 90, 32)

    $render = {
        param($Value)
        $statusBox.Text = $Value | ConvertTo-Json -Depth 8
    }
    $maintenance = [pscustomobject]@{
        Active = $false
        TrackedTargets = @()
        TargetWidth = 0
        TargetHeight = 0
        CorrectionCount = 0
    }
    $maintenanceTimer = [Windows.Forms.Timer]::new()
    $maintenanceTimer.Interval = 2000
    $maintenanceTimer.Add_Tick({
        $maintenanceTimer.Stop()
        if (-not $maintenance.Active) { return }
        try {
            $cycle = Invoke-MaintainNormalizedWindows -TrackedTargets $maintenance.TrackedTargets -TargetWidth $maintenance.TargetWidth -TargetHeight $maintenance.TargetHeight
            $maintenance.CorrectionCount += [int]$cycle.corrections
            & $render ([ordered]@{
                status = 'maintaining_compact_size'
                correctionCount = $maintenance.CorrectionCount
                targetFrame = [ordered]@{ width = $maintenance.TargetWidth; height = $maintenance.TargetHeight }
                foregroundPreserved = $cycle.foregroundPreserved
                results = $cycle.results
            })
        } catch {
            $maintenanceTimer.Stop()
            $maintenance.Active = $false
            $statusBox.Text = "Compact-size maintenance stopped: $($_.Exception.Message)"
        } finally {
            if ($maintenance.Active) { $maintenanceTimer.Start() }
        }
    })
    $refresh = {
        try { & $render (Get-NormalizerInspection) } catch { $statusBox.Text = $_.Exception.Message }
    }
    $refreshButton.Add_Click($refresh)
    $applyButton.Add_Click({
        try {
            $maintenanceTimer.Stop()
            $maintenance.Active = $false
            $requested = if ($gptCheck.Checked -and $claudeCheck.Checked) { 'both' }
                elseif ($gptCheck.Checked) { 'gptdesktop' }
                elseif ($claudeCheck.Checked) { 'claudedesktop' }
                else { throw 'Select at least one target.' }
            $targets = @(Resolve-NormalizerTargets -RequestedTarget $requested)
            $result = Invoke-NormalizeWindows -Targets $targets -TargetWidth ([int]$widthInput.Value) -TargetHeight ([int]$heightInput.Value) -UseCompactOverride $compactCheck.Checked
            if ($compactCheck.Checked) {
                $maintenance.TrackedTargets = $targets
                $maintenance.TargetWidth = [int]$widthInput.Value
                $maintenance.TargetHeight = [int]$heightInput.Value
                $maintenance.CorrectionCount = 0
                $maintenance.Active = $true
                $result['maintenance'] = [ordered]@{
                    status = 'active_while_widget_open'
                    intervalMilliseconds = $maintenanceTimer.Interval
                }
                $maintenanceTimer.Start()
            }
            & $render $result
        } catch { $statusBox.Text = $_.Exception.Message }
    })
    $restoreButton.Add_Click({
        try {
            $maintenanceTimer.Stop()
            $maintenance.Active = $false
            & $render (Restore-NormalizerWindows)
        } catch { $statusBox.Text = $_.Exception.Message }
    })
    $compactCheck.Add_CheckedChanged({
        if (-not $compactCheck.Checked) {
            $maintenanceTimer.Stop()
            $maintenance.Active = $false
        }
    })
    $closeButton.Add_Click({ $form.Close() })
    $form.Add_FormClosed({
        $maintenanceTimer.Stop()
        $maintenanceTimer.Dispose()
    })

    $form.Controls.AddRange(@(
        $widthLabel, $widthInput, $heightLabel, $heightInput,
        $gptCheck, $claudeCheck, $compactCheck, $statusBox,
        $refreshButton, $applyButton, $restoreButton, $closeButton
    ))
    $form.Add_Shown($refresh)
    [void]$form.ShowDialog()
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'Inspect' { Get-NormalizerInspection | ConvertTo-Json -Depth 8 }
        'Apply' {
            $targets = @(Resolve-NormalizerTargets -RequestedTarget $Target)
            Invoke-NormalizeWindows -Targets $targets -TargetWidth $Width -TargetHeight $Height -UseCompactOverride $CompactOverride.IsPresent | ConvertTo-Json -Depth 8
        }
        'Restore' { Restore-NormalizerWindows | ConvertTo-Json -Depth 8 }
        'Widget' { Show-NormalizerWidget }
    }
}
