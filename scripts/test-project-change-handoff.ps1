$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts/project-build-handoff.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper parse failed'}
$branch=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($ChangeAction)')},$true)
if(!$branch){throw 'Change branch missing'}
$run=[scriptblock]::Create($branch.Extent.Text)
$serviceUrl='https://fixture.invalid';$contextQuery='context=ctx-fixture';$token='fixture-only'
$headers=@{};$script:calls=@();$script:payload='';$script:result=$null
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$TimeoutSec,$ContentType,$Body)
 $script:calls+=@{method=$Method;uri=$Uri;body=$Body}
 return @{status='fixture'}
}
function Get-Content {param($LiteralPath,[switch]$Raw) return $script:payload}
function Write-CompactJson {param($Value) $script:result=$Value}
function Check($condition,$message){if(!$condition){throw $message}}
$ChangeAction='inspect';$ChangePayloadPath='';$Approved=$false
& $run
Check ($script:calls.Count -eq 1 -and $script:calls[0].method -eq 'Get') 'Inspect must make one read'
Check ($script:calls[0].uri -eq 'https://fixture.invalid/api/plugin/project-changes?context=ctx-fixture') 'Wrong endpoint/context'
$script:calls=@();$ChangeAction='propose';$ChangePayloadPath='fixture.json'
$script:payload='{"projectId":"project","runtimeId":"runtime","patch":{"layoutCharacter":"minimal"},"approved":true}'
& $run
$body=$script:calls[0].body|ConvertFrom-Json
Check ($body.action -eq 'propose' -and $body.patch.layoutCharacter -eq 'minimal') 'Proposal payload lost'
Check (!$body.PSObject.Properties['approved']) 'Proposal must not carry approval'
$script:calls=@();$ChangeAction='apply';$script:payload='{"proposalId":"reviewed","approved":true}'
$rejected=$false
try { & $run } catch { $rejected=$true }
Check ($rejected -and $script:calls.Count -eq 0) 'Payload alone must not authorize apply'
$Approved=$true
& $run
$body=$script:calls[0].body|ConvertFrom-Json
Check ($body.action -eq 'apply' -and $body.approved -eq $true -and $body.proposalId -eq 'reviewed') 'Approved proposal changed'
$script:calls=@();$ChangeAction='complete_repair';$Approved=$false
$script:payload='{"completionId":"11111111-1111-4111-8111-111111111111","projectId":"project","runtimeId":"runtime","issue":"invisible_control","cause":"implementation","change":"styling","outcome":"verified","checks":["behavioural","visual"]}'
& $run
$body=$script:calls[0].body|ConvertFrom-Json
Check ($body.action -eq 'complete_repair' -and $body.repair.issue -eq 'invisible_control') 'Completion payload lost'
Check (!$body.PSObject.Properties['approved']) 'Completion is not baseline approval'
$script:calls=@();$script:payload='x'*24577;$rejected=$false
try { & $run } catch { $rejected=$true }
Check ($rejected -and $script:calls.Count -eq 0) 'Oversized payload sent'
Write-Output 'PASS: production helper inspect/propose/apply/complete_repair branches; denied approval and oversized payloads send no request. Network and credential access mocked.'
