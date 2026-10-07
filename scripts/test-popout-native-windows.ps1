$ErrorActionPreference='Stop'
# Exercise production native code against disposable fixture windows only.
# No ChatGPT window, credential, keyboard injection or production worker is used.
Add-Type -AssemblyName System.Windows.Forms
$watcher=Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($watcher,[ref]$tokens,[ref]$errors)
foreach($name in @('Initialize-PopoutWorkspaceLifecycle','Initialize-PopupPinHotkey')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 $code=[regex]::Match($fn.Extent.Text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
 Add-Type -TypeDefinition $code
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeFixture {
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr Style(IntPtr h,int i);
}
'@
$type=[CogentSpec.PopoutWorkspaceLifecycle]
$flags=[Reflection.BindingFlags]'NonPublic,Static'
function Field($name,$value){$type.GetField($name,$flags).SetValue($null,$value)}
function Pump {for($i=0;$i -lt 15;$i++){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 10}}
function Check($condition,$label){if(-not $condition){throw $label};$script:checks.Add($label)}
function Pinned($handle){return (([NativeFixture]::Style($handle,-20).ToInt64() -band 8) -ne 0)}
$checks=[Collections.Generic.List[string]]::new()
$prior=[NativeFixture]::GetForegroundWindow()
$work=[Windows.Forms.Form]::new();$work.Text='CogentSpec native acceptance fixture';$work.Width=320;$work.Height=100;$work.ShowInTaskbar=$false
$popup=$null
try {
 $work.Show();$work.Activate();Pump
 Check ([NativeFixture]::GetForegroundWindow() -eq $work.Handle) 'fixture work window obtained foreground'
 foreach($pinned in @($false,$true)){
  $popup=[Windows.Forms.Form]::new();$popup.Text='Disposable Popout fixture';$popup.Width=260;$popup.Height=100;$popup.ShowInTaskbar=$false;$popup.TopMost=$pinned;$popup.Show();Pump
  $handle=$popup.Handle
  [CogentSpec.PopoutWorkspaceLifecycle]::Observe($handle.ToInt64(),$PID,('a'*64))
  Field 'owner' 'fixture-owner';Field 'browser' $work.Handle;Field 'browserPid' ([uint32]$PID)
  Field 'browserStarted' ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
  $work.Activate();Pump
  [CogentSpec.PopoutWorkspaceLifecycle]::Receive('fixture-owner',('a'*64),1,'active',0)
  [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup($handle.ToInt64(),$PID)
  $allow=[CogentSpec.ChatGptPopupPinHotkey].GetMethod('WorkspacePinAllowed',$flags).Invoke($null,@($handle.ToInt64()))
  Check $allow "workspace hotkey target accepted (pinned=$pinned)"
  $toggle=[CogentSpec.ChatGptPopupPinHotkey].GetMethod('ToggleTopmost',$flags)
  $toggle.Invoke($null,@($handle,$work.Handle));Pump
  Check ((Pinned $handle) -eq (-not $pinned)) "first native pin toggle changes state (pinned=$pinned)"
  $toggle.Invoke($null,@($handle,$work.Handle));Pump
  Check ((Pinned $handle) -eq $pinned) "second native pin toggle restores state (pinned=$pinned)"
  [CogentSpec.PopoutWorkspaceLifecycle]::Receive('fixture-owner',('a'*64),2,'hidden',0)
  [CogentSpec.PopoutWorkspaceLifecycle]::Tick('');Pump;[CogentSpec.PopoutWorkspaceLifecycle]::Tick('')
  Check (-not [NativeFixture]::IsWindowVisible($handle)) "native hide works (pinned=$pinned)"
  Check ([NativeFixture]::IsWindow($handle)) "hide retains original handle (pinned=$pinned)"
  Check ((Pinned $handle) -eq $pinned) "hide preserves pin state (pinned=$pinned)"
  $work.Activate();Pump
  [CogentSpec.PopoutWorkspaceLifecycle]::Receive('fixture-owner',('a'*64),3,'active',0)
  [CogentSpec.PopoutWorkspaceLifecycle]::Tick('');Pump;[CogentSpec.PopoutWorkspaceLifecycle]::Tick('')
  Check ([NativeFixture]::IsWindowVisible($handle)) "native restore works (pinned=$pinned)"
  Check ((Pinned $handle) -eq $pinned) "restore preserves pin state (pinned=$pinned)"
  [CogentSpec.PopoutWorkspaceLifecycle]::Receive('fixture-owner',('a'*64),4,'close',0)
  [CogentSpec.PopoutWorkspaceLifecycle]::Tick('');Pump;[CogentSpec.PopoutWorkspaceLifecycle]::Tick('')
  Check (-not [NativeFixture]::IsWindow($handle)) "explicit native close destroys fixture (pinned=$pinned)"
  Check ([CogentSpec.PopoutWorkspaceLifecycle]::LastAction -eq 'close_confirmed') "destruction is acknowledged (pinned=$pinned)"
  $popup.Dispose();$popup=$null
 }
 @{status='passed';nativeAssertions=$checks.Count;checks=$checks;chatGptWindowsTouched=$false}|ConvertTo-Json -Depth 3
}finally{
 if($popup){$popup.Dispose()};$work.Dispose()
 if([NativeFixture]::IsWindow($prior)){[void][NativeFixture]::SetForegroundWindow($prior)}
}
