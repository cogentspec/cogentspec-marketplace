[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repository 'plugins\cogentspec\skills\cogentspec\scripts\watch-cogentstack-bridge.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Worker source does not parse.' }
foreach ($name in @('Stop-OwnedFoundationProcess','Invoke-CancellableFoundationHelper')) {
    $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}.GetNewClosure(),$true)
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression $definition.Extent.Text
}
$fixture = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('cogentspec-build-stop-' + [Guid]::NewGuid().ToString('N'))))
if ([IO.Path]::GetDirectoryName($fixture) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($fixture) -notmatch '^cogentspec-build-stop-[a-f0-9]{32}$') { throw 'Unsafe fixture directory' }
[void](New-Item -ItemType Directory -Path $fixture)
$runtime = (Get-Process -Id $PID).Path
$contextQuery = 'context=ctx-fixture'
$request = [pscustomobject]@{id='fixture-action';targetRequestId='fixture-project'}
$script:polls=0; $script:heartbeats=0; $script:acknowledged=$false; $script:shouldStop=$true; $script:rejectAck=$false
function Write-BridgePresenceReady { $script:heartbeats++ }
function Invoke-BridgeApi([string]$Method,[string]$Path,[string]$Token,$Body=$null) {
    if ($Token -ne 'fixture-only') { throw 'Unexpected token' }
    if ($Method -eq 'Get' -and $Path.StartsWith('/api/plugin/project-requests?')) {
        $script:polls++
        return [pscustomobject]@{request=[pscustomobject]@{status=if($script:polls -eq 1){'requested'}else{'creating'};cancelledAt=$null;cancellationRequestedAt=if($script:shouldStop -and $script:polls -ge 3 -and (Test-Path -LiteralPath $descendant)){'requested'}else{$null}}}
    }
    if ($Method -eq 'Get' -and $Path.StartsWith('/api/plugin/desktop-actions?')) { return [pscustomobject]@{request=$null} }
    if ($Method -eq 'Patch' -and $Body.action -eq 'cancel' -and $Body.requestId -eq 'fixture-project' -and $Body.desktopActionId -eq 'fixture-action') {
        if ($script:rejectAck) { throw 'Fixture acknowledgement unavailable' }
        $script:acknowledged=$true; return [pscustomobject]@{status='cancelled'}
    }
    throw 'Unexpected API call'
}
$control=$null
try {
    $kept=Join-Path $fixture 'existing-file.txt'; [IO.File]::WriteAllText($kept,'keep this file')
    $child=Join-Path $fixture 'child.ps1'; [IO.File]::WriteAllText($child,'Start-Sleep -Seconds 60')
    $descendant=Join-Path $fixture 'descendant.txt'
    $helper=Join-Path $fixture 'helper.ps1'
    $escape={param([string]$value) $value.Replace("'","''")}
    $body="`$child = Start-Process -FilePath '$(& $escape $runtime)' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','`"$child`"') -WindowStyle Hidden -PassThru`r`n`$child.Id | Set-Content -LiteralPath '$(& $escape $descendant)'`r`nStart-Sleep -Seconds 60"
    [IO.File]::WriteAllText($helper,$body)
    $control=Start-Process -FilePath $runtime -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$child+'"')) -WindowStyle Hidden -PassThru
    $result=Invoke-CancellableFoundationHelper -Request $request -Executable $runtime -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper) -Token 'fixture-only'
    if ($result.status -ne 'cancelled' -or -not $script:acknowledged) { throw 'Cancellation was not acknowledged' }
    if ($script:heartbeats -lt 1) { throw 'A running build blocked heartbeat renewal' }
    $descendantId=[int](Get-Content -LiteralPath $descendant -Raw)
    $descendantProcess=Get-Process -Id $descendantId -ErrorAction SilentlyContinue
    if ($descendantProcess -and -not $descendantProcess.WaitForExit(3000)) { throw 'A build descendant is still running' }
    if ($control.HasExited) { throw 'An unrelated process was stopped' }
    if ([IO.File]::ReadAllText($kept) -ne 'keep this file') { throw 'Existing files were changed' }
    $script:polls=0; $script:heartbeats=0; $script:shouldStop=$false; $script:acknowledged=$false
    $normal=Join-Path $fixture 'normal.ps1'; [IO.File]::WriteAllText($normal,"Start-Sleep -Seconds 2`r`n'{`"status`":`"created`"}'")
    $completed=Invoke-CancellableFoundationHelper -Request $request -Executable $runtime -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$normal) -Token 'fixture-only'
    if (($completed | ConvertFrom-Json).status -ne 'created' -or $script:acknowledged) { throw 'Normal completion was changed' }
    $script:polls=0; $script:shouldStop=$true; $script:rejectAck=$true; $unconfirmed=$false
    Remove-Item -LiteralPath $descendant -Force
    try { Invoke-CancellableFoundationHelper -Request $request -Executable $runtime -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper) -Token 'fixture-only' | Out-Null }
    catch { $unconfirmed=$true }
    if (-not $unconfirmed -or $script:acknowledged) { throw 'An unconfirmed stop reported success' }
    [ordered]@{runtime=[IO.Path]::GetFileName($runtime);processTreeStopped=$true;unrelatedProcessPreserved=$true;filesPreserved=$true;heartbeatsContinue=$true;normalCompletionPreserved=$true;unconfirmedStopNotReportedAsSuccess=$true} | ConvertTo-Json -Compress
} finally {
    if ($control -and -not $control.HasExited) { Stop-OwnedFoundationProcess $control }
    if ($control) { $control.Dispose() }
    if ([IO.Path]::GetFileName($fixture) -notmatch '^cogentspec-build-stop-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $fixture).LinkType) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
