$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helper = Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/start-cogentstack-bridge.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Launcher has parser errors.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-FreshPopoutInspection' }, $true)
Invoke-Expression $function.Extent.Text
$pluginId = 'cogentspec'
$pluginVersion = '0.6.84'
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec'
$watcher = Join-Path $root "popout-runtime\$pluginId-$pluginVersion\watch-cogentspec-popout-bridge.ps1"
$script:worker = @{ processId=42; watcherScript=$watcher }
$script:marker = @{ processId=42; acknowledgedAt=[DateTime]::UtcNow.ToString('o'); serverAcknowledged=$true; status='ready'; pluginId=$pluginId; pluginVersion=$pluginVersion; conversationState='identified'; connectedChatMarkerFound=$true; currentConversationKey=('a'*64); popupWindowHandle=123; popupVisible=$false }
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '$watcher'"))
$script:process = @{ CommandLine="powershell.exe -EncodedCommand $encoded" }
$script:runtimeHash = 'matching'
# No real worker files, credentials or native process inspection are used.
function Get-Content {
    param([switch]$Raw, $LiteralPath)
    if ($LiteralPath.EndsWith('worker.json')) { return ($script:worker | ConvertTo-Json -Compress) }
    if ($LiteralPath.EndsWith('ready.json')) { return ($script:marker | ConvertTo-Json -Compress) }
    throw 'Unexpected fixture file read.'
}
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return $script:process }
function Get-FileHash { param($LiteralPath, $Algorithm) return @{Hash= if ($LiteralPath -eq 'fixture-helper') {'matching'} else {$script:runtimeHash}} }
function Assert-Rejected([string]$Label) {
    if ($null -ne (Read-FreshPopoutInspection -HelperPath 'fixture-helper')) { throw "Unsafe cache accepted: $Label" }
}
$inspection = Read-FreshPopoutInspection -HelperPath 'fixture-helper'
if (-not $inspection -or $inspection.chatFingerprint -ne ('a'*64)) { throw 'Fresh hidden exact-chat snapshot was rejected.' }
$script:marker.acknowledgedAt = [DateTime]::UtcNow
$inspection = Read-FreshPopoutInspection -HelperPath 'fixture-helper'
if (-not $inspection) { throw 'PowerShell 7 DateTime JSON values must not be reparsed through a locale-dependent string.' }
$script:marker.acknowledgedAt = [DateTime]::UtcNow.AddSeconds(-4).ToString('o'); Assert-Rejected 'expired'
$script:marker.acknowledgedAt = [DateTime]::UtcNow.AddSeconds(10).ToString('o'); Assert-Rejected 'future'
$script:marker.acknowledgedAt = [DateTime]::UtcNow.ToString('o')
$script:marker.serverAcknowledged=$false; Assert-Rejected 'not server acknowledged'; $script:marker.serverAcknowledged=$true
$script:marker.conversationState='blank'; Assert-Rejected 'blank chat'; $script:marker.conversationState='identified'
$script:marker.connectedChatMarkerFound=$false; Assert-Rejected 'missing command marker'; $script:marker.connectedChatMarkerFound=$true
$script:marker.pluginVersion='0.0.0'; Assert-Rejected 'other package'; $script:marker.pluginVersion=$pluginVersion
$script:marker.processId=43; Assert-Rejected 'other worker'; $script:marker.processId=42
$script:process.CommandLine='powershell.exe -EncodedCommand QQ=='; Assert-Rejected 'unrelated process'; $script:process.CommandLine="powershell.exe -EncodedCommand $encoded"
$script:runtimeHash='different'; Assert-Rejected 'stale runtime helper'
'PASS: fresh hidden snapshot accepted; stale/future/unacknowledged/blank/markerless/foreign-worker/package/hash snapshots rejected.'
