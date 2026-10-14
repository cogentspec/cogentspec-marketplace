# Exercise the real restore function with fake native APIs. No Windows are touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type @'
using System;
using System.Collections.Generic;
public static class NormalizerRestoreFixtureNative {
  public static List<int> ShowCommands = new List<int>();
  public static int PositionCalls = 0;
  public static IntPtr GetForegroundWindow() { return new IntPtr(999); }
  public static bool ShowWindowAsync(IntPtr window, int command) { ShowCommands.Add(command); return true; }
  public static bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags) { PositionCalls++; return true; }
}
'@
$helper = Join-Path $PSScriptRoot 'popout-window-normalizer.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Normalizer parse error.' }
$restore = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restore-NormalizerWindows'
}, $true)
Invoke-Expression ($restore.Extent.Text.Replace('[CogentSpec.PopoutWindowNormalizerNative]', '[NormalizerRestoreFixtureNative]'))
$script:targetAvailable = $true
$script:currentShowCommand = 1
function Get-NormalizerWindows {
  if ($script:targetAvailable) { [pscustomobject]@{ name='gptdesktop'; window=[IntPtr]1; processId=123; processPath='fixture.exe' } }
}
function Get-WindowPlacementState { param($Window) [pscustomobject]@{ ShowCommand=$script:currentShowCommand } }
function Get-WindowGeometry { param($Window) [pscustomobject]@{ frame=[pscustomobject]@{ x=10; y=20; width=900; height=600 } } }
function Convert-RectToObject { param($Rect) $Rect }
function Start-Sleep { param($Milliseconds) }
$script:SetWindowFlags = [uint32](0x0004 -bor 0x0010 -bor 0x0200)
$taskFixture = Join-Path ([IO.Path]::GetTempPath()) ('normalizer-restore-fixture-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($taskFixture)
$script:StatePath = Join-Path $taskFixture 'state.json'
try {
  foreach ($savedShowCommand in @(1, 3)) {
    $script:currentShowCommand = $savedShowCommand
    @{ protocol='cogentspec-desktop-normalizer-state-v1'; windows=@(@{
      name='gptdesktop'; hwnd=1; processId=123; processPath='fixture.exe'; showCommand=$savedShowCommand
      outer=@{x=10;y=20;width=900;height=600}
    }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StatePath
    $result = Restore-NormalizerWindows
    if (-not $result.foregroundPreserved) { throw 'Fixture foreground changed.' }
    if ($savedShowCommand -eq 1 -and ($result.status -ne 'restore_complete' -or $result.results[0].status -ne 'restored')) { throw 'Normal restore regressed.' }
    if ($savedShowCommand -eq 3 -and ($result.status -ne 'restore_partial' -or $result.results[0].status -ne 'geometry_restored_maximize_deferred')) { throw 'Maximized restore falsely reported completion.' }
  }
  $script:targetAvailable = $false
  $missing = Restore-NormalizerWindows
  if ($missing.status -ne 'restore_partial' -or $missing.results[0].status -ne 'original_window_no_longer_available') { throw 'Missing window restore falsely succeeded.' }
  if ([NormalizerRestoreFixtureNative]::PositionCalls -ne 2) { throw 'Restore changed an unexpected target.' }
  if (@([NormalizerRestoreFixtureNative]::ShowCommands | Where-Object { $_ -ne 4 }).Count) { throw 'Restore attempted an activating or hiding show command.' }
  'PASS: normal restore, honest deferred maximization, missing-target recovery, and no activating/hiding native calls.'
} finally {
  $taskResolved = [IO.Path]::GetFullPath($taskFixture)
  if (-not $taskResolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $taskResolved) -notlike 'normalizer-restore-fixture-*') { throw 'Unsafe fixture cleanup path.' }
  Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
