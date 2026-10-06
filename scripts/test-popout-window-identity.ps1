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
$script:PinHotkeyReady=$false
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
@{status='passed';scenarios=10;nativeWindowCallsPerformed=$false;physicalAcceptance='not_performed'}|ConvertTo-Json -Compress
