using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;

// This is a fixed GPTWeb browser handler, never a shell/tool endpoint. The URI
// carries one opaque request ID. Account, device and context are checked online
// by connect.ps1 before any worker is started. No URL supplies a file or command.
internal static class GptWebBrowserHost {
    internal static string RequestId(string value) {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != "cogentspec-gptweb"
            || uri.Host != "connect" || !uri.IsDefaultPort || uri.UserInfo != "" || uri.Fragment != ""
            || (uri.AbsolutePath != "" && uri.AbsolutePath != "/") || !uri.Query.StartsWith("?request=", StringComparison.Ordinal)) return null;
        var id = uri.Query.Substring(9);
        return Regex.IsMatch(id, "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$") ? id : null;
    }
    [STAThread] static int Main(string[] args) {
        if (args.Length == 2 && args[0] == "--check-uri") return RequestId(args[1]) == null ? 64 : 0;
        if (args.Length != 1) return 64;
        var id = RequestId(args[0]); if (id == null) return 64;
        try {
            var root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            var script = Path.Combine(root, "connect.ps1");
            if (!File.Exists(script) || (File.GetAttributes(script) & FileAttributes.ReparsePoint) != 0) return 65;
            // Validate the complete installed source inventory on every launch.
            var manifest = File.ReadAllLines(Path.Combine(root, "files.sha256"));
            foreach (var line in manifest) {
                if (line.Length < 67 || line.Substring(64, 2) != "  ") return 65;
                var relative = line.Substring(66);
                if (!Regex.IsMatch(line.Substring(0, 64), "^[a-f0-9]{64}$") || relative.Contains("..") || Path.IsPathRooted(relative)) return 65;
                var path = Path.GetFullPath(Path.Combine(root, relative));
                if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return 65;
                using (var sha = System.Security.Cryptography.SHA256.Create()) {
                    var actual = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(path))).Replace("-", "").ToLowerInvariant();
                    if (actual != line.Substring(0, 64)) return 65;
                }
            }
            var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"));
            info.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -RequestId " + id;
            info.UseShellExecute = false; info.CreateNoWindow = true; info.WindowStyle = ProcessWindowStyle.Hidden;
            info.WorkingDirectory = root;
            info.EnvironmentVariables.Remove("CODEX_THREAD_ID"); info.EnvironmentVariables.Remove("CODEX_SESSION_ID");
            info.EnvironmentVariables["PSModulePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules")
                + ";" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules");
            using (var process = Process.Start(info)) {
                if (!process.WaitForExit(60000)) { process.Kill(); return 70; }
                return process.ExitCode;
            }
        } catch { return 70; }
    }
}
