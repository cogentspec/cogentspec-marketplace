using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;

// A Windows GUI application, not a console executable. Only the fixed package
// script and one validated browser handoff can be started.
internal static class QwenWindowlessLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 1 || !Regex.IsMatch(args[0], @"\Acogentspec-browser://qwenlocal/[a-f0-9]{64}\z")) return 2;
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "scripts", "start-qwenlocal.ps1");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(script) || !File.Exists(powershell)) return 3;
            var start = new ProcessStartInfo(powershell);
            start.Arguments = "-NoProfile -NonInteractive -File \"" + script + "\" -Uri \"" + args[0] + "\"";
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process process = Process.Start(start)) return process == null ? 4 : 0;
        }
        catch { return 1; } // Never display or log the one-use handoff.
    }
}
