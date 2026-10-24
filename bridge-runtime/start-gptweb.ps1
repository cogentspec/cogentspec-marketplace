[CmdletBinding()]
param([ValidatePattern('^$|^ctx-[a-f0-9]{64}$')][string]$ContextKey = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -le 5) { $env:PSModulePath = Join-Path $PSHOME 'Modules' }
$timer = [Diagnostics.Stopwatch]::StartNew()
$stage = 'runtime_metadata'
$installed = $false
$child = $null

function Remaining { $ms=120000-[int]$timer.ElapsedMilliseconds; if($ms -le 0){throw 'runtime_timeout'}; return $ms }
function Plain-Directory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'unsafe_runtime_path'}
        }
        $parent=Split-Path -Parent $cursor
        if(-not $parent -or $parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
function Run([string]$File,[string[]]$Arguments,[string]$WorkingDirectory,[int]$LimitMilliseconds=30000) {
    [void](Remaining)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $info.WorkingDirectory=$WorkingDirectory;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    if([IO.Path]::GetFileName($File) -ieq 'git.exe'){
        $info.EnvironmentVariables['GIT_TERMINAL_PROMPT']='0'
        $info.EnvironmentVariables['GCM_INTERACTIVE']='Never'
    }
    # Only fixed trusted paths, Git flags and a validated context reach argv.
    $quoted=@($Arguments | ForEach-Object {
        if($_ -notmatch '[\s"]' -and $_.Length){$_}else{
            $escaped=[regex]::Replace($_,'(\\*)"','$1$1\"')
            '"'+[regex]::Replace($escaped,'(\\+)$','$1$1')+'"'
        }
    });$info.Arguments=$quoted -join ' '
    $script:child=[Diagnostics.Process]::new();$script:child.StartInfo=$info
    try{
        if(-not $script:child.Start()){throw 'process_start_failed'}
        $stdout=$script:child.StandardOutput.ReadToEndAsync();$stderr=$script:child.StandardError.ReadToEndAsync()
        $limit=[Math]::Min((Remaining),$LimitMilliseconds)
        if(-not $script:child.WaitForExit($limit)){throw 'runtime_timeout'}
        if(-not $stdout.Wait((Remaining)) -or -not $stderr.Wait((Remaining))){throw 'runtime_timeout'}
        if($script:child.ExitCode -ne 0){throw 'runtime_operation_failed'}
        return $stdout.GetAwaiter().GetResult().Trim()
    }finally{
        if($script:child){
            if(-not $script:child.HasExited){
                try{$script:child.Kill($true)}catch{
                    # Fixed executable and numeric owned PID only; never a shell.
                    $kill=[Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'),('/PID '+$script:child.Id+' /T /F'))
                    $kill.UseShellExecute=$false;$kill.CreateNoWindow=$true;$kill.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
                    $killer=[Diagnostics.Process]::Start($kill);try{[void]$killer.WaitForExit(1500)}finally{$killer.Dispose()}
                }
            }
            $script:child.Dispose();$script:child=$null
        }
    }
}
function Verify-Package([string]$Directory,[string]$ExpectedHash) {
    $null=Plain-Directory $Directory
    $manifest=Join-Path $Directory 'runtime.json'
    if((Get-Item -LiteralPath $manifest -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'unsafe_runtime_manifest'}
    if((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'runtime_manifest_mismatch'}
    $package=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if($package.protocol -cne 'cogentspec-standalone-web-runtime-v1' -or $package.version -cne $metadata.version -or
        $package.command -cne '$gptweb' -or $package.surface -cne 'chatgpt' -or $package.experience -cne 'web' -or
        $package.pluginRequired -cne $false -or $package.codexRequired -cne $false){throw 'runtime_identity_mismatch'}
    $expected=@('runtime.json')
    foreach($file in $package.files.PSObject.Properties){
        if($file.Name -cnotmatch '^scripts/[a-z0-9-]+\.(ps1|mjs)$' -or [string]$file.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'unsafe_runtime_file'}
        $path=Join-Path $Directory $file.Name.Replace('/','\')
        $null=Plain-Directory (Split-Path -Parent $path)
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.Value){throw 'runtime_file_mismatch'}
        $expected+=$file.Name
    }
    $children=@(Get-ChildItem -LiteralPath $Directory -Force)
    foreach($item in $children){
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($item.PSIsContainer -and $item.Name -cne 'scripts')){throw 'unexpected_runtime_path'}
    }
    $scriptFiles=@(Get-ChildItem -LiteralPath (Join-Path $Directory 'scripts') -Force)
    foreach($item in $scriptFiles){if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'unexpected_runtime_path'}}
    $actual=@($children | Where-Object{-not $_.PSIsContainer} | ForEach-Object{$_.Name})+@($scriptFiles | ForEach-Object{'scripts/'+$_.Name})
    if(@(Compare-Object @($expected|Sort-Object) @($actual|Sort-Object)).Count){throw 'unexpected_runtime_file'}
    if(-not $package.files.PSObject.Properties['scripts/connect-gptweb.ps1']){throw 'runtime_entry_missing'}
}
try {
    if($env:OS -ne 'Windows_NT'){throw 'windows_required'}
    $workspace=(Get-Location).ProviderPath
    # Public metadata contains only fixed source identifiers and release hashes.
    $metadata=Invoke-RestMethod -Uri 'https://cogentspec.app/api/bridge/gptweb/runtime' -Method Get -MaximumRedirection 0 -TimeoutSec 10
    if($metadata.protocol -cne 'cogentspec-standalone-web-release-v1' -or $metadata.command -cne '$gptweb' -or
        $metadata.version -cnotmatch '^\d+\.\d+\.\d+$' -or $metadata.manifestSha256 -cnotmatch '^[a-f0-9]{64}$' -or $metadata.revision -cnotmatch '^[a-f0-9]{40}$' -or
        $metadata.repository -cne 'https://github.com/cogentspec/cogentspec-marketplace.git' -or
        $metadata.sourceDirectory -cne 'bridge-runtime/gptweb' -or $metadata.pluginRequired -cne $false -or $metadata.codexRequired -cne $false){throw 'invalid_runtime_metadata'}
    $root=Plain-Directory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\standalone-web')
    [void][IO.Directory]::CreateDirectory($root)
    $destination=Join-Path $root ($metadata.version+'-'+$metadata.manifestSha256.Substring(0,16))
    if(-not (Test-Path -LiteralPath $destination)){
        $stage='runtime_install'
        $gitCommand=@(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if(-not $gitCommand.Count){throw 'git_unavailable'}
        $git=[string]$gitCommand[0].Source
        $temporary=Join-Path $root ('stage-'+[Guid]::NewGuid().ToString('N'))
        $null=Plain-Directory $temporary
        [void][IO.Directory]::CreateDirectory($temporary)
        $hooks=Join-Path $temporary 'empty-hooks';[void][IO.Directory]::CreateDirectory($hooks)
        $checkout=Join-Path $temporary 'source'
        $null=Run $git @('-c','core.autocrlf=false','-c',('core.hooksPath='+$hooks),'clone','--quiet','--filter=blob:none','--sparse','--no-checkout',
            'https://github.com/cogentspec/cogentspec-marketplace.git',$checkout) $workspace
        $remote=Run $git @('-C',$checkout,'remote','get-url','origin') $workspace
        if($remote -cne 'https://github.com/cogentspec/cogentspec-marketplace.git'){throw 'runtime_source_mismatch'}
        $null=Run $git @('-c',('core.hooksPath='+$hooks),'-C',$checkout,'fetch','--quiet','--depth=1','origin',$metadata.revision) $workspace
        # Pin HEAD without checking out the mutable default branch. The first
        # file materialization therefore uses only the reviewed release commit.
        $null=Run $git @('-C',$checkout,'update-ref','--no-deref','HEAD',$metadata.revision) $workspace
        $null=Run $git @('-c','core.autocrlf=false','-c',('core.hooksPath='+$hooks),'-C',$checkout,'sparse-checkout','set','--no-cone','/bridge-runtime/gptweb/') $workspace
        $null=Run $git @('-c','core.autocrlf=false','-c',('core.hooksPath='+$hooks),'-C',$checkout,'checkout','--detach','--quiet',$metadata.revision) $workspace
        $candidate=Join-Path $checkout 'bridge-runtime\gptweb'
        Verify-Package $candidate $metadata.manifestSha256
        # Move only our verified fixed package from its direct staging parent.
        $candidate=Plain-Directory $candidate
        $expectedCandidate=[IO.Path]::GetFullPath((Join-Path $temporary 'source\bridge-runtime\gptweb'))
        if($candidate -cne $expectedCandidate -or -not $candidate.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'unsafe_runtime_promotion'}
        if(Test-Path -LiteralPath $destination){throw 'concurrent_runtime_install'}
        Move-Item -LiteralPath $candidate -Destination $destination
        $installed=$true
        # This contains only our fresh clone and empty hooks; preserve it as
        # provenance rather than recursively deleting or following Git paths.
    }
    $stage='runtime_integrity'
    Verify-Package $destination $metadata.manifestSha256
    $stage='workspace_connection'
    $powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoProfile','-NonInteractive','-File',(Join-Path $destination 'scripts\connect-gptweb.ps1'))
    if($ContextKey){$arguments+=@('-ContextKey',$ContextKey)}
    $reply=(Run $powershell $arguments $workspace 50000) | ConvertFrom-Json
    if($reply.status -cne 'connected'){
        $message=switch([string]$reply.status){
            'approval_required' {'Approve this computer in your existing CogentSpec account before connecting GPTWeb.'}
            'execution_permission_required' {'GPTWeb needs the host permission to run its connection helper as your Windows user.'}
            'licence_required' {'The current computer is not authorized for this Bridge connection.'}
            default {'GPTWeb could not reach and verify this listening work area. No other tab was opened.'}
        }
        [ordered]@{protocol='cogentspec-standalone-gptweb-v1';status='not_connected';failureStage=$stage;runtimeInstalled=$installed;
            pluginInstalled=$false;codexRequired=$false;browserOpened=$false;workspaceConnected=$false;acknowledgementVerified=$false;userMessage=$message}|ConvertTo-Json -Compress
        return
    }
    $connected=$reply.protocol -ceq 'cogentspec-workspace-beacon-start-v1' -and $reply.status -ceq 'connected' -and
        $reply.surface -ceq 'chatgpt' -and $reply.experience -ceq 'web' -and $reply.workspaceConnected -ceq $true -and
        $reply.acknowledgementVerified -ceq $true -and $reply.browserReused -ceq $true -and $reply.browserOpened -ceq $false -and
        $reply.browserHandoff -ceq 'authenticated-workspace-reuse'
    [ordered]@{protocol='cogentspec-standalone-gptweb-v1';status=$(if($connected){'connected'}else{'not_connected'});
        runtimeInstalled=$installed;pluginInstalled=$false;codexRequired=$false;browserOpened=$false;workspaceConnected=$connected;
        acknowledgementVerified=$connected;userMessage=$(if($connected){'GPTWeb connected.'}else{'GPTWeb could not connect to the listening work area. Check its Bridge initiation or required computer approval.'})}|ConvertTo-Json -Compress
}catch{
    $reason=[string]$_.Exception.Message
    $message=switch($reason){
        'git_unavailable' {'GPTWeb needs Git on this computer to prepare its standalone Bridge. No plugin was installed.'}
        'windows_required' {'GPTWeb needs an approved local Windows execution host for its standalone Bridge.'}
        'runtime_timeout' {'GPTWeb reached its setup or connection time limit. Nothing was retried.'}
        {$_ -in @('runtime_manifest_mismatch','runtime_file_mismatch','unexpected_runtime_file','unexpected_runtime_path','unsafe_runtime_file','unsafe_runtime_path','unsafe_runtime_manifest','runtime_identity_mismatch')} {'GPTWeb runtime verification failed. The unverified runtime was not started.'}
        {$_ -in @('runtime_source_mismatch','invalid_runtime_metadata')} {'GPTWeb could not verify its official runtime source. No plugin was installed.'}
        default {'GPTWeb setup or connection could not be verified. No plugin was installed and no other tab was opened.'}
    }
    [ordered]@{protocol='cogentspec-standalone-gptweb-v1';status='not_connected';failureStage=$stage;runtimeInstalled=$installed;
        pluginInstalled=$false;codexRequired=$false;browserOpened=$false;workspaceConnected=$false;acknowledgementVerified=$false;
        userMessage=$message}|ConvertTo-Json -Compress
}
