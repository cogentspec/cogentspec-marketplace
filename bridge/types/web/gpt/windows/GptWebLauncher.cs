using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32;

// Dedicated GPTWeb Bridge installer/launcher. The Windows GUI subsystem avoids
// a console; this executable creates no application window or setup wizard.
internal static class GptWebLauncher {
    const string Version = "0.2.1";
    const string Origin = "https://cogentspec.app";
    const string Startup = Origin + "/api/bridge/gptweb/startup";
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 65536 };
    static readonly Regex Uuid = new Regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$");
    static readonly Regex Context = new Regex("^ctx-[a-f0-9]{64}$");
    static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CogentSpec", "gptweb-native");
    static string Text(IDictionary<string, object> value, string key) { object result; return value.TryGetValue(key, out result) && result is string ? (string)result : ""; }
    static string Hash(byte[] bytes) { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
    static string Quote(string value) { return "\"" + Regex.Replace(Regex.Replace(value, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\""; }

    internal static string RequestId(string value) {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != "cogentspec-gptweb" || uri.Host != "connect"
            || !uri.IsDefaultPort || uri.UserInfo != "" || uri.Fragment != "" || (uri.AbsolutePath != "" && uri.AbsolutePath != "/")) return null;
        const string prefix = "?request=";
        if (!uri.Query.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var id = uri.Query.Substring(prefix.Length);
        return Uuid.IsMatch(id) ? id : null;
    }
    static void SafeDirectory(string path) {
        var full = Path.GetFullPath(path);
        for (var current = full; !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current)) {
            if (File.Exists(current) || Directory.Exists(current)) {
                var attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
                    throw new InvalidOperationException("GPTWeb's installation folder is not a plain directory.");
            }
        }
    }
    static void PlainFile(string path) {
        SafeDirectory(Path.GetDirectoryName(path));
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("GPTWeb's installation file cannot be a link.");
    }
    static byte[] Download(string url, byte[] body) {
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.AllowAutoRedirect = false; request.Timeout = 15000; request.ReadWriteTimeout = 15000;
        request.Accept = "application/json";
        if (body != null) {
            request.Method = "POST"; request.ContentType = "application/json"; request.ContentLength = body.Length;
            using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
        }
        using (var response = (HttpWebResponse)request.GetResponse()) {
            if (response.StatusCode != HttpStatusCode.OK) throw new InvalidOperationException("GPTWeb's trusted setup service did not respond.");
            using (var input = response.GetResponseStream()) using (var output = new MemoryStream()) {
                input.CopyTo(output); if (output.Length > 1024 * 1024) throw new InvalidOperationException("GPTWeb setup response is too large.");
                return output.ToArray();
            }
        }
    }
    static Dictionary<string, object> Post(Dictionary<string, object> body) { return Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(Download(Startup, Encoding.UTF8.GetBytes(Json.Serialize(body))))); }
    static void Report(string request, string status, string approval = null) {
        if (!Uuid.IsMatch(request ?? "")) return;
        try {
            var body = new Dictionary<string, object> { { "operation", "report" }, { "requestId", request }, { "status", status } };
            if (approval != null) body.Add("approvalUrl", approval);
            Post(body);
        } catch { }
    }
    static string ProfileContext() {
        SafeDirectory(Root); Directory.CreateDirectory(Root);
        var path = Path.Combine(Root, "profile.json"); PlainFile(path);
        if (File.Exists(path)) {
            var value = Text(Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path)), "contextKey");
            if (!Context.IsMatch(value)) throw new InvalidOperationException("GPTWeb's saved workspace identity is invalid.");
            return value;
        }
        var bytes = new byte[32]; using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
        var created = "ctx-" + BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            var content = Encoding.UTF8.GetBytes(Json.Serialize(new Dictionary<string, object> { { "version", 1 }, { "contextKey", created } }));
            stream.Write(content, 0, content.Length);
        }
        return created;
    }
    static string Bootstrap() {
        var release = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(Download(Origin + "/api/bridge/gptweb/native-release", null)));
        var digest = Text(release, "bootstrapSha256");
        if (Text(release, "protocol") != "cogentspec-gptweb-native-release-v1" || Text(release, "command") != "$gptweb"
            || !Regex.IsMatch(digest, "^[a-f0-9]{64}$")) throw new InvalidOperationException("GPTWeb's release identity is invalid.");
        SafeDirectory(Root); Directory.CreateDirectory(Root);
        var path = Path.Combine(Root, "bootstrap-" + digest + ".ps1"); PlainFile(path);
        if (!File.Exists(path)) {
            var bytes = Download(Origin + "/api/bridge/gptweb/native-bootstrap", null);
            if (Hash(bytes) != digest) throw new InvalidOperationException("GPTWeb's setup bytes did not match the trusted release.");
            using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Write(bytes, 0, bytes.Length);
        }
        if (Hash(File.ReadAllBytes(path)) != digest) throw new InvalidOperationException("GPTWeb's installed setup bytes changed.");
        return path;
    }
    internal static ProcessStartInfo VerifiedPowerShell(string file, string context, string request, bool prepare, bool resume, bool enroll) {
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"));
        // Only this child session uses the embedded application's verified
        // script policy. No user/machine policy is written; Group Policy wins.
        info.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(file) + " -ContextKey " + context
            + (prepare ? " -PrepareOnly" : enroll ? " -EnrollOnly" : " -StartupRequest " + request) + (resume ? " -ResumeApproval" : "");
        // A test-owned application proxy must cover the complete native chain.
        // Retain the original HTTPS origins and normal certificate validation;
        // never change the Windows user's proxy or another connector's process.
        var proxy = WebRequest.DefaultWebProxy;
        var origin = new Uri(Origin);
        var transport = proxy != null && !proxy.IsBypassed(origin) ? proxy.GetProxy(origin) : null;
        if (transport != null && transport.Scheme == "http" && transport.Host == "127.0.0.1"
            && transport.Port >= 1024 && transport.UserInfo == "" && transport.AbsolutePath == "/"
            && transport.Query == "" && transport.Fragment == "") {
            var endpoint = transport.GetLeftPart(UriPartial.Authority);
            var command = "$ProgressPreference='SilentlyContinue'; [Net.WebRequest]::DefaultWebProxy=New-Object Net.WebProxy('" + endpoint + "'); & '" + file.Replace("'", "''")
                + "' -ContextKey '" + context + "'" + (prepare ? " -PrepareOnly" : enroll ? " -EnrollOnly" : " -StartupRequest '" + request + "'")
                + (resume ? " -ResumeApproval" : "");
            info.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "
                + Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
            info.EnvironmentVariables["COGENTSPEC_GPTWEB_LOOPBACK_PROXY"] = endpoint;
        }
        info.UseShellExecute = false; info.CreateNoWindow = true; info.WindowStyle = ProcessWindowStyle.Hidden;
        info.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        info.RedirectStandardOutput = true; info.RedirectStandardError = true;
        return info;
    }
    static Dictionary<string, object> Run(string context, string request, bool prepare, bool resume, bool enroll = false) {
        if (!Context.IsMatch(context) || (!prepare && !enroll && !Uuid.IsMatch(request ?? ""))) throw new InvalidOperationException("GPTWeb's setup request is invalid.");
        var info = VerifiedPowerShell(Bootstrap(), context, request, prepare, resume, enroll);
        using (var child = Process.Start(info)) {
            var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
            if (!child.WaitForExit(170000)) { child.Kill(); throw new InvalidOperationException("GPTWeb setup reached its time limit."); }
            Task.WaitAll(new Task[] { stdout, stderr }, 5000);
            if (!stdout.IsCompleted || child.ExitCode != 0) throw new InvalidOperationException("GPTWeb setup could not finish.");
            var lines = stdout.Result.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (var i = lines.Length - 1; i >= 0; --i) if (lines[i].StartsWith("{", StringComparison.Ordinal)) {
                var result = Json.Deserialize<Dictionary<string, object>>(lines[i]);
                if (Text(result, "protocol") != "cogentspec-gptweb-native-v1") throw new InvalidOperationException("GPTWeb returned an unexpected setup protocol.");
                return result;
            }
            throw new InvalidOperationException("GPTWeb did not return a verified startup result.");
        }
    }
    static string RequestedContext(string request) {
        var result = Post(new Dictionary<string, object> { { "operation", "info" }, { "requestId", request } });
        if (Text(result, "protocol") != "cogentspec-gptweb-startup-v1" || Text(result, "command") != "$gptweb") throw new InvalidOperationException("GPTWeb's request is unavailable.");
        var context = Text(result, "requestedContext");
        if (context != "" && !Context.IsMatch(context)) throw new InvalidOperationException("GPTWeb's requested workspace is invalid.");
        return context == "" ? ProfileContext() : context;
    }
    static void InstallProtocol() {
        SafeDirectory(Root); Directory.CreateDirectory(Root);
        var target = Path.Combine(Root, "CogentSpec.GPTWeb." + Version + ".exe"); PlainFile(target);
        var source = Assembly.GetExecutingAssembly().Location;
        if (!String.Equals(Path.GetFullPath(source), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase)
            && (!File.Exists(target) || Hash(File.ReadAllBytes(target)) != Hash(File.ReadAllBytes(source)))) File.Copy(source, target, true);
        const string key = @"Software\Classes\cogentspec-gptweb";
        using (var old = Registry.CurrentUser.OpenSubKey(key + @"\shell\open\command")) {
            if (old != null) {
                var command = old.GetValue("") as string ?? "";
                if (!command.StartsWith("\"" + Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The GPTWeb protocol is registered to another application.");
            }
        }
        using (var protocol = Registry.CurrentUser.CreateSubKey(key)) {
            protocol.SetValue("", "URL:CogentSpec GPTWeb"); protocol.SetValue("URL Protocol", "");
            using (var command = protocol.CreateSubKey(@"shell\open\command")) command.SetValue("", Quote(target) + " \"%1\"");
        }
    }
    static void QuietStart(string request) {
        try {
            Report(request, "starting");
            using (var gate = new Mutex(false, @"Local\CogentSpec.GPTWeb.Setup.V1")) {
                bool held;
                try { held = gate.WaitOne(175000); } catch (AbandonedMutexException) { held = true; }
                if (!held) { Report(request, "setup_failed"); return; }
                try {
                    var context = RequestedContext(request);
                    var deadline = DateTime.UtcNow.AddSeconds(280);
                    bool resume = false;
                    while (DateTime.UtcNow < deadline) {
                        var result = Run(context, request, false, resume);
                        var status = Text(result, "status");
                        if (status == "ready") { InstallProtocol(); return; }
                        if (status != "approval_required") { Report(request, "setup_failed"); return; }
                        // Show genuine device permission in the already signed-in
                        // web tab. Never approve it or open an installer window.
                        Uri approval;
                        if (!Uri.TryCreate(Text(result, "approvalUrl"), UriKind.Absolute, out approval)
                            || approval.GetLeftPart(UriPartial.Authority) != "https://cogentspec.com"
                            || approval.AbsolutePath != "/activate" || approval.Fragment != "")
                            throw new InvalidOperationException("Invalid computer approval.");
                        Report(request, "approval_required", approval.AbsoluteUri);
                        Thread.Sleep(5000); resume = true;
                    }
                    Report(request, "setup_failed");
                } finally { gate.ReleaseMutex(); }
            }
        } catch { Report(request, "setup_failed"); }
    }
    internal static string InstallerRequestId(string filename) {
        var match = Regex.Match(filename, "^CogentSpec-GPTWeb-Bridge-([a-f0-9-]{36})(?: \\(\\d+\\))?\\.exe$", RegexOptions.CultureInvariant);
        return match.Success && Uuid.IsMatch(match.Groups[1].Value) ? match.Groups[1].Value : null;
    }
    [STAThread] static int Main(string[] args) {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        if (args.Length == 2 && args[0] == "--validate-uri") return RequestId(args[1]) == null ? 64 : 0;
        if (args.Length == 2 && args[0] == "--validate-filename") return InstallerRequestId(args[1]) == null ? 64 : 0;
        if (args.Length == 1) {
            var request = RequestId(args[0]); if (request == null) return 64;
            QuietStart(request); return 0;
        }
        if (args.Length != 0) return 64;
        var id = InstallerRequestId(Path.GetFileName(Assembly.GetExecutingAssembly().Location));
        if (id == null) return 64;
        QuietStart(id); return 0;
    }
}
