[CmdletBinding()]
param([ValidateSet('','native','uia')][string]$SnapshotKind='', [string]$PolicyPath='')
$ErrorActionPreference='Stop'
if(!$PolicyPath){$PolicyPath=Join-Path $PSScriptRoot 'open-chatgpt-popup.ps1'}
function Import-DecisionFunctions([string]$Path) {
    # Parse, never execute the helper's top-level code (which can send input).
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Policy helper cannot be parsed'}
    foreach($name in @('Test-ChatGptPopupSpecificComposer','Select-ChatGptPopupWindowMatch','Resolve-ChatGptPopupDiscovery','Get-ChatGptPopupStartupDecision')) {
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if(!$fn){throw "Missing policy function: $name"}
        # Functions have pure evidence inputs only, no native calls.
        Invoke-Expression ($fn.Extent.Text -replace ("function " + [regex]::Escape($name)), ("function script:" + $name))
    }
}
function Read-Worker {
    try {
        $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec/popout-bridge/ready.json'
        $m=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{kind='worker';available=$true;version=$m.pluginVersion;pid=$m.processId;at=$m.acknowledgedAt;
            handle=$m.popupWindowHandle;visible=$m.popupVisible;verified=$m.windowControlVerified;
            state=$m.workspaceLifecycleState;action=$m.workspaceLifecycleAction;pinHotkeyReady=$m.pinHotkeyReady;
            fastControlConnected=$m.fastControlConnected;nativeDispatchMilliseconds=$m.nativeDispatchMilliseconds;
            pinTraceAvailable=($m.pinCaptureSession -eq $config.id -and [bool]$m.pinCaptureSession);
            pinAttempts=if($m.pinCaptureSession -eq $config.id -and $m.pinCaptureSession){@($m.pinAttempts)}else{@()}}
    } catch {return @{kind='worker';inspectionComplete=$false;status='marker_unavailable_or_incomplete'}}
}

if($SnapshotKind) {
Import-DecisionFunctions $PolicyPath
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PopoutCaptureNative {
 public class Window {public long handle,owner;public int pid,width,height;public bool visible,foreground,pinned,tool;public string kind;}
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int left,top,right,bottom;}
 delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f,IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint c);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h,int n);
 public static int Chord() {
  if((GetAsyncKeyState(0x11)&0x8000)==0 || (GetAsyncKeyState(0x10)&0x8000)==0)return 0;
  if((GetAsyncKeyState(0x20)&0x8000)!=0)return 1;
  if((GetAsyncKeyState(0x59)&0x8000)!=0)return 2;
  return 0;
 }
 public static Window[] Read(int[] ids) {
  var result=new List<Window>();var fg=GetForegroundWindow();
  EnumWindows(delegate(IntPtr h,IntPtr ignored){
   uint p;GetWindowThreadProcessId(h,out p);if(Array.IndexOf(ids,(int)p)<0)return true;
   var n=new StringBuilder(128);GetClassName(h,n,n.Capacity);
   string raw=n.ToString(); // only fixed native classes are retained, not arbitrary strings
   string kind=raw=="Chrome_WidgetWin_1"?"chromium_window":raw=="Chrome_WidgetWin_0"?"chromium_auxiliary":"other_native_class";
   long style=GetWindowLongPtr(h,-20).ToInt64();Rect r;GetWindowRect(h,out r);
   result.Add(new Window{handle=h.ToInt64(),pid=(int)p,owner=GetWindow(h,4).ToInt64(),visible=IsWindowVisible(h),foreground=h==fg,
     pinned=(style&8)!=0,tool=(style&128)!=0,width=r.right-r.left,height=r.bottom-r.top,kind=kind});return true;
  },IntPtr.Zero);return result.ToArray();
 }
}
'@
# Verify the executable before reading its windows; no credential or account file is read.
$processes=@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
$paths=@($processes | ForEach-Object {$_.Path} | Where-Object {$_} | Sort-Object -Unique)
if($paths.Count -ne 1){throw 'Exactly one running ChatGPT installation is required. No app was launched.'}
$signature=Get-AuthenticodeSignature -LiteralPath $paths[0]
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)\bO="?OpenAI(?: OpCo)?,? LLC"?\b') {throw 'ChatGPT publisher could not be verified'}
$verifiedPath=$paths[0]
function Read-Native {
    $ids=[int[]]@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $verifiedPath} | ForEach-Object Id)
    return @([PopoutCaptureNative]::Read($ids))
}

if($SnapshotKind -eq 'uia') {
    Add-Type -AssemblyName UIAutomationClient
    $started=[DateTime]::UtcNow
    $names=@('Work with ChatGPT','Ask ChatGPT anything locally','Ask ChatGPT anything','Do anything')
    $conditions=[System.Windows.Automation.Condition[]]@($names | ForEach-Object {
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,$_)
    })
    $composerCondition=[System.Windows.Automation.OrCondition]::new($conditions)
    $dismissCondition=[System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,'Dismiss Popout Window'))
    $evidence=@();$rows=@()
    foreach($w in @(Read-Native | Where-Object kind -eq 'chromium_window')) {
        $row=@{handle=$w.handle;pid=$w.pid;visible=$w.visible;pinned=$w.pinned;tool=$w.tool;inspectionSucceeded=$false;composerCount=0;composerLabel='';dismiss=$false}
        try {
            $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.handle)
            $matches=@($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$composerCondition) | Where-Object {$_.Current.IsEnabled -and $_.Current.IsKeyboardFocusable})
            $label=if($matches.Count -eq 1){[string]$matches[0].Current.Name}else{''}
            $row.composerLabel=if($label -in $names){$label}else{''}
            $row.composerCount=$matches.Count
            $row.dismiss=$null -ne $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$dismissCondition)
            $row.inspectionSucceeded=$true
        } catch {$row.errorType=$_.Exception.GetType().Name}
        $strict=$row.inspectionSucceeded -and $row.composerCount -eq 1 -and $row.dismiss
        $fallback=$row.inspectionSucceeded -and $row.composerCount -eq 1 -and (Test-ChatGptPopupSpecificComposer (!$w.tool) $row.composerLabel)
        $evidence+=@{window=[IntPtr]$w.handle;strict=$strict;popupSpecific=$fallback;visible=$w.visible;foreground=$w.foreground;isMainWindow=(!$w.tool);inspectionSucceeded=$row.inspectionSucceeded}
        $row.strict=$strict;$row.fallback=$fallback;$rows+=$row
    }
    $proposed=Resolve-ChatGptPopupDiscovery -Evidence $evidence
    # Replay the released 0.6.98 skip condition from the SAME evidence.
    $released=Select-ChatGptPopupWindowMatch $evidence 0
    $releasedUnknownTool=@($rows | Where-Object tool).Count -gt 0
    @{kind='uia';startedAt=$started.ToString('o');endedAt=[DateTime]::UtcNow.ToString('o');windows=$rows;state=$proposed.state;
        released098WouldSuppressOpening=($released.candidateDetected -or $releasedUnknownTool);
        inspectionComplete=$true} | ConvertTo-Json -Depth 9 -Compress
    return
}


if($SnapshotKind -eq 'native') {
    $watch=[Diagnostics.Stopwatch]::StartNew();$last='';$lastChord=0
    while($watch.Elapsed.TotalMinutes -lt 20) {
        $windows=@(Read-Native)
        $json=$windows|ConvertTo-Json -Depth 4 -Compress
        if($json -ne $last) {
            @{kind='native';at=[DateTime]::UtcNow.ToString('o');elapsedMs=$watch.ElapsedMilliseconds;inspectionComplete=$true;windows=$windows}|ConvertTo-Json -Depth 6 -Compress
            $last=$json
        }
        $chord=[PopoutCaptureNative]::Chord()
        if($chord -and $chord -ne $lastChord){@{kind=$(if($chord -eq 1){'ctrl_shift_space'}else{'ctrl_shift_y'});at=[DateTime]::UtcNow.ToString('o');elapsedMs=$watch.ElapsedMilliseconds}|ConvertTo-Json -Compress}
        $lastChord=$chord
        Start-Sleep -Milliseconds 100
    }
}
return
}
# Secret travels over an inherited anonymous stdin pipe, never command line or disk.
$config=[Console]::In.ReadLine()|ConvertFrom-Json
if($config.service -ne 'https://cogentspec.com'){throw 'Unsupported capture service'}
if([string]$config.id -notmatch '^[a-f0-9-]{36}$' -or [string]$config.worker -notmatch '^[a-f0-9-]{36}$'){throw 'Invalid capture identity'}
$deadline=[DateTime]::UtcNow.AddMinutes(20)
$jobs=@{};$sequence=0;$lastUia=[DateTime]::MinValue
function Request([string]$Method,$Body=$null) {
    $params=@{Method=$Method;Uri=($config.service+'/api/plugin/popout-diagnostics');Headers=@{Authorization=('Bearer '+$config.token)};TimeoutSec=5;MaximumRedirection=0}
    if($Body){$params.ContentType='application/json';$params.Body=$Body|ConvertTo-Json -Compress -Depth 10}
    Invoke-RestMethod @params
}
function Start-Reader([string]$Kind) {
    $command="& '$($PSCommandPath.Replace("'","''"))' -SnapshotKind '$Kind'"
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=(Get-Process -Id $PID).Path
    $info.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($info)
    return @{process=$p;line=$p.StandardOutput.ReadLineAsync();error=$p.StandardError.ReadToEndAsync();started=[DateTime]::UtcNow}
}
try {
    # Recheck opt-in before touching native UI, including after worker startup delay.
    $active=(Request Get).capture
    if(!$active -or $active.id -ne $config.id -or ($active.worker -and $active.worker -ne $config.worker)){return}
    # Win the account/session worker fence before inspecting any native window.
    $claim=Request Post @{id=$config.id;worker=$config.worker;sequence=0;evidence=@{kind='capture_armed';inspectionComplete=$false;at=[DateTime]::UtcNow.ToString('o')}}
    if(!$claim.accepted){return}
    $sequence=1
    $jobs.native=Start-Reader 'native'
    while([DateTime]::UtcNow -lt $deadline) {
        $active=(Request Get).capture
        if(!$active -or $active.id -ne $config.id -or ($active.worker -and $active.worker -ne $config.worker)){break}
        $samples=[Collections.Generic.List[object]]::new()
        # Passive timing capture: do not contend with the production opener's UIA provider.
        # Standalone SnapshotKind uia remains available for explicit offline diagnostics.
        foreach($kind in @('native','uia')) {
            $job=$jobs[$kind];if(!$job){continue}
            while($job.line.IsCompleted -and $samples.Count -lt 80) {
                $line=$job.line.GetAwaiter().GetResult()
                if($null -eq $line){break}
                try {$sample=$line|ConvertFrom-Json;$samples.Add($sample)} catch {$samples.Add(@{kind=$kind;status='invalid_result';inspectionComplete=$false})}
                $job.line=$job.process.StandardOutput.ReadLineAsync()
            }
            if($job.process.HasExited -or ($kind -eq 'uia' -and ([DateTime]::UtcNow-$job.started).TotalSeconds -ge 6)) {
                if(!$job.process.HasExited){$job.process.Kill();$samples.Add(@{kind=$kind;status='timeout';inspectionComplete=$false})}
                elseif($job.process.ExitCode -ne 0){$samples.Add(@{kind=$kind;status='inspection_failed';inspectionComplete=$false})}
                $job.process.Dispose();$jobs.Remove($kind)
                if($kind -eq 'native'){$samples.Add(@{kind='native';status='collector_stopped';inspectionComplete=$false})}
            }
        }
        $samples.Add((Read-Worker))
        $evidence=@{kind='capture_batch';at=[DateTime]::UtcNow.ToString('o');samples=@($samples.ToArray())}
        if(($evidence|ConvertTo-Json -Compress -Depth 10).Length -gt 58000){$evidence=@{kind='capture_gap';status='batch_too_large';inspectionComplete=$false;at=[DateTime]::UtcNow.ToString('o')}}
        $response=Request Post @{id=$config.id;worker=$config.worker;sequence=$sequence;evidence=$evidence}
        if(!$response.accepted){break}
        $sequence++
        if(!$jobs.native){break}
        Start-Sleep -Milliseconds 500
    }
} finally {
    foreach($job in $jobs.Values){if(!$job.process.HasExited){$job.process.Kill()};$job.process.Dispose()}
    $config=$null
}
