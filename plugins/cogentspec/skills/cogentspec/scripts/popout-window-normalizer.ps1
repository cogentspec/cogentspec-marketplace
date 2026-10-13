[CmdletBinding()]
param(
    [ValidateSet('Widget', 'Inspect', 'Apply', 'Restore')]
    [string]$Mode = 'Widget',

    [ValidateRange(320, 3840)]
    [int]$Width = 900,

    [ValidateRange(240, 2160)]
    [int]$Height = 600,

    [ValidateSet('gptpop', 'claudepop', 'both')]
    [string]$Target = 'both',

    [switch]$AllowClaudeCandidate
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

$script:StatePath = Join-Path $env:LOCALAPPDATA 'CogentSpec\popout-window-normalizer-state.json'
$script:SetWindowFlags = [uint32](0x0004 -bor 0x0010 -bor 0x0200) # SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER
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

function Test-GptPopComposer {
    param([IntPtr]$Window)
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        $root = [Windows.Automation.AutomationElement]::FromHandle($Window)
        if (-not $root) { return $false }
        $composerNames = @(
            'Work with ChatGPT',
            'Ask ChatGPT anything locally',
            'Ask ChatGPT anything',
            'Do anything',
            'Work with Codex'
        )
        $count = 0
        foreach ($name in $composerNames) {
            $condition = [Windows.Automation.AndCondition]::new(
                [Windows.Automation.PropertyCondition]::new(
                    [Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::Edit
                ),
                [Windows.Automation.PropertyCondition]::new(
                    [Windows.Automation.AutomationElement]::NameProperty,
                    $name
                )
            )
            $count += $root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition).Count
        }
        return $count -eq 1
    } catch {
        return $false
    }
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
        if ($placement.ShowCommand -ne 1) { continue }
        $geometry = Get-WindowGeometry -Window $window
        $isGptPop = $processEntry.process.ProcessName -eq 'ChatGPT' -and
            $title -eq 'ChatGPT' -and
            $mainChatGptHandles -notcontains $window.ToInt64() -and
            (Test-GptPopComposer -Window $window)
        $isClaudeCandidate = $processEntry.process.ProcessName -eq 'claude' -and $title -eq 'Claude'
        if (-not $isGptPop -and -not $isClaudeCandidate) { continue }

        $rows += [pscustomobject]@{
            name = if ($isGptPop) { 'gptpop' } else { 'claudepop' }
            identity = if ($isGptPop) { 'verified_retained_popout' } else { 'single_signed_claude_window_candidate' }
            window = [IntPtr]$window
            processId = [int]$processId
            processPath = $processEntry.path
            dpi = [CogentSpec.PopoutWindowNormalizerNative]::GetDpiForWindow($window)
            geometry = $geometry
            topmost = Test-WindowTopmost -Window $window
        }
    }
    return @($rows)
}

function Resolve-NormalizerTargets {
    param(
        [ValidateSet('gptpop', 'claudepop', 'both')]
        [string]$RequestedTarget,
        [bool]$ClaudeCandidateAllowed
    )

    $rows = @(Get-NormalizerWindows)
    $targets = @()
    if ($RequestedTarget -in @('gptpop', 'both')) {
        $matches = @($rows | Where-Object { $_.name -eq 'gptpop' })
        if ($matches.Count -ne 1) { throw "Expected one verified GPT Popout, found $($matches.Count)." }
        $targets += $matches[0]
    }
    if ($RequestedTarget -in @('claudepop', 'both')) {
        if (-not $ClaudeCandidateAllowed) {
            throw 'ClaudePop is not a registered retained-Popout flow. Select the signed Claude candidate explicitly.'
        }
        $matches = @($rows | Where-Object { $_.name -eq 'claudepop' })
        if ($matches.Count -ne 1) { throw "Expected one signed visible Claude window, found $($matches.Count)." }
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
        protocol = 'cogentspec-popout-normalizer-state-v1'
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
        [int]$TargetHeight
    )

    Save-NormalizerState -Targets $Targets
    $foregroundBefore = [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
    $results = @()
    foreach ($target in $Targets) {
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
        $results += [ordered]@{
            name = $target.name
            identity = $target.identity
            requestedFrame = [ordered]@{ width = $TargetWidth; height = $TargetHeight }
            acceptedFrame = $actualFrame
            status = if ($clamped) { 'clamped_by_application' } else { 'applied' }
            topmostPreserved = $true
        }
    }
    return [ordered]@{
        status = 'normalized'
        foregroundPreserved = $foregroundBefore -eq [CogentSpec.PopoutWindowNormalizerNative]::GetForegroundWindow()
        statePath = $script:StatePath
        results = $results
    }
}

function Restore-NormalizerWindows {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { throw 'No saved Popout Normalizer state exists.' }
    $state = Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
    if ($state.protocol -ne 'cogentspec-popout-normalizer-state-v1') { throw 'The saved normalizer state is not recognized.' }
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
        Start-Sleep -Milliseconds 250
        $actual = Get-WindowGeometry -Window $target[0].window
        $results += [ordered]@{ name = $saved.name; status = 'restored'; frame = Convert-RectToObject $actual.frame }
    }
    return [ordered]@{ status = 'restore_complete'; results = $results }
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
    $form.Text = 'Popout Window Normalizer'
    $form.Width = 470
    $form.Height = 390
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
    $gptCheck.Text = 'GPTPop (verified retained Popout)'
    $gptCheck.Checked = $Target -in @('gptpop', 'both')
    $gptCheck.SetBounds(20, 60, 390, 28)

    $claudeCheck = [Windows.Forms.CheckBox]::new()
    $claudeCheck.Text = 'ClaudePop candidate (one signed visible Claude window)'
    $claudeCheck.Checked = $AllowClaudeCandidate -or $Target -eq 'claudepop'
    $claudeCheck.SetBounds(20, 90, 420, 28)

    $statusBox = [Windows.Forms.TextBox]::new()
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $statusBox.ScrollBars = 'Vertical'
    $statusBox.SetBounds(20, 130, 415, 145)

    $refreshButton = [Windows.Forms.Button]::new()
    $refreshButton.Text = 'Refresh'
    $refreshButton.SetBounds(20, 292, 90, 32)
    $applyButton = [Windows.Forms.Button]::new()
    $applyButton.Text = 'Apply'
    $applyButton.SetBounds(120, 292, 90, 32)
    $restoreButton = [Windows.Forms.Button]::new()
    $restoreButton.Text = 'Restore'
    $restoreButton.SetBounds(220, 292, 90, 32)
    $closeButton = [Windows.Forms.Button]::new()
    $closeButton.Text = 'Close'
    $closeButton.SetBounds(345, 292, 90, 32)

    $render = {
        param($Value)
        $statusBox.Text = $Value | ConvertTo-Json -Depth 8
    }
    $refresh = {
        try { & $render (Get-NormalizerInspection) } catch { $statusBox.Text = $_.Exception.Message }
    }
    $refreshButton.Add_Click($refresh)
    $applyButton.Add_Click({
        try {
            $requested = if ($gptCheck.Checked -and $claudeCheck.Checked) { 'both' }
                elseif ($gptCheck.Checked) { 'gptpop' }
                elseif ($claudeCheck.Checked) { 'claudepop' }
                else { throw 'Select at least one target.' }
            $targets = @(Resolve-NormalizerTargets -RequestedTarget $requested -ClaudeCandidateAllowed $claudeCheck.Checked)
            & $render (Invoke-NormalizeWindows -Targets $targets -TargetWidth ([int]$widthInput.Value) -TargetHeight ([int]$heightInput.Value))
        } catch { $statusBox.Text = $_.Exception.Message }
    })
    $restoreButton.Add_Click({
        try { & $render (Restore-NormalizerWindows) } catch { $statusBox.Text = $_.Exception.Message }
    })
    $closeButton.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@(
        $widthLabel, $widthInput, $heightLabel, $heightInput,
        $gptCheck, $claudeCheck, $statusBox,
        $refreshButton, $applyButton, $restoreButton, $closeButton
    ))
    $form.Add_Shown($refresh)
    [void]$form.ShowDialog()
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'Inspect' { Get-NormalizerInspection | ConvertTo-Json -Depth 8 }
        'Apply' {
            $targets = @(Resolve-NormalizerTargets -RequestedTarget $Target -ClaudeCandidateAllowed $AllowClaudeCandidate.IsPresent)
            Invoke-NormalizeWindows -Targets $targets -TargetWidth $Width -TargetHeight $Height | ConvertTo-Json -Depth 8
        }
        'Restore' { Restore-NormalizerWindows | ConvertTo-Json -Depth 8 }
        'Widget' { Show-NormalizerWidget }
    }
}
