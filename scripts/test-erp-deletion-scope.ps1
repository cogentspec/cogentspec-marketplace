param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$WorkerSourcePath,[Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'The removal helper could not be parsed.'}
foreach($name in @('Get-DecodedProcessCommand','Stop-VerifiedProjectProcesses','Resolve-ApprovedDeletionTarget')){
 $definition=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 . ([scriptblock]::Create($definition.Extent.Text))
}
$previewWatcherRoot=Join-Path $TestRoot 'watchers'
$target=Join-Path $TestRoot 'one'
[void][IO.Directory]::CreateDirectory($target)
$runtime=Join-Path $target 'scripts\odoo-runtime.mjs'
$script:stopped=@()
function Get-CimInstance {param($ClassName,$ErrorAction);return @(
 [pscustomobject]@{ProcessId=101;ParentProcessId=1;Name='node.exe';CommandLine=('node.exe "'+$runtime+'" start')},
 [pscustomobject]@{ProcessId=102;ParentProcessId=1;Name='node.exe';CommandLine=('node.exe "'+$target+'-other\scripts\odoo-runtime.mjs" start')},
 [pscustomobject]@{ProcessId=103;ParentProcessId=1;Name='Code.exe';CommandLine=('Code.exe "'+$target+'"')},
 [pscustomobject]@{ProcessId=104;ParentProcessId=101;Name='docker.exe';CommandLine='docker synthetic-owned-child'}
)}
function Stop-Process {param($Id,[switch]$Force,$ErrorAction);$script:stopped+=,[int]$Id}
$count=Stop-VerifiedProjectProcesses -ExactTargetPath $target -ExactRequestId 'synthetic' -ErpOnly
if($count -ne 2 -or $script:stopped -contains 102 -or $script:stopped -contains 103 -or $script:stopped -notcontains 101 -or $script:stopped -notcontains 104){throw 'Removal targeted another project or an editor.'}
$resolved=Resolve-ApprovedDeletionTarget -TargetPath $target -WorkDirectory $TestRoot -ProjectSlug 'one'
if($resolved -ne $target){throw 'Exact folder identity was not preserved.'}
$rejected=$false
try{Resolve-ApprovedDeletionTarget -TargetPath (Join-Path $TestRoot 'one-other') -WorkDirectory $TestRoot -ProjectSlug 'one' | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'A different folder was accepted.'}
# Exercise the real hidden-child wrapper with a harmless test helper, never the
# installed worker, customer folders or the real deletion API.
$workerTree=[System.Management.Automation.Language.Parser]::ParseFile($WorkerSourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'The ERP worker could not be parsed.'}
$dispatch=$workerTree.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ErpDeletion'},$true).Extent.Text
if($dispatch -notmatch 'WaitForExit\(900000\)' -or $dispatch -notmatch 'CreateNoWindow = \$true'){throw 'ERP removal lost its deadline or hidden launch.'}
. ([scriptblock]::Create($dispatch.Replace('$PSScriptRoot',("'"+$TestRoot.Replace("'","''")+"'"))))
$entry=Join-Path $TestRoot 'erp-delete-project.ps1'
$receipt=Join-Path $TestRoot 'dispatch.json'
[IO.File]::WriteAllText($entry,'param($Mode,$RequestId,$ContextKey);@{mode=$Mode;id=$RequestId;context=$ContextKey}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $PSScriptRoot dispatch.json)')
$deleteId='11111111-2222-4333-8444-555555555555';$contextId='ctx-'+('a'*64)
Invoke-ErpDeletion -Deletion ([pscustomobject]@{requestId=$deleteId;contextKey=$contextId})
$record=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
if($record.mode -ne 'delete' -or $record.id -ne $deleteId -or $record.context -ne $contextId){throw 'The removal child received another identity.'}
[IO.File]::WriteAllText($entry,'exit 1')
$rejected=$false;try{Invoke-ErpDeletion -Deletion ([pscustomobject]@{requestId=$deleteId;contextKey=$contextId})}catch{$rejected=$true}
if(-not $rejected){throw 'A failed removal child was reported successful.'}
$rejected=$false;try{Invoke-ErpDeletion -Deletion ([pscustomobject]@{requestId='invalid" -Command';contextKey=$contextId})}catch{$rejected=$true}
if(-not $rejected){throw 'An invalid removal identity reached a child process.'}
@{passed=$true;realProcessesStopped=$false;neighbourProjectPreserved=$true;editorPreserved=$true;exactFolderRequired=$true;hiddenChildDispatchVerified=$true}|ConvertTo-Json -Compress
