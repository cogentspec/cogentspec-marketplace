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
  $aggregate=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-RequestTiming'},$true)
  Invoke-Expression $aggregate.Extent.Text
  $sinkExpression=$ast.Find({param($n)$n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text -match 'param\(\$row\)' -and $n.Extent.Text -match '& \$timingWriter'},$true).Extent.Text
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

$state=@{groups=[ordered]@{};milestones=[Collections.Generic.List[object]]::new();truncated=$false}
Add-RequestTiming $state @{stage='opener';phase='start'} 0
for($i=0;$i -lt 2000;$i++) {
 Add-RequestTiming $state @{stage='uia_composer_search';phase='start';handle=42} ($i*10)
 Add-RequestTiming $state @{stage='uia_composer_search';phase='end';handle=42;durationMs=2;status=$(if($i -eq 100){'error'}else{'ok'})} ($i*10+2)
 Add-RequestTiming $state @{stage='composer_matches';phase='point';handle=42;composerCount=$(if($i -ge 1900){1}else{0});visible=$true} ($i*10+3)
}
foreach($stage in @('composer_focus','composer_insert','pin_window','opener','final_verification')) { Add-RequestTiming $state @{stage=$stage;phase='end'} 24000 }
$summary=$state.groups['uia_composer_search:42']
if($summary.completedCount -ne 2000 -or $summary.startedCount -ne 2000 -or $summary.totalDurationMs -ne 4000 -or $summary.maxDurationMs -ne 2 -or $summary.errorCount -ne 1){throw 'Incorrect whole-request aggregate'}
if($state.groups['composer_matches:42'].firstMatchElapsedMs -ne 19003){throw 'First successful match lost'}
if($state.truncated -or $state.milestones.Count -ne 6 -or $state.groups.Count -ne 2){throw 'Repeated scans displaced terminal milestones'}
Add-RequestTiming $state @{stage='uia_composer_search';phase='start';handle=42} 25000
if($summary.startedCount -ne 2001 -or $summary.completedCount -ne 2000){throw 'Unfinished inspection hidden'}
for($i=0;$i -lt 200;$i++){Add-RequestTiming $state @{stage='uia_root';phase='start';handle=(100+$i)} 26000}
if(-not $state.truncated -or $state.groups.Count -ne 128 -or $state.milestones[-1].stage -ne 'final_verification'){throw 'Group overflow corrupted milestones'}
Write-Output 'PASS: 6000 scan events retain late milestones, full totals, first match, incomplete calls, and explicit bounded overflow.'

# Construct the actual callback inside a child scope, then invoke after that
# scope has gone away. No global function lookup may be required.
$fixture = & {
 param($writer,$expression)
 $timingWriter=$writer
 $timingState=@{groups=[ordered]@{};milestones=[Collections.Generic.List[object]]::new();truncated=$false}
 $timingClock=[Diagnostics.Stopwatch]::StartNew()
 $callback=(Invoke-Expression $expression).GetNewClosure()
 @{sink=$callback;state=$timingState}
} ${function:Add-RequestTiming} $sinkExpression
& $fixture.sink @{stage='opener';phase='start'}
& $fixture.sink @{stage='uia_root';phase='end';handle=77;durationMs='invalid-fixture-duration';status='ok'}
& $fixture.sink @{stage='final_verification';phase='end'}
if($fixture.state.milestones.Count -ne 2 -or -not $fixture.state.truncated){throw 'Scoped callback lost milestones or leaked diagnostics failure'}
Write-Output 'PASS: production callback survives child-scope exit and contains injected aggregation failure.'
