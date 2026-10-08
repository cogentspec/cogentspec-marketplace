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
 SetProp='if(NativeFixture.RejectProperty)return false;NativeFixture.Properties[h.ToInt64()]=value;return true;'
 GetProp='IntPtr v;return NativeFixture.Properties.TryGetValue(h.ToInt64(),out v)?v:IntPtr.Zero;'
 RemoveProp='IntPtr v;NativeFixture.Properties.TryGetValue(h.ToInt64(),out v);NativeFixture.Properties.Remove(h.ToInt64());return v;'
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
  public static bool RejectProperty,Pinned,RejectPin;public static int PinCalls;
  public static System.Collections.Generic.Dictionary<long,IntPtr> Properties=new System.Collections.Generic.Dictionary<long,IntPtr>();
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
# Captured partial failure: native window verified, composer insertion failed.
# Window control handoff is independently eligible, no input success required.
$native::Foreground=10
Check ($type::BeginHandoff($owner)) 'Partial-failure handoff denied'
$type::Observe(22,22,'partial');$native::Foreground=22;$native::Visible=$true
Check ($type::ContinueHandoff(22)) 'Verified partial target lost'
Check ($type::EndHandoff($true)) 'Composer failure must not discard window handoff'
$type::Receive($owner,'partial',1,'blurred',0)
Check ($type::BoundOwner -eq $owner) 'Partial window did not bind'
$native::Foreground=30;$type::Receive($owner,'partial',2,'hidden',0);$type::Tick('')
Check (-not $native::Visible) 'Partial-failure window remained visible after departure'
$type::Receive($owner,'partial',3,'close',0);$type::Tick('')
Check ($native::Closes -eq 2) 'Partial-failure window could not close'
$native::Foreground=10;Check ($type::BeginHandoff($owner)) 'Replacement test handoff denied'
$native::Foreground=22;Check ($type::ContinueHandoff(22)) 'Replacement test target denied'
$type::Observe(23,23,'replacement');$native::Foreground=23
Check (-not $type::EndHandoff($true)) 'Replaced native target inherited partial handoff'

# Actual updater + native controller: new composer loses UIA identity, not its
# native lifetime. Run each pin starting state through hide/return and failure.
$hookFn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-PopupPinHotkey'},$true)
$hookCode=[regex]::Match($hookFn.Extent.Text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value.Replace('namespace CogentSpec {','namespace CogentSpecHandoffFixture {').Replace('CogentSpec.','CogentSpecHandoffFixture.')
$hookBodies=@{
 SetWindowsHookEx='throw new InvalidOperationException("No live hooks in fixture");'
 UnhookWindowsHookEx='return true;'
 CallNextHookEx='return IntPtr.Zero;'
 GetAsyncKeyState='return virtualKey==0x11||virtualKey==0x10?unchecked((short)0x8000):(short)0;'
 GetForegroundWindow='return new IntPtr(NativeFixture.Foreground);'
 IsWindow='return window!=IntPtr.Zero;'
 IsWindowVisible='return NativeFixture.Visible;'
 GetWindowThreadProcessId='processId=(uint)window.ToInt64();return processId;'
 GetWindowLongPtr='return new IntPtr(NativeFixture.Pinned?8:0);'
 SetWindowPos='NativeFixture.PinCalls++;if(NativeFixture.RejectPin)return false;NativeFixture.Pinned=insertAfter.ToInt64()==-1;return true;'
 GetMessage='message=new Message();return 0;'
 TranslateMessage='return true;'
 DispatchMessage='return IntPtr.Zero;'
 PostThreadMessage='return true;'
 GetModuleHandle='return IntPtr.Zero;'
 GetCurrentThreadId='return 1;'
}
$hookCode=[regex]::Replace($hookCode,'\[DllImport\([^\n]+?\)\]\s+private static extern ([^;]+);',{
 param($m)
 $signature=$m.Groups[1].Value;$name=[regex]::Match($signature,'(\w+)\(').Groups[1].Value
 if(!$hookBodies.ContainsKey($name)){throw "Unmocked hook call $name"}
 'private static '+$signature+' {'+$hookBodies[$name]+'}'
})
if($hookCode -match 'DllImport|extern '){throw 'Native hook call escaped fixture'}
# Compile together so the hook can reference the native fixture without an on-disk assembly.
$hookCode=$hookCode.Replace('CogentSpecHandoffFixture','CogentSpecPinFixture').Replace('Marshal.GetLastWin32Error()','5')
$combined=$code.Replace('CogentSpecHandoffFixture','CogentSpecPinFixture')+"`n"+$hookCode
$usings=([regex]::Matches($combined,'(?m)^using [^;]+;')|ForEach-Object {$_.Value}|Select-Object -Unique)-join "`n"
Add-Type -TypeDefinition ($usings+"`n"+[regex]::Replace($combined,'(?m)^using [^;]+;',''))
$type=[CogentSpecPinFixture.PopoutWorkspaceLifecycle];$native=[CogentSpecPinFixture.NativeFixture]
$hook=[CogentSpecPinFixture.ChatGptPopupPinHotkey]
$hookCallback=$hook.GetMethod('HookCallback',[Reflection.BindingFlags]'NonPublic,Static')
$hookTarget=$hook.GetField('verifiedPopupWindow',[Reflection.BindingFlags]'NonPublic,Static')
function Press-PinFixture {
 $data=[Runtime.InteropServices.Marshal]::AllocHGlobal(32)
 try {
  for($i=0;$i -lt 32;$i+=4){[Runtime.InteropServices.Marshal]::WriteInt32($data,$i,0)}
  [Runtime.InteropServices.Marshal]::WriteInt32($data,0,0x59)
  $null=$hookCallback.Invoke($null,@(0,[IntPtr]0x100,$data))
  $null=$hookCallback.Invoke($null,@(0,[IntPtr]0x100,$data)) # autorepeat must not toggle twice
  $null=$hookCallback.Invoke($null,@(0,[IntPtr]0x101,$data))
 } finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($data)}
}
Press-PinFixture
Check ($hook::Attempts().Length -eq 0) 'Diagnostics recorded before opt-in'
$hook::ConfigureCapture($owner)
Press-PinFixture
$blankAttempt=$hook::Attempts()[-1]
Check ($blankAttempt.status -eq 'no_verified_target' -and !$blankAttempt.nativeCalled -and $native::PinCalls -eq 0) 'Fresh unverified blank attempt was not diagnosed without input'
$hook::ConfigureCapture($other)
Check ($hook::Attempts().Length -eq 0) 'Previous capture leaked into new session'
foreach($name in @('Restore-PopoutWindowControlTarget','Update-PopupPinHotkeyTarget')) {
 $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression ($definition.Extent.Text.Replace('CogentSpec.','CogentSpecPinFixture.'))
}
$script:TestToken='';$script:PinHotkeyReady=$true;$script:RequestTimingSink=$null
$script:CurrentPopupWindowHandle=0;$script:LifecyclePopupHandle=0;$script:LifecyclePopupProcessId=0;$script:LifecycleWindowKey=''
$script:popupHelper=Join-Path $PSScriptRoot 'fixtures/popout-inspection-child.ps1';$script:throwInspection=$false
foreach($pinned in @($false,$true)) {
 $h=if($pinned){25}else{24};$native::Foreground=10;$native::Visible=$true;$native::Pinned=$pinned
 $script:inspectionFixture=@{status='ready';publisherVerified=$true;popupVerified=$true;popupWindowHandle=$h;popupProcessId=$h;popupVisible=$true;conversationState='identified';currentConversationKey=('a'*64);chatFingerprint=('b'*64)}
 Update-PopupPinHotkeyTarget
 Check ($script:CurrentPopupWindowHandle -eq $h -and $hookTarget.GetValue($null) -eq $h) 'Real child-script inspection failed to register the parent watcher pin target'
 $key=$script:LifecycleWindowKey;$worker=$script:LifecycleWorkerId
 $native::Foreground=$h
 $pinCallsBefore=$native::PinCalls
 Press-PinFixture
 Check ($native::PinCalls -eq $pinCallsBefore+1 -and $native::Pinned -ne $pinned) 'Foreground Popout could not pin before first workspace handshake'
 Press-PinFixture
 Check ($native::Pinned -eq $pinned) 'Foreground Popout could not unpin before first workspace handshake'
 $native::Foreground=10
 $type::Receive($owner,$key,1,'active',0)
 Check ($type::AllowsWorkspacePin($h)) 'Initial workspace pin denied'
 $script:inspectionFixture.popupVerified=$false
 Update-PopupPinHotkeyTarget
 Check ($script:CurrentPopupWindowHandle -eq $h -and $hookTarget.GetValue($null) -eq $h) 'New composer cleared shortcut target'
 Check (!$script:CurrentConversationKey -and !$script:ActiveChatFingerprint -and $script:CurrentConversationState -eq 'unknown') 'New composer inherited green connection'
 Check ($type::AllowsWorkspacePin($h)) 'New composer revoked workspace pin permission'
 Check ($type::MatchesWindow($h)) 'New composer revoked composer-focused shortcut identity'
 $readsBefore=$native::PinCalls
 Check ($hook::ReadPinState($h) -eq [int]$pinned) 'Pin telemetry disagrees with actual native state'
 Check ($native::PinCalls -eq $readsBefore) 'Pin telemetry mutated the native window'
 $calls=$native::PinCalls;Press-PinFixture
 Check ($native::Pinned -ne $pinned -and $native::PinCalls -eq $calls+1) 'Workspace shortcut did not toggle exactly once'
 Check ($hook::ReadPinState($h) -eq [int](!$pinned)) 'Pin telemetry did not observe shortcut toggle'
 $attempt=$hook::Attempts()[-1]
 Check ($attempt.nativeCalled -and $attempt.applied -and $attempt.beforePinned -eq $pinned -and $attempt.afterPinned -ne $pinned -and $attempt.foregroundHandle -eq 10) 'Native pin attempt evidence incorrect'
 Press-PinFixture
 Check ($native::Pinned -eq $pinned -and $native::PinCalls -eq $calls+2) 'Workspace shortcut could not toggle back'
 $native::Foreground=$h;Press-PinFixture;Press-PinFixture
 Check ($native::Pinned -eq $pinned -and $native::PinCalls -eq $calls+4) 'Composer-focused shortcut failed'
 $native::Foreground=10
 $type::Receive($owner,$key,2,'hidden',0);$type::Tick('');$type::Tick('')
 Check (!$native::Visible) 'New composer failed to hide'
 $calls=$native::PinCalls;Press-PinFixture
 Check ($native::PinCalls -eq $calls -and $native::Pinned -eq $pinned) 'Hidden shortcut changed pin state'
 Update-PopupPinHotkeyTarget
 Check ($script:LifecycleWindowKey -eq $key -and $script:LifecycleWorkerId -eq $worker) 'Hidden composer changed stream identity'
 $native::Foreground=10;$type::Receive($owner,$key,3,'active',0);$type::Tick('');$type::Tick('')
 Check ($native::Visible) 'New composer did not return with workspace'
 Check ($native::Pinned -eq $pinned) 'Hide/restore changed pin preference'
 $script:throwInspection=$true;Update-PopupPinHotkeyTarget;$script:throwInspection=$false
 Check ($script:CurrentPopupWindowHandle -eq $h -and $type::AllowsWorkspacePin($h)) 'Inspection exception discarded live controls'
 $native::Foreground=30
 Check (!$type::AllowsWorkspacePin($h)) 'Unrelated application gained pin authority'
 Press-PinFixture;Check ($native::PinCalls -eq $calls) 'Unrelated foreground toggled pin'
 $native::Properties.Remove($h)|Out-Null # destruction and immediate same-HWND/PID reuse
 Check (!$type::MatchesWindow($h)) 'Reused handle inherited shortcut authority'
 Check ($hook::ReadPinState($h) -eq -1) 'Pin telemetry accepted a recycled handle'
 $native::Foreground=$h;Press-PinFixture
 Check ($native::PinCalls -eq $calls) 'Recycled foreground HWND inherited shortcut authority'
 $shows=$native::Shows;$native::Visible=$false;$native::Foreground=10
 $type::Receive($owner,$key,4,'active',0);$type::Tick('');Update-PopupPinHotkeyTarget
 Check ($native::Shows -eq $shows -and $script:CurrentPopupWindowHandle -eq 0 -and $hookTarget.GetValue($null) -eq 0) 'Destroyed/reused window was restored or pinned'
 $script:inspectionFixture.popupVerified=$true;Update-PopupPinHotkeyTarget
 Check ($script:LifecycleWindowKey -ne $key -and $script:LifecycleWorkerId -ne $worker -and $type::BoundOwner -eq '') 'Freshly verified replacement inherited old ownership'
}
$native::Visible=$true;$native::Foreground=$h;$native::RejectPin=$true
Press-PinFixture
$failed=$hook::Attempts()[-1]
Check ($failed.nativeCalled -and !$failed.applied -and $failed.win32Error -eq 5 -and $failed.status -eq 'pin_failed') 'Failed native call lost Windows error'
$native::RejectPin=$false
for($i=0;$i -lt 70;$i++){Press-PinFixture}
Check ($hook::Attempts().Length -eq 64 -and $hook::Attempts()[0].sequence -gt 1) 'Trace bound or sequence gap lost'
$hook.GetField('captureUntil',[Reflection.BindingFlags]'NonPublic,Static').SetValue($null,[DateTime]::UtcNow.AddSeconds(-1))
Press-PinFixture;Check ($hook::Attempts().Length -eq 0 -and $hook::CaptureSession -eq '') 'Expired capture still exposed evidence'
$hook::ConfigureCapture('');Press-PinFixture
Check ($hook::Attempts().Length -eq 0) 'Stopped capture still records'
$native::RejectProperty=$true
Check (!$type::Observe(26,26,'denied')) 'Failed lifetime registration accepted'
$native::RejectProperty=$false
$type::Stop()
Check (!$type::MatchesWindow($script:LifecyclePopupHandle)) 'Stopped worker retained native lifetime property'
Write-Output 'PASS: actual updater and controller, new-composer target loss, inspection exception, hide/restore, red connection, foreign foreground and same-HWND/PID reuse rejection.'
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
