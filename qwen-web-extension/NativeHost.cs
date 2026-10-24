using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CogentSpecQwenWeb {
 public static class Protocol {
  public static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 8192 };
  public static byte[] Read(Stream input) {
   var header = new byte[4];
   if (Fill(input, header) != 4) throw new InvalidDataException();
   uint length = BitConverter.ToUInt32(header, 0);
   if (length == 0 || length > 2048) throw new InvalidDataException();
   var bytes = new byte[(int)length];
   if (Fill(input, bytes) != bytes.Length) throw new InvalidDataException();
   return bytes;
  }
  static int Fill(Stream stream, byte[] bytes) {
   int count = 0, next;
   while (count < bytes.Length && (next = stream.Read(bytes, count, bytes.Length-count)) > 0) count += next;
   return count;
  }
  public static void Write(Stream output, object message) {
   var bytes = Encoding.UTF8.GetBytes(Json.Serialize(message));
   output.Write(BitConverter.GetBytes(bytes.Length),0,4); output.Write(bytes,0,bytes.Length); output.Flush();
  }
  public static bool True(Dictionary<string, object> value, string key) { return value.ContainsKey(key) && value[key] is bool && (bool)value[key]; }
  public static string Text(Dictionary<string, object> value, string key) { return value.ContainsKey(key) ? value[key] as string : null; }
  public static object Execute(byte[] bytes, Func<string, Dictionary<string, object>> connect) {
   var request = Json.Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(bytes));
   Guid id;
   if (request.Count != 4 || Text(request,"protocol") != "cogentspec-qwen-web-command-v1" || Text(request,"command") != "$qwenweb"
     || !Guid.TryParseExact(Text(request,"requestId"),"D",out id)
     || !Regex.IsMatch(Text(request,"contextKey") ?? "", "^ctx-[a-f0-9]{64}$")) throw new InvalidDataException();
   var result = connect(Text(request,"contextKey"));
   bool verified = Text(result,"protocol") == "cogentspec-workspace-beacon-start-v1" && Text(result,"status") == "connected"
     && Text(result,"surface") == "qwen-web" && Text(result,"experience") == "web"
     && Text(result,"browserHandoff") == "authenticated-workspace-reuse"
     && True(result,"workspaceConnected") && True(result,"acknowledgementVerified") && True(result,"browserReused")
     && result.ContainsKey("browserOpened") && result["browserOpened"] is bool && !(bool)result["browserOpened"];
   // Never forward helper text, context, credentials, handoff material or paths.
   return new { protocol="cogentspec-workspace-beacon-start-v1", requestId=id.ToString(), status=verified?"connected":"not_connected",
    workspaceConnected=verified, acknowledgementVerified=verified, browserReused=verified, browserOpened=false,
    browserHandoff="authenticated-workspace-reuse", surface="qwen-web", experience="web" };
  }
 }
 public static class Host {
  [StructLayout(LayoutKind.Sequential)] struct BasicInfo { public IntPtr Reserved, Peb, Reserved2, Reserved3, Id, Parent; }
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int kind,ref BasicInfo info,int length,out int returned);
  static string Hash(string path) { using(var hash=SHA256.Create()) using(var file=File.OpenRead(path)) return BitConverter.ToString(hash.ComputeHash(file)).Replace("-","").ToLowerInvariant(); }
  static Dictionary<string,object> Connect(string context, Dictionary<string,object> config) {
   var helper = Protocol.Text(config,"helperPath");
   if (!Path.IsPathRooted(helper) || Path.GetFileName(helper) != "start-workspace-beacon.ps1" || Hash(helper) != Protocol.Text(config,"helperSha256")) throw new InvalidDataException();
   var start = new ProcessStartInfo {
    FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe"),
    Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+helper+"\" -Surface qwen-web -Experience web -ContextKey "+context,
    WorkingDirectory=Path.GetDirectoryName(helper), UseShellExecute=false, CreateNoWindow=true,
    RedirectStandardOutput=true, RedirectStandardError=true
   };
   using(var process=Process.Start(start)) {
    var output=process.StandardOutput.ReadToEndAsync(); var errors=process.StandardError.ReadToEndAsync();
    if(!process.WaitForExit(55000)) { try {process.Kill();} catch {} throw new TimeoutException(); }
    if(process.ExitCode!=0 || !output.Wait(1000) || !errors.Wait(1000) || output.Result.Length>8192) throw new InvalidDataException();
    return Protocol.Json.Deserialize<Dictionary<string,object>>(output.Result.Trim());
   }
  }
  public static int Main(string[] args) {
   try {
    var configPath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CogentSpec","qwen-web","registration.json");
    if(new FileInfo(configPath).Length>8192) return 2;
    var config=Protocol.Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(configPath));
    if(args.Length==0 || args[0]!=Protocol.Text(config,"origin")) return 3;
    BasicInfo info=new BasicInfo();int length;
    using(var current=Process.GetCurrentProcess()) if(NtQueryInformationProcess(current.Handle,0,ref info,Marshal.SizeOf(info),out length)!=0)return 4;
    using(var parent=Process.GetProcessById(info.Parent.ToInt32()))
     if(!String.Equals(parent.MainModule.FileName,Protocol.Text(config,"browserPath"),StringComparison.OrdinalIgnoreCase))return 5;
    var receipt=Protocol.Execute(Protocol.Read(Console.OpenStandardInput()),context=>Connect(context,config));
    Protocol.Write(Console.OpenStandardOutput(),receipt);return 0;
   } catch { return 1; }
  }
 }
}
