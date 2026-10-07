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
