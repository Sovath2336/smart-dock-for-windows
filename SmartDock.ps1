param([switch]$Restore)   # -Restore: put every window's taskbar button back, then exit
# Floating square window dock: shows open (taskbar-style) windows as a grid of icons.
# Left-click a tile = bring window to front (restores if minimized). Right-click a tile = close window.
# Drag the top strip to move. Right-click the strip = auto-hide taskbar toggle / exit. Wheel = scroll.
# Single instance: a second launch exits quietly (not applied to -Restore)
if (-not $Restore) {
    $script:dockMutex = New-Object System.Threading.Mutex($false, 'Local\SmartDockForWindows')
    if (-not $script:dockMutex.WaitOne(0)) { exit }
}
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class Snap { public Bitmap Bmp; public Rectangle R; public DateTime At; }

// Click-through, per-pixel-alpha overlay that shows the animated frames.
public class GenieOverlay : Form
{
    [StructLayout(LayoutKind.Sequential)] struct BLEND { public byte Op, Flags, Alpha, Format; }
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref Point pd, ref Size sz, IntPtr src, ref Point ps, int key, ref BLEND b, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

    public GenieOverlay()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x08000000; return cp; } // LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE
    }
    public void Push(Bitmap bmp, Point loc)
    {
        IntPtr sdc = GetDC(IntPtr.Zero), mdc = CreateCompatibleDC(sdc), hb = bmp.GetHbitmap(Color.FromArgb(0)), old = SelectObject(mdc, hb);
        Size sz = bmp.Size; Point src = Point.Empty, dst = loc;
        BLEND bl = new BLEND(); bl.Op = 0; bl.Flags = 0; bl.Alpha = 255; bl.Format = 1;
        UpdateLayeredWindow(Handle, sdc, ref dst, ref sz, mdc, ref src, 0, ref bl, 2);
        SelectObject(mdc, old); DeleteObject(hb); DeleteDC(mdc); ReleaseDC(IntPtr.Zero, sdc);
    }
}

// Mac-style genie: snapshot a window, then warp it into / out of a dock tile.
public static class Genie
{
    [StructLayout(LayoutKind.Sequential)] struct R4 { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)] struct ANIM { public uint cb; public int minAnimate; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out R4 r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint a, uint p, ref ANIM v, uint ini);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out R4 r, int size);

    static int cache = -1;
    public static bool Enabled
    {
        get
        {
            if (cache < 0)
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\SmartDock"))
                { object v = (k == null) ? null : k.GetValue("Genie"); cache = (v == null || Convert.ToInt32(v) != 0) ? 1 : 0; }
            return cache == 1;
        }
        set
        {
            cache = value ? 1 : 0;
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\SmartDock")) k.SetValue("Genie", cache, RegistryValueKind.DWord);
        }
    }

    public static Snap Capture(IntPtr h)
    {
        try
        {
            if (IsIconic(h) || IsHungAppWindow(h)) return null;
            R4 w; if (!GetWindowRect(h, out w)) return null;
            R4 e; if (DwmGetWindowAttribute(h, 9, out e, Marshal.SizeOf(typeof(R4))) != 0) e = w;
            int ww = w.r - w.l, wh = w.b - w.t;
            if (ww <= 0 || wh <= 0 || ww > 8000 || wh > 8000) return null;
            Rectangle vis = Rectangle.Intersect(new Rectangle(e.l - w.l, e.t - w.t, e.r - e.l, e.b - e.t), new Rectangle(0, 0, ww, wh));
            if (vis.Width <= 0 || vis.Height <= 0) return null;
            Bitmap bm = new Bitmap(vis.Width, vis.Height, PixelFormat.Format32bppArgb);
            using (Bitmap full = new Bitmap(ww, wh, PixelFormat.Format32bppRgb))
            {
                using (Graphics g = Graphics.FromImage(full)) { IntPtr dc = g.GetHdc(); try { PrintWindow(h, dc, 2); } finally { g.ReleaseHdc(dc); } }
                using (Graphics g = Graphics.FromImage(bm))
                {
                    if (!IsZoomed(h))   // round the corners like a Windows 11 window
                    {
                        using (GraphicsPath gp = Rounded(new Rectangle(0, 0, vis.Width, vis.Height), 8)) g.SetClip(gp);
                    }
                    g.DrawImage(full, new Rectangle(0, 0, vis.Width, vis.Height), vis, GraphicsUnit.Pixel);
                }
            }
            bool blank = true;
            for (int i = 1; i < 8 && blank; i++) for (int j = 1; j < 8 && blank; j++)
            { Color c = bm.GetPixel(bm.Width * i / 8, bm.Height * j / 8); if (c.R + c.G + c.B > 0 && c.A > 0) blank = false; }
            if (blank) { bm.Dispose(); return null; }
            Snap s = new Snap(); s.Bmp = bm; s.R = new Rectangle(e.l, e.t, e.r - e.l, e.b - e.t); s.At = DateTime.Now; return s;
        }
        catch { return null; }
    }
    static GraphicsPath Rounded(Rectangle r, int d)
    {
        GraphicsPath p = new GraphicsPath(); int D = d * 2;
        p.AddArc(r.X, r.Y, D, D, 180, 90); p.AddArc(r.Right - D, r.Y, D, D, 270, 90);
        p.AddArc(r.Right - D, r.Bottom - D, D, D, 0, 90); p.AddArc(r.X, r.Bottom - D, D, D, 90, 90);
        p.CloseFigure(); return p;
    }

    // Run the real minimize/restore with Windows' own animation switched off for that instant (not persisted).
    static void NoAnim(Action a)
    {
        ANIM ai = new ANIM(); ai.cb = (uint)Marshal.SizeOf(typeof(ANIM));
        SystemParametersInfo(0x48, ai.cb, ref ai, 0); int old = ai.minAnimate;
        ai.minAnimate = 0; SystemParametersInfo(0x49, ai.cb, ref ai, 0);
        try { a(); System.Threading.Thread.Sleep(40); }
        finally { ai.minAnimate = old; SystemParametersInfo(0x49, ai.cb, ref ai, 0); }
    }

    static float Lerp(float a, float b, float t) { return a + (b - a) * t; }
    static float Smooth(float t) { return t * t * (3 - 2 * t); }
    static float Smoother(float t) { return t * t * t * (t * (t * 6 - 15) + 10); }

    static void Row(float v, float P, Snap s, float ty, float tx, float tw, Point o, out float y, out float cx, out float rw)
    {
        const float k = 0.6f;                              // lag: top rows trail the bottom rows
        float u = Math.Max(0f, Math.Min(1f, P * (1 + k) - (1 - v) * k));
        float h = s.Bmp.Height, w = s.Bmp.Width;
        y = Lerp(s.R.Y - o.Y + v * h, ty, Smooth(u));
        float sx = Smoother(u);
        cx = Lerp(s.R.X - o.X + w / 2f, tx, sx);
        rw = Lerp(w, tw, sx);
    }

    static void Render(Bitmap frame, Snap s, Rectangle tile, Point o, float P)
    {
        using (Graphics g = Graphics.FromImage(frame))
        using (ImageAttributes ia = new ImageAttributes())
        {
            g.Clear(Color.Transparent);
            g.CompositingQuality = CompositingQuality.HighSpeed; g.InterpolationMode = InterpolationMode.Bilinear;
            ia.SetWrapMode(WrapMode.TileFlipXY);
            float tx = tile.X + tile.Width / 2f - o.X, ty = tile.Y + tile.Height / 2f - o.Y, tw = Math.Max(10, tile.Width);
            int h = s.Bmp.Height, w = s.Bmp.Width; const int step = 3;
            for (int r = 0; r < h; r += step)
            {
                int rh = Math.Min(step, h - r);
                float y1, cx1, w1, y2, cx2, w2;
                Row((float)r / h, P, s, ty, tx, tw, o, out y1, out cx1, out w1);
                Row((float)(r + rh) / h, P, s, ty, tx, tw, o, out y2, out cx2, out w2);
                if (w1 < 1) continue;
                int dy = (int)Math.Round(Math.Min(y1, y2)), dh = Math.Max(1, (int)Math.Round(Math.Abs(y2 - y1)) + 1);
                Rectangle dst = new Rectangle((int)Math.Round(cx1 - w1 / 2f), dy, Math.Max(1, (int)Math.Round(w1)), dh);
                g.DrawImage(s.Bmp, dst, 0, r, w, rh, GraphicsUnit.Pixel, ia);
            }
        }
    }

    // minimize: window -> tile.  restore: tile -> window.  'real' performs the actual minimize/restore.
    public static void Play(Snap s, Rectangle tile, bool minimize, Action real)
    {
        Rectangle b = Rectangle.Union(s.R, tile); b.Inflate(6, 6);
        using (Bitmap frame = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb))
        using (GenieOverlay ov = new GenieOverlay())
        {
            ov.SetBounds(b.X, b.Y, b.Width, b.Height);
            ov.Show();
            Render(frame, s, tile, b.Location, minimize ? 0f : 1f); ov.Push(frame, b.Location);
            if (minimize) NoAnim(real);                 // overlay already covers the window, so hide the real one now
            System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
            const double dur = 360;
            while (true)
            {
                double t = sw.ElapsedMilliseconds / dur; if (t >= 1) break;
                float e = Smooth((float)t);
                Render(frame, s, tile, b.Location, minimize ? e : 1f - e); ov.Push(frame, b.Location);
                System.Threading.Thread.Sleep(1);
            }
            if (!minimize)
            {
                Render(frame, s, tile, b.Location, 0f); ov.Push(frame, b.Location);
                NoAnim(real);                           // real window appears under the full-size overlay
                System.Threading.Thread.Sleep(140);
            }
            ov.Close();
        }
    }
}

[ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList { void HrInit(); void AddTab(IntPtr h); void DeleteTab(IntPtr h); void ActivateTab(IntPtr h); void SetActiveAlt(IntPtr h); }
[ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] class TaskbarListClass { }

public class DockItem { public IntPtr H; public string Title; public Bitmap Icon; }

public class DockForm : Form
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)] struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] static extern IntPtr GetClassLongPtr(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint PrivateExtractIcons(string file, int idx, int cx, int cy, IntPtr[] icons, uint[] ids, uint n, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);

    const int Cols = 4, Rows = 4, Tile = 60, Bar = 28, Pad = 6;
    ITaskbarList tb;
    readonly Dictionary<IntPtr, Snap> snaps = new Dictionary<IntPtr, Snap>();
    string barTip = "";
    bool lastAllMin;
    readonly List<IntPtr> released = new List<IntPtr>();   // windows the user moved back to the taskbar
    readonly List<DockItem> items = new List<DockItem>();
    readonly ToolTip tip = new ToolTip();
    int scroll = 0, hover = -1, side;
    bool origAutoHide, changedAutoHide, collapsed;
    const int CollapsedW = 242;
    public static string ScriptPath = "";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    readonly Font gearFont = new Font("Segoe UI Symbol", 15f);
    IntPtr lastTarget = IntPtr.Zero;
    readonly Font small = new Font("Segoe UI", 7f);
    readonly Font barFont = new Font("Segoe UI", 9f, FontStyle.Bold);

    public DockForm()
    {
        SetProcessDPIAware();
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        DoubleBuffered = true;
        BackColor = Color.FromArgb(32, 32, 36);
        side = Bar + Rows * Tile + Pad;
        Size = new Size(side, side);
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Left + 12, wa.Bottom - side - 12);
        origAutoHide = GetAutoHide();
        tb = (ITaskbarList)new TaskbarListClass(); tb.HrInit();

        Timer t = new Timer();
        t.Interval = 700;
        t.Tick += delegate { Refresh_(); };
        t.Start();
        Refresh_();
    }

    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80 | 0x08000000; return cp; } // TOOLWINDOW | NOACTIVATE
    }
    protected override bool ShowWithoutActivation { get { return true; } }

    // ---- taskbar auto-hide ----
    static bool GetAutoHide()
    {
        APPBARDATA d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
        return (SHAppBarMessage(4, ref d).ToUInt32() & 1) != 0;
    }
    static void SetAutoHide(bool on)
    {
        APPBARDATA d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
        d.lParam = (IntPtr)(on ? 1 : 0);
        SHAppBarMessage(0xA, ref d);
    }

    // ---- window enumeration ----
    bool IsTaskbarWindow(IntPtr h) { return IsTaskbarWindowFor(h, Handle); }
    static bool IsTaskbarWindowFor(IntPtr h, IntPtr self)
    {
        if (h == self || !IsWindowVisible(h)) return false;
        if (GetWindow(h, 4) != IntPtr.Zero) return false;                  // has owner
        int ex = GetWindowLong(h, -20);
        if ((ex & 0x80) != 0 && (ex & 0x40000) == 0) return false;         // toolwindow w/o appwindow
        int cloaked; DwmGetWindowAttribute(h, 14, out cloaked, 4);
        if (cloaked != 0) return false;
        StringBuilder sb = new StringBuilder(8);
        return GetWindowText(h, sb, 8) > 0;
    }
    static string TitleOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }

    // High-resolution (64px) icon straight from the executable, so it can be scaled down sharply.
    static Bitmap ExeIcon(string path)
    {
        IntPtr[] arr = new IntPtr[1]; uint[] ids = new uint[1];
        uint n = PrivateExtractIcons(path, 0, 64, 64, arr, ids, 1, 0);
        if (n == 0 || arr[0] == IntPtr.Zero) return null;
        try
        {
            using (Icon i = Icon.FromHandle(arr[0]))
            using (Bitmap src = i.ToBitmap())
            {
                Bitmap bm = new Bitmap(64, 64, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                using (Graphics g = Graphics.FromImage(bm))
                {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                    g.DrawImage(src, 0, 0, 64, 64);
                }
                return bm;
            }
        }
        finally { DestroyIcon(arr[0]); }
    }

    Bitmap IconOf(IntPtr h)
    {
        try   // prefer the exe's big icon (UWP frames share one host exe, so use the window icon there)
        {
            uint pid; GetWindowThreadProcessId(h, out pid);
            Process p = Process.GetProcessById((int)pid);
            if (p.ProcessName != "ApplicationFrameHost") { Bitmap b = ExeIcon(p.MainModule.FileName); if (b != null) return b; }
        }
        catch { }
        IntPtr ic = IntPtr.Zero;
        SendMessageTimeout(h, 0x7F, (IntPtr)1, IntPtr.Zero, 2, 100, out ic);
        if (ic == IntPtr.Zero) SendMessageTimeout(h, 0x7F, (IntPtr)2, IntPtr.Zero, 2, 100, out ic);
        if (ic == IntPtr.Zero) ic = GetClassLongPtr(h, -14);
        try { if (ic != IntPtr.Zero) { using (Icon i = Icon.FromHandle(ic)) return new Bitmap(i.ToBitmap()); } }
        catch { }
        return null;
    }

    void Refresh_()
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { if (IsTaskbarWindow(h)) found.Add(h); return true; }, IntPtr.Zero);
        found.RemoveAll(delegate(IntPtr x) { return released.Contains(x); });
        released.RemoveAll(delegate(IntPtr x) { return !IsWindow(x); });
        bool dirty = false;
        for (int i = items.Count - 1; i >= 0; i--)
            if (!found.Contains(items[i].H)) { if (items[i].Icon != null) items[i].Icon.Dispose(); Snap rs; if (snaps.TryGetValue(items[i].H, out rs)) { rs.Bmp.Dispose(); snaps.Remove(items[i].H); } items.RemoveAt(i); dirty = true; }
        foreach (IntPtr h in found)
        {
            DockItem it = items.Find(delegate(DockItem x) { return x.H == h; });
            string title = TitleOf(h);
            if (it == null) { items.Add(new DockItem { H = h, Title = title, Icon = IconOf(h) }); dirty = true; }
            else if (it.Title != title) { it.Title = title; dirty = true; }
        }
        foreach (DockItem it2 in items) { try { tb.DeleteTab(it2.H); } catch { } }   // keep their taskbar buttons hidden
        IntPtr fg = GetForegroundWindow();
        if (Genie.Enabled && items.Exists(delegate(DockItem x) { return x.H == fg; }))
        {
            Snap old; snaps.TryGetValue(fg, out old);
            if (old == null || (DateTime.Now - old.At).TotalMilliseconds > 2500)
            { Snap n = Genie.Capture(fg); if (n != null) { if (old != null) old.Bmp.Dispose(); snaps[fg] = n; } }
        }
        if (fg != Handle && items.Exists(delegate(DockItem x) { return x.H == fg; }) && fg != lastTarget) { lastTarget = fg; dirty = true; }
        int maxScroll = Math.Max(0, (items.Count + Cols - 1) / Cols - Rows);
        if (scroll > maxScroll) { scroll = maxScroll; dirty = true; }
        bool am = AllMinimized;
        if (am != lastAllMin) { lastAllMin = am; dirty = true; }   // flip the button icon when the state changes
        if (dirty) Invalidate();
    }

    // ---- layout / painting ----
    int MarginX { get { return (side - Cols * Tile) / 2; } }
    Rectangle CellRect(int index)
    {
        int row = index / Cols - scroll, col = index % Cols;
        if (row < 0 || row >= Rows) return Rectangle.Empty;
        return new Rectangle(MarginX + col * Tile, Bar + row * Tile, Tile, Tile);
    }
    void ToggleCollapse()
    {
        collapsed = !collapsed;
        int bottom = Bottom;
        Size = collapsed ? new Size(CollapsedW, Bar) : new Size(side, side);
        Top = bottom - Height;           // keep bottom-left corner anchored
        Invalidate();
    }
    static string StartupLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Smart Dock.lnk"); } }
    static bool AutoStartOn()
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) { if (k != null && k.GetValue("SmartDock") != null) return true; }
        return File.Exists(StartupLnk);
    }
    static void SetAutoStart(bool on)
    {
        try { if (File.Exists(StartupLnk)) File.Delete(StartupLnk); } catch { }   // avoid a duplicate entry
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
        {
            if (on && ScriptPath.Length > 0)
            {
                string exe = Path.Combine(Path.GetDirectoryName(ScriptPath), "SmartDock.exe");   // installed build: use the hidden launcher
                k.SetValue("SmartDock", File.Exists(exe) ? "\"" + exe + "\""
                    : "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ScriptPath + "\"");
            }
            else k.DeleteValue("SmartDock", false);
        }
    }
    Rectangle GearRect { get { return new Rectangle(Width - 62 - 34, 3, 30, Bar - 6); } }
    Rectangle MinAllRect { get { return new Rectangle(Width - 62 - 34 - 34, 3, 30, Bar - 6); } }
    bool AllMinimized
    {
        get
        {
            if (items.Count == 0) return false;
            foreach (DockItem it in items) if (IsWindow(it.H) && !IsIconic(it.H)) return false;
            return true;
        }
    }
    // One button, two jobs: everything minimized -> restore all; otherwise -> minimize all.
    void ToggleAll()
    {
        bool restore = AllMinimized;
        foreach (DockItem it in items)
        {
            if (!IsWindow(it.H)) continue;
            if (restore) ShowWindow(it.H, 4);                    // back to previous size/position, no focus steal
            else if (!IsIconic(it.H)) ShowWindow(it.H, 7);       // minimize without stealing focus
        }
        lastTarget = IntPtr.Zero; lastAllMin = !restore && AllMinimized; Invalidate();
    }
    Rectangle ToggleRect { get { return new Rectangle(Width - 62, 3, 58, Bar - 6); } }
    Rectangle TargetRect(int index)
    {
        Rectangle r = (collapsed || index < 0) ? Rectangle.Empty : CellRect(index);
        if (r.IsEmpty) return RectangleToScreen(new Rectangle(Width / 2 - 14, 4, 28, 14));
        return RectangleToScreen(new Rectangle(r.X + Tile / 2 - 14, r.Y + 10, 28, 28));
    }
    int HitTest(Point p)
    {
        if (collapsed) return -1;
        for (int i = 0; i < items.Count; i++) { Rectangle r = CellRect(i); if (!r.IsEmpty && r.Contains(p)) return i; }
        return -1;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using (Brush bb = new SolidBrush(Color.FromArgb(48, 48, 54))) g.FillRectangle(bb, 0, 0, Width, Bar);
        g.DrawString(items.Count + " windows", barFont, Brushes.Gainsboro, 8, 5);
        using (Brush tb2 = new SolidBrush(collapsed ? Color.FromArgb(40, 150, 90) : Color.FromArgb(50, 110, 200))) g.FillRectangle(tb2, ToggleRect);
        using (Brush gb = new SolidBrush(Color.FromArgb(70, 70, 82))) g.FillRectangle(gb, GearRect);
        using (Brush mb = new SolidBrush(Color.FromArgb(70, 70, 82))) g.FillRectangle(mb, MinAllRect);
        if (lastAllMin)   // everything minimized: show a "restore" glyph (a window outline)
        {
            using (Pen wp = new Pen(Color.White, 2)) g.DrawRectangle(wp, MinAllRect.X + MinAllRect.Width / 2 - 6, MinAllRect.Y + 5, 12, 9);
        }
        else g.FillRectangle(Brushes.White, MinAllRect.X + MinAllRect.Width / 2 - 7, MinAllRect.Y + MinAllRect.Height - 8, 14, 3);
        StringFormat gf = new StringFormat(); gf.Alignment = StringAlignment.Center; gf.LineAlignment = StringAlignment.Center;
        g.DrawString("\u2699", gearFont, Brushes.White, GearRect, gf);
        StringFormat bf = new StringFormat(); bf.Alignment = StringAlignment.Center; bf.LineAlignment = StringAlignment.Center;
        g.DrawString(collapsed ? "SHOW" : "HIDE", barFont, Brushes.White, ToggleRect, bf);
        using (Pen border = new Pen(Color.FromArgb(70, 70, 78))) g.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
        if (collapsed) return;
        StringFormat sf = new StringFormat(); sf.Alignment = StringAlignment.Center; sf.Trimming = StringTrimming.EllipsisCharacter; sf.FormatFlags = StringFormatFlags.NoWrap;
        for (int i = 0; i < items.Count; i++)
        {
            Rectangle r = CellRect(i);
            if (r.IsEmpty) continue;
            Rectangle inner = Rectangle.Inflate(r, -2, -2);
            if (i == hover) using (Brush hb = new SolidBrush(Color.FromArgb(70, 70, 80))) g.FillRectangle(hb, inner);
            if (items[i].H == lastTarget) using (Pen ap = new Pen(Color.FromArgb(90, 160, 255), 2)) g.DrawRectangle(ap, inner);
            if (items[i].Icon != null) g.DrawImage(items[i].Icon, r.X + (Tile - 36) / 2, r.Y + 4, 36, 36);
            g.DrawString(items[i].Title, small, Brushes.Gainsboro, new RectangleF(r.X + 2, r.Y + 41, Tile - 4, 14), sf);
        }
        int totalRows = (items.Count + Cols - 1) / Cols;
        if (totalRows > Rows)
        {
            int trackH = Rows * Tile, barH = Math.Max(16, trackH * Rows / totalRows);
            int y = Bar + (trackH - barH) * scroll / Math.Max(1, totalRows - Rows);
            using (Brush sb = new SolidBrush(Color.FromArgb(120, 150, 150, 160))) g.FillRectangle(sb, side - 4, y, 3, barH);
        }
    }

    // ---- input ----
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Y < Bar)
        {
            if (e.Button == MouseButtons.Left && ToggleRect.Contains(e.Location)) { ToggleCollapse(); return; }
            if (e.Button == MouseButtons.Left && MinAllRect.Contains(e.Location)) { ToggleAll(); return; }
            if (e.Button == MouseButtons.Left && GearRect.Contains(e.Location)) { BarMenu(new Point(GearRect.Left, Bar)); return; }
            if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); }
            else if (e.Button == MouseButtons.Right) BarMenu(e.Location);
            return;
        }
        int i = HitTest(e.Location);
        if (i < 0) return;
        IntPtr h = items[i].H;
        if (!IsWindow(h)) return;
        if (e.Button == MouseButtons.Left)
        {
            // Taskbar behaviour: minimized -> restore; already active -> minimize; otherwise -> activate.
            Snap sn; bool genie = Genie.Enabled;
            if (IsIconic(h))
            {
                Action restore = delegate { ShowWindow(h, 9); SetForegroundWindow(h); };
                if (genie && snaps.TryGetValue(h, out sn)) Genie.Play(sn, TargetRect(i), false, restore); else restore();
                lastTarget = h;
            }
            else if (GetForegroundWindow() == h)
            {
                Action minimize = delegate { ShowWindow(h, 6); };
                Snap fresh = genie ? Genie.Capture(h) : null;
                if (fresh != null) { if (snaps.TryGetValue(h, out sn)) sn.Bmp.Dispose(); snaps[h] = fresh; }
                if (genie && snaps.TryGetValue(h, out sn)) Genie.Play(sn, TargetRect(i), true, minimize); else minimize();
                lastTarget = IntPtr.Zero;
            }
            else { SetForegroundWindow(h); lastTarget = h; }
            Invalidate();
        }
        else if (e.Button == MouseButtons.Right)
        {
            ContextMenuStrip m = new ContextMenuStrip();
            m.Items.Add("Close window", null, delegate { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); });
            m.Items.Add("Minimize", null, delegate { ShowWindow(h, 6); });
            m.Items.Add("Show in taskbar", null, delegate { released.Add(h); try { tb.AddTab(h); } catch { } Refresh_(); });
            m.Show(this, e.Location);
        }
    }
    void BarMenu(Point p)
    {
        ContextMenuStrip m = new ContextMenuStrip();
        ToolStripMenuItem ah = new ToolStripMenuItem("Auto-hide taskbar");
        ah.Checked = GetAutoHide();
        ah.Click += delegate { bool on = !ah.Checked; SetAutoHide(on); changedAutoHide = (on != origAutoHide); };
        m.Items.Add(collapsed ? "Expand" : "Collapse", null, delegate { ToggleCollapse(); });
        if (released.Count > 0) m.Items.Add("Return " + released.Count + " taskbar window(s) to dock", null, delegate { released.Clear(); Refresh_(); });
        ToolStripMenuItem au = new ToolStripMenuItem("Start with Windows");
        au.Checked = AutoStartOn();
        au.Click += delegate { SetAutoStart(!au.Checked); };
        m.Items.Add(au);
        ToolStripMenuItem gn = new ToolStripMenuItem("Genie animation");
        gn.Checked = Genie.Enabled;
        gn.Click += delegate { Genie.Enabled = !gn.Checked; };
        m.Items.Add(gn);
        m.Items.Add(ah);
        m.Items.Add("Exit dock", null, delegate { Close(); });
        m.Show(this, p);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        string bt = "";
        if (e.Y < Bar) bt = MinAllRect.Contains(e.Location) ? (lastAllMin ? "Restore all windows" : "Minimize all windows") : GearRect.Contains(e.Location) ? "Settings" : ToggleRect.Contains(e.Location) ? (collapsed ? "Show dock" : "Hide dock") : "";
        if (bt != barTip) { barTip = bt; tip.SetToolTip(this, bt); }
        int i = e.Y < Bar ? -1 : HitTest(e.Location);
        if (i != hover)
        {
            hover = i; Invalidate();
            if (i >= 0) tip.SetToolTip(this, items[i].Title); else tip.SetToolTip(this, "");
        }
    }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (hover != -1) { hover = -1; Invalidate(); } }
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (collapsed) return;
        int maxScroll = Math.Max(0, (items.Count + Cols - 1) / Cols - Rows);
        scroll = Math.Max(0, Math.Min(maxScroll, scroll + (e.Delta > 0 ? -1 : 1)));
        Invalidate();
    }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        foreach (DockItem it in items) { try { tb.AddTab(it.H); } catch { } }   // give the taskbar buttons back
        if (changedAutoHide) SetAutoHide(origAutoHide);   // leave taskbar as we found it
        base.OnFormClosing(e);
    }

    public static void RestoreAll()
    {
        ITaskbarList t = (ITaskbarList)new TaskbarListClass(); t.HrInit();
        EnumWindows(delegate(IntPtr h, IntPtr l) { if (IsTaskbarWindowFor(h, IntPtr.Zero)) t.AddTab(h); return true; }, IntPtr.Zero);
    }
    public static void RunDock() { Application.EnableVisualStyles(); Application.Run(new DockForm()); }
}
'@
if ($Restore) { [DockForm]::RestoreAll() } else { [DockForm]::ScriptPath = $PSCommandPath; [DockForm]::RunDock() }
