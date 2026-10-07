// SmartDock.exe: tiny launcher that starts SmartDock.ps1 hidden (no console flash).
// Extra arguments (for example -Restore) are passed through to the script.
using System;
using System.Diagnostics;
using System.IO;

static class Launcher
{
    static void Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "SmartDock.ps1");
        if (!File.Exists(script)) return;
        string extra = args.Length > 0 ? " " + string.Join(" ", args) : "";
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"" + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
