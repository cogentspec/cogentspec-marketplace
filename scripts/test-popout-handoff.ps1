$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/watch-cogentspec-popout-bridge.ps1'
$source=Get-Content -Raw $path
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Watcher parse failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-PopoutWorkspaceLifecycle'},$true)
$code=[regex]::Match($fn.Extent.Text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
# Execute production controller logic with only native and process access replaced.
# No window, hook, keyboard or live Desktop operation is performed.
$code=$code.Replace('namespace CogentSpec {','namespace CogentSpecHandoffFixture {').Replace('Process.GetProcessById','NativeFixture.Process')
$bodies=@{
 GetForegroundWindow='return new IntPtr(NativeFixture.Foreground);'
 IsWindow='return h!=IntPtr.Zero;'
 IsWindowVisible='return NativeFixture.Visible;'
 GetWindowThreadProcessId='p=(uint)h.ToInt64();return p;'
 GetWindowText='b.Append(h.ToInt64()==10?"CogentSpec | work":"ChatGPT");return b.Length;'
 ShowWindowAsync='NativeFixture.Shows++;NativeFixture.Visible=command!=0;return true;'
 PostMessage='NativeFixture.Closes++;return true;'
}
$code=[regex]::Replace($code,'\[DllImport\([^\n]+?\)\] static extern ([^;]+);',{
 param($m)
 $signature=$m.Groups[1].Value
 $name=[regex]::Match($signature,'(\w+)\(').Groups[1].Value
 if(-not $bodies.ContainsKey($name)){throw "Unmocked native call $name"}
 'static '+$signature+' {'+$bodies[$name]+'}'
})
$code+=@'
namespace CogentSpecHandoffFixture {
 public sealed class FakeProcess:System.IDisposable {
  public string ProcessName; public System.DateTime StartTime=new System.DateTime(2026,1,1);
  public void Dispose(){}
 }
 public static class NativeFixture {
  public static long Foreground=10;public static bool Visible=false;public static int Shows,Closes;
  public static FakeProcess Process(int p){return new FakeProcess{ProcessName=p==10?"chrome":"ChatGPT"};}
 }
}
'@
if($code -match 'DllImport|extern '){throw 'Native call escaped fixture'}
Add-Type -TypeDefinition $code
$type=[CogentSpecHandoffFixture.PopoutWorkspaceLifecycle]
$native=[CogentSpecHandoffFixture.NativeFixture]
$owner='aaaaaaaa-1111-1111-1111-111111111111';$other='bbbbbbbb-1111-1111-1111-111111111111'
function Check($value,$message){if(-not $value){throw $message}}
Check ($type::BeginHandoff($owner)) 'Foreground originating browser must start handoff'
$type::Observe(20,20,'key')
$native::Foreground=20;$native::Visible=$true
Check ($type::ContinueHandoff(20)) 'Popout focus must not interrupt handoff'
$type::EndHandoff($true)
$type::Receive($other,'key',1,'blurred',0)
Check ($type::BoundOwner -eq '') 'Wrong owner adopted focus grant'
$type::Receive($owner,'key',1,'blurred',0)
Check ($type::BoundOwner -eq $owner) 'Exact owner could not complete while Popout focused'
$type::Tick('')
Check ($native::Shows -eq 0) 'Completion caused competing visibility operation'

$native::Foreground=10
$type::Receive($owner,'key',2,'hidden',0);$type::Tick('')
Check (-not $native::Visible) 'Hide failed before retained-window startup'
$type::Receive($owner,'key',3,'active',0)
Check ($type::BeginHandoff($owner)) 'Retained startup denied'
$shows=$native::Shows;$type::Tick('')
Check ($native::Shows -eq $shows) 'Lifecycle restore competed with opener'
$native::Visible=$true;$native::Foreground=20
$type::Receive($owner,'key',4,'blurred',0)
Check ($type::ContinueHandoff(20)) 'Typing focus cancelled startup'
$type::Receive($owner,'key',5,'hidden',0);$type::Tick('')
Check (-not $type::ContinueHandoff(20)) 'Hidden work tab did not interrupt input'
Check (-not $native::Visible) 'Startup lock blocked hide'
$type::Receive($owner,'key',6,'close',0);$type::Tick('')
Check ($native::Closes -eq 1) 'Startup lock blocked explicit close'
$type::EndHandoff($false)

# New target: failed handoff and other-application focus grant no ownership.
$native::Foreground=10;Check ($type::BeginHandoff($owner)) 'New handoff denied'
$type::Observe(21,21,'next');$native::Foreground=30
Check (-not $type::ContinueHandoff(21)) 'Taskbar departure did not cancel startup'
$type::EndHandoff($false);$native::Foreground=21
$type::Receive($owner,'next',1,'blurred',0)
Check ($type::BoundOwner -eq '') 'Failed handoff granted ownership'
$native::Foreground=30
Check (-not $type::BeginHandoff($owner)) 'Unrelated application authorized startup'
Write-Output 'PASS: production native controller handoff, retained restore exclusion, exact owner, focus, hide, close and taskbar cancellation; all native calls mocked.'

# Execute the real final helper branch for fresh/retained and pin permutations.
$helperPath=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/open-chatgpt-popup.ps1'
$helper=Get-Content -Raw $helperPath
$ast=[Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper parse failed'}
$measure=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Measure-PopupStage'},$true)
Invoke-Expression $measure.Extent.Text
$start=$helper.IndexOf('$temporaryTopmostRestored = Restore-ChatGptPopupTopmost')
$end=$helper.IndexOf('Write-CompactJson ([ordered]@{',$start)
if($start -lt 0 -or $end -lt $start){throw 'Final readiness branch missing'}
$branch=[scriptblock]::Create($helper.Substring($start,$end-$start))
Add-Type -TypeDefinition @'
namespace CogentSpec {public static class ChatGptPopupNative {
 public static bool Pinned; public static bool IsTopmost(System.IntPtr h){return Pinned;}
}}
'@
$trace=[Collections.Generic.List[string]]::new()
function Restore-ChatGptPopupTopmost {param($PopupWindow,$Required)
 $trace.Add('pin');if($Required){[CogentSpec.ChatGptPopupNative]::Pinned=$false};return $true
}
function Focus-ChatGptComposer {param($PopupWindow)
 $trace.Add('focus');return @{focused=$focusWorks;draftPreserved=$true;status=$(if($focusWorks){'focused'}else{'focus_failed'})}
}
function Test-PopupInteractionReady {param($PopupWindow)
 $trace.Add('verify');return @{focused=$ready;foreground=$ready;visible=$true;pinned=[CogentSpec.ChatGptPopupNative]::Pinned;status=$(if($ready){'ready'}else{'interaction_not_ready'})}
}
function Write-Failure {param($Status,$Reason,$Opened,$PopupDetected,$PopupVerification) $script:failure=$Status}
$TimingSink=$null;$ContinueHandoff=$null;$popupWindow=[IntPtr]20;$temporaryTopmostWindow=$popupWindow;$popupVerification='verified'
foreach($retained in @($false,$true)){foreach($pinned in @($false,$true)){
 $activatedExisting=$retained;$KeepPinned=$pinned;$temporaryTopmost=-not $pinned
 [CogentSpec.ChatGptPopupNative]::Pinned=$true;$focusWorks=$true;$ready=$true;$script:failure='';$trace.Clear()
 . $branch
 Check ($failure -eq '') 'Successful final handoff failed'
 Check (($trace -join ',') -eq 'pin,focus,verify') 'Focus was not verified after final pin changes'
 Check ([CogentSpec.ChatGptPopupNative]::Pinned -eq $pinned) 'Final check changed requested pin state'
}}
foreach($failedPhase in @('focus','verify')) {
 $focusWorks=$failedPhase -ne 'focus';$ready=$false;$trace.Clear();$script:failure=''
 . $branch
 Check ($failure -in @('popup_final_focus_failed','popup_interaction_not_ready')) 'Failed readiness reported success'
 Check (($trace | Where-Object {$_ -eq 'focus'}).Count -eq 1) 'Failure retried focus'
}
Check (-not $helper.Contains('$topmostCycleReset = $true')) 'Unpin/refocus/repin cycle remains'
Write-Output 'PASS: actual final helper branch; fresh/retained, pinned/unpinned, failed focus and failed final snapshot; no native calls.'
