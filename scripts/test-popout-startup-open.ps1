$ErrorActionPreference = 'Stop'
# Execute the PRODUCTION opening branch, with only the clock and OS boundary
# replaced. No Desktop process, UI Automation, window or keyboard is accessed.
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/open-chatgpt-popup.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Production helper parse failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ChatGptPopupSpecificComposer'},$true)
Invoke-Expression $fn.Extent.Text
foreach($name in @('Resolve-ChatGptPopupDiscovery','Get-ChatGptPopupStartupDecision')) {
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $fn.Extent.Text
}
foreach($case in @(
 @{rows=@();state='absent';decision='open_once'},
 @{rows=@(@{window=12;strict=$false;popupSpecific=$false;visible=$true});state='unknown';decision='stop_unverified'},
 @{rows=@(@{window=12;strict=$true;popupSpecific=$false;visible=$true});state='visible';decision='use_verified'},
 @{rows=@(@{window=12;strict=$true;popupSpecific=$false;visible=$false});state='hidden';decision='restore_verified'},
 @{rows=@(@{window=12;strict=$true;popupSpecific=$false;visible=$true},@{window=13;strict=$true;popupSpecific=$false;visible=$false});state='ambiguous';decision='stop_ambiguous'}
)) {
 $d=Resolve-ChatGptPopupDiscovery $case.rows
 if($d.state -ne $case.state -or (Get-ChatGptPopupStartupDecision $d.state $false) -ne $case.decision){throw 'Evidence classification failed'}
}
foreach($name in @('Work with ChatGPT','Ask ChatGPT anything locally','Ask ChatGPT anything','Do anything')) {
 if(!(Test-ChatGptPopupSpecificComposer $false $name)){throw "Unpinned standalone composer rejected: $name"}
 if(Test-ChatGptPopupSpecificComposer $true $name){throw "Main Desktop composer mistaken for Popout: $name"}
}
if(Test-ChatGptPopupSpecificComposer $false 'Unrelated editor'){throw 'Unknown composer accepted'}
Write-Output 'PASS: all four composer variants, with main-window and unrelated-window rejection.'
# Sanitized replay of the uploaded 2026-10-07 capture. No native UI is read.
$captured=@(
 @{window=1246424;strict=$false;popupSpecific=$false;visible=$true;isMainWindow=$true;inspectionSucceeded=$true},
 @{window=1049284;strict=$false;popupSpecific=$false;visible=$false;isMainWindow=$false;inspectionSucceeded=$true},
 @{window=132598;strict=$false;popupSpecific=$false;visible=$false;isMainWindow=$false;inspectionSucceeded=$true},
 @{window=197228;strict=$false;popupSpecific=$false;visible=$false;isMainWindow=$true;inspectionSucceeded=$true}
)
$discovery=Resolve-ChatGptPopupDiscovery $captured
if($discovery.state -ne 'hidden_shells' -or $discovery.window -ne [IntPtr]::Zero -or
 (Get-ChatGptPopupStartupDecision $discovery.state $false) -ne 'open_once' -or
 (Get-ChatGptPopupStartupDecision $discovery.state $true) -ne 'observe'){throw 'Captured hidden shells must open once without being adopted'}
foreach($bad in @(
 @{window=44;strict=$false;popupSpecific=$false;visible=$true;isMainWindow=$false;inspectionSucceeded=$true},
 @{window=44;strict=$false;popupSpecific=$false;visible=$false;isMainWindow=$false;inspectionSucceeded=$false}
)) {
 if((Resolve-ChatGptPopupDiscovery ($captured+@($bad))).state -ne 'unknown'){throw 'Visible/unreadable candidate must block a toggle'}
 if((Resolve-ChatGptPopupDiscovery @($bad,@{window=55;strict=$true;popupSpecific=$false;visible=$false})).state -ne 'unknown'){throw 'Verified hidden target must not override unresolved competing evidence'}
}
if((Resolve-ChatGptPopupDiscovery @($captured[0],$captured[3])).state -ne 'absent'){throw 'Inspected main windows must not block startup'}
Write-Output 'PASS: captured main/hidden-shell replay, visible competitor and failed-inspection fences.'
# Execute the production candidate filter against the five-window capture.
$filter=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($StartupCandidateHandle -ne 0)')},$true)
if(!$filter){throw 'Startup candidate filter missing'}
$filterBlock=[scriptblock]::Create($filter.Extent.Text)
$StartupCandidateHandle=20187320
for($scan=0;$scan -lt 35;$scan++) {
 $nativeCandidates=@([IntPtr]1246424,[IntPtr]1049284,[IntPtr]132598,[IntPtr]197228,[IntPtr]20187320)
 . $filterBlock
 if($nativeCandidates.Count -ne 1 -or $nativeCandidates[0].ToInt64() -ne 20187320){throw 'Startup scanned unrelated windows'}
}
$StartupCandidateHandle=0;$nativeCandidates=@([IntPtr]1,[IntPtr]2);. $filterBlock
if($nativeCandidates.Count -ne 2){throw 'Initial broad discovery was changed'}
Write-Output 'PASS: five-window capture replay; 35 targeted inspections instead of 175, broad discovery preserved.'
$start = $source.IndexOf('if (-not $activatedExisting) {', $source.IndexOf('$taskOwner = [ordered]'))
$end = $source.IndexOf('if (-not $activatedExisting -and $popupWindow', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Production opening branch not found' }
$block = [scriptblock]::Create($source.Substring($start,$end-$start).Replace('[DateTime]::UtcNow','[StartupFixture]::Now'))
Add-Type @'
using System;
public static class StartupFixture {
 public static DateTime Now;
 public static int Toggles;
 public static bool Visible, SendWorks;
 public static DateTime Started;
 public static double CandidateAt;
 public static double DisappearAt;
 public static double ReplaceAt, MultipleAt;
}
namespace CogentSpec {
 public static class ChatGptPopupNative {
  public static bool SendControlShiftSpace() { StartupFixture.Toggles++; return StartupFixture.SendWorks; }
  public static IntPtr[] FindPopupWindows(int[] p) {
   double elapsed=(StartupFixture.Now-StartupFixture.Started).TotalSeconds;
   if(elapsed>=StartupFixture.MultipleAt)return new[]{new IntPtr(1234),new IntPtr(4321)};
   if(elapsed>=StartupFixture.ReplaceAt)return new[]{new IntPtr(4321)};
   return elapsed >= StartupFixture.CandidateAt && elapsed < StartupFixture.DisappearAt ? new[]{new IntPtr(1234)} : new IntPtr[0];
  }
  public static bool IsVisible(IntPtr h) { return h != IntPtr.Zero && (StartupFixture.Visible || FindPopupWindows(new int[0]).Length > 0); }
 }
}
'@
function Start-Sleep { param($Milliseconds) [StartupFixture]::Now=[StartupFixture]::Now.AddMilliseconds($Milliseconds) }
function Write-Failure { param($Status,$Reason) $script:failure=$Status }
function Find-ChatGptPopupWindowMatch {
 param($ProcessIds,$MainWindowHandles,$PreferredWindowHandle,$StartupCandidateHandle)
 if($StartupCandidateHandle -ne 1234){throw 'Startup inspection not restricted to owned candidate'}
 $elapsed=([StartupFixture]::Now-$script:started).TotalMilliseconds
 if($elapsed -lt ($script:candidateAt*1000)){throw 'UIA polling before native appearance'}
 $ready=$elapsed -ge ($script:readyAt * 1000)
 [StartupFixture]::Now=[StartupFixture]::Now.AddMilliseconds($script:scanDelay)
 [StartupFixture]::Visible=$ready
 return @{window=$(if($ready){[IntPtr]1234}else{[IntPtr]::Zero});verification=$(if($ready){'dismiss_and_composer'}else{'awaiting_composer'});
  candidateDetected=($ready -or $elapsed -ge ($script:candidateAt * 1000));ambiguous=$script:ambiguous}
}
function Check($condition,$message) { if(!$condition){throw $message} }
$cases=@(
 @{name='closure-during-inspection';ready=0;candidate=0;disappear=.5;scanDelay=1000;toggles=1},
 @{name='replacement-during-inspection';ready=0;candidate=0;replace=.5;scanDelay=1000;toggles=1},
 @{name='competitor-during-inspection';ready=0;candidate=0;multiple=.5;scanDelay=1000;toggles=1},
 @{name='cold-fast';ready=.2;candidate=.1;toggles=1},
 @{name='captured-hidden-shells';ready=.2;candidate=0;toggles=1;state='hidden_shells'},
 @{name='cold-delayed-beyond-old-retry';ready=8;candidate=4;toggles=1},
 @{name='capture-da7989-late-verification';ready=20.3;candidate=.7;toggles=1},
 @{name='diagnostic-late-verification';ready=27.2;candidate=.7;toggles=1},
 @{name='visible-never-verifies';ready=99;candidate=.7;toggles=1},
 @{name='user-hides-during-verification';ready=20;candidate=.7;disappear=3;toggles=1},
 @{name='candidate-replaced-during-verification';ready=20;candidate=.7;replace=3;toggles=1},
 @{name='second-candidate-during-verification';ready=20;candidate=.7;multiple=3;toggles=1},
 @{name='accessibility-delayed';ready=5;candidate=0;toggles=0;unknown=$true},
 @{name='already-visible';ready=0;candidate=0;toggles=0;activated=$true},
 @{name='never-opens';ready=99;candidate=99;toggles=1},
 @{name='unverified-window';ready=99;candidate=0;toggles=0;unknown=$true},
 @{name='ambiguous';ready=99;candidate=0;toggles=0;ambiguous=$true},
 @{name='shortcut-rejected';ready=99;candidate=99;toggles=1;sendFailure=$true}
)
foreach($case in $cases) {
 $script:scanDelay=if($case.scanDelay){$case.scanDelay}else{0}
 $script:started=[DateTime]'2026-01-01T00:00:00Z';[StartupFixture]::Now=$started
 [StartupFixture]::Started=$started;[StartupFixture]::CandidateAt=$case.candidate
 [StartupFixture]::DisappearAt=if($case.disappear){$case.disappear}else{999}
 [StartupFixture]::ReplaceAt=if($case.replace){$case.replace}else{999}
 [StartupFixture]::MultipleAt=if($case.multiple){$case.multiple}else{999}
 $appearanceObserved=$false;$script:progressCount=0
 $StartupProgress={param($stage) Check ($stage -eq 'awaiting_verification') 'Unexpected stage';$script:progressCount++}
 [StartupFixture]::Toggles=0;[StartupFixture]::Visible=[bool]$case.activated;[StartupFixture]::SendWorks=!$case.sendFailure
 $script:readyAt=$case.ready;$script:candidateAt=$case.candidate;$script:ambiguous=[bool]$case.ambiguous;$script:failure=''
 $popupWindow=if($case.activated){[IntPtr]1234}else{[IntPtr]::Zero}
 $activatedExisting=[bool]$case.activated;$popupCandidateDetected=$case.candidate -eq 0;$popupCandidateAmbiguous=$false
 $chatGptProcessIds=@(5678);$chatGptMainWindowHandles=@(9000);$PreferredWindowHandle=0
 $shortcutSent=$false;$shortcutAttempts=0;$popupVisible=$false
 $popupMatch=@{discoveryState=$(if($case.state){$case.state}elseif($case.ambiguous){'ambiguous'}elseif($case.unknown){'unknown'}else{'absent'})}
 . $block
 Check ([StartupFixture]::Toggles -eq $case.toggles) "$($case.name): wrong number of global toggles"
 if($case.sendFailure) { Check ($failure -eq 'shortcut_failed') 'Input failure must be explicit' }
 elseif($case.unknown -or $case.ambiguous) { Check ($failure -eq 'popup_identity_unresolved' -and !$popupVisible) 'Unknown identity must fail closed without claiming open' }
 elseif($case.ready -lt 45 -and !$case.disappear -and !$case.replace -and !$case.multiple) { Check ($popupVisible -and $popupWindow -eq [IntPtr]1234) "$($case.name): verified window was missed" }
 else { Check (!$popupVisible) "$($case.name): unverified window reported as open" }
 Check (([StartupFixture]::Now-$started).TotalSeconds -le 45.1) "$($case.name): unbounded observation"
 if($case.name -eq 'never-opens'){Check (([StartupFixture]::Now-$started).TotalSeconds -le 12.1) 'Absent window should not use verification budget'}
 if($case.name -like '*late-verification'){
  Check ($failure -eq '' -and $progressCount -eq 1) 'Late verification must remain pending then succeed, with one progress notification'
 }
 if($case.disappear){Check (([StartupFixture]::Now-$started).TotalSeconds -le 3.1) "Do not reopen a user-hidden candidate: $($case.name), elapsed=$(([StartupFixture]::Now-$started).TotalSeconds), delay=$script:scanDelay"}
 if($case.replace -or $case.multiple){Check ($popupCandidateAmbiguous -and !$popupVisible) 'Changed or competing target must never be adopted'}
 if($case.name -eq 'cold-fast') {
  Check (([StartupFixture]::Now-$started).TotalMilliseconds -le 250) "Ready window delayed behind a fixed timeout: $(([StartupFixture]::Now-$started).TotalMilliseconds) ms"
 }
 Write-Output "PASS: $($case.name)"
}
Write-Output "PASS: startup production branch; $($cases.Count) scenarios; no native UI accessed."
$settleStart=$source.IndexOf('$popupFollowerSettleMilliseconds = 0')
$settleEnd=$source.IndexOf('if ($popupWindow -eq [IntPtr]::Zero -or -not $popupVisible)', $settleStart)
if($settleStart -lt 0 -or $settleEnd -le $settleStart){throw 'Production settle branch not found'}
$settle=[scriptblock]::Create($source.Substring($settleStart,$settleEnd-$settleStart))
foreach($retained in @($true,$false)) {
 $UseRetainedChat=$retained;$activatedExisting=$false;$popupWindow=[IntPtr]1234;$popupVisible=$true
 $before=[StartupFixture]::Now
 . $settle
 $expected=if($retained){0}else{1200}
 Check (([StartupFixture]::Now-$before).TotalMilliseconds -eq $expected) 'Wrong startup settle delay'
 Check ($popupFollowerSettleMilliseconds -eq $expected) 'Reported settle delay is inaccurate'
}
Write-Output 'PASS: retained startup has no follower delay; non-retained owner handoff retains its safety pause.'

# Exercise real terminal classification, not just an assertion on its text.
$failureStart=$source.IndexOf('if ($popupWindow -eq [IntPtr]::Zero -or -not $popupVisible)', $settleStart)
$failureEnd=$source.IndexOf('if (-not $activatedExisting -and -not (Measure-PopupStage', $failureStart)
$failureBlock=[scriptblock]::Create($source.Substring($failureStart,$failureEnd-$failureStart))
function Restore-ChatGptPopupTopmost { param($PopupWindow,$Required) return $true }
foreach($case in @(
 @{appearance=$true;ambiguous=$false;expected='popup_verification_incomplete'},
 @{appearance=$false;ambiguous=$false;expected='popup_not_opened'},
 @{appearance=$true;ambiguous=$true;expected='popup_identity_unresolved'}
)){
 $popupWindow=[IntPtr]::Zero;$popupVisible=$false;$appearanceObserved=$case.appearance
 $popupCandidateAmbiguous=$case.ambiguous;$popupCandidateDetected=$false;$script:failure=''
 $temporaryTopmostWindow=[IntPtr]::Zero;$temporaryTopmost=$false
 . $failureBlock
 Check ($failure -eq $case.expected) 'Appearance, ambiguity and verification failure must remain distinct'
}
Write-Output 'PASS: terminal messages distinguish absent, unverified and changed windows.'
