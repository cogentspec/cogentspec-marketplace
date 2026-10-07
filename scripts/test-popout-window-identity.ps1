$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Watcher parse failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-PopupPinHotkeyTarget'},$true)
Invoke-Expression $fn.Extent.Text
# Run the real identity/update function against an in-memory inspection fixture.
# No ChatGPT UI, native window, credential, worker or server is accessed.
$script:TestToken='fixture'
Add-Type 'namespace CogentSpec { public static class ChatGptPopupPinHotkey { public static long Target; public static void SetVerifiedPopup(long h,int p) { Target=h; } } }'
$script:PinHotkeyReady=$true
$script:LifecyclePopupHandle=0
$script:LifecyclePopupProcessId=0
$script:LifecycleWindowKey=''
$script:CurrentPopupWindowHandle=0
$script:popupHelper='Get-InspectionFixture'
$script:inspectionFixture=@{status='ready';publisherVerified=$true;popupVerified=$true;
 popupVisible=$true;popupWindowHandle=1234;popupProcessId=5678;
 conversationState='blank';currentConversationKey='';chatFingerprint=''}
function Get-InspectionFixture { param($Mode,$PreferredWindowHandle) $script:inspectionFixture | ConvertTo-Json -Compress }
Update-PopupPinHotkeyTarget
$key=$script:LifecycleWindowKey;$worker=$script:LifecycleWorkerId
if($key -notmatch '^[0-9a-f]{64}$' -or $script:CurrentConversationKey){throw 'Blank chat needs independent window identity'}
foreach($state in @('identified','blank','unknown','identified')){
 $script:inspectionFixture.conversationState=$state
 $script:inspectionFixture.currentConversationKey=if($state -eq 'identified'){'a'*64}else{''}
 Update-PopupPinHotkeyTarget
 if($script:LifecycleWindowKey -ne $key -or $script:LifecycleWorkerId -ne $worker){throw 'Chat state changed window ownership'}
}
$script:inspectionFixture.currentConversationKey='b'*64
$script:inspectionFixture.popupVisible=$false
Update-PopupPinHotkeyTarget
if($script:LifecycleWindowKey -ne $key -or $script:LifecycleWorkerId -ne $worker){throw 'Hidden/changed chat changed window ownership'}
$script:inspectionFixture.publisherVerified=$false
Update-PopupPinHotkeyTarget
if($script:CurrentPopupWindowHandle -ne 0){throw 'Unverified window must not advertise authority'}
$script:inspectionFixture.publisherVerified=$true
Update-PopupPinHotkeyTarget
if($script:LifecycleWindowKey -ne $key){throw 'Reinspection lost same-window ownership'}
foreach($field in @('popupProcessId','popupWindowHandle')){
 $script:inspectionFixture[$field]++
 Update-PopupPinHotkeyTarget
 if($script:LifecycleWindowKey -eq $key -or $script:LifecycleWorkerId -eq $worker){throw 'Replacement window inherited authority'}
 $key=$script:LifecycleWindowKey;$worker=$script:LifecycleWorkerId
}
$source=Get-Content -Raw -LiteralPath $path
if($source -notmatch '::Observe\([^\r\n]+\$script:LifecycleWindowKey\)'){throw 'Native controller does not use window identity'}
if($source -match '::Observe\([^\r\n]+\$script:CurrentConversationKey\)'){throw 'Conversation still controls native ownership'}
$helperSource=Get-Content -Raw (Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/open-chatgpt-popup.ps1')
$helperAst=[Management.Automation.Language.Parser]::ParseInput($helperSource,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper parse failed'}
foreach($name in @('Get-ChatGptPopupIdentityEvidence','Test-ChatGptPopupSpecificComposer','Select-ChatGptPopupWindowMatch','Resolve-ChatGptPopupDiscovery')) {
 $definition=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $definition.Extent.Text
}
# Replay ready -> missing/disabled (zero matches) -> duplicate -> ready composer.
# Window identity is freshly evidenced by its own dismiss control, not a cache.
foreach($count in @(1,0,2,1)) {
 $identity=Get-ChatGptPopupIdentityEvidence $true $count $false 'Do anything'
 $row=@{window=1234;strict=$identity.strict;popupSpecific=$identity.popupSpecific;visible=$true;foreground=$true;isMainWindow=$false;inspectionSucceeded=$true}
 $selection=Select-ChatGptPopupWindowMatch @($row)
 if($selection.window -ne [IntPtr]1234){throw 'New composer revoked positive native identity'}
 $script:inspectionFixture=@{status='ready';publisherVerified=$true;popupVerified=$true;popupVisible=$true;popupWindowHandle=1234;popupProcessId=5678;conversationState='unknown';currentConversationKey='';chatFingerprint=''}
 Update-PopupPinHotkeyTarget
 if([CogentSpec.ChatGptPopupPinHotkey]::Target -ne 1234 -or $script:ActiveChatFingerprint -or $script:CurrentConversationKey){throw 'Pin target or conversation separation failed'}
}
$identity=Get-ChatGptPopupIdentityEvidence $false 0 $false ''
if($identity.strict -or $identity.popupSpecific){throw 'Unverified shell accepted'}
if((Resolve-ChatGptPopupDiscovery @($row,$row)).state -ne 'ambiguous'){throw 'Multiple Popouts accepted'}
$script:inspectionFixture.popupVerified=$false
Update-PopupPinHotkeyTarget
if([CogentSpec.ChatGptPopupPinHotkey]::Target -ne 0){throw 'Lost window proof retained a shortcut target'}
# Execute the actual conversation guard: stale message markers cannot survive a
# missing/disabled/duplicate composer. This is not a native/UI test.
$observation=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ChatGptConversationObservation'},$true)
$guard=$observation.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($null -eq $composer)')},$true)
if(!$guard){throw 'Missing new-composer conversation guard'}
$composer=$null
$unknown=& ([scriptblock]::Create($guard.Extent.Text))
if($unknown.state -ne 'unknown' -or $unknown.currentConversationKey -or $unknown.chatFingerprint -or $unknown.commandMarkerFound){throw 'New composer inherited a connection'}
@{status='passed';scenarios=18;nativeWindowCallsPerformed=$false;physicalAcceptance='not_performed'}|ConvertTo-Json -Compress

Add-Type -AssemblyName UIAutomationClient
foreach($name in @('Get-ChatGptComposerCondition','Test-IsChatGptComposer','Get-ChatGptComposerMatches')) {
 $definition=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $definition.Extent.Text
}
function Measure-PopupStage {param($Stage,$Operation,$Handle) & $Operation}
$TimingSink=$null
$mockRoot=[pscustomobject]@{Calls=0;Exact=@();Fallback=@()}
$mockRoot|Add-Member ScriptMethod FindAll {param($scope,$condition) $this.Calls++;if($this.Calls -eq 1){return $this.Exact};return $this.Fallback}
function Field($name,$enabled=$true,$focusable=$true){[pscustomobject]@{Current=[pscustomobject]@{Name=$name;IsEnabled=$enabled;IsKeyboardFocusable=$focusable}}}
foreach($case in @(
 @{fields=@((Field (' '+[char]0x200B+'Do anything ')));expected=1},
 @{fields=@((Field 'Private draft text'));expected=0},
 @{fields=@((Field 'Do anything' $false));expected=0},
 @{fields=@((Field 'Do anything' $true $false));expected=0},
 @{fields=@((Field 'Do anything'),(Field 'Work with ChatGPT'));expected=2}
)) {
 $mockRoot.Calls=0;$mockRoot.Exact=@();$mockRoot.Fallback=$case.fields
 $matches=@(Get-ChatGptComposerMatches $mockRoot 1234)
 if($matches.Count -ne $case.expected){throw 'Normalized composer selection or fail-closed guard failed'}
}
$mockRoot.Calls=0;$mockRoot.Exact=@((Field 'Do anything'));$mockRoot.Fallback=@()
if(@(Get-ChatGptComposerMatches $mockRoot 1234).Count -ne 1 -or $mockRoot.Calls -ne 1){throw 'Exact ready composer unnecessarily rescanned'}

# Execute production window evidence ordering. A verified dismiss control must
# bypass even a broken/slow composer provider, without weakening the fallback.
$definition=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ChatGptPopupRootEvidence'},$true)
Invoke-Expression $definition.Extent.Text
$rootFixture=[pscustomobject]@{Dismiss=$true;Broken=$false}
$rootFixture | Add-Member ScriptMethod FindFirst {param($scope,$condition) if($this.Broken){throw 'UIA unavailable'};if($this.Dismiss){return [pscustomobject]@{Verified=$true}};return $null}
$script:composerCalls=0;$script:composerBroken=$true;$script:composerFixture=@()
function Get-ChatGptComposerMatches {param($Root,$Handle) $script:composerCalls++;if($script:composerBroken){throw 'Composer inspection must not run'};return $script:composerFixture}
$identity=Get-ChatGptPopupRootEvidence $rootFixture 1234 $false
if(!$identity.strict -or $script:composerCalls -ne 0){throw 'Window identity waited for composer inspection'}
$rootFixture.Dismiss=$false;$script:composerBroken=$false
$identity=Get-ChatGptPopupRootEvidence $rootFixture 1234 $false
if($identity.strict -or $identity.popupSpecific){throw 'Unknown window accepted without positive evidence'}
$script:composerFixture=@([pscustomobject]@{Current=[pscustomobject]@{Name='Do anything'}})
$identity=Get-ChatGptPopupRootEvidence $rootFixture 1234 $false
if(!$identity.popupSpecific){throw 'Composer identity fallback lost'}
$identity=Get-ChatGptPopupRootEvidence $rootFixture 1234 $true
if($identity.popupSpecific){throw 'Main window accepted through fallback'}
$rootFixture.Broken=$true;$threw=$false
try {Get-ChatGptPopupRootEvidence $rootFixture 1234 $false}catch{$threw=$true}
if(!$threw){throw 'Unreadable window did not fail closed'}
Write-Output 'PASS: dismiss-first identity; zero unnecessary composer scans; guarded fallback and unreadable-window rejection.'
Write-Output 'PASS: normalized-name fallback, unrelated/disabled/unfocusable rejection, duplicate ambiguity, exact fast path; no native UI calls.'
