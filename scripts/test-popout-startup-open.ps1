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
}
namespace CogentSpec {
 public static class ChatGptPopupNative {
  public static bool SendControlShiftSpace() { StartupFixture.Toggles++; return StartupFixture.SendWorks; }
  public static bool IsVisible(IntPtr h) { return h != IntPtr.Zero && StartupFixture.Visible; }
 }
}
'@
function Start-Sleep { param($Milliseconds) [StartupFixture]::Now=[StartupFixture]::Now.AddMilliseconds($Milliseconds) }
function Write-Failure { param($Status,$Reason) $script:failure=$Status }
function Find-ChatGptPopupWindowMatch {
 param($ProcessIds,$MainWindowHandles,$PreferredWindowHandle)
 $elapsed=([StartupFixture]::Now-$script:started).TotalMilliseconds
 $ready=$elapsed -ge ($script:readyAt * 1000)
 [StartupFixture]::Visible=$ready
 return @{window=$(if($ready){[IntPtr]1234}else{[IntPtr]::Zero});verification=$(if($ready){'dismiss_and_composer'}else{'awaiting_composer'});
  candidateDetected=($ready -or $elapsed -ge ($script:candidateAt * 1000));ambiguous=$script:ambiguous}
}
function Check($condition,$message) { if(!$condition){throw $message} }
$cases=@(
 @{name='cold-fast';ready=.2;candidate=.1;toggles=1},
 @{name='captured-hidden-shells';ready=.2;candidate=0;toggles=1;state='hidden_shells'},
 @{name='cold-delayed-beyond-old-retry';ready=8;candidate=4;toggles=1},
 @{name='accessibility-delayed';ready=5;candidate=0;toggles=0;unknown=$true},
 @{name='already-visible';ready=0;candidate=0;toggles=0;activated=$true},
 @{name='never-opens';ready=99;candidate=99;toggles=1},
 @{name='unverified-window';ready=99;candidate=0;toggles=0;unknown=$true},
 @{name='ambiguous';ready=99;candidate=0;toggles=0;ambiguous=$true},
 @{name='shortcut-rejected';ready=99;candidate=99;toggles=1;sendFailure=$true}
)
foreach($case in $cases) {
 $script:started=[DateTime]'2026-01-01T00:00:00Z';[StartupFixture]::Now=$started
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
 elseif($case.ready -lt 12) { Check ($popupVisible -and $popupWindow -eq [IntPtr]1234) "$($case.name): verified window was missed" }
 else { Check (!$popupVisible) "$($case.name): unverified window reported as open" }
 Check (([StartupFixture]::Now-$started).TotalSeconds -le 12.1) "$($case.name): unbounded observation"
 if($case.name -eq 'cold-fast') {
  Check (([StartupFixture]::Now-$started).TotalMilliseconds -le 250) "Ready window delayed behind a fixed timeout: $(([StartupFixture]::Now-$started).TotalMilliseconds) ms"
 }
 Write-Output "PASS: $($case.name)"
}
Write-Output 'PASS: startup production branch; 9 scenarios; no native UI accessed.'
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
