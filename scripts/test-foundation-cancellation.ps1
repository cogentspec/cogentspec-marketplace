[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repository 'plugins\cogentspec\skills\cogentspec\scripts\watch-cogentstack-bridge.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Worker source does not parse.' }
foreach ($name in @('Stop-OwnedFoundationProcess','Invoke-CancellableFoundationHelper','Get-FoundationRecoveryProcesses','Invoke-FoundationCancellationRecovery')) {
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
$script:recoveryMode=$false; $script:recoveryAcknowledged=$false
function Write-BridgePresenceReady { $script:heartbeats++ }
function Invoke-BridgeApi([string]$Method,[string]$Path,[string]$Token,$Body=$null) {
    if ($Token -ne 'fixture-only') { throw 'Unexpected token' }
    if ($script:recoveryMode) {
        if ($Method -eq 'Get' -and $Path.EndsWith('&status=stopping')) { return [pscustomobject]@{requests=@($script:recoveryRequest)} }
        if ($Method -eq 'Patch' -and $Body.action -eq 'cancel' -and $Body.recover -and $Body.requestId -eq $script:recoveryRequest.id -and $Body.desktopActionId -eq $script:recoveryRequest.desktopActionId) {
            $script:recoveryAcknowledged=$true; return [pscustomobject]@{status='cancelled'}
        }
        throw 'Unexpected recovery API call'
    }
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
$control=$null; $recovered=$null; $unknown=$null
try {
    $kept=Join-Path $fixture 'existing-file.txt'; [IO.File]::WriteAllText($kept,'keep this file')
    $child=Join-Path $fixture 'child.ps1'; [IO.File]::WriteAllText($child,'Start-Sleep -Seconds 180')
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
    $stateRoot=$fixture; $ContextKey='ctx-fixture'
    $recoveryRoot=Join-Path $fixture ('bridge-runtime\'+('a'*24)); [void](New-Item -ItemType Directory -Path $recoveryRoot -Force)
    $foundationHelperPath=Join-Path $recoveryRoot 'fulfil-project.ps1'; $recoveryChild=Join-Path $fixture 'recovery-child.txt'
    $recoveryBody="param([string]`$Mode,[string]`$RequestId,[string]`$ContextKey)`r`n`$child = Start-Process -FilePath '$(& $escape $runtime)' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','`"$child`"') -WindowStyle Hidden -PassThru`r`n`$child.Id | Set-Content -LiteralPath '$(& $escape $recoveryChild)'`r`nStart-Sleep -Seconds 180"
    [IO.File]::WriteAllText($foundationHelperPath,$recoveryBody)
    $script:recoveryMode=$true; $script:recoveryRequest=[pscustomobject]@{id='11111111-2222-4333-8444-555555555555';desktopActionId='22222222-3333-4444-8555-666666666666';status='creating';cancellationRequestedAt='stop';targetPath=(Join-Path $fixture 'project')}
    $recoveryArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$foundationHelperPath+'"'),'-Mode','create','-RequestId',$script:recoveryRequest.id,'-ContextKey',$ContextKey)
    $recovered=Start-Process -FilePath $runtime -ArgumentList $recoveryArguments -WindowStyle Hidden -PassThru
    $startup=[Diagnostics.Stopwatch]::StartNew(); while(-not(Test-Path -LiteralPath $recoveryChild)){if($startup.Elapsed.TotalSeconds -gt 15){throw 'Recovery fixture did not start'};Start-Sleep -Milliseconds 50}
    $recoveredChildId=[int](Get-Content -LiteralPath $recoveryChild -Raw)
    Invoke-FoundationCancellationRecovery 'fixture-only'
    if(-not $script:recoveryAcknowledged -or -not $recovered.WaitForExit(3000)){throw 'Reconnected worker failed to stop the existing helper'}
    $recoveredDescendant=Get-Process -Id $recoveredChildId -ErrorAction SilentlyContinue
    if($recoveredDescendant -and -not $recoveredDescendant.WaitForExit(3000)){throw 'Recovery left a build descendant running'}
    if($control.HasExited -or [IO.File]::ReadAllText($kept) -ne 'keep this file'){throw 'Recovery changed unrelated work or files'}
    $script:recoveryAcknowledged=$false
    Invoke-FoundationCancellationRecovery 'fixture-only'
    if(-not $script:recoveryAcknowledged){throw 'Already exited build was not acknowledged'}
    $script:recoveryAcknowledged=$false
    $unknown=Start-Process -FilePath $runtime -ArgumentList @('-NoProfile','-File',('"'+$child+'"'),'-TargetPath',('"'+$script:recoveryRequest.targetPath+'"')) -WindowStyle Hidden -PassThru
    Invoke-FoundationCancellationRecovery 'fixture-only'
    if($script:recoveryAcknowledged -or $unknown.HasExited){throw 'Recovery stopped or acknowledged an unowned target process'}
    Stop-OwnedFoundationProcess $unknown; $unknown.Dispose(); $unknown=$null
    $untrustedRoot=Join-Path $fixture ('bridge-runtime\'+('b'*24)); [void](New-Item -ItemType Directory -Path $untrustedRoot -Force)
    $untrusted=Join-Path $untrustedRoot 'fulfil-project.ps1'; [IO.File]::WriteAllText($untrusted,'param($Mode,$RequestId,$ContextKey); Start-Sleep -Seconds 180')
    $untrustedArguments=$recoveryArguments.Clone(); $untrustedArguments[4]='"'+$untrusted+'"'
    $unknown=Start-Process -FilePath $runtime -ArgumentList $untrustedArguments -WindowStyle Hidden -PassThru
    Invoke-FoundationCancellationRecovery 'fixture-only'
    if($script:recoveryAcknowledged -or $unknown.HasExited){throw 'Recovery adopted an untrusted helper'}
    Stop-OwnedFoundationProcess $unknown; $unknown.Dispose(); $unknown=$null
    [ordered]@{runtime=[IO.Path]::GetFileName($runtime);processTreeStopped=$true;unrelatedProcessPreserved=$true;filesPreserved=$true;heartbeatsContinue=$true;normalCompletionPreserved=$true;unconfirmedStopNotReportedAsSuccess=$true;reconnectedBuildStopped=$true;alreadyExitedBuildAcknowledged=$true;unownedTargetProcessPreserved=$true;untrustedHelperPreserved=$true} | ConvertTo-Json -Compress
} finally {
    foreach($owned in @($recovered,$unknown)){if($owned){if(-not $owned.HasExited){Stop-OwnedFoundationProcess $owned};$owned.Dispose()}}
    if ($control -and -not $control.HasExited) { Stop-OwnedFoundationProcess $control }
    if ($control) { $control.Dispose() }
    if ([IO.Path]::GetFileName($fixture) -notmatch '^cogentspec-build-stop-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $fixture).LinkType) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
