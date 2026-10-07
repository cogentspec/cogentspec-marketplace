$ErrorActionPreference = 'Stop'
# Execute the production retained-window branch with an in-memory native sink.
# No real window inspection, input injection, credentials or Desktop UI access.
$path = Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\open-chatgpt-popup.ps1'
$source = Get-Content -LiteralPath $path -Raw
$native = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $native) { throw 'Production native code not found' }
# Compile the full production native helper without invoking any native method.
Add-Type -TypeDefinition ($native.Replace('ChatGptPopupNative', 'ChatGptPopupCompileOnly'))
$start = $source.IndexOf('if ($popupWindow -ne [IntPtr]::Zero) {', $source.IndexOf('$existingPopupDismissed = $false'))
$end = $source.IndexOf('if ($UseRetainedChat -and -not $activatedExisting -and -not $OpenWithShortcut)', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Production retained-window branch not found' }
$block = [scriptblock]::Create($source.Substring($start, $end-$start))
Add-Type -TypeDefinition @'
using System;
namespace CogentSpec {
 public static class ChatGptPopupNative {
  public static bool Visible, Pinned, RestoreWorks=true;
  public static int Shows, Pins, Activations;
  public static bool IsVisible(IntPtr h) { return Visible; }
  public static bool IsTopmost(IntPtr h) { return Pinned; }
  public static bool ShowWindowAsync(IntPtr h, int c) { Shows++; if(RestoreWorks) Visible=true; return RestoreWorks; }
  public static bool SetPopupTopmost(IntPtr h,bool value) { Pins++;Pinned=value;return true; }
  public static bool SendControlShiftSpace() { throw new Exception("Known window must never receive a toggle shortcut"); }
 }
}
'@
function Invoke-PopupActivation { param([IntPtr]$PopupWindow) [CogentSpec.ChatGptPopupNative]::Activations++; return $true }
function Write-Failure { param($Status,$Reason,[switch]$Opened) $script:failure=$Status }
function Check($condition,$label) { if(-not $condition) { throw $label } }
foreach ($scenario in @('hidden','visible-unpinned','visible-pinned','restore-failure')) {
 [CogentSpec.ChatGptPopupNative]::Visible=$scenario.StartsWith('visible')
 [CogentSpec.ChatGptPopupNative]::Pinned=$scenario -eq 'visible-pinned'
 [CogentSpec.ChatGptPopupNative]::RestoreWorks=$scenario -ne 'restore-failure'
 [CogentSpec.ChatGptPopupNative]::Shows=0
 [CogentSpec.ChatGptPopupNative]::Pins=0
 [CogentSpec.ChatGptPopupNative]::Activations=0
 $popupWindow=[IntPtr]1234; $UseRetainedChat=$true; $OpenWithShortcut=$true; $KeepPinned=$true
 $failure=''
 & $block
 if ($scenario -eq 'restore-failure') {
  Check ($failure -eq 'popup_restore_failed') 'Failed restore must be reported'
  Check ([CogentSpec.ChatGptPopupNative]::Pins -eq 0) 'Failed restore must not pin'
 } else {
  Check ([CogentSpec.ChatGptPopupNative]::Visible) 'Popout should be visible'
  Check ([CogentSpec.ChatGptPopupNative]::Pinned) 'Popout should be pinned'
  Check ([CogentSpec.ChatGptPopupNative]::Activations -eq 1) 'Activate exact retained window once'
  Check ([CogentSpec.ChatGptPopupNative]::Pins -eq [int]($scenario -ne 'visible-pinned')) 'Pin is set, not toggled'
 }
 Check ([CogentSpec.ChatGptPopupNative]::Shows -eq [int](-not $scenario.StartsWith('visible'))) 'Only a hidden window needs restoration'
}
Write-Output 'PASS: four production initialization branch scenarios; no real Desktop UI accessed.'
