param([switch]$Restore)   # -Restore: put every window's taskbar button back, then exit
# Floating square window dock: shows open (taskbar-style) windows as a grid of icons.
# Left-click a tile = bring window to front (restores if minimized). Right-click a tile = close window.
# Drag the top strip to move. Right-click the strip = auto-hide taskbar toggle / exit. Wheel = scroll.
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

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
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);

    const int Cols = 4, Rows = 4, Tile = 60, Bar = 28, Pad = 6;
    ITaskbarList tb;
    readonly List<IntPtr> released = new List<IntPtr>();   // windows the user moved back to the taskbar
    readonly List<DockItem> items = new List<DockItem>();
    readonly ToolTip tip = new ToolTip();
    int scroll = 0, hover = -1, side;
    bool origAutoHide, changedAutoHide, collapsed;
    const int CollapsedW = 170;
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

    Bitmap IconOf(IntPtr h)
    {
        IntPtr ic = IntPtr.Zero;
        SendMessageTimeout(h, 0x7F, (IntPtr)1, IntPtr.Zero, 2, 100, out ic);
        if (ic == IntPtr.Zero) SendMessageTimeout(h, 0x7F, (IntPtr)2, IntPtr.Zero, 2, 100, out ic);
        if (ic == IntPtr.Zero) ic = GetClassLongPtr(h, -14);
        try
        {
            if (ic != IntPtr.Zero) { using (Icon i = Icon.FromHandle(ic)) return new Bitmap(i.ToBitmap(), 32, 32); }
            uint pid; GetWindowThreadProcessId(h, out pid);
            string path = Process.GetProcessById((int)pid).MainModule.FileName;
            using (Icon i = Icon.ExtractAssociatedIcon(path)) return new Bitmap(i.ToBitmap(), 32, 32);
        }
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
            if (!found.Contains(items[i].H)) { if (items[i].Icon != null) items[i].Icon.Dispose(); items.RemoveAt(i); dirty = true; }
        foreach (IntPtr h in found)
        {
            DockItem it = items.Find(delegate(DockItem x) { return x.H == h; });
            string title = TitleOf(h);
            if (it == null) { items.Add(new DockItem { H = h, Title = title, Icon = IconOf(h) }); dirty = true; }
            else if (it.Title != title) { it.Title = title; dirty = true; }
        }
        foreach (DockItem it2 in items) { try { tb.DeleteTab(it2.H); } catch { } }   // keep their taskbar buttons hidden
        IntPtr fg = GetForegroundWindow();
        if (fg != Handle && items.Exists(delegate(DockItem x) { return x.H == fg; }) && fg != lastTarget) { lastTarget = fg; dirty = true; }
        int maxScroll = Math.Max(0, (items.Count + Cols - 1) / Cols - Rows);
        if (scroll > maxScroll) { scroll = maxScroll; dirty = true; }
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
    Rectangle ToggleRect { get { return new Rectangle(Width - 62, 3, 58, Bar - 6); } }
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
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using (Brush bb = new SolidBrush(Color.FromArgb(48, 48, 54))) g.FillRectangle(bb, 0, 0, Width, Bar);
        g.DrawString(items.Count + " windows", barFont, Brushes.Gainsboro, 8, 5);
        using (Brush tb2 = new SolidBrush(collapsed ? Color.FromArgb(40, 150, 90) : Color.FromArgb(50, 110, 200))) g.FillRectangle(tb2, ToggleRect);
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
            if (items[i].Icon != null) g.DrawImage(items[i].Icon, r.X + (Tile - 32) / 2, r.Y + 6, 32, 32);
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
            if (IsIconic(h)) ShowWindow(h, 9);
            SetForegroundWindow(h);
            lastTarget = h; Invalidate();
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
        m.Items.Add(ah);
        m.Items.Add("Exit dock", null, delegate { Close(); });
        m.Show(this, p);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
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
if ($Restore) { [DockForm]::RestoreAll() } else { [DockForm]::RunDock() }
