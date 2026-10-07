$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../plugins/cogentspec/skills/cogentspec/scripts'
foreach($name in @('open-chatgpt-popup.ps1','watch-cogentspec-popout-bridge.ps1','capture-popout-diagnostics.ps1')) {
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
 if($name -eq 'open-chatgpt-popup.ps1') {
  $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Measure-PopupStage'},$true)
  Invoke-Expression $fn.Extent.Text
 }
 if($name -eq 'watch-cogentspec-popout-bridge.ps1') {
  $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PopoutApi'},$true)
  Invoke-Expression $fn.Extent.Text
 }
}
$TimingSink=$null
if((Measure-PopupStage 'composer_focus' {42}) -ne 42){throw 'Disabled tracing changed output'}
$rows=[Collections.Generic.List[object]]::new()
$TimingSink={param($row)$rows.Add($row)}
$result=@(Measure-PopupStage 'uia_composer_search' {1;2} -Handle 123)
if($result.Count -ne 2 -or $result[0] -ne 1 -or $result[1] -ne 2){throw 'Tracing changed collection output'}
if($rows.Count -ne 2 -or $rows[0].phase -ne 'start' -or $rows[1].status -ne 'ok' -or $rows[1].durationMs -lt 0 -or $rows[1].handle -ne 123){throw 'Missing monotonic duration or target'}
try {Measure-PopupStage 'composer_insert' {throw 'fixture failure'};throw 'Exception swallowed'}catch{if($_.Exception.Message -ne 'fixture failure'){throw}}
if($rows[3].status -ne 'error'){throw 'Failure timing missing'}
$TimingSink={throw 'sink unavailable'}
if((Measure-PopupStage 'composer_focus' {42}) -ne 42){throw 'Sink error changed operation'}
$ServiceUrl='https://fixture.invalid'
function Invoke-RestMethod {param($Method,$Uri,$Headers,$TimeoutSec,$ContentType,$Body) return ($Body|ConvertFrom-Json)}
$result=Invoke-PopoutApi Patch '/fixture' 'fixture-only' @{diagnostics=@{timings=@(@{stage='composer_focus';durationMs=42})}}
if($result.diagnostics.timings[0].durationMs -ne 42){throw 'API serialization lost nested timings'}
Write-Output 'PASS: syntax, disabled tracing, collection preservation, target/duration, operation failures, failed sink isolation and real API serialization. No native UI accessed.'
