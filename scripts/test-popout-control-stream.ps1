param([Parameter(Mandatory)][string]$ServiceUrl)
$ErrorActionPreference='Stop'
if($ServiceUrl -notmatch '^http://127\.0\.0\.1:\d+$'){throw 'Loopback fixture only'}
$watcher=Join-Path $PSScriptRoot '..\plugins\cogentspec\skills\cogentspec\scripts\watch-cogentspec-popout-bridge.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($watcher,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Watcher parse failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-PopoutWorkspaceLifecycle'},$true)
$code=[regex]::Match($fn.Extent.Text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$transport=$code.Substring($code.IndexOf(' public sealed class PopoutControlFrame'))
# Compile production networking/parser against a recording sink, not user32.
# The test neither reads nor controls any ChatGPT/native window or credential.
$sink=@'
using System;
using System.Diagnostics;
using System.Threading;
namespace CogentSpec {
 public sealed class CapturedControl { public long Sequence,ReceivedAt; public string State; }
 public static class PopoutWorkspaceLifecycle {
  static readonly object gate=new object();
  static string owner="",sequence="0",action="none";
  static System.Collections.Generic.List<CapturedControl> frames=new System.Collections.Generic.List<CapturedControl>();
  public static void Receive(string id,string key,long seq,string state,int age) {
   lock(gate){owner=id;sequence=seq.ToString();action=state=="close"?"close_confirmed":state=="hidden"?"hide_confirmed":"restore_confirmed";
    frames.Add(new CapturedControl{Sequence=seq,State=state,ReceivedAt=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()});}
  }
  public static string[] ControlAcknowledgment(){lock(gate){return new[]{owner,sequence,action};}}
  public static CapturedControl[] Captured(){lock(gate){return frames.ToArray();}}
 }
'@
Add-Type -TypeDefinition ($sink+$transport)
$worker='aaaaaaaa-1111-1111-1111-111111111111';$key='a'*64
[CogentSpec.PopoutControlTransport]::Configure($ServiceUrl,'test-only-stream-token',$worker,$key)
try {
 # Deliberately block the PowerShell/inspection thread. Delivery must continue.
 Start-Sleep -Seconds 5
 $frames=[CogentSpec.PopoutWorkspaceLifecycle]::Captured()
 if($frames.Count -lt 4){throw 'Independent stream did not deliver while main thread was blocked'}
 @{frames=$frames;fresh=[CogentSpec.PopoutControlTransport]::IsFresh;nativeWindowCallsPerformed=$false}|ConvertTo-Json -Depth 5 -Compress
} finally {[CogentSpec.PopoutControlTransport]::Stop()}
