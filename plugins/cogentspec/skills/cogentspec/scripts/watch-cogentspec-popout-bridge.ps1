[CmdletBinding()]
param(
    [ValidateSet('cogentspec', 'cogentstack')]
    [string]$PluginId = 'cogentspec',

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$PluginVersion,

    [string]$ReadyPath = '',

    [ValidateRange(250, 10000)]
    [int]$PollMilliseconds = 1500,

    [ValidateRange(1000, 60000)]
    [int]$MaximumRetryMilliseconds = 30000,

    [string]$ServiceUrl = 'https://cogentspec.com',

    [string]$TestToken = '',

    [string]$TestHelperPath = '',

    [ValidateRange(0, 100)]
    [int]$MaxPolls = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PinHotkeyReady = $false
$script:PinHotkeyError = ''
$script:VerifiedPopupVisible = $false
$script:CurrentConversationState = 'unknown'
$script:CurrentConversationKey = ''
$script:ActiveChatFingerprint = ''
$script:CurrentPopupWindowHandle = 0
$script:LifecycleWorkerId = [Guid]::NewGuid().ToString('D')
$script:LifecyclePopupHandle = 0
$script:LifecyclePopupProcessId = 0
$script:LifecycleWindowKey = ''
$script:StartupStage = 'native_initialization'
function Write-MarkerJson($Value) {
    if (-not $ReadyPath) { return }
    $parent = Split-Path -Parent $ReadyPath
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temporary = "$ReadyPath.$PID.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        for ($attempt=0; $attempt -lt 10; $attempt++) {
            try {
                if ([IO.File]::Exists($ReadyPath)) { [IO.File]::Replace($temporary,$ReadyPath,[System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temporary,$ReadyPath) }
                return
            } catch [IO.IOException] {
                if ($attempt -eq 9) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
function Write-StartupMarker([string]$Stage) {
    $script:StartupStage = $Stage
    if (-not $ReadyPath) { return }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $ReadyPath) -Force)
    Write-MarkerJson ([ordered]@{ processId=$PID; pluginId=$PluginId; pluginVersion=$PluginVersion;
        serverAcknowledged=$false; acknowledgedAt=[DateTime]::UtcNow.ToString('o');
        status='starting'; startupStage=$Stage })
}
Write-StartupMarker 'native_initialization'
# Native lifecycle is independent from keyboard shortcuts and account-wide rows.
function Initialize-PopoutWorkspaceLifecycle {
    if ($null -ne ('CogentSpec.PopoutWorkspaceLifecycle' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace CogentSpec {
 public sealed class PopoutLifecycleModel {
  public bool ControllerHidden, ManualReveal;
  public bool HandoffActive, HandoffCancelled;
  public void BeginHandoff(){HandoffActive=true;HandoffCancelled=false;}
  public void ReceiveDuringHandoff(string state){
   if(HandoffActive&&(state=="hidden"||state=="departed"||state=="close"))HandoffCancelled=true;
  }
  public string Decide(string state, bool exists, bool visible, bool popupForeground, bool workspaceForeground) {
   if (!exists) {ControllerHidden=false; ManualReveal=false; return "none";}
   if (state=="close") return "close";
   if (state=="active") {
    if (HandoffActive) return "none";
    if (!workspaceForeground) return "none";
    ManualReveal=false;
    if (ControllerHidden && !visible) return "restore";
    if (visible) ControllerHidden=false;
    return "none";
   }
   if (state!="hidden" && state!="blurred") return "none";
   // A hidden work document means a different tab is selected. Popout focus
   // must not override that explicit event. Blur alone may be Popout interaction.
   if (state=="blurred" && ControllerHidden && visible) {ControllerHidden=false; ManualReveal=true;}
   if (state=="blurred" && (popupForeground || ManualReveal)) return "none";
   if (visible) {ControllerHidden=true; return "hide";}
   return "none";
  }
 }
 public static class PopoutWorkspaceLifecycle {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool SetProp(IntPtr h,string name,IntPtr value);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetProp(IntPtr h,string name);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr RemoveProp(IntPtr h,string name);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h,int command);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  static object gate=new object();
  static IntPtr popup, browser;
  static uint popupPid,browserPid;
  // Windows destroys window properties with the native instance. Unlike a
  // cached HWND/PID pair this cannot survive handle reuse in the same process.
  static readonly string lifetimeProperty="CogentSpec.Popout."+Guid.NewGuid().ToString("N");
  static long browserStarted;
  static string fingerprint="",owner="";
  static string handoffOwner="";
  static IntPtr handoffBrowser;
  static uint handoffBrowserPid;
  static long handoffBrowserStarted;
  static DateTime handoffUntil;
  static IntPtr handoffTarget;
  static IntPtr handoffPopup;
  static long sequence;
  static DateTime received,actionAt;
  static PopoutLifecycleModel model=new PopoutLifecycleModel();
  static Thread thread;
  static AutoResetEvent wake=new AutoResetEvent(false);
  static long commandReceived;
  public static double LastDispatchMilliseconds;
  static volatile bool running;
  public static string State="unknown", LastAction="none", Authority="awaiting_workspace_owner";
  public static string BoundOwner {get {lock(gate){return owner;}}}
  public static bool BeginHandoff(string id) {
   lock(gate) {
    Guid parsed;if(!Guid.TryParseExact(id,"D",out parsed)||model.HandoffActive)return false;
    var h=GetForegroundWindow();uint p;GetWindowThreadProcessId(h,out p);
    var title=new StringBuilder(512);GetWindowText(h,title,title.Capacity);
    try {using(var process=Process.GetProcessById((int)p)) {
     if((process.ProcessName!="chrome"&&process.ProcessName!="msedge")||title.ToString().IndexOf("CogentSpec",StringComparison.OrdinalIgnoreCase)<0)return false;
     handoffBrowser=h;handoffBrowserPid=p;handoffBrowserStarted=process.StartTime.ToUniversalTime().Ticks;
    }}catch{return false;}
    handoffOwner=id;handoffPopup=IntPtr.Zero;handoffTarget=IntPtr.Zero;handoffUntil=DateTime.MinValue;
    model.BeginHandoff();return true;
   }
  }
  public static bool ContinueHandoff(long h) {
   lock(gate) {
    var foreground=GetForegroundWindow();
    if(foreground!=handoffBrowser&&foreground!=new IntPtr(h))model.HandoffCancelled=true;
    if(foreground==handoffBrowser){
     var title=new StringBuilder(512);GetWindowText(foreground,title,title.Capacity);
     if(title.ToString().IndexOf("CogentSpec",StringComparison.OrdinalIgnoreCase)<0)model.HandoffCancelled=true;
    }
    if(model.HandoffActive&&!model.HandoffCancelled&&h!=0)handoffTarget=new IntPtr(h);
    return model.HandoffActive&&!model.HandoffCancelled;
   }
  }
  public static bool EndHandoff(bool windowHandoffAllowed) {
   lock(gate) {
    bool grant=windowHandoffAllowed&&model.HandoffActive&&!model.HandoffCancelled&&Matches()&&
     popup==handoffTarget&&GetForegroundWindow()==popup;
    model.HandoffActive=false;
    handoffPopup=grant?popup:IntPtr.Zero;
    handoffUntil=grant?DateTime.UtcNow.AddSeconds(10):DateTime.MinValue;
    if(!grant)handoffOwner="";
    wake.Set();
    return grant;
   }
  }
  public static string[] ControlAcknowledgment() {
   lock(gate){return new string[]{owner,sequence.ToString(System.Globalization.CultureInfo.InvariantCulture),LastAction};}
  }
  public static bool AllowsWorkspacePin(long h) {
   lock(gate){return owner!="" && popup.ToInt64()==h && Matches() &&
    State=="active" && (DateTime.UtcNow-received).TotalSeconds<=10 &&
    WorkspaceForeground();}
  }
  static bool Matches() {uint p;return popup!=IntPtr.Zero&&IsWindow(popup)&&GetWindowThreadProcessId(popup,out p)!=0&&p==popupPid&&GetProp(popup,lifetimeProperty)==new IntPtr(1);}
  public static bool MatchesWindow(long h) {lock(gate){return popup.ToInt64()==h&&Matches();}}
  public static long[] RetainedWindow() {
   lock(gate){return Matches()?new long[]{popup.ToInt64(),popupPid,IsWindowVisible(popup)?1:0}:new long[0];}
  }
  static bool WorkspaceForeground() {
   if (browser==IntPtr.Zero||GetForegroundWindow()!=browser||!IsWindow(browser))return false;
   uint p;GetWindowThreadProcessId(browser,out p);
   try {using(var process=Process.GetProcessById((int)p)) {
    if(p!=browserPid||process.StartTime.ToUniversalTime().Ticks!=browserStarted)return false;
   }} catch{return false;}
   var title=new StringBuilder(512);GetWindowText(browser,title,title.Capacity);
   return title.ToString().IndexOf("CogentSpec",StringComparison.OrdinalIgnoreCase)>=0;
  }
  public static bool Observe(long h,int pid,string key) {
   lock(gate) {
    uint actual;var handle=new IntPtr(h);
    if(handle==IntPtr.Zero||!IsWindow(handle)||GetWindowThreadProcessId(handle,out actual)==0||actual!=(uint)pid)return false;
    if(popup!=handle||popupPid!=actual||!Matches()) {
     if(!SetProp(handle,lifetimeProperty,new IntPtr(1)))return false;
     if(popup!=handle&&Matches())RemoveProp(popup,lifetimeProperty);
     var oldModel=model;model=new PopoutLifecycleModel();
     model.HandoffActive=oldModel.HandoffActive;model.HandoffCancelled=oldModel.HandoffCancelled;
     owner="";sequence=0;browser=IntPtr.Zero;
     LastAction="none";State="unknown";Authority="awaiting_workspace_owner";
    }
    popup=handle;popupPid=actual;fingerprint=key;
    return true;
   }
  }
  public static bool IsControllerHidden(long h) {
   lock(gate){return popup.ToInt64()==h&&model.ControllerHidden&&Matches()&&!IsWindowVisible(popup);}
  }
  public static void Receive(string id,string key,long seq,string state,int age) {
   lock(gate) {
    if(!Matches()||key!=fingerprint||age<0||age>10000) {State="unknown";return;}
    if(owner!=id) {
     if(String.IsNullOrEmpty(key)&&String.IsNullOrEmpty(owner))return;
     // Bind only on an active work-page handshake while a CogentSpec browser
     // window is foreground. No remote/hidden page can establish ownership.
     bool handoff=state=="blurred"&&id==handoffOwner&&popup==handoffPopup&&
      DateTime.UtcNow<=handoffUntil&&GetForegroundWindow()==popup;
     if(state!="active"&&!handoff)return;
     var h=handoff?handoffBrowser:GetForegroundWindow();uint p;GetWindowThreadProcessId(h,out p);
     var title=new StringBuilder(512);GetWindowText(h,title,title.Capacity);
     if(title.ToString().IndexOf("CogentSpec",StringComparison.OrdinalIgnoreCase)<0)return;
     try {using(var process=Process.GetProcessById((int)p)) {
      if(process.ProcessName!="chrome"&&process.ProcessName!="msedge")return;
      if(handoff&&(p!=handoffBrowserPid||process.StartTime.ToUniversalTime().Ticks!=handoffBrowserStarted))return;
      browser=h;browserPid=p;browserStarted=process.StartTime.ToUniversalTime().Ticks;
     }}catch{return;}
     owner=id;sequence=0;Authority="bound_workspace_document";
     handoffOwner="";handoffUntil=DateTime.MinValue;
    }
    if(seq<sequence)return;
    model.ReceiveDuringHandoff(state);
    if(state!=State&&(LastAction=="hide_requested"||LastAction=="restore_requested"||LastAction=="hide_failed"||LastAction=="restore_failed"||
       (LastAction=="close_failed"&&state!="close")))LastAction="none";
    if(seq!=sequence || state!=State)commandReceived=Stopwatch.GetTimestamp();
    sequence=seq;State=state;received=DateTime.UtcNow.AddMilliseconds(-age);
    wake.Set();
   }
  }
  public static void Tick(string ignored) {
   lock(gate) {
    if(owner=="")return;
    if(!Matches()) {
     if(LastAction=="close_requested")LastAction="close_confirmed";
     model.ControllerHidden=false;State="unknown";return;
    }
    if(LastAction=="close_requested") {
     if((DateTime.UtcNow-actionAt).TotalSeconds>=5)LastAction="close_failed";
     return;
    }
    if(LastAction=="close_confirmed"||LastAction=="close_failed")return;
    if(LastAction=="hide_failed"||LastAction=="restore_failed")return;
    if((DateTime.UtcNow-received).TotalSeconds>10){State="unknown";return;}
    bool visible=IsWindowVisible(popup);
    if(LastAction=="hide_requested"&&visible) {
     if((DateTime.UtcNow-actionAt).TotalSeconds<3)return;
     model.ControllerHidden=false;LastAction="hide_failed";return;
    }
    if(LastAction=="hide_requested"&&!visible)LastAction="hide_confirmed";
    if(LastAction=="restore_requested"&&!visible) {
     if((DateTime.UtcNow-actionAt).TotalSeconds<3)return;
     LastAction="restore_failed";return;
    }
    if(LastAction=="restore_requested"&&visible)LastAction="restore_confirmed";
    var action=model.Decide(State,true,visible,GetForegroundWindow()==popup,WorkspaceForeground());
    if(action=="hide"||action=="restore") {
     LastDispatchMilliseconds=(Stopwatch.GetTimestamp()-commandReceived)*1000.0/Stopwatch.Frequency;
     var ok=ShowWindowAsync(popup,action=="hide"?0:4);
     LastAction=action+(ok?"_requested":"_failed");actionAt=DateTime.UtcNow;
     if(!ok&&action=="hide")model.ControllerHidden=false;
    } else if(action=="close") {
     // Explicit close or the server's accepted 15-second owner expiry policy.
     // Never infer closure from a local stream/network disconnection.
     var ok=PostMessage(popup,0x0010,IntPtr.Zero,IntPtr.Zero);
     LastAction=ok?"close_requested":"close_failed";actionAt=DateTime.UtcNow;
    }
   }
  }
  public static void Start() {
   lock(gate){if(running)return;running=true;
    thread=new Thread(delegate(){while(running){try{Tick(null);}catch{State="unknown";}wake.WaitOne(50);}});
    thread.IsBackground=true;thread.Start();
   }
  }
  public static void Stop(){running=false;wake.Set();if(thread!=null)thread.Join(1000);lock(gate){if(Matches())RemoveProp(popup,lifetimeProperty);}}
 }
 // Independent of PowerShell inspection/action execution. No UI Automation,
 // synthetic keys, project access or LED confirmation runs on these threads.
 public sealed class PopoutControlFrame {
  public string Worker,Owner,Key,State;
  public long Sequence,IssuedAt;
  public int Age;
  public static PopoutControlFrame Parse(string line,string worker,string key) {
   if(line==null||line.Length>512||!line.StartsWith("data: v1\t",StringComparison.Ordinal))return null;
   var p=line.Substring(6).Split('\t');long seq,issued;int age;Guid id;
   if(p.Length!=8||p[1]!=worker||p[3]!=key||
    (p[2]!=""&&!Guid.TryParseExact(p[2],"D",out id))||
    !long.TryParse(p[4],out seq)||seq<0||!int.TryParse(p[6],out age)||age<0||
    !long.TryParse(p[7],out issued)||issued<0||
    Array.IndexOf(new[]{"active","hidden","blurred","departed","close","unknown"},p[5])<0)return null;
   return new PopoutControlFrame{Worker=p[1],Owner=p[2],Key=p[3],Sequence=seq,State=p[5],Age=age,IssuedAt=issued};
  }
 }
 public static class PopoutControlTransport {
  static readonly object gate=new object();
  static string service="",token="",worker="",key="";
  static int generation;
  static volatile bool running;
  static Thread receiver,acknowledger;
  static System.Net.HttpWebRequest streamRequest,ackRequest;
  static DateTime streamSeen=DateTime.MinValue,ackSeen=DateTime.MinValue;
  public static bool IsFresh {get {lock(gate){return (DateTime.UtcNow-streamSeen).TotalSeconds<3 && (DateTime.UtcNow-ackSeen).TotalSeconds<4;}}}
  public static void Configure(string url,string credential,string workerId,string windowKey) {
   url=url.TrimEnd('/');
   var uri=new Uri(url);
   if(uri.Scheme!="https"&&!uri.IsLoopback)throw new ArgumentException("Secure control endpoint required");
   lock(gate) {
    if(service!=url||token!=credential||worker!=workerId||key!=windowKey) {
     service=url.TrimEnd('/');token=credential;worker=workerId;key=windowKey;generation++;
     streamSeen=ackSeen=DateTime.MinValue;
     if(streamRequest!=null)streamRequest.Abort();if(ackRequest!=null)ackRequest.Abort();
    }
    if(running)return;running=true;
    receiver=new Thread(ReceiveLoop);receiver.IsBackground=true;receiver.Start();
    acknowledger=new Thread(AcknowledgeLoop);acknowledger.IsBackground=true;acknowledger.Start();
   }
  }
  static string[] Configuration(out int version) {
   lock(gate){version=generation;return new[]{service,token,worker,key};}
  }
  static bool Current(int version){lock(gate){return running&&version==generation;}}
  static System.Net.HttpWebRequest Request(string[] c,string method,string extra) {
   // This worker also runs on Windows PowerShell 5.1/.NET Framework. Retain
   // its shared transport API until both runtimes can use the same HttpClient.
#pragma warning disable
   var r=(System.Net.HttpWebRequest)System.Net.WebRequest.Create(c[0]+"/api/plugin/desktop-popout-control-stream?workerId="+
    Uri.EscapeDataString(c[2])+"&fingerprint="+Uri.EscapeDataString(c[3])+extra);
#pragma warning restore
   r.Method=method;r.Headers["Authorization"]="Bearer "+c[1];r.AllowAutoRedirect=false;
   r.Accept=method=="GET"?"text/event-stream":"application/json";
   r.Timeout=4000;r.ReadWriteTimeout=4000;r.ServicePoint.ConnectionLimit=Math.Max(6,r.ServicePoint.ConnectionLimit);
   if(method=="POST")r.ContentLength=0;
   return r;
  }
  static void ReceiveLoop() {
   int failures=0;
   while(running) {
    int version;var c=Configuration(out version);
    if(c[3]==""){Thread.Sleep(100);continue;}
    try {
     var r=Request(c,"GET","");lock(gate){if(!Current(version))continue;streamRequest=r;}
     using(var response=(System.Net.HttpWebResponse)r.GetResponse()) {
      if(response.StatusCode!=System.Net.HttpStatusCode.OK||!response.ContentType.StartsWith("text/event-stream",StringComparison.OrdinalIgnoreCase))throw new System.IO.IOException("Stream unavailable");
      DateTimeOffset serverDate;
      long serverStart=DateTimeOffset.TryParse(response.Headers["Date"],out serverDate)?serverDate.ToUnixTimeMilliseconds():DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
      var elapsed=Stopwatch.StartNew();
      using(var reader=new System.IO.StreamReader(response.GetResponseStream())) {
       string line;
       while(Current(version)&&(line=reader.ReadLine())!=null) {
        var frame=PopoutControlFrame.Parse(line,c[2],c[3]);if(frame==null)continue;
        // Account for proxy backlog using the response clock, not local clock
        // agreement. HTTP Date has one-second resolution. Never replay backlog.
        long transit=serverStart+elapsed.ElapsedMilliseconds-frame.IssuedAt;
        if(transit>2000||transit < -2000)throw new System.IO.IOException("Stale stream frame");
        lock(gate) {
         if(!Current(version))break;
         streamSeen=DateTime.UtcNow;failures=0;
         int age=(int)Math.Min(10001,(long)frame.Age+Math.Max(0,transit));
         PopoutWorkspaceLifecycle.Receive(frame.Owner,frame.Key,frame.Sequence,
          age>10000?"unknown":frame.State,age>10000?0:age);
        }
       }
      }
     }
    } catch {failures=Math.Min(4,failures+1);}
    finally {lock(gate){if(version==generation){streamRequest=null;streamSeen=DateTime.MinValue;}}}
    // Normal bounded stream rotation reconnects immediately with a fresh state;
    // failures back off, without changing visibility or closing a window.
    if(failures>0)Thread.Sleep(Math.Min(5000,250*(1<<failures)));
   }
  }
  static void AcknowledgeLoop() {
   string last="";DateTime sent=DateTime.MinValue;int lastGeneration=-1;
   while(running) {
    int version;var c=Configuration(out version);
    var a=PopoutWorkspaceLifecycle.ControlAcknowledgment();var identity=String.Join("|",a);
    if(version!=lastGeneration||identity!=last||(DateTime.UtcNow-sent).TotalMilliseconds>=1500) {
     try {
      var r=Request(c,"POST","&ownerId="+Uri.EscapeDataString(a[0])+"&sequence="+a[1]+"&outcome="+Uri.EscapeDataString(a[2]));
      lock(gate){if(!Current(version))continue;ackRequest=r;}
      using(var response=(System.Net.HttpWebResponse)r.GetResponse()) {
       // Drain tiny response so connection reuse does not wait for finalization.
       using(var reader=new System.IO.StreamReader(response.GetResponseStream())){reader.ReadToEnd();}
       if(response.StatusCode!=System.Net.HttpStatusCode.OK)throw new System.IO.IOException("Acknowledgment rejected");
      }
      lock(gate){if(Current(version))ackSeen=DateTime.UtcNow;}
      last=identity;lastGeneration=version;sent=DateTime.UtcNow;
     } catch {sent=DateTime.UtcNow;last=identity;lastGeneration=version;}
     finally {lock(gate){if(version==generation)ackRequest=null;}}
    }
    Thread.Sleep(50);
   }
  }
  public static void Stop() {
   lock(gate){running=false;generation++;if(streamRequest!=null)streamRequest.Abort();if(ackRequest!=null)ackRequest.Abort();}
   if(receiver!=null)receiver.Join(5500);if(acknowledger!=null)acknowledger.Join(4500);
   lock(gate){token="";streamSeen=ackSeen=DateTime.MinValue;}
  }
 }
}
'@
}
$script:WorkspaceLifecycleState = 'unmanaged'
$script:WorkspaceLifecycleSeenAt = [DateTime]::MinValue
if (-not $TestToken) {
    Initialize-PopoutWorkspaceLifecycle
    [CogentSpec.PopoutWorkspaceLifecycle]::Start()
}

function Write-ReadyMarker([bool]$ServerAcknowledged, [string]$Status = 'ready', [string]$LastError = '') {
    if (-not $ReadyPath) { return }
    $parent = Split-Path -Parent $ReadyPath
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    Write-MarkerJson ([ordered]@{
        processId = $PID
        pluginId = $PluginId
        pluginVersion = $PluginVersion
        serverAcknowledged = $ServerAcknowledged
        acknowledgedAt = [DateTime]::UtcNow.ToString('o')
        status = $Status
        startupStage = $script:StartupStage
        lastError = $LastError
        pinHotkey = 'Ctrl+Shift+Y'
        pinHotkeyReady = [bool]$script:PinHotkeyReady
        pinHotkeyScope = 'verified_popout_or_bound_active_workspace'
        pinHotkeyError = [string]$script:PinHotkeyError
        pinCaptureSession = if (-not $TestToken -and $script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::CaptureSession } else { '' }
        # Keep zero/single attempts as JSON arrays, not null or a lone object.
        pinAttempts = @(if (-not $TestToken -and $script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::Attempts() })
        popupVisible = [bool]$script:VerifiedPopupVisible
        targetTrace = @(if (Get-Variable TargetTrace -Scope Script -ErrorAction SilentlyContinue) { $script:TargetTrace })
        conversationState = [string]$script:CurrentConversationState
        currentConversationKey = [string]$script:CurrentConversationKey
        connectedChatMarkerFound = [bool]$script:ActiveChatFingerprint
        popupWindowHandle = [long]$script:CurrentPopupWindowHandle
        windowControlProtocol = 'window-v1'
        windowControlVerified = [bool]($script:CurrentPopupWindowHandle -ne 0 -and $script:LifecycleWindowKey)
        workspaceLifecycleState = if ($TestToken) { [string]$script:WorkspaceLifecycleState } else { [CogentSpec.PopoutWorkspaceLifecycle]::State }
        workspaceLifecycleAction = if ($TestToken) { 'test' } else { [CogentSpec.PopoutWorkspaceLifecycle]::LastAction }
        workspaceLifecycleAuthority = if ($TestToken) { 'test' } else { [CogentSpec.PopoutWorkspaceLifecycle]::Authority }
        fastControlConnected = if ($TestToken) { $false } else { [CogentSpec.PopoutControlTransport]::IsFresh }
        nativeDispatchMilliseconds = if ($TestToken) { 0 } else { [CogentSpec.PopoutWorkspaceLifecycle]::LastDispatchMilliseconds }
    })
}

function Unprotect-CogentSpecValue([string]$Value) {
    if ($null -eq ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    $protected = [Convert]::FromBase64String($Value)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-PopoutApi([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = $ServiceUrl.TrimEnd('/') + $Path
        Headers = @{ Accept = 'application/json'; Authorization = "Bearer $Token" }
        TimeoutSec = 12
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Read-DesktopToken {
    $credentialPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CogentSpec\desktop-credential.json'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) { throw 'Desktop Bridge is not connected to an account.' }
    $credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    return Unprotect-CogentSpecValue ([string]$credential.token)
}

function Get-HttpStatusCode($Failure) {
    $responseProperty = $Failure.Exception.PSObject.Properties['Response']
    if (-not $responseProperty -or $null -eq $responseProperty.Value) { return 0 }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if (-not $statusProperty -or $null -eq $statusProperty.Value) { return 0 }
    try { return [int]$statusProperty.Value } catch { return 0 }
}

function Initialize-PopupPinHotkey {
    if ($TestToken) { return }
    try {
        if ($null -eq ('CogentSpec.ChatGptPopupPinHotkey' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace CogentSpec {
    public static class ChatGptPopupPinHotkey {
        private const int WH_KEYBOARD_LL = 13;
        private const uint WM_KEYDOWN = 0x0100;
        private const uint WM_KEYUP = 0x0101;
        private const uint WM_SYSKEYDOWN = 0x0104;
        private const uint WM_SYSKEYUP = 0x0105;
        private const uint WM_QUIT = 0x0012;
        private const int VK_CONTROL = 0x11;
        private const int VK_SHIFT = 0x10;
        private const int VK_MENU = 0x12;
        private const int VK_Y = 0x59;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;
        private const int GWL_EXSTYLE = -20;
        private const long WS_EX_TOPMOST = 0x00000008L;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

        private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardData {
            public uint virtualKey;
            public uint scanCode;
            public uint flags;
            public uint time;
            public UIntPtr extraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Point {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Message {
            public IntPtr window;
            public uint message;
            public UIntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public Point point;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int hookId, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out Message message, IntPtr window, uint minimum, uint maximum);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref Message message);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref Message message);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        private static readonly object Sync = new object();
        private static ManualResetEvent ready;
        private static Thread hookThread;
        private static LowLevelKeyboardProc callback;
        private static IntPtr hook;
        private static uint hookThreadId;
        private static long verifiedPopupWindow;
        private static int verifiedProcessId;
        private static int capturedY;
        private static int started;
        private static string lastToggleStatus = "idle";
        private static int lastTogglePinned;
        private static long lastToggleUtcTicks;
        public sealed class PinAttempt {
            public long sequence,handle,foregroundHandle; public string at,status;
            public bool verified,nativeCalled,applied,beforePinned,requestedPinned,afterPinned;
            public int win32Error;
        }
        private static readonly object TraceLock=new object();
        private static readonly System.Collections.Generic.Queue<PinAttempt> trace=new System.Collections.Generic.Queue<PinAttempt>();
        private static string captureSession=""; private static DateTime captureUntil;
        private static long attemptSequence;
        public static void ConfigureCapture(string session) {
            lock(TraceLock){if(session!=captureSession){trace.Clear();attemptSequence=0;}
                captureSession=session??"";captureUntil=DateTime.UtcNow.AddSeconds(10);}
        }
        public static string CaptureSession {get {lock(TraceLock){return DateTime.UtcNow<captureUntil?captureSession:"";}}}
        public static PinAttempt[] Attempts(){lock(TraceLock){return CaptureSession!=""?trace.ToArray():new PinAttempt[0];}}
        private static void RecordAttempt(PinAttempt attempt) {
            // Only this known shortcut; no text, other keys, UIA, I/O or network.
            lock(TraceLock){if(CaptureSession=="")return;attempt.sequence=++attemptSequence;
                attempt.at=DateTime.UtcNow.ToString("o");if(trace.Count==64)trace.Dequeue();trace.Enqueue(attempt);}
        }

        public static bool Start() {
            lock (Sync) {
                if (started != 0) return hook != IntPtr.Zero;
                started = 1;
                ready = new ManualResetEvent(false);
                hookThread = new Thread(HookThreadMain);
                hookThread.IsBackground = true;
                hookThread.Name = "CogentSpec ChatGPT Popout pin hotkey";
                hookThread.SetApartmentState(ApartmentState.STA);
                hookThread.Start();
            }
            ready.WaitOne(3000);
            if (hook != IntPtr.Zero) return true;
            Stop();
            return false;
        }

        public static void Stop() {
            Thread thread;
            uint threadId;
            lock (Sync) {
                thread = hookThread;
                threadId = hookThreadId;
            }
            SetVerifiedPopup(0, 0);
            if (threadId != 0) PostThreadMessage(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            if (thread != null && thread != Thread.CurrentThread) thread.Join(2000);
            lock (Sync) {
                hookThread = null;
                hookThreadId = 0;
                started = 0;
                capturedY = 0;
            }
        }

        public static void SetVerifiedPopup(long windowHandle, int processId) {
            Interlocked.Exchange(ref verifiedPopupWindow, 0);
            Interlocked.Exchange(ref verifiedProcessId, processId);
            Interlocked.Exchange(ref verifiedPopupWindow, windowHandle);
        }

        public static bool IsRunning { get { return hook != IntPtr.Zero; } }
        public static string LastToggleStatus { get { return lastToggleStatus; } }
        public static bool LastTogglePinned { get { return lastTogglePinned != 0; } }
        public static int ReadPinState(long handle) {
            var window = new IntPtr(handle);
            if (!IsVerifiedPopup(window)) return -1;
            bool pinned = IsTopmost(window);
            return IsVerifiedPopup(window) ? (pinned ? 1 : 0) : -1;
        }
        public static long LastToggleUtcTicks { get { return Interlocked.Read(ref lastToggleUtcTicks); } }

        private static void HookThreadMain() {
            callback = HookCallback;
            hookThreadId = GetCurrentThreadId();
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, callback, GetModuleHandle(null), 0);
            ready.Set();
            if (hook == IntPtr.Zero) return;
            Message message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }

        private static bool IsPressed(int virtualKey) {
            return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        }

        private static bool IsTopmost(IntPtr window) {
            return window != IntPtr.Zero && (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;
        }

        private static bool IsVerifiedForegroundPopup(IntPtr window) {
            return window == GetForegroundWindow() && IsVerifiedPopup(window);
        }

        public static bool PinAllowed(bool verified, bool popupForeground, bool bound, bool active, bool fresh, bool workspaceForeground) {
            return verified && (popupForeground || (bound && active && fresh && workspaceForeground));
        }

        private static bool WorkspacePinAllowed(long target) {
            // Controller and hook are separate Add-Type assemblies.
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                var controller = assembly.GetType("CogentSpec.PopoutWorkspaceLifecycle");
                if (controller == null) continue;
                try { return (bool)controller.GetMethod("AllowsWorkspacePin").Invoke(null, new object[] { target }); }
                catch { return false; }
            }
            return false;
        }

        private static bool IsVerifiedPopup(IntPtr window) {
            return VerificationFailure(window)=="";
        }
        private static string VerificationFailure(IntPtr window) {
            long expectedWindow = Interlocked.Read(ref verifiedPopupWindow);
            int expectedProcess = Interlocked.CompareExchange(ref verifiedProcessId, 0, 0);
            if (expectedWindow == 0 || expectedProcess <= 0 || window.ToInt64() != expectedWindow) return "no_verified_target";
            if (!IsWindow(window)) return "window_destroyed";
            if (!IsWindowVisible(window)) return "target_hidden";
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != (uint)expectedProcess) return "process_mismatch";
            // Reject a destroyed/recycled HWND even before the next inspection.
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                var controller = assembly.GetType("CogentSpec.PopoutWorkspaceLifecycle");
                if (controller == null) continue;
                try { return (bool)controller.GetMethod("MatchesWindow").Invoke(null, new object[] { expectedWindow })?"":"window_lifetime_mismatch"; }
                catch { return "controller_check_failed"; }
            }
            return "controller_unavailable";
        }

        private static void ToggleTopmost(IntPtr window, IntPtr foreground) {
            bool shouldPin = !IsTopmost(window);
            IntPtr position = shouldPin ? HWND_TOPMOST : HWND_NOTOPMOST;
            uint flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
            bool applied = SetWindowPos(window, position, 0, 0, 0, 0, flags);
            int error = applied ? 0 : Marshal.GetLastWin32Error();
            bool finalPinned = IsTopmost(window);
            lastTogglePinned = finalPinned ? 1 : 0;
            lastToggleStatus = applied && finalPinned == shouldPin
                ? (finalPinned ? "pinned" : "unpinned")
                : "pin_failed";
            Interlocked.Exchange(ref lastToggleUtcTicks, DateTime.UtcNow.Ticks);
            RecordAttempt(new PinAttempt{handle=window.ToInt64(),foregroundHandle=foreground.ToInt64(),
                verified=true,nativeCalled=true,applied=applied,beforePinned=!shouldPin,requestedPinned=shouldPin,
                afterPinned=finalPinned,win32Error=error,status=lastToggleStatus});
        }

        private static IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                KeyboardData data = (KeyboardData)Marshal.PtrToStructure(lParam, typeof(KeyboardData));
                uint message = unchecked((uint)wParam.ToInt64());
                bool keyDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                bool keyUp = message == WM_KEYUP || message == WM_SYSKEYUP;
                if (data.virtualKey == VK_Y && (keyDown || keyUp)) {
                    if (keyUp && Interlocked.Exchange(ref capturedY, 0) != 0) return new IntPtr(1);
                    if (keyDown && Interlocked.CompareExchange(ref capturedY, 0, 0) != 0) return new IntPtr(1);
                    if (keyDown && IsPressed(VK_CONTROL) && IsPressed(VK_SHIFT) &&
                        !IsPressed(VK_MENU) && !IsPressed(VK_LWIN) && !IsPressed(VK_RWIN)) {
                        IntPtr foreground = GetForegroundWindow();
                        IntPtr target = new IntPtr(Interlocked.Read(ref verifiedPopupWindow));
                        if (PinAllowed(IsVerifiedPopup(target),
                            IsVerifiedForegroundPopup(foreground), true, true, true,
                            WorkspacePinAllowed(target.ToInt64()))) {
                            Interlocked.Exchange(ref capturedY, 1);
                            ToggleTopmost(target,foreground);
                            return new IntPtr(1);
                        }
                        string reason=VerificationFailure(target);
                        RecordAttempt(new PinAttempt{handle=target.ToInt64(),foregroundHandle=foreground.ToInt64(),
                            verified=reason=="",status=reason==""?"workspace_not_authorized":reason});
                    }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
'@ -ErrorAction Stop
        }
        $script:PinHotkeyReady = [CogentSpec.ChatGptPopupPinHotkey]::Start()
        if (-not $script:PinHotkeyReady) { $script:PinHotkeyError = 'keyboard_hook_unavailable' }
    } catch {
        $script:PinHotkeyReady = $false
        $script:PinHotkeyError = 'keyboard_hook_initialization_failed'
    }
}

function Add-RequestTiming {
    param($State, $Row, [double]$ElapsedMs)
    $Row.elapsedMs = $ElapsedMs
    $Row.at = [DateTime]::UtcNow.ToString('o')
    if ($Row.stage -like 'uia_*' -or $Row.stage -eq 'composer_matches') {
        $key = '{0}:{1}' -f $Row.stage, $Row.handle
        if (-not $State.groups.Contains($key)) {
            if ($State.groups.Count -ge 128) { $State.truncated = $true; return }
            $State.groups[$key] = @{stage=$Row.stage;phase='summary';handle=$Row.handle;firstElapsedMs=$ElapsedMs;startedCount=0;completedCount=0;errorCount=0;sampleCount=0;totalDurationMs=0.0;maxDurationMs=0.0}
        }
        $summary = $State.groups[$key]
        $summary.elapsedMs = $ElapsedMs
        $summary.at = $Row.at
        if ($Row.phase -eq 'start') { $summary.startedCount++ }
        if ($Row.phase -eq 'end') {
            $summary.completedCount++
            $summary.totalDurationMs += [double]$Row.durationMs
            $summary.maxDurationMs = [Math]::Max($summary.maxDurationMs, [double]$Row.durationMs)
            if ($Row.status -eq 'error') { $summary.errorCount++ }
        }
        if ($Row.stage -eq 'composer_matches') {
            $summary.sampleCount++
            $summary.composerCount = $Row.composerCount
            $summary.visible = $Row.visible
            if ($Row.composerCount -gt 0 -and -not $summary.ContainsKey('firstMatchElapsedMs')) { $summary.firstMatchElapsedMs = $ElapsedMs }
        }
    } else {
        # Separate budget: scan volume cannot evict focus, pin or completion milestones.
        if ($State.milestones.Count -ge 128) { $State.milestones.RemoveAt(0); $State.truncated = $true }
        $State.milestones.Add($Row)
    }
}

$script:RequestTimingSink = $null
function Restore-PopoutWindowControlTarget {
    if ($TestToken) { return $false }
    $retained = [CogentSpec.PopoutWorkspaceLifecycle]::RetainedWindow()
    if ($retained.Length -ne 3 -or $retained[0] -ne $script:LifecyclePopupHandle -or
        $retained[1] -ne $script:LifecyclePopupProcessId -or -not $script:LifecycleWindowKey) { return $false }
    # Retain only native controls, never the old chat's connection or input proof.
    $script:CurrentPopupWindowHandle = [long]$retained[0]
    $script:VerifiedPopupVisible = $retained[2] -eq 1
    $script:CurrentConversationState = 'unknown'
    $script:CurrentConversationKey = ''
    $script:ActiveChatFingerprint = ''
    $script:ClientUnavailable = $false
    if ($script:PinHotkeyReady) {
        [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup([long]$retained[0], [int]$retained[1])
    }
    return $true
}
function Update-PopupPinHotkeyTarget {
    $beforeHandle = $script:CurrentPopupWindowHandle
    $decision = 'inspection_started'
    $errorType = ''
    try {
    # Only the same verified, controller-hidden native instance can retain its
    # previous exact-chat proof. It cannot be interacted with while hidden.
    # Once visible, normal inspection runs before the next server presence POST.
    if (-not $TestToken -and $script:CurrentPopupWindowHandle -ne 0 -and
        [CogentSpec.PopoutWorkspaceLifecycle]::IsControllerHidden([long]$script:CurrentPopupWindowHandle)) {
        $script:VerifiedPopupVisible = $false
        $decision = 'controller_hidden_retained'
        # Retain the exact verified target. The hook itself checks actual native
        # visibility and PID, so it is usable immediately after fast restoration.
        return
    }
    try {
        $inspectionArguments = @{ Mode = 'inspect'; TimingSink = $script:RequestTimingSink }
        # The helper returns data across a real script boundary. Register the
        # target below, in this watcher's scope; never mutate watcher $script:
        # state from a callback executing inside the helper script.
        if ($script:CurrentPopupWindowHandle -ne 0) {
            $inspectionArguments.PreferredWindowHandle = [long]$script:CurrentPopupWindowHandle
        }
        $inspectionOutput = @(& $popupHelper @inspectionArguments 2>&1)
        $inspectionJson = @($inspectionOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if (-not $inspectionJson) { throw 'The verified ChatGPT Popout helper returned no inspection result.' }
        $inspection = $inspectionJson | ConvertFrom-Json
        $verified = [string]$inspection.status -eq 'ready' -and [bool]$inspection.publisherVerified -and
            [bool]$inspection.popupVerified -and
            [long]$inspection.popupWindowHandle -ne 0 -and [int]$inspection.popupProcessId -gt 0
        if (-not $verified -and (Restore-PopoutWindowControlTarget)) { $decision = 'native_target_retained_chat_unknown'; return }
        $decision = if ($verified) { 'inspection_verified' } else { 'inspection_unverified_target_cleared' }
        $visible = $verified -and [bool]$inspection.popupVisible
        $conversationState = if ($verified -and $inspection.PSObject.Properties['conversationState'] -and
            [string]$inspection.conversationState -in @('blank', 'identified')) { [string]$inspection.conversationState } else { 'unknown' }
        $currentConversationKey = if ($verified -and $inspection.PSObject.Properties['currentConversationKey'] -and
            [string]$inspection.currentConversationKey -match '^[a-f0-9]{64}$') { [string]$inspection.currentConversationKey } else { '' }
        $fingerprint = if ($inspection.PSObject.Properties['chatFingerprint'] -and
            [string]$inspection.chatFingerprint -match '^[a-f0-9]{64}$') { [string]$inspection.chatFingerprint } else { '' }
        $script:VerifiedPopupVisible = $visible
        $missingClientNotice = ($verified -and $inspection.PSObject.Properties['clientUnavailable'] -and [bool]$inspection.clientUnavailable)
        if ($missingClientNotice -and $currentConversationKey) { $script:UnavailableConversationKey = $currentConversationKey }
        # Dismissing a toast is not client recovery. Only a different/new command
        # turn can release the affected identity; a blank/unknown chat stays red.
        $script:ClientUnavailable = $missingClientNotice -or ($currentConversationKey -and
            (Get-Variable -Name UnavailableConversationKey -Scope Script -ErrorAction SilentlyContinue) -and
            $script:UnavailableConversationKey -eq $currentConversationKey)
        if ($script:ClientUnavailable) { $conversationState = 'unknown' }
        $script:CurrentConversationState = $conversationState
        $script:CurrentConversationKey = $currentConversationKey
        $script:ActiveChatFingerprint = if ($verified) { $fingerprint } else { '' }
        $script:CurrentPopupWindowHandle = if ($verified) { [long]$inspection.popupWindowHandle } else { 0 }
        if ($verified) {
            # Stable for this native window, including blank/new/disconnected chats.
            # Never use the conversation key as window-control authority.
            if ($script:LifecyclePopupHandle -ne [long]$inspection.popupWindowHandle -or
                $script:LifecyclePopupProcessId -ne [int]$inspection.popupProcessId -or
                (-not $TestToken -and -not [CogentSpec.PopoutWorkspaceLifecycle]::MatchesWindow([long]$inspection.popupWindowHandle))) {
                $script:LifecycleWorkerId = [Guid]::NewGuid().ToString('D')
                $script:LifecycleWindowKey = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
            }
            $script:LifecyclePopupHandle = [long]$inspection.popupWindowHandle
            $script:LifecyclePopupProcessId = [int]$inspection.popupProcessId
            if (-not $TestToken) {
                if (-not [CogentSpec.PopoutWorkspaceLifecycle]::Observe([long]$inspection.popupWindowHandle, [int]$inspection.popupProcessId, [string]$script:LifecycleWindowKey)) {
                    throw 'Verified Popout lifetime could not be registered.'
                }
            }
        }
        if ($script:PinHotkeyReady) {
            if ($verified) {
                [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup([long]$inspection.popupWindowHandle, [int]$inspection.popupProcessId)
            } else {
                [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup(0, 0)
            }
        }
    } catch {
        $errorType = $_.Exception.GetType().Name
        if (Restore-PopoutWindowControlTarget) { $decision = 'inspection_error_native_retained'; return }
        $decision = 'inspection_error_target_cleared'
        $script:VerifiedPopupVisible = $false
        $script:ClientUnavailable = $false
        $script:CurrentConversationState = 'unknown'
        $script:CurrentConversationKey = ''
        $script:ActiveChatFingerprint = ''
        $script:CurrentPopupWindowHandle = 0
        if ($script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::SetVerifiedPopup(0, 0) }
    }
    } finally {
        # Passive bounded trace only: no input, inspection, authority or lifecycle changes.
        try {
            if (-not (Get-Variable TargetTrace -Scope Script -ErrorAction SilentlyContinue)) { $script:TargetTrace = @() }
            $script:TargetTrace = @($script:TargetTrace | Select-Object -Last 31) + @(@{
                at=[DateTime]::UtcNow.ToString('o'); decision=$decision; errorType=$errorType
                beforeHandle=[long]$beforeHandle; handle=[long]$script:CurrentPopupWindowHandle
                visible=[bool]$script:VerifiedPopupVisible; conversationState=[string]$script:CurrentConversationState
                conversationIdentified=[bool]$script:CurrentConversationKey
            })
        } catch { } # Diagnostic failure must never change production behaviour.
    }
}

if ($TestToken) {
    if ($ServiceUrl -notmatch '^https?://(localhost|127\.0\.0\.1)(:\d+)?$' -or -not $TestHelperPath) {
        throw 'Test tokens are restricted to a loopback service and an explicit helper.'
    }
    $token = $TestToken
    $popupHelper = $TestHelperPath
} else {
    if ($ServiceUrl -ne 'https://cogentspec.com') { throw 'The production standalone Popout Bridge only connects to CogentSpec.' }
    Write-StartupMarker 'protected_credential_read'
    $token = Read-DesktopToken
    $popupHelper = Join-Path $PSScriptRoot 'open-chatgpt-popup.ps1'
}

if (-not (Test-Path -LiteralPath $popupHelper -PathType Leaf)) { throw 'The verified ChatGPT Popout helper is missing.' }
$query = '?pluginId=' + [Uri]::EscapeDataString($PluginId) + '&pluginVersion=' + [Uri]::EscapeDataString($PluginVersion)
$polls = 0
$diagnosticProcess = $null
$diagnosticSession = ''
$consecutiveFailures = 0
Write-StartupMarker 'keyboard_hook_initialization'
Initialize-PopupPinHotkey
Write-StartupMarker 'popout_inspection'
Update-PopupPinHotkeyTarget
Write-StartupMarker 'service_acknowledgment'

try {
    while ($true) {
        try {
            if (-not $TestToken) {
                $controlKey = if ($script:CurrentPopupWindowHandle -ne 0) { $script:LifecycleWindowKey } else { '' }
                [CogentSpec.PopoutControlTransport]::Configure($ServiceUrl,$token,$script:LifecycleWorkerId,$controlKey)
            }
            $presenceQuery = $query + '&popupVisible=' + $script:VerifiedPopupVisible.ToString().ToLowerInvariant()
            $presenceQuery += '&conversationState=' + [Uri]::EscapeDataString($script:CurrentConversationState)
            $presenceQuery += '&lifecycleWorkerId=' + $script:LifecycleWorkerId
            # Read-only native state, including changes made outside our hotkey.
            # Do not infer pinning from connection, visibility or the last keypress.
            if ($script:PinHotkeyReady -and $script:CurrentPopupWindowHandle -ne 0) {
                try {
                    $pinState = [CogentSpec.ChatGptPopupPinHotkey]::ReadPinState([long]$script:CurrentPopupWindowHandle)
                    if ($pinState -ge 0) { $presenceQuery += '&windowPinned=' + ($pinState -eq 1).ToString().ToLowerInvariant() }
                } catch { <# Missing telemetry must never stop the Bridge heartbeat. #> }
            }
            $fastControl = -not $TestToken -and [CogentSpec.PopoutControlTransport]::IsFresh
            if (-not $fastControl) { $presenceQuery += '&lifecycleProtocol=window-v1' }
            if ($script:CurrentPopupWindowHandle -ne 0) {
                $presenceQuery += '&lifecycleWindowKey=' + $script:LifecycleWindowKey
            }
            if (-not $TestToken -and -not [CogentSpec.PopoutControlTransport]::IsFresh) {
                $presenceQuery += '&lifecycleOutcome=' + [CogentSpec.PopoutWorkspaceLifecycle]::LastAction
                $presenceQuery += '&lifecycleBoundOwner=' + [CogentSpec.PopoutWorkspaceLifecycle]::BoundOwner
            }
            if ($script:CurrentConversationKey) {
                $presenceQuery += '&currentConversationKey=' + [Uri]::EscapeDataString($script:CurrentConversationKey)
            }
            if ($script:ActiveChatFingerprint) {
                $presenceQuery += '&chatFingerprint=' + [Uri]::EscapeDataString($script:ActiveChatFingerprint)
            }
            $script:StartupStage = 'service_acknowledgment'
            $listing = Invoke-PopoutApi -Method Get -Path "/api/plugin/desktop-popout-actions$presenceQuery" -Token $token
            $consecutiveFailures = 0
            # Capture has its own process/network/UIA deadlines: it never runs on
            # the lifecycle controller thread and is armed only by website opt-in.
            if (-not $TestToken -and $listing.PSObject.Properties['diagnosticCapture']) {
                $capture = $listing.diagnosticCapture
                if ($script:PinHotkeyReady) { [CogentSpec.ChatGptPopupPinHotkey]::ConfigureCapture($(if ($capture) { [string]$capture.id } else { '' })) }
                if ($capture -and [string]$capture.id -ne $diagnosticSession) {
                    if ($diagnosticProcess) { $diagnosticProcess.Dispose() }
                    $diagnosticSession = [string]$capture.id
                    try {
                        $path = Join-Path $PSScriptRoot 'capture-popout-diagnostics.ps1'
                        $info = [Diagnostics.ProcessStartInfo]::new()
                        $info.FileName = (Get-Process -Id $PID).Path
                        $info.Arguments = '-NoProfile -NonInteractive -File "' + $path + '"'
                        $info.UseShellExecute = $false
                        $info.CreateNoWindow = $true
                        $info.RedirectStandardInput = $true
                        $diagnosticProcess = [Diagnostics.Process]::Start($info)
                        $diagnosticProcess.StandardInput.WriteLine((@{service=$ServiceUrl;id=$capture.id;worker=$script:LifecycleWorkerId;token=$token}|ConvertTo-Json -Compress))
                        $diagnosticProcess.StandardInput.Close()
                    } catch { $diagnosticProcess = $null }
                }
                # Stop is handled by the collector's account-bound poll so its
                # finally block can also terminate its own read-only children.
            }
            if (-not $TestToken -and -not [CogentSpec.PopoutControlTransport]::IsFresh) {
                if ($listing.PSObject.Properties['control'] -and $listing.control.PSObject.Properties['ownerId']) {
                    [CogentSpec.PopoutWorkspaceLifecycle]::Receive([string]$listing.control.ownerId,
                        [string]$listing.control.fingerprint, [long]$listing.control.sequence,
                        [string]$listing.control.state, [int]$listing.control.ageMilliseconds)
                } else { [CogentSpec.PopoutWorkspaceLifecycle]::Receive('', '', 0, 'unknown', 0) }
            }
            if ($listing.PSObject.Properties['workspaceLifecycle']) {
                $script:WorkspaceLifecycleState = [string]$listing.workspaceLifecycle.state
                $script:WorkspaceLifecycleSeenAt = [DateTime]::UtcNow
            } else { $script:WorkspaceLifecycleState = 'unmanaged' }
            if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Tick($script:WorkspaceLifecycleState) }
            Write-ReadyMarker -ServerAcknowledged $true -Status 'ready'
            $request = $listing.request
            if ($request) {
                $claimed = Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                    requestId = [string]$request.id
                    action = 'claim'
                }
                if ($claimed.request) {
                    $completed = $false
                    $handoffStarted = $false
                    $diagnostics = @{ status='helper_exception'; decision='not_reported' }
                    $timingState = @{groups=[ordered]@{};milestones=[Collections.Generic.List[object]]::new();truncated=$false}
                    $timingClock = [Diagnostics.Stopwatch]::StartNew()
                    $script:RequestTimingSink = $null
                    if ($listing.PSObject.Properties['diagnosticCapture'] -and $listing.diagnosticCapture) {
                        # Capture the implementation itself: GetNewClosure's module
                        # cannot resolve script-local function names under & launch.
                        $timingWriter = ${function:Add-RequestTiming}
                        $script:RequestTimingSink = {
                            param($row)
                            try { [void](& $timingWriter $timingState $row $timingClock.Elapsed.TotalMilliseconds) }
                            catch { $timingState.truncated = $true }
                        }.GetNewClosure()
                    }
                    $message = 'The standalone ChatGPT Popout could not be opened.'
                    try {
                        $target = [string]$claimed.request.targetRequestId
                        if ($target -notin @('chatgpt-desktop-popup', 'chatgpt-desktop-popup:connect', 'chatgpt-desktop-popup:update')) {
                            throw 'Standalone Popout Bridge rejected an unsupported target.'
                        }
                        $composerRequired = $target -ne 'chatgpt-desktop-popup'
                        # Refresh before dispatch: a user may have switched chats
                        # after the web request. Do not recover a different chat.
                        $requestConversationKey = if ($claimed.request.PSObject.Properties['recoveryChatFingerprint']) { [string]$claimed.request.recoveryChatFingerprint } else { '' }
                        # Existing-chat/recovery requests need a fresh snapshot.
                        # A closed-window startup has no chat target to recover;
                        # the opener independently verifies before any input.
                        # Do not delay it with a duplicate conversation scan.
                        if ($composerRequired -and ($script:CurrentPopupWindowHandle -ne 0 -or $requestConversationKey)) {
                            Update-PopupPinHotkeyTarget
                        }
                        $recoverThreadId = if ($claimed.request.PSObject.Properties['recoveryThreadId']) { [string]$claimed.request.recoveryThreadId } else { '' }
                        if ($script:ClientUnavailable -and ($target -ne 'chatgpt-desktop-popup:connect' -or
                            -not $requestConversationKey -or $requestConversationKey -ne $script:CurrentConversationKey -or
                            $recoverThreadId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) {
                            throw 'This retained Popout has no desktop client. Open the original saved chat from the desktop chat list and send $cogentspec there. No verified thread is available for automatic recovery; no new chat was substituted.'
                        }
                        $startupProgress = {
                            param($stage)
                            if ($stage -eq 'awaiting_verification') {
                                [void](Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                                    requestId = [string]$request.id
                                    action = 'progress'
                                    stage = 'awaiting_verification'
                                })
                            }
                        }
                        $handoffStarted = $false
                        $continueHandoff = $null
                        if (-not $TestToken) {
                            $handoffOwner = if ($claimed.request.PSObject.Properties['initializationOwnerId']) { [string]$claimed.request.initializationOwnerId } else { '' }
                            if (-not $handoffOwner) { $handoffOwner = [CogentSpec.PopoutWorkspaceLifecycle]::BoundOwner }
                            $handoffStarted = [CogentSpec.PopoutWorkspaceLifecycle]::BeginHandoff($handoffOwner)
                            if (-not $handoffStarted) { throw 'Popout startup requires its originating CogentSpec work tab to be foreground. No input was sent.' }
                            $continueHandoff = { param($handle) [CogentSpec.PopoutWorkspaceLifecycle]::ContinueHandoff([long]$handle) }
                        }
                        if ($script:RequestTimingSink) { [void](& $script:RequestTimingSink @{stage='opener';phase='start'}) }
                        $helperOutput = if ($script:ClientUnavailable -and $target -eq 'chatgpt-desktop-popup:connect' -and
                            $requestConversationKey -and $requestConversationKey -eq $script:CurrentConversationKey -and
                            $recoverThreadId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                            @(& $popupHelper -TimingSink $script:RequestTimingSink -Mode recover -ThreadId $recoverThreadId 2>&1)
                        } elseif ($target -eq 'chatgpt-desktop-popup:connect') {
                            @(& $popupHelper -TimingSink $script:RequestTimingSink -ContinueHandoff $continueHandoff -Mode open -UseRetainedChat -OpenWithShortcut -KeepPinned -PasteClipboard -StartupProgress $startupProgress 2>&1)
                        } elseif ($target -eq 'chatgpt-desktop-popup:update') {
                            @(& $popupHelper -TimingSink $script:RequestTimingSink -ContinueHandoff $continueHandoff -Mode open -UseRetainedChat -KeepPinned -PasteClipboard 2>&1)
                        } elseif ($claimed.request.PSObject.Properties['initializationOwnerId'] -and $claimed.request.initializationOwnerId) {
                            # Fresh work-area initialization opens once and pins explicitly.
                            # No composer text, connection claim, or shortcut toggle loop.
                            @(& $popupHelper -TimingSink $script:RequestTimingSink -ContinueHandoff $continueHandoff -Mode open -UseRetainedChat -OpenWithShortcut -KeepPinned -StartupProgress $startupProgress 2>&1)
                        } else {
                            @(& $popupHelper -TimingSink $script:RequestTimingSink -ContinueHandoff $continueHandoff -Mode open -UseRetainedChat -KeepPinned 2>&1)
                        }
                        if ($script:RequestTimingSink) { [void](& $script:RequestTimingSink @{stage='opener';phase='end'}) }
                        $helperJson = @($helperOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
                        if (-not $helperJson) { throw 'The verified ChatGPT Popout helper returned no result.' }
                        $result = $helperJson | ConvertFrom-Json
                        $diagnostics = @{ status=[string]$result.status; decision='not_reported' }
                        if ($result.PSObject.Properties['decision']) { $diagnostics.decision=[string]$result.decision }
                        $completed = [string]$result.status -eq 'opened' -and [bool]$result.opened -and
                            (-not $composerRequired -or [bool]$result.composerPopulated)
                        $message = if ($completed) {
                            if ($composerRequired) { 'Standalone ChatGPT Popout opened, pinned, and filled.' }
                            else { 'Standalone ChatGPT Popout opened and pinned.' }
                        } elseif ($result.reason) { [string]$result.reason }
                        else { 'The standalone ChatGPT Popout could not be opened.' }
                    } catch {
                        $message = $_.Exception.Message
                    }
                    if ($script:RequestTimingSink) { [void](& $script:RequestTimingSink @{stage='final_verification';phase='start'}) }
                    try { Update-PopupPinHotkeyTarget } finally {
                        $windowControlReady = $false
                        if (-not $TestToken) {
                            # Positive identity from final inspection plus the exact
                            # guarded startup target; independent of paste success.
                            $windowControlReady = [CogentSpec.PopoutWorkspaceLifecycle]::EndHandoff($handoffStarted -and $script:CurrentPopupWindowHandle -ne 0)
                        }
                        if ($script:RequestTimingSink -and -not $TestToken -and $script:CurrentPopupWindowHandle -ne 0) {
                            try {
                                $h = [IntPtr]$script:CurrentPopupWindowHandle
                                [void](& $script:RequestTimingSink @{stage='handoff_release';phase='point';handle=$h.ToInt64();
                                    foreground=[CogentSpec.ChatGptPopupNative]::IsForeground($h);
                                    visible=[CogentSpec.ChatGptPopupNative]::IsVisible($h);
                                    pinned=[CogentSpec.ChatGptPopupNative]::IsTopmost($h)})
                            } catch { $timingState.truncated = $true }
                        }
                        if ($script:RequestTimingSink) { [void](& $script:RequestTimingSink @{stage='final_verification';phase='end'}) }
                        $script:RequestTimingSink = $null
                    }
                    if ($timingState.milestones.Count -gt 0 -or $timingState.groups.Count -gt 0 -or $timingState.truncated) {
                        try {
                            $diagnostics.timings = @(@($timingState.milestones.ToArray()) + @($timingState.groups.Values) | Sort-Object elapsedMs)
                            $diagnostics.timingTruncated = $timingState.truncated
                        } catch {
                            # Optional evidence must never prevent terminal reporting.
                            $diagnostics.timings = @()
                            $diagnostics.timingTruncated = $true
                        }
                    }
                    [void](Invoke-PopoutApi -Method Patch -Path "/api/plugin/desktop-popout-actions$query" -Token $token -Body @{
                        requestId = [string]$request.id
                        action = if ($completed) { 'complete' } else { 'fail' }
                        statusMessage = $message
                        windowControlReady = $windowControlReady
                        diagnostics = $diagnostics
                    })
                }
            }
        } catch {
            $consecutiveFailures++
            $statusCode = Get-HttpStatusCode -Failure $_
            $authorizationFailure = $statusCode -eq 401 -or $statusCode -eq 403
            $errorKind = if ($authorizationFailure) { 'authorization_failure' }
                elseif ($statusCode -gt 0) { "http_$statusCode" }
                else { 'transport_failure' }
            Write-ReadyMarker -ServerAcknowledged $false -Status 'retrying' -LastError $errorKind
            if ($authorizationFailure -and -not $TestToken) {
                try { $token = Read-DesktopToken } catch { }
            }
        }
        $polls++
        if ($MaxPolls -gt 0 -and $polls -ge $MaxPolls) { break }
        $retryExponent = [Math]::Min(5, [Math]::Max(0, $consecutiveFailures - 1))
        $retryMilliseconds = if ($consecutiveFailures -gt 0) {
            [Math]::Min($MaximumRetryMilliseconds, [int]($PollMilliseconds * [Math]::Pow(2, $retryExponent)))
        } else { $PollMilliseconds }
        $waitDeadline = [DateTime]::UtcNow.AddMilliseconds($retryMilliseconds)
        do {
            $remainingMilliseconds = [int][Math]::Max(0, ($waitDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min(1500, $remainingMilliseconds))
            Update-PopupPinHotkeyTarget
            if (([DateTime]::UtcNow - $script:WorkspaceLifecycleSeenAt).TotalSeconds -gt 90) {
                $script:WorkspaceLifecycleState = 'unknown'
            }
            if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Tick($script:WorkspaceLifecycleState) }
        } while ([DateTime]::UtcNow -lt $waitDeadline)
    }
} finally {
    if (-not $TestToken) { [CogentSpec.PopoutControlTransport]::Stop() }
    if (-not $TestToken) { [CogentSpec.PopoutWorkspaceLifecycle]::Stop() }
    if ($script:PinHotkeyReady) {
        [CogentSpec.ChatGptPopupPinHotkey]::Stop()
        $script:PinHotkeyReady = $false
    }
    $token = $null
}
