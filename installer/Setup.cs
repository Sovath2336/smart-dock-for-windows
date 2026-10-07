// SmartDock-Setup.exe: per-user installer / uninstaller (no admin rights needed).
//   SmartDock-Setup.exe              interactive install
//   SmartDock-Setup.exe /S           silent install with defaults (add /dir="C:\path" to change location)
//   Uninstall.exe [/S]               remove (the installer copies itself into the install folder as Uninstall.exe)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    public const string Ver = "1.0.0";
    const string UKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\SmartDock";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    [STAThread]
    static int Main(string[] args)
    {
        bool silent = false, uninstall = false; string dir = null;
        foreach (string a in args)
        {
            string l = a.ToLowerInvariant();
            if (l == "/s" || l == "/silent") silent = true;
            else if (l == "/uninstall") uninstall = true;
            else if (l.StartsWith("/dir=")) dir = a.Substring(5).Trim('"');
        }
        if (Path.GetFileName(Application.ExecutablePath).ToLowerInvariant() == "uninstall.exe") uninstall = true;
        if (dir == null) dir = DefaultDir();
        Application.EnableVisualStyles();
        try
        {
            if (uninstall)
            {
                if (!silent && MessageBox.Show("Remove Smart Dock from this computer?", "Smart Dock", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return 1;
                Uninstall();
                if (!silent) MessageBox.Show("Smart Dock was removed.", "Smart Dock", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            if (silent) { Install(dir, true, true, false); Launch(dir); return 0; }
            Application.Run(new SetupForm(dir));
            return 0;
        }
        catch (Exception ex)
        {
            if (!silent) MessageBox.Show(ex.Message, "Smart Dock setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }

    public static string DefaultDir()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Smart Dock");
    }

    // ---- helpers ----
    static void Extract(string resource, string target)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        using (FileStream f = File.Create(target)) s.CopyTo(f);
    }

    static void StopDock()
    {
        using (ManagementObjectSearcher q = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
            foreach (ManagementObject mo in q.Get())
            {
                string cmd = mo["CommandLine"] as string;
                if (cmd != null && cmd.IndexOf("SmartDock.ps1", StringComparison.OrdinalIgnoreCase) >= 0)
                    try { Process.GetProcessById((int)(uint)mo["ProcessId"]).Kill(); } catch { }
            }
        System.Threading.Thread.Sleep(400);
    }

    // The dock hides taskbar buttons; if it was killed, give them back.
    static void RestoreTaskbar(string dir)
    {
        string script = Path.Combine(dir, "SmartDock.ps1");
        if (!File.Exists(script)) return;
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\" -Restore");
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        using (Process p = Process.Start(psi)) p.WaitForExit(15000);
    }

    static void MakeLink(string path, string target, string workDir, string desc)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object sh = Activator.CreateInstance(t);
        object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { path });
        Type lt = lnk.GetType();
        lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
        lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { workDir });
        lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { desc });
        lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { target + ",0" });
        lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
    }
    static string StartMenuLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Smart Dock.lnk"); } }
    static string DesktopLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Smart Dock.lnk"); } }
    static string OldStartupLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Smart Dock.lnk"); } }
    static void DeleteQuiet(string f) { try { if (File.Exists(f)) File.Delete(f); } catch { } }

    // ---- install / uninstall ----
    public static void Install(string dir, bool autostart, bool startMenu, bool desktop)
    {
        StopDock();
        Directory.CreateDirectory(dir);
        string exe = Path.Combine(dir, "SmartDock.exe");
        Extract("SmartDock.ps1", Path.Combine(dir, "SmartDock.ps1"));
        Extract("SmartDock.exe", exe);
        string un = Path.Combine(dir, "Uninstall.exe");
        if (!string.Equals(Application.ExecutablePath, un, StringComparison.OrdinalIgnoreCase)) File.Copy(Application.ExecutablePath, un, true);

        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(UKey))
        {
            k.SetValue("DisplayName", "Smart Dock for Windows");
            k.SetValue("DisplayVersion", Ver);
            k.SetValue("Publisher", "Smart Dock");
            k.SetValue("InstallLocation", dir);
            k.SetValue("DisplayIcon", exe);
            k.SetValue("UninstallString", "\"" + un + "\"");
            k.SetValue("QuietUninstallString", "\"" + un + "\" /S");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        if (startMenu) MakeLink(StartMenuLnk, exe, dir, "Smart Dock for Windows"); else DeleteQuiet(StartMenuLnk);
        if (desktop) MakeLink(DesktopLnk, exe, dir, "Smart Dock for Windows"); else DeleteQuiet(DesktopLnk);
        DeleteQuiet(OldStartupLnk);   // avoid a duplicate autostart entry from earlier manual setups
        using (RegistryKey r = Registry.CurrentUser.CreateSubKey(RunKey))
        {
            if (autostart) r.SetValue("SmartDock", "\"" + exe + "\""); else r.DeleteValue("SmartDock", false);
        }
        RestoreTaskbar(dir);
    }

    public static void Launch(string dir)
    {
        string exe = Path.Combine(dir, "SmartDock.exe");
        if (File.Exists(exe)) Process.Start(exe);
    }

    static void Uninstall()
    {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UKey))
        {
            object loc = (k == null) ? null : k.GetValue("InstallLocation");
            if (loc != null) dir = loc.ToString();
        }
        StopDock();
        RestoreTaskbar(dir);
        DeleteQuiet(StartMenuLnk); DeleteQuiet(DesktopLnk); DeleteQuiet(OldStartupLnk);
        using (RegistryKey r = Registry.CurrentUser.OpenSubKey(RunKey, true)) { if (r != null) r.DeleteValue("SmartDock", false); }
        Registry.CurrentUser.DeleteSubKeyTree(UKey, false);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\SmartDock", false);
        // this exe may live in the folder being removed, so delete it after we exit
        ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 4 >nul & rmdir /s /q \"" + dir + "\"");
        psi.CreateNoWindow = true; psi.UseShellExecute = false;
        Process.Start(psi);
    }
}

class SetupForm : Form
{
    readonly TextBox path = new TextBox();
    readonly CheckBox cAuto = new CheckBox(), cMenu = new CheckBox(), cDesk = new CheckBox(), cRun = new CheckBox();
    readonly Button go = new Button();

    public SetupForm(string dir)
    {
        Text = "Smart Dock for Windows - Setup";
        ClientSize = new Size(480, 330);
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        Panel head = new Panel(); head.SetBounds(0, 0, 480, 74); head.BackColor = Color.FromArgb(32, 32, 36); Controls.Add(head);
        Label t = new Label(); t.Text = "Smart Dock for Windows"; t.ForeColor = Color.White; t.Font = new Font("Segoe UI Semibold", 15f); t.SetBounds(20, 12, 440, 30); head.Controls.Add(t);
        Label s = new Label(); s.Text = "Version " + Program.Ver + "  -  your open windows in one floating grid"; s.ForeColor = Color.Gainsboro; s.SetBounds(22, 44, 440, 20); head.Controls.Add(s);

        Label l = new Label(); l.Text = "Install to:"; l.SetBounds(20, 92, 200, 20); Controls.Add(l);
        path.Text = dir; path.SetBounds(20, 114, 350, 24); Controls.Add(path);
        Button b = new Button(); b.Text = "Browse..."; b.SetBounds(378, 112, 82, 27); Controls.Add(b);
        b.Click += delegate
        {
            using (FolderBrowserDialog f = new FolderBrowserDialog())
                if (f.ShowDialog() == DialogResult.OK) path.Text = Path.Combine(f.SelectedPath, "Smart Dock");
        };

        Check(cAuto, "Start Smart Dock when I sign in to Windows", 20, 156, true);
        Check(cMenu, "Create a Start menu shortcut", 20, 182, true);
        Check(cDesk, "Create a desktop shortcut", 20, 208, false);
        Check(cRun, "Launch Smart Dock when setup finishes", 20, 234, true);

        Label note = new Label(); note.Text = "Installs for the current user only. No administrator rights needed."; note.ForeColor = Color.DimGray; note.SetBounds(20, 268, 440, 18); Controls.Add(note);
        go.Text = "Install"; go.SetBounds(290, 290, 82, 28); Controls.Add(go);
        Button cancel = new Button(); cancel.Text = "Cancel"; cancel.SetBounds(378, 290, 82, 28); cancel.Click += delegate { Close(); }; Controls.Add(cancel);
        AcceptButton = go; CancelButton = cancel;
        go.Click += delegate { DoInstall(); };
    }
    void Check(CheckBox c, string text, int x, int y, bool on) { c.Text = text; c.Checked = on; c.SetBounds(x, y, 440, 22); Controls.Add(c); }

    void DoInstall()
    {
        go.Enabled = false; Cursor = Cursors.WaitCursor;
        try
        {
            string dir = path.Text.Trim();
            Program.Install(dir, cAuto.Checked, cMenu.Checked, cDesk.Checked);
            if (cRun.Checked) Program.Launch(dir);
            MessageBox.Show("Smart Dock is installed.\n\nUninstall it any time from Settings > Apps.", "Smart Dock", MessageBoxButtons.OK, MessageBoxIcon.Information);
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Install failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            go.Enabled = true; Cursor = Cursors.Default;
        }
    }
}
