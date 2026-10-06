using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace CogentSpecBrowser {
 public static class Framing {
  public static byte[] Read(Stream input) {
   var header = new byte[4]; int count = Fill(input, header);
   if (count == 0) return null;
   if (count != 4) throw new InvalidDataException("Truncated frame");
   uint size = BitConverter.ToUInt32(header, 0);
   if (size == 0 || size > 65536) throw new InvalidDataException("Invalid frame length");
   var body = new byte[(int)size];
   if (Fill(input, body) != body.Length) throw new InvalidDataException("Truncated message");
   return body;
  }
  static int Fill(Stream input, byte[] bytes) {
   int total = 0, next;
   while (total < bytes.Length && (next = input.Read(bytes, total, bytes.Length-total)) > 0) total += next;
   return total;
  }
  public static void Write(Stream output, byte[] bytes) {
   var length = BitConverter.GetBytes(bytes.Length);
   output.Write(length, 0, 4); output.Write(bytes, 0, bytes.Length); output.Flush();
  }
 }
 public static class Host {
  [StructLayout(LayoutKind.Sequential)] struct BasicInfo {
   public IntPtr Reserved1, PebBaseAddress, Reserved2a, Reserved2b, UniqueProcessId, ParentProcessId;
  }
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle, int type, ref BasicInfo info, int length, out int returned);
  static JavaScriptSerializer json = new JavaScriptSerializer {MaxJsonLength = 65536};
  static string Session;
  static long Sequence;
  static Dictionary<string, object> Last;
  static string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CogentSpec", "browser-lifecycle");
  static string StatePath;
  static Process Browser;
  static void Save(Dictionary<string, object> message) {
   message["observedAt"] = DateTime.UtcNow.ToString("o");
   message["browserProcessId"] = Browser.Id;
   message["browserStartedAt"] = Browser.StartTime.ToUniversalTime().ToString("o");
   message["hostProcessId"] = Process.GetCurrentProcess().Id;
   string temporary = StatePath + "." + Process.GetCurrentProcess().Id + ".tmp";
   File.WriteAllText(temporary, json.Serialize(message), new UTF8Encoding(false));
   if (File.Exists(StatePath)) File.Replace(temporary, StatePath, null); else File.Move(temporary, StatePath);
   // Fixed, validated fields let the PowerShell 5/7 controller read snapshots
   // without depending on a particular .NET JSON runtime.
   string authorityPath = Path.ChangeExtension(StatePath, ".state");
   string authorityTemp = authorityPath + "." + Process.GetCurrentProcess().Id + ".tmp";
   File.WriteAllText(authorityTemp, String.Join("|", new string[] {"1", Session, Sequence.ToString(),
    (string)message["state"], DateTime.UtcNow.Ticks.ToString(), Browser.Id.ToString(),
    Browser.StartTime.ToUniversalTime().Ticks.ToString()}), new UTF8Encoding(false));
   if (File.Exists(authorityPath)) File.Replace(authorityTemp, authorityPath, null); else File.Move(authorityTemp, authorityPath);
  }
  public static int Main(string[] args) {
   try {
    var config = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Root, "registration.json")));
    string origin = (string)config["origin"];
    if (args.Length == 0 || args[0] != origin) return 2;
    BasicInfo info = new BasicInfo(); int returned;
    using (var current = Process.GetCurrentProcess()) {
     if (NtQueryInformationProcess(current.Handle, 0, ref info, Marshal.SizeOf(info), out returned) != 0) return 3;
    }
    Browser = Process.GetProcessById(info.ParentProcessId.ToInt32());
    if (!String.Equals(Browser.ProcessName, (string)config["processName"], StringComparison.OrdinalIgnoreCase)) return 4;
    var input = Console.OpenStandardInput(); var output = Console.OpenStandardOutput();
    byte[] frame;
    while ((frame = Framing.Read(input)) != null) {
     var m = json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(frame));
     if ((string)m["protocol"] != "cogentspec-browser-lifecycle-v1") throw new InvalidDataException("Protocol");
     Guid id;
     if (!Guid.TryParseExact((string)m["sessionId"], "D", out id)) throw new InvalidDataException("Session");
     if (Session != null && Session != id.ToString()) throw new InvalidDataException("Session changed on port");
     long next = Convert.ToInt64(m["sequence"]);
     if (next <= Sequence || next > 9007199254740991L) throw new InvalidDataException("Sequence");
     string state = (string)m["state"];
     if (state != "active" && state != "hidden" && state != "blurred" && state != "closed") throw new InvalidDataException("State");
     var tabs = m["workspaceTabs"] as IList;
     if (tabs == null || tabs.Count > 128 || (state == "closed") != (tabs.Count == 0)) throw new InvalidDataException("Tabs");
     var sanitized = new List<object>();
     foreach (Dictionary<string, object> tab in tabs) {
      int tabId = Convert.ToInt32(tab["id"]), windowId = Convert.ToInt32(tab["windowId"]);
      if (tabId < 0 || windowId < 0 || !(tab["active"] is bool)) throw new InvalidDataException("Tab identity");
      sanitized.Add(new {id = tabId, windowId = windowId, active = (bool)tab["active"]});
     }
     Session = id.ToString(); Sequence = next;
     StatePath = Path.Combine(Root, Session + ".json");
     Last = new Dictionary<string, object> {{"protocol", "cogentspec-browser-lifecycle-v1"}, {"sessionId", Session},
      {"sequence", Sequence}, {"state", state}, {"workspaceTabs", sanitized}};
     Save(Last);
     Framing.Write(output, Encoding.UTF8.GetBytes(json.Serialize(new {accepted = true, sequence = Sequence})));
    }
    return 0;
   } catch { return 1; }
   finally {
    // Disconnect is not proof that a workspace tab closed. Parent process death
    // is checked independently by the controller, including abrupt browser exit.
    if (Last != null) { try { Last["state"] = "disconnected"; Save(Last); } catch {} }
   }
  }
 }
}
