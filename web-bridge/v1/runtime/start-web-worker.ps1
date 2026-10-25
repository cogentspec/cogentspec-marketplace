[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidatePattern('^ctx-[a-f0-9]{64}$')][string]$ContextKey,
    [Parameter(Mandatory=$true)][ValidateSet('$gptweb','$claudeweb')][string]$Command)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$package=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\manifest.json') | ConvertFrom-Json
if($package.protocol -cne 'cogentspec-web-runtime-v1'){throw 'invalid_runtime'}
$name=$Command.TrimStart('$')
$root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('CogentSpec\web-command-v1\workers\'+$name)
[void][IO.Directory]::CreateDirectory($root)
$hash=[Security.Cryptography.SHA256]::Create()
try{$digest=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($ContextKey)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
$statePath=Join-Path $root ($digest+'.json');$ready=Join-Path $root ($digest+'.ready.json')
$watcher=Join-Path $PSScriptRoot 'watch-web-worker.ps1'
$powershell=(Get-Process -Id $PID).Path
function Worker-Command([string]$Path){
    return "& '$($Path.Replace("'","''"))' -ContextKey '$ContextKey' -PluginId 'cogentspec' -PluginVersion '$($package.bridgeCompatibilityVersion)' -WebCommand '$name' -ReadyPath '$($ready.Replace("'","''"))'"
}
function Matches($Process,[string]$Path){
    if(-not $Process -or [IO.Path]::GetFileName([string]$Process.ExecutablePath) -notmatch '^(powershell|pwsh)\.exe$'){return $false}
    $match=[regex]::Match([string]$Process.CommandLine,'(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)')
    if(-not $match.Success){return $false}
    return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value)) -ceq (Worker-Command $Path)
}
function Fresh([int]$ProcessId){
    try{
        $marker=Get-Content -Raw -LiteralPath $ready | ConvertFrom-Json
        $age=([DateTime]::UtcNow-([DateTime]$marker.acknowledgedAt).ToUniversalTime()).TotalSeconds
        return $marker.serverAcknowledged -ceq $true -and [int]$marker.processId -eq $ProcessId -and
            $marker.contextKey -ceq $ContextKey -and $marker.pluginVersion -ceq $package.bridgeCompatibilityVersion -and $age -ge 0 -and $age -lt 6
    }catch{return $false}
}
$worker=$null
if(Test-Path -LiteralPath $statePath){
    $old=Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $previous=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$old.processId)" -ErrorAction SilentlyContinue
    if($previous){
        $allowed=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\web-command-v1\packages\'
        if(-not ([string]$old.watcher).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or -not (Matches $previous ([string]$old.watcher))){throw 'worker_identity_conflict'}
        if([string]$old.watcher -ceq $watcher -and (Fresh ([int]$old.processId))){return}
        # Only an exactly verified worker in this Web command's private state is stopped.
        Stop-Process -Id ([int]$old.processId) -Force
        Wait-Process -Id ([int]$old.processId) -Timeout 3 -ErrorAction SilentlyContinue
    }
}
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Worker-Command $watcher)))
$startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[UInt16]0}
$created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine=('"'+$powershell+'" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded)
    ProcessStartupInformation=$startup
}
if([int]$created.ReturnValue -ne 0 -or [int]$created.ProcessId -le 0){throw 'worker_start_failed'}
$worker=[int]$created.ProcessId
@{processId=$worker;watcher=$watcher;contextKey=$ContextKey;command=$name}|ConvertTo-Json -Compress|Set-Content -LiteralPath $statePath
$deadline=[DateTime]::UtcNow.AddSeconds(15)
do{if(Fresh $worker){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $deadline)
throw 'worker_not_ready'
