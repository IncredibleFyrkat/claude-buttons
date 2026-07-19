# All non-switch parameters are named-only: a stray token from an unquoted path
# (-AddButton C:\My Temp\p.json) used to bind positionally and the script exited 0 having
# written nothing - a caller checking only the exit code reports success for a button
# that was never saved.
param(
    [switch]$SmokeTest,
    [Parameter(DontShow)][string]$PasteProbe = $null,
    [string]$AddButton,
    [string]$RemoveButton
)

# THERE IS NO TYPING PATH. Escape-SendKeys and its -EscapeProbe hook lived here and encoded
# text into synthetic keystrokes as a fallback for when the clipboard paste could not be
# confirmed. That fallback was the leak: it typed the correct text underneath whatever had
# actually landed in the box - often the user's own clipboard - and pressed Enter, sending
# both. Removing the fallback made the function dead code, and deleting it removes the whole
# class: this script now synthesises exactly two keystrokes, '^v' and '{ENTER}', and a test
# asserts that no third one appears.
# Claude Buttons - a slim button strip that docks onto the Claude desktop app's bottom bar.
# - Visible only when the Claude window itself is in the foreground
# - Click (or right-click) the vertical 3-dot kebab for the menu
#   (pin new button / language / hover tooltips / close panel)
# - Global buttons + buttons pinned to the currently displayed chat
# - buttons.json auto-reloads; all writes merge against a fresh file (atomic + retry, locked)
# - Buttons with "confirm": true require two clicks (Confirm?)
# - Per-chat buttons never auto-send (they only insert text)
# Errors are logged to %LOCALAPPDATA%\claude-buttons.log
# Requires Windows 10/11 built-in Windows PowerShell 5.1 (do not run under pwsh 7).

$ErrorActionPreference = 'Stop'
$CB_VERSION = '1.9.0'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# All C# in one compile (faster startup):
# - CkDpi: per-monitor DPI awareness (set BEFORE any window is created)
# - NoActivateForm: never takes focus, so keystrokes land in Claude
# - PillButton/GripHandle: owner-drawn with antialiasing (smooth pill corners)
# - CkWin: win32 helpers
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public static class CkDpi {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    public static void Enable() {
        // powershell.exe's manifest may already declare system-DPI awareness, in which case
        // these calls fail harmlessly. We compute the real scale per-window at runtime anyway.
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
        catch { try { SetProcessDPIAware(); } catch {} }
    }
}

public class NoActivateForm : Form {
    public NoActivateForm() { this.DoubleBuffered = true; }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams p = base.CreateParams;
            p.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return p;
        }
    }
}

// A no-activate window that is ALSO per-pixel-alpha layered (WS_EX_LAYERED). Its content
// comes from UpdateLayeredWindow (an ARGB bitmap), NOT normal painting: the background is
// truly transparent and click-through where alpha==0, while button pixels (alpha>0) stay
// clickable. Do NOT set Form.Opacity on these - that uses SetLayeredWindowAttributes, which
// is mutually exclusive with UpdateLayeredWindow.
public class LayeredForm : NoActivateForm {
    protected override CreateParams CreateParams {
        get {
            CreateParams p = base.CreateParams;
            p.ExStyle |= 0x00080000; // WS_EX_LAYERED
            return p;
        }
    }
}

public static class Layered {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int Cx, Cy; public SIZE(int x, int y) { Cx = x; Cy = y; } }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    // SetLastError: a failed push is otherwise completely silent - the bool return was
    // discarded, no exception was raised, so the strip simply stopped updating and the log
    // stayed clean. For a panel whose failure mode is "it disappeared", that silence is the
    // difference between a one-line config fix and an undiagnosable bug report.
    [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref POINT ppt, ref SIZE size, IntPtr src, ref POINT pptSrc, int crKey, ref BLENDFUNCTION blend, int flags);
    // Push a premultiplied-ARGB bitmap to the layered window at screen (x,y). This both
    // positions and shows the window, so it doubles as the reposition path.
    public static void Push(IntPtr hwnd, Bitmap bmp, int x, int y) {
        // Every handle is acquired INSIDE the try. GetHbitmap throws exactly when GDI is
        // under pressure (near the 10,000-handle per-process ceiling, or low memory) - and
        // acquiring the DCs before the try meant each such throw leaked two more handles.
        // That turns a transient glitch into a death spiral: the caller logs and the tick
        // keeps pushing, so the failure accelerates the condition that caused it, until
        // every GDI allocation in the process fails and the panel is dead until restarted.
        IntPtr screen = IntPtr.Zero, mem = IntPtr.Zero, hbmp = IntPtr.Zero, old = IntPtr.Zero;
        try {
            screen = GetDC(IntPtr.Zero);
            if (screen == IntPtr.Zero) return;
            mem = CreateCompatibleDC(screen);
            if (mem == IntPtr.Zero) return;
            hbmp = bmp.GetHbitmap(Color.FromArgb(0));
            old = SelectObject(mem, hbmp);
            var size = new SIZE(bmp.Width, bmp.Height);
            var src = new POINT(0, 0);
            var dst = new POINT(x, y);
            var blend = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 }; // AC_SRC_ALPHA
            if (!UpdateLayeredWindow(hwnd, screen, ref dst, ref size, mem, ref src, 0, ref blend, 2)) // ULW_ALPHA
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally {
            if (mem != IntPtr.Zero && old != IntPtr.Zero) SelectObject(mem, old);
            if (hbmp != IntPtr.Zero) DeleteObject(hbmp);
            if (mem != IntPtr.Zero) DeleteDC(mem);
            if (screen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screen);
        }
    }
}

public class PillButton : Control {
    public Color Fill = Color.FromArgb(48, 47, 44);
    public Color HoverFill = Color.FromArgb(60, 58, 54);
    public Color DownFill = Color.FromArgb(70, 67, 62);
    // Active state for toggle buttons. Two constraints pull against each other: the fill must
    // separate from the bar (WCAG 1.4.11, 3:1) AND the label/glyph on top of it must stay
    // readable (1.4.3, 4.5:1). The old pairing satisfied only the first - a grey glyph on the
    // old fill measured 1.96:1, so the lit state was the LEAST legible state in the product,
    // and that is the state the shutdown power button uses to mean "this PC is armed to power
    // off". Darkening the fill alone breaks the state cue, so the foreground brightens too.
    public Color ToggleFill = Color.FromArgb(144, 102, 36);  // 3.30:1 vs the bar
    public Color ToggleFore = Color.FromArgb(255, 255, 255); // 5.11:1 on ToggleFill
    public Color Accent = Color.Empty; // border on per-chat buttons
    public bool Bold = false;          // draw the glyph with extra stroke weight (icons)
    bool toggled;
    public bool Toggled { get { return toggled; } set { toggled = value; Invalidate(); FireRepaint(); } }
    bool hover, down;
    // Fired whenever the visual state changes so the layered strip can recomposite
    // (a layered per-pixel-alpha window ignores normal WM_PAINT, so Invalidate() alone
    // is not enough - the owner must rebuild and push the ARGB bitmap).
    public event EventHandler Repaint;
    protected void FireRepaint() { var h = Repaint; if (h != null) h(this, EventArgs.Empty); }
    public PillButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Cursor = Cursors.Hand;
        // Expose an accessible role so a screen reader announces "button", not "client".
        // AccessibleName is set per-instance to the label (not the icon glyph).
        AccessibleRole = AccessibleRole.PushButton;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); FireRepaint(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); FireRepaint(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); FireRepaint(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); FireRepaint(); base.OnMouseUp(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); FireRepaint(); base.OnTextChanged(e); }
    // Force the hover/press highlight off (a tick-level safety net: WM_MOUSELEAVE can lag
    // on a layered window, so the panel also clears hover when the cursor leaves the rect).
    public void ClearHover() { if (hover || down) { hover = false; down = false; Invalidate(); FireRepaint(); } }
    static GraphicsPath RoundRect(Rectangle r, int rad) {
        int d = rad * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);                 // top-left
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);         // top-right
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);  // bottom-right
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);         // bottom-left
        p.CloseFigure();
        return p;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rc = new Rectangle(0, 0, Width - 1, Height - 1);
        int rad = Math.Max(4, Height / 4);   // rounded corners, not a full pill/circle
        // Resting buttons have NO background - they sit transparent on the bar like Claude's
        // own toolbar icons. A rounded-corner highlight appears only on hover/press; a
        // toggled button stays highlighted so its "on" state is visible.
        if (hover || down || toggled) {
            Color f = down ? DownFill : (toggled ? ToggleFill : HoverFill);
            using (var path = RoundRect(rc, rad))
            using (var b = new SolidBrush(f)) g.FillPath(b, path);
        }
        // Per-chat accent: brighter + 2px so it clears WCAG 1.4.11 (3:1 non-text contrast).
        if (Accent != Color.Empty) {
            using (var path = RoundRect(rc, rad))
            using (var pen = new Pen(Accent, 2f)) g.DrawPath(pen, path);
        }
        // Toggle-on gets a NON-COLOR cue (a bright left dot) so state isn't conveyed by fill alone.
        int textLeft = 0;
        if (toggled) {
            int dd = Math.Max(4, Height / 3);
            int dx = Math.Max(3, (Height - dd) / 2);
            using (var b = new SolidBrush(Color.FromArgb(236, 200, 130)))
                g.FillEllipse(b, dx, (Height - dd) / 2, dd, dd);
            textLeft = dx + dd;
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(textLeft, 0, Width - textLeft, Height),
            toggled ? ToggleFore : ForeColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
    // Composite this button onto a transparent ARGB surface at (ox,oy). The whole
    // button rect is painted at alpha=1: invisible on any background, but non-zero
    // alpha means the layered window still hit-tests (and hovers) there, so the button
    // is fully clickable without a visible box. Glyph/hover/accent draw at full alpha.
    public void RenderTo(Graphics g, int ox, int oy) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var hit = new SolidBrush(Color.FromArgb(1, 0, 0, 0)))
            g.FillRectangle(hit, new Rectangle(ox, oy, Width, Height));
        var rc = new Rectangle(ox, oy, Width - 1, Height - 1);
        int rad = Math.Max(4, Height / 4);
        if (hover || down || toggled) {
            Color f = down ? DownFill : (toggled ? ToggleFill : HoverFill);
            using (var path = RoundRect(rc, rad))
            using (var b = new SolidBrush(Color.FromArgb(255, f))) g.FillPath(b, path);
        }
        if (Accent != Color.Empty) {
            using (var path = RoundRect(rc, rad))
            using (var pen = new Pen(Accent, 2f)) g.DrawPath(pen, path);
        }
        int textLeft = 0;
        if (toggled) {
            int dd = Math.Max(4, Height / 3);
            int dx = Math.Max(3, (Height - dd) / 2);
            using (var b = new SolidBrush(Color.FromArgb(236, 200, 130)))
                g.FillEllipse(b, ox + dx, oy + (Height - dd) / 2, dd, dd);
            textLeft = dx + dd;
        }
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
        using (var sf = new StringFormat()) {
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            sf.FormatFlags = StringFormatFlags.NoWrap;
            var rect = new RectangleF(ox + textLeft, oy, Width - textLeft, Height);
            using (var b = new SolidBrush(toggled ? ToggleFore : ForeColor)) {
                if (Bold) {
                    // Faux-bold: redraw the glyph at sub-pixel offsets to thicken strokes
                    // without enlarging the icon (Segoe Fluent Icons has no bold weight).
                    float o = 0.3f;
                    float[] dx = { -o, o, 0, 0 };
                    float[] dy = { 0, 0, -o, o };
                    for (int k = 0; k < 4; k++)
                        g.DrawString(Text, Font, b, new RectangleF(rect.X + dx[k], rect.Y + dy[k], rect.Width, rect.Height), sf);
                }
                g.DrawString(Text, Font, b, rect, sf);
            }
        }
    }
}

// The menu button: a vertical 3-dot kebab that is visually IDENTICAL to an icon
// PillButton (same square size, hover/press highlight, and white dots) - it just draws
// dots instead of a glyph and opens the menu instead of sending text.
public class GripHandle : Control {
    public Color DotColor = Color.White;
    public Color HoverFill = Color.FromArgb(48, 48, 47);
    public Color DownFill = Color.FromArgb(58, 58, 56);
    bool hover, down;
    public event EventHandler Repaint;
    protected void FireRepaint() { var h = Repaint; if (h != null) h(this, EventArgs.Empty); }
    public GripHandle() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Cursor = Cursors.Hand;
        AccessibleRole = AccessibleRole.ButtonDropDown;
        AccessibleName = "Claude Buttons menu";
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); FireRepaint(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); FireRepaint(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); FireRepaint(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); FireRepaint(); base.OnMouseUp(e); }
    public void ClearHover() { if (hover || down) { hover = false; down = false; Invalidate(); FireRepaint(); } }
    static GraphicsPath RoundRect(Rectangle r, int rad) {
        int d = rad * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    // Shared face draw (used by both normal and layered rendering), matching PillButton.
    void DrawFace(Graphics g, int ox, int oy) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (hover || down) {
            var rc = new Rectangle(ox, oy, Width - 1, Height - 1);
            int rad = Math.Max(4, Height / 4);
            Color f = down ? DownFill : HoverFill;
            using (var path = RoundRect(rc, rad))
            using (var b = new SolidBrush(Color.FromArgb(255, f))) g.FillPath(b, path);
        }
        // Match the icon glyphs exactly: same soft-grey, and each dot is drawn with the SAME
        // faux-bold stacking (center + 4 sub-pixel offsets) so its edges are reinforced and it
        // reads as solid/bright as a glyph stroke, not a faded single-pass circle.
        float d = Math.Max(1.8f, Height / 12f);
        float cx = ox + Width / 2f, cy = oy + Height / 2f, vgap = d * 2f;
        float o = 0.3f;
        float[] dx = { 0f, -o, o, 0f, 0f };
        float[] dy = { 0f, 0f, 0f, -o, o };
        using (var b = new SolidBrush(DotColor)) {
            for (int row = -1; row <= 1; row++) {   // vertical 3-dot kebab
                float y = cy + row * vgap;
                for (int k = 0; k < 5; k++)
                    g.FillEllipse(b, cx - d / 2f + dx[k], y - d / 2f + dy[k], d, d);
            }
        }
    }
    protected override void OnPaint(PaintEventArgs e) { e.Graphics.Clear(BackColor); DrawFace(e.Graphics, 0, 0); }
    // Composite onto a transparent ARGB surface at (ox,oy); the full rect is painted at
    // alpha=1 so it stays clickable while invisible (see PillButton).
    public void RenderTo(Graphics g, int ox, int oy) {
        using (var hit = new SolidBrush(Color.FromArgb(1, 0, 0, 0)))
            g.FillRectangle(hit, new Rectangle(ox, oy, Width, Height));
        DrawFace(g, ox, oy);
    }
}

// Dark menu theme in the app's warm colors
public class CkColors : ProfessionalColorTable {
    static Color bg = Color.FromArgb(40, 39, 37);
    static Color hi = Color.FromArgb(62, 60, 56);
    public override Color ToolStripDropDownBackground { get { return bg; } }
    public override Color ImageMarginGradientBegin { get { return bg; } }
    public override Color ImageMarginGradientMiddle { get { return bg; } }
    public override Color ImageMarginGradientEnd { get { return bg; } }
    public override Color MenuItemSelected { get { return hi; } }
    public override Color MenuItemSelectedGradientBegin { get { return hi; } }
    public override Color MenuItemSelectedGradientEnd { get { return hi; } }
    public override Color MenuItemPressedGradientBegin { get { return hi; } }
    public override Color MenuItemPressedGradientMiddle { get { return hi; } }
    public override Color MenuItemPressedGradientEnd { get { return hi; } }
    public override Color MenuItemBorder { get { return hi; } }
    public override Color MenuBorder { get { return Color.FromArgb(78, 75, 70); } }
    public override Color SeparatorDark { get { return Color.FromArgb(72, 69, 64); } }
    public override Color SeparatorLight { get { return bg; } }
    public override Color CheckBackground { get { return hi; } }
    public override Color CheckSelectedBackground { get { return hi; } }
    public override Color CheckPressedBackground { get { return hi; } }
}
public class CkRenderer : ToolStripProfessionalRenderer {
    public CkRenderer() : base(new CkColors()) {}
    // Paint the background ourselves - the color table is not always honored for open/selected items
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Color f = (e.Item.Selected || e.Item.Pressed) ? Color.FromArgb(62, 60, 56) : Color.FromArgb(40, 39, 37);
        using (var b = new SolidBrush(f))
            e.Graphics.FillRectangle(b, new Rectangle(Point.Empty, e.Item.Size));
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(214, 210, 202) : Color.FromArgb(130, 127, 120);
        base.OnRenderItemText(e);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = Color.FromArgb(214, 210, 202);
        base.OnRenderArrow(e);
    }
}

public class CkWin {
    public struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    // Root top-level window currently at a screen point (what the user would actually see/click
    // there). Used to tell whether a pane's spot on Claude is visible or covered by another app.
    public static IntPtr RootAtPoint(int x, int y) {
        IntPtr h = WindowFromPoint(new POINT { X = x, Y = y });
        if (h == IntPtr.Zero) return IntPtr.Zero;
        return GetAncestor(h, 2); // GA_ROOT
    }
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    // WS_EX_TOPMOST: screen-snip/capture overlays are top-most and briefly cover Claude; a
    // normal app that covers Claude is not. Used to avoid hiding the strips for such overlays.
    public static bool IsTopmost(IntPtr h) { return (GetWindowLong(h, -20) & 0x00000008) != 0; }
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);

    // Dark title bar for dialog windows (DWMWA_USE_IMMERSIVE_DARK_MODE = 20, or 19 on older Win10)
    public static void DarkTitle(IntPtr h) {
        int on = 1;
        try { if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); } catch {}
    }
    // Dark scrollbars for a scrollable control (textbox, panel)
    [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string sub, string list);
    public static void DarkScroll(IntPtr h) { try { SetWindowTheme(h, "DarkMode_Explorer", null); } catch {} }

    // Per-window DPI scale (1.0 = 96 dpi). Falls back to 1.0 on older Windows.
    public static double WindowScale(IntPtr h) {
        try { uint d = GetDpiForWindow(h); if (d >= 48 && d <= 960) return d / 96.0; } catch {}
        return 0.0; // caller keeps its previous scale
    }

    public static IntPtr FindTarget(string titlePart, string procName) {
        IntPtr found = IntPtr.Zero;
        uint myPid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == myPid) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (!sb.ToString().Contains(titlePart)) return true;
            if (!string.IsNullOrEmpty(procName)) {
                try {
                    string pn = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
                    if (!pn.Equals(procName, StringComparison.OrdinalIgnoreCase)) return true;
                } catch { return true; }
            }
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
}
"@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# WinEvent hooks: let Windows tell us when the Claude window is moved/resized, shown/
# hidden, or (de)foregrounded, instead of polling those every tick. The callback only
# flips a Dirty flag; the timer consumes it to run the expensive window/UIA/reposition
# work on demand (with a slow backstop, so a missed event just means a slightly-late
# reposition rather than a stall). The delegate is held in a C# STATIC field on purpose:
# a PowerShell-side delegate would be GC-collected while Windows still holds the native
# pointer and crash the process on the next event - the classic PS 5.1 callback footgun.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinHook {
    delegate void WinEventDelegate(IntPtr hHook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr hmod, WinEventDelegate cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    // SHOW..NAMECHANGE spans show/hide/reorder/focus/location/name - i.e. Claude being
    // moved, resized, shown/hidden, or switching the displayed chat (its title changes).
    const uint EVENT_OBJECT_SHOW = 0x8002, EVENT_OBJECT_NAMECHANGE = 0x800C;
    const uint OUTOFCONTEXT = 0x0000, SKIPOWNPROCESS = 0x0002;
    static WinEventDelegate _cb;   // rooted here so the GC never frees the native callback
    static IntPtr _hFg, _hObj;
    // volatile: the callback runs on our message-loop thread, but a plain field could be
    // cached; volatile guarantees the timer sees the latest value.
    static volatile bool _dirty = true;   // start dirty so the first tick positions
    public static uint TargetPid = 0;     // set by the panel so LOCATIONCHANGE noise from
                                          // other apps is ignored (Claude has multiple procs,
                                          // so 0 = accept all until the panel narrows it).
    static void OnEvent(IntPtr hHook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time) {
        // Foreground changes always matter (Claude gaining/losing focus). Object events
        // (move/resize/show/hide) fire constantly across the desktop, so when we know
        // Claude's PID, ignore object events from other processes.
        if (ev != EVENT_SYSTEM_FOREGROUND && TargetPid != 0) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid != TargetPid) return;
        }
        _dirty = true;
    }
    public static void Start() {
        _cb = OnEvent;
        _hFg = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _cb, 0, 0, OUTOFCONTEXT | SKIPOWNPROCESS);
        _hObj = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, _cb, 0, 0, OUTOFCONTEXT | SKIPOWNPROCESS);
    }
    public static void Stop() {
        try { if (_hFg != IntPtr.Zero) UnhookWinEvent(_hFg); if (_hObj != IntPtr.Zero) UnhookWinEvent(_hObj); } catch {}
    }
    // Returns true (and clears) if an event arrived since the last call.
    public static bool Consume() { bool d = _dirty; _dirty = false; return d; }
    public static void Touch() { _dirty = true; }   // force the next tick to do full work
}
"@

# Enumerate a window's Chrome_RenderWidgetHostHWND children. Requesting the accessibility
# root of each is what turns ON Chromium's web AXTree (it stays off until an AT client asks),
# which is the only way to see the chat panes/composers of the Electron app from outside.
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CkChild {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    public static IntPtr[] RenderWidgets(IntPtr top) {
        var list = new List<IntPtr>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(200); GetClassName(h, sb, 200);
            if (sb.ToString().StartsWith("Chrome_RenderWidgetHostHWND")) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@

[CkDpi]::Enable()
# Startup scale from the primary monitor; updated per-window once the target is found.
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $g.DpiX / 96.0
$g.Dispose()
$script:winScale = $script:scale   # scale of the monitor the Claude window is on
function S([double]$v) { [int][Math]::Round($v * $script:scale) }        # control sizing (startup scale)
function SW([double]$v) { [int][Math]::Round($v * $script:winScale) }    # positioning vs the target window

# ---------- Logging ----------
$script:logPath = Join-Path $env:LOCALAPPDATA 'claude-buttons.log'
$script:lastLogMsg = ''
$script:lastLogAt = Get-Date '2000-01-01'
function Write-CkLog([string]$msg) {
    try {
        if ($script:lastLogMsg -eq $msg -and ((Get-Date) - $script:lastLogAt).TotalSeconds -lt 60) { return }
        $script:lastLogMsg = $msg; $script:lastLogAt = Get-Date
        Add-Content -Path $script:logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8
    } catch {}
}

# ---------- Config ----------
$configPath = Join-Path $PSScriptRoot 'buttons.json'
$activePath = Join-Path $env:USERPROFILE '.claude\active-session.json'

# Marker file so the /pin and /unpin skills know where this install keeps buttons.json,
# without hardcoding any username or path. Written ONLY by a real panel launch: any invocation
# that runs from a temp/dev copy must never repoint a live install's marker. That includes
# -SmokeTest and the -AddButton/-RemoveButton CLI, which the skills themselves call - a CLI
# run from the wrong folder would rewrite the very file the skills use to find the panel, and
# the breakage is self-propagating because there is then no correct path left to recover from.
# No BOM: the skills read this as a PATH, and a leading U+FEFF is a silent "file not found".
# Deliberately a FUNCTION, called only after the single-instance mutex is won (see the bottom
# of this file). Writing it here would still repoint a live install's marker when someone
# double-clicks a repo copy once: that duplicate exits at the single-instance guard ~2000 lines
# later, but by then it has already rewritten the file the skills use to find the panel.
function Write-InstallMarker {
    if ($SmokeTest -or $AddButton -or $RemoveButton) { return }
    try {
        $markerDir = Join-Path $env:USERPROFILE '.claude'
        if (Test-Path $markerDir) {
            [IO.File]::WriteAllText((Join-Path $markerDir 'claude-buttons-path.txt'), $configPath,
                                    (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# Cross-process lock so panel writes and /pin edits never clobber each other
$script:cfgLock = New-Object System.Threading.Mutex($false, 'Local\ClaudeButtonsConfig')

function Read-FreshConfig {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $c = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Normalize: a valid JSON file missing the buttons array must not crash callers
            if ($null -eq $c.buttons) { $c | Add-Member -NotePropertyName buttons -NotePropertyValue @() -Force }
            return $c
        }
        catch { Start-Sleep -Milliseconds 120 }
    }
    Write-CkLog 'Could not read buttons.json (locked/invalid after 3 attempts)'
    return $null
}

function Write-ConfigAtomic($cfg) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $tmp = "$configPath." + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
            # Depth 100, not 6: PS 5.1 does not error past -Depth, it stringifies the over-deep
            # node into "@{k=v}", silently and irreversibly corrupting anything nested that a
            # newer version or a hand-editing user put there. No BOM: buttons.json is JSON, and
            # the marker/skill readers are strict (Set-Content -Encoding UTF8 emits a BOM here).
            $json = $cfg | ConvertTo-Json -Depth 100
            [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -Path $tmp -Destination $configPath -Force
            $script:cfgTime = (Get-Item $configPath).LastWriteTimeUtc
            return $true
        } catch { Start-Sleep -Milliseconds 150 }
    }
    Write-CkLog 'Could not write buttons.json (3 attempts)'
    return $false
}

$script:config = Read-FreshConfig
if (-not $script:config) {
    # H3: a corrupt/locked buttons.json must not kill the panel (launched hidden, the
    # user would just see nothing). Fall back to the shipped defaults, else an empty
    # in-memory config, log it, and carry on. The bad file is left untouched on disk.
    Write-CkLog 'buttons.json unreadable at startup - falling back to defaults (file left untouched)'
    $defPath = Join-Path $PSScriptRoot 'buttons.default.json'
    try { $script:config = Get-Content $defPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $script:config = $null }
    if (-not $script:config) {
        $script:config = [pscustomobject]@{ schemaVersion = 1; buttons = @() }
    }
    if ($null -eq $script:config.buttons) { $script:config | Add-Member -NotePropertyName buttons -NotePropertyValue @() -Force }
    # If this was a transient lock, keep retrying the real file (unchanged mtime) for a short
    # window so it self-heals; after that, stop hammering (a permanently bad file would otherwise
    # burn ~360ms on every 200ms tick). A later real edit changes the mtime and reloads normally.
    $script:cfgHealUntil = (Get-Date).AddSeconds(5)
}
try { $script:cfgTime = (Get-Item $configPath).LastWriteTimeUtc } catch { $script:cfgTime = Get-Date '2000-01-01' }
$script:activeSession = ''
$script:activeTime = $null
$script:activeTs = $null        # timestamp from the hook (UTC)
$script:activeExpired = $false  # signal older than 10 min -> hide chat buttons

$targetTitle = 'Claude'
if ($script:config.targetTitle) { $targetTitle = [string]$script:config.targetTitle }
$targetProcess = 'claude'
if ($null -ne $script:config.targetProcess) { $targetProcess = [string]$script:config.targetProcess }

# App-dependent names/measures - editable in buttons.json without code changes if the app updates
$script:uiaPaneName = 'Primary pane'    # accessibility name of the (first) chat area
if ($script:config.uiaPaneName) { $script:uiaPaneName = [string]$script:config.uiaPaneName }
# Matches EVERY chat pane in split/grid view: "Primary pane", "Secondary pane", "Tertiary pane"...
$script:uiaPaneMatch = ' pane$'
if ($script:config.uiaPaneMatch) { $script:uiaPaneMatch = [string]$script:config.uiaPaneMatch }
# Accessible name of the chat composer. Overridable like every other app-dependent name, so a
# rename or localization on Claude's side can be self-healed from buttons.json.
$script:uiaComposerName = 'Prompt'
if ($script:config.uiaComposerName) { $script:uiaComposerName = [string]$script:config.uiaComposerName }
$script:uiaSidebarName = 'Sidebar'      # accessibility name of the sidebar (fallback strategy)
if ($script:config.uiaSidebarName) { $script:uiaSidebarName = [string]$script:config.uiaSidebarName }
$script:zoneTop = 45                    # height (logical px) of the top zone holding the chat-title tab
if ($script:config.zoneTop) { $script:zoneTop = [int]$script:config.zoneTop }
$script:zoneBottom = 55                 # height of the bottom zone holding the app's own buttons
if ($script:config.zoneBottom) { $script:zoneBottom = [int]$script:config.zoneBottom }
$script:fallbackRow = 33                # fallback: strip center above the window bottom
if ($script:config.fallbackRow) { $script:fallbackRow = [int]$script:config.fallbackRow }
$script:stripGap = 10                   # gap between the app's buttons and the strip
if ($script:config.stripGap) { $script:stripGap = [int]$script:config.stripGap }
$script:reservedW = 380                 # width reserved for the app's own bar elements (compact threshold)
if ($script:config.reservedW) { $script:reservedW = [int]$script:config.reservedW }
$script:relX = 0.0
if ($null -ne $script:config.relX) { $script:relX = [double]$script:config.relX }
$script:vNudge = [int]$script:config.vNudge   # vertical nudge in px (+ = down, - = up); 0 if unset
$script:tipCtrl = $null    # control the hover tip is currently showing for
$script:tipsOff = [bool]$script:config.tipsOff   # hover-tooltip off switch (grip menu; persisted)

# ---------- Language (default: English; switch in the grip menu) ----------
$script:lang = 'en'
if ($script:config.lang) { $script:lang = [string]$script:config.lang }
$script:strings = @{
    en = @{
        rename = 'Rename...'; moveLeft = 'Move left'; moveRight = 'Move right'; remove = 'Remove this button'
        pinNew = 'Pin new button'; custom = 'Other: type your own...'; onlyChat = 'Only this chat'; globalScope = 'Global (all chats)'
        closePanel = 'Close panel'; language = 'Language'
        confirm = 'Confirm?'; gripTip = 'Click: menu'
        dupPin = 'That command is already pinned in this scope.'
        tipGlobal = 'Global'; tipChatOnly = 'Only in this chat'; tipChatIn = 'Only in chat: {0}'
        tipSends = 'types and sends'; tipInserts = 'inserts text only'; tipRemove = 'Right-click: rename / move / remove'
        tipShift = 'Shift-click: insert without sending'
        sendBlank = 'Not sent: this button has no text to send. Check its text in buttons.json.'
        sendNoClipboard = 'Not sent: the clipboard was unavailable, so nothing was pasted. The message box was not changed.'
        sendMismatch = 'Not sent: the paste did not land as expected. Check the message box before sending - something else may be in it.'
        sendUnverified = 'Not sent: could not read the message box to confirm the paste. Nothing was submitted.'
        noActive = 'The panel cannot tell which chat is active right now (send a message in the chat first). The button was NOT pinned.'
        pinTitle = 'Pin new button'; askText = 'Text/command the button should type (e.g. /my-command or plain text):'
        askLabel = 'Button name (empty = use the text):'; renameAsk = 'New name for the button:'; renameTitle = 'Rename button'
        firstRun = 'Click the menu button to add buttons'
        setIcon = 'Set icon...'; iconTitle = 'Set icon'
        iconAsk = "Icon name (empty = show text label instead).`nAvailable: {0}"
        toggleMode = 'On/off (toggle) mode'
        tipToggle = 'toggle on/off'
        editText = 'Edit text/prompt...'; editTextTitle = 'Edit button text'
        dlgOk = 'OK'; dlgCancel = 'Cancel'
    }
    da = @{
        rename = 'Omdøb…'; moveLeft = 'Flyt til venstre'; moveRight = 'Flyt til højre'; remove = 'Fjern denne knap'
        pinNew = 'Pin ny knap'; custom = 'Andet: skriv selv…'; onlyChat = 'Kun denne chat'; globalScope = 'Global (alle chats)'
        closePanel = 'Luk panelet'; language = 'Sprog'
        confirm = 'Bekræft?'; gripTip = 'Klik: menu'
        dupPin = 'Kommandoen er allerede pinnet i dette scope.'
        tipGlobal = 'Global'; tipChatOnly = 'Kun i denne chat'; tipChatIn = 'Kun i chatten: {0}'
        tipSends = 'skriver og sender'; tipInserts = 'indsætter kun tekst'; tipRemove = 'Højreklik: omdøb / flyt / fjern'
        tipShift = 'Shift-klik: indsæt uden at sende'
        sendBlank = 'Ikke sendt: denne knap har ingen tekst at sende. Tjek dens tekst i buttons.json.'
        sendNoClipboard = 'Ikke sendt: udklipsholderen var utilgængelig, så intet blev indsat. Beskedfeltet blev ikke ændret.'
        sendMismatch = 'Ikke sendt: indsættelsen landede ikke som forventet. Tjek beskedfeltet før du sender - der kan stå noget andet i det.'
        sendUnverified = 'Ikke sendt: kunne ikke læse beskedfeltet for at bekræfte indsættelsen. Intet blev afsendt.'
        noActive = 'Panelet kan ikke afgøre hvilken chat der er aktiv lige nu (send en besked i chatten først). Knappen blev IKKE pinnet.'
        pinTitle = 'Pin ny knap'; askText = 'Tekst/kommando knappen skal skrive (f.eks. /min-command eller almindelig tekst):'
        askLabel = 'Knappens navn (tom = brug teksten):'; renameAsk = 'Nyt navn til knappen:'; renameTitle = 'Omdøb knap'
        firstRun = 'Klik på menuknappen for at tilføje knapper'
        setIcon = 'Vælg ikon…'; iconTitle = 'Vælg ikon'
        iconAsk = "Ikon-navn (tom = vis tekst i stedet).`nMulige: {0}"
        toggleMode = 'On/off-tilstand (toggle)'
        tipToggle = 'tænd/sluk'
        editText = 'Redigér tekst/prompt…'; editTextTitle = 'Redigér knappens tekst'
        dlgOk = 'OK'; dlgCancel = 'Annuller'
    }
}
function L([string]$k) { $script:strings[$script:lang][$k] }

# Save ONLY the panel's own fields - merge against a fresh file so /pin edits are never overwritten
function Save-PanelState {
    # M7: only release a mutex we actually acquired. WaitOne returns $false on timeout (releasing
    # then would throw). AbandonedMutexException is thrown WHILE granting ownership (a prior holder
    # died without releasing) - we DO own it in that case, so treat it as held.
    $held = $false
    try { $held = $script:cfgLock.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    catch { $held = $false }
    if (-not $held) { Write-CkLog 'Config lock busy - skipped panel-state save'; return }
    try {
        $fresh = Read-FreshConfig
        if (-not $fresh) { return }
        $fresh | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1 -Force
        $fresh | Add-Member -NotePropertyName targetTitle -NotePropertyValue $targetTitle -Force
        $fresh | Add-Member -NotePropertyName targetProcess -NotePropertyValue $targetProcess -Force
        $fresh | Add-Member -NotePropertyName lang -NotePropertyValue $script:lang -Force
        $fresh | Add-Member -NotePropertyName relX -NotePropertyValue ([Math]::Round($script:relX, 4)) -Force
        $fresh | Add-Member -NotePropertyName tipsOff -NotePropertyValue ([bool]$script:tipsOff) -Force
        # Strip is statically docked; drop any legacy free-placement / offset fields.
        foreach ($legacy in @('freeX', 'freeY', 'x', 'y', 'offsetX', 'offsetY', 'offsetBottom')) { $fresh.PSObject.Properties.Remove($legacy) }
        [void](Write-ConfigAtomic $fresh)
    } finally { [void]$script:cfgLock.ReleaseMutex() }
}

# Transform the buttons array against a FRESH file (merge, don't overwrite) and update memory
function Update-Buttons([scriptblock]$transform) {
    $held = $false
    try { $held = $script:cfgLock.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    catch { $held = $false }
    if (-not $held) { Write-CkLog 'Config lock busy - button change not saved'; return $false }
    try {
        $fresh = Read-FreshConfig
        if (-not $fresh) { return $false }
        $fresh.buttons = @(& $transform @($fresh.buttons))
        if (Write-ConfigAtomic $fresh) { $script:config = $fresh; return $true }
        return $false
    } finally { [void]$script:cfgLock.ReleaseMutex() }
}

function Same-Button($a, $b) {
    # -ceq, not -eq: PowerShell's -eq is case-INSENSITIVE, so "Deploy"/"/deploy prod" matched
    # a genuinely different button "deploy"/"/DEPLOY PROD". Two buttons whose text differs only
    # by case are two different prompts, and treating them as one deleted the wrong one.
    ($a.label -ceq $b.label) -and ($a.text -ceq $b.text) -and ([string]$a.chat -ceq [string]$b.chat)
}

# ---------- Locked CLI entry points for the /pin and /unpin skills ----------
# The skills used to read buttons.json, think, and write it back by hand. The panel guards
# every write with the Local\ClaudeButtonsConfig mutex and merges against a fresh read - but
# a lock only one of three writers honours is not a lock, and a panel edit landing inside the
# skill's read->write window was silently destroyed. Routing the skills through the SAME
# merge protocol closes that, and costs them nothing: one call instead of three file steps.
# Exits before any UI is built, so this is safe to run headless while the panel is running.
# Bind on PRESENCE, not truthiness: `-AddButton ""` used to be falsy, fall through, and launch
# the whole panel UI - so a caller whose payload path came out empty got a second panel instance
# and exit 0, i.e. "success" for a button that was never written.
if ($PSBoundParameters.ContainsKey('AddButton') -or $PSBoundParameters.ContainsKey('RemoveButton')) {
    if ($PSBoundParameters.ContainsKey('AddButton') -and $PSBoundParameters.ContainsKey('RemoveButton')) {
        [Console]::Error.Write('Pass -AddButton or -RemoveButton, not both.'); exit 2
    }
    # The value is either a PATH to a UTF-8 JSON file or inline JSON. Prefer the file: a button's
    # text can be a multi-paragraph prompt containing quotes and newlines, and those do not
    # survive being passed as a command-line argument through PowerShell. Same reason
    # -PasteProbe takes a file for the same reason.
    $isAdd = $PSBoundParameters.ContainsKey('AddButton')
    $raw = if ($isAdd) { $AddButton } else { $RemoveButton }
    if ([string]::IsNullOrWhiteSpace($raw)) { [Console]::Error.Write('Empty payload argument.'); exit 2 }
    # A mistyped path must say so. Reporting "Invalid JSON" for a missing file sent callers
    # off to retry with inline JSON - the one form that mangles multi-line prompts.
    $looksLikePath = $raw -match '^[A-Za-z]:\\|^\\\\|\.json\s*$'
    if ($looksLikePath -and -not (Test-Path -LiteralPath $raw -PathType Leaf)) {
        [Console]::Error.Write("Payload file not found: $raw"); exit 2
    }
    $payload = if (Test-Path -LiteralPath $raw -PathType Leaf) { [IO.File]::ReadAllText($raw) } else { $raw }
    try { $entry = $payload | ConvertFrom-Json } catch {
        [Console]::Error.Write("Invalid JSON in payload: $($_.Exception.Message)"); exit 2
    }
    if ($null -eq $entry) { [Console]::Error.Write('Payload parsed to null.'); exit 2 }
    # NOTE: Update-Buttons assigns the transform's output to $fresh.buttons UNCONDITIONALLY.
    # There is no "return nothing = leave it alone" contract, so a transform that declines to
    # change anything must still return the FULL array it was given. Returning $null writes
    # a buttons array containing one null entry, i.e. destroys the user's buttons.
    if ($isAdd) {
        if (-not $entry.text) { [Console]::Error.Write('A button needs a "text" field.'); exit 2 }
        if (-not $entry.label) { $entry | Add-Member label ([string]$entry.text) -Force }
        $script:cbAdded = $false
        $ok = Update-Buttons {
            param($btns)
            # Same duplicate rule the panel's own pin menu uses: same text in the same scope.
            $dup = @($btns | Where-Object { $_.text -eq $entry.text -and [string]$_.chat -eq [string]$entry.chat })
            if ($dup.Count -gt 0) { return @($btns) }   # unchanged, NOT null
            $script:cbAdded = $true
            @($btns) + $entry
        }
        if (-not $ok) { [Console]::Error.Write('Could not write buttons.json (locked or unreadable).'); exit 1 }
        if (-not $script:cbAdded) { Write-Output 'DUPLICATE: a button with that text already exists in that scope.'; exit 0 }
        Write-Output "ADDED: $($entry.label)"
        exit 0
    }
    # Refuse an ambiguous delete rather than guessing. Removing "every match" turned one
    # requested deletion into several, and a button's text may be a prompt the user wrote by
    # hand - there is no backup and no undo, so the only safe answer to "which one?" is to ask.
    $script:cbRemoved = 0
    $script:cbAmbiguous = 0
    $ok = Update-Buttons {
        param($btns)
        $all = @($btns)
        $hits = @($all | Where-Object { Same-Button $_ $entry })
        if ($hits.Count -gt 1) { $script:cbAmbiguous = $hits.Count; return $all }   # unchanged
        if ($hits.Count -eq 0) { return $all }                                      # unchanged
        $script:cbRemoved = 1
        $dropped = $false
        @($all | Where-Object {
            if (-not $dropped -and (Same-Button $_ $entry)) { $dropped = $true; $false } else { $true }
        })
    }
    if (-not $ok) { [Console]::Error.Write('Could not write buttons.json (locked or unreadable).'); exit 1 }
    if ($script:cbAmbiguous -gt 1) {
        [Console]::Error.Write("AMBIGUOUS: $($script:cbAmbiguous) buttons match that label/text/scope exactly - refusing to guess which to delete. Nothing was changed.")
        exit 3
    }
    if ($script:cbRemoved -eq 0) { Write-Output 'NOTFOUND: no button matched.'; exit 0 }
    Write-Output "REMOVED: 1"
    exit 0
}

# ---------- Text helpers ----------
$script:btnFont = New-Object System.Drawing.Font('Segoe UI', 11)
$script:compact = $false
$script:padX = S(6)   # tighter side padding so the label can carry a larger font at the same width

# ---------- Icons (built-in Windows icon font - Lucide-style line icons, no downloads) ----------
$fams = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
$script:iconFontName = if ($fams -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' }
                       elseif ($fams -contains 'Segoe MDL2 Assets') { 'Segoe MDL2 Assets' } else { $null }
$script:iconFont = if ($script:iconFontName) { New-Object System.Drawing.Font($script:iconFontName, 9) } else { $null }
# Lucide-style names -> glyph codepoints (shared between Fluent Icons and MDL2 Assets)
$script:iconMap = @{
    'mic'='E720'; 'power'='E7E8'; 'play'='E768'; 'pause'='E769'; 'stop'='E71A'
    'refresh'='E72C'; 'check'='E73E'; 'x'='E711'; 'trash'='E74D'; 'settings'='E713'
    'search'='E721'; 'save'='E74E'; 'code'='E943'; 'bug'='EBE8'; 'star'='E734'
    'pin'='E718'; 'send'='E724'; 'bell'='EA8F'; 'clock'='E823'; 'sun'='E706'
    'moon'='E708'; 'zap'='E945'; 'home'='E80F'; 'folder'='E8B7'; 'camera'='E722'
    'edit'='E70F'; 'plus'='E710'; 'download'='E896'; 'upload'='E898'; 'user'='E77B'
    'mail'='E715'; 'globe'='E774'; 'lock'='E72E'; 'heart'='EB51'; 'flag'='E7C1'
    'calendar'='E787'; 'phone'='E717'; 'broom'='EA99'; 'terminal'='E756'; 'shield'='EA18'
    'copy'='E8C8'; 'link'='E71B'
    # help / status
    'help'='E9CE'; 'question'='E897'; 'info'='E946'; 'warning'='E7BA'; 'error'='E783'
    # actions / editing
    'sync'='E895'; 'filter'='E71C'; 'list'='E8FD'; 'eye'='E7B3'; 'undo'='E7A7'
    'redo'='E7A6'; 'clipboard'='E77F'; 'file'='E7C3'; 'keyboard'='E765'; 'bulb'='EA80'
    # chat / feedback
    'comment'='E90A'; 'message'='E8BD'; 'thumbup'='E8E1'; 'thumbdown'='E8E0'; 'more'='E712'
    # arrows / navigation
    'arrow-right'='E72A'; 'arrow-left'='E72B'; 'arrow-up'='E70E'; 'arrow-down'='E70D'
    'up'='E74A'; 'down'='E74B'; 'chevron-left'='E76B'; 'chevron-right'='E76C'
    'expand'='E740'; 'collapse'='E73F'; 'move'='E7C2'; 'menu'='E700'; 'grid'='E75F'
    # notes / documents
    'note'='E70B'; 'document'='E729'; 'text'='E7BC'; 'book'='E736'; 'archive'='E7B8'
    'tag'='E75C'; 'attach'='E723'; 'checklist'='E762'; 'brackets'='E799'; 'cut'='E77A'
    # media / image
    'image'='E7AA'; 'video'='E714'; 'crop'='E7A8'; 'palette'='E790'; 'brush'='E754'
    'contrast'='E7A1'; 'volume'='E767'; 'mute'='E74F'; 'headphones'='E7F6'; 'record'='E7C8'
    # people / social
    'people'='E716'; 'contacts'='E779'; 'badge'='E780'; 'smile'='E76E'; 'chat'='E7E7'
    'share'='E72D'; 'megaphone'='E789'; 'gift'='E74C'; 'cart'='E7BF'
    # devices / system
    'monitor'='E770'; 'laptop'='E75B'; 'mobile'='E72F'; 'mouse'='E75E'; 'devices'='E703'
    'wifi'='E701'; 'bluetooth'='E702'; 'cloud'='E753'; 'print'='E749'; 'game'='E7FC'
    'car'='E7EC'; 'plane'='E709'; 'building'='E731'
    # actions / state
    'sparkle'='E794'; 'target'='E759'; 'sliders'='E78A'; 'zoom-in'='E71E'; 'zoom-out'='E71F'
    'unlock'='E785'; 'block'='E733'; 'reset'='E777'; 'logout'='E7F2'; 'alarm'='E781'
    'bell-off'='E7ED'; 'star-fill'='E735'; 'location'='E707'; 'translate'='E775'
    'accessibility'='E776'; 'education'='E7BE'; 'click'='E7C9'
}
# Dark single-line input dialog (replaces the plain white VB InputBox). Returns $null on cancel.
function Show-InputDialog([string]$title, [string]$message, [string]$default) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 39, 37)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 420), (S 122))
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $message
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(214, 210, 202)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lbl.Location = New-Object System.Drawing.Point((S 12), (S 12))
    $lbl.AutoSize = $true; $lbl.MaximumSize = New-Object System.Drawing.Size((S 396), 0)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $default
    $tb.BackColor = [System.Drawing.Color]::FromArgb(30, 29, 28)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(220, 216, 208)
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $tb.Location = New-Object System.Drawing.Point((S 12), (S 52))
    $tb.Size = New-Object System.Drawing.Size((S 396), (S 24))
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = L 'dlgOk'; $ok.DialogResult = 'OK'
    $ok.FlatStyle = 'Flat'; $ok.BackColor = [System.Drawing.Color]::FromArgb(62, 60, 56); $ok.ForeColor = $tb.ForeColor
    $ok.Location = New-Object System.Drawing.Point((S 230), (S 86)); $ok.Size = New-Object System.Drawing.Size((S 85), (S 28))
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'dlgCancel'; $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = $ok.BackColor; $cancel.ForeColor = $tb.ForeColor
    $cancel.Location = New-Object System.Drawing.Point((S 323), (S 86)); $cancel.Size = New-Object System.Drawing.Size((S 85), (S 28))
    $dlg.Controls.AddRange(@($lbl, $tb, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.add_Shown({ [CkWin]::DarkTitle($this.Handle); $this.Activate(); $this.BringToFront(); $tb.SelectAll(); $tb.Focus() })
    $res = $dlg.ShowDialog()
    $out = if ($res -eq 'OK') { $tb.Text } else { $null }
    $dlg.Dispose()
    return $out
}

# Dark multiline text dialog (for long standard prompts). Returns $null on cancel.
function Show-TextDialog([string]$title, [string]$message, [string]$default) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 39, 37)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 460), (S 250))
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $message
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(214, 210, 202)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lbl.Location = New-Object System.Drawing.Point((S 12), (S 10))
    $lbl.Size = New-Object System.Drawing.Size((S 436), (S 20))
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.AcceptsReturn = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Text = $default
    $tb.BackColor = [System.Drawing.Color]::FromArgb(30, 29, 28)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(220, 216, 208)
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $tb.Location = New-Object System.Drawing.Point((S 12), (S 34))
    $tb.Size = New-Object System.Drawing.Size((S 436), (S 168))
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = L 'dlgOk'; $ok.DialogResult = 'OK'
    $ok.FlatStyle = 'Flat'; $ok.BackColor = [System.Drawing.Color]::FromArgb(62, 60, 56); $ok.ForeColor = $tb.ForeColor
    $ok.Location = New-Object System.Drawing.Point((S 270), (S 212)); $ok.Size = New-Object System.Drawing.Size((S 85), (S 28))
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'dlgCancel'; $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = $ok.BackColor; $cancel.ForeColor = $tb.ForeColor
    $cancel.Location = New-Object System.Drawing.Point((S 363), (S 212)); $cancel.Size = New-Object System.Drawing.Size((S 85), (S 28))
    $dlg.Controls.AddRange(@($lbl, $tb, $ok, $cancel))
    $dlg.AcceptButton = $null   # Enter inserts a newline in the textbox; click OK to accept
    $dlg.CancelButton = $cancel
    $dlg.add_Shown({ [CkWin]::DarkTitle($this.Handle); [CkWin]::DarkScroll($tb.Handle); $this.Activate(); $this.BringToFront() })
    $res = $dlg.ShowDialog()
    $out = if ($res -eq 'OK') { $tb.Text } else { $null }
    $dlg.Dispose()
    return $out
}

function Get-IconGlyph([string]$name) {
    if (-not $script:iconFont -or [string]::IsNullOrWhiteSpace($name)) { return $null }
    $n = $name.Trim().ToLower()
    if ($script:iconMap.ContainsKey($n)) { return [string][char][Convert]::ToInt32($script:iconMap[$n], 16) }
    if ($n -match '^[0-9a-f]{4}$') { return [string][char][Convert]::ToInt32($n, 16) }  # raw codepoint for power users
    return $null
}

# Visual icon picker: a grid of the actual glyphs. Returns the chosen name,
# '' for "no icon (text label)", or $null on cancel.
# Fuzzy match score for the icon search: lower is better, $null means "no match".
# Ranks exact > prefix > substring > subsequence (chars in order with gaps), so typing
# "arw" finds arrow-* and "img" finds image without needing the exact name.
function Get-IconMatchScore([string]$needle, [string]$name) {
    if ([string]::IsNullOrWhiteSpace($needle)) { return 0 }
    $n = ($needle.Trim().ToLower() -replace '\s', '')
    $h = $name.ToLower()
    if ($h -eq $n) { return 0 }
    if ($h.StartsWith($n)) { return 1 }
    $idx = $h.IndexOf($n)
    if ($idx -ge 0) { return 10 + $idx }
    $i = 0; $gaps = 0; $last = -1
    for ($k = 0; $k -lt $h.Length -and $i -lt $n.Length; $k++) {
        if ($h[$k] -eq $n[$i]) {
            if ($last -ge 0) { $gaps += ($k - $last - 1) }
            $last = $k; $i++
        }
    }
    if ($i -eq $n.Length) { return 100 + $gaps }
    return $null
}

# Repopulate the picker grid, filtered by the search box. Plain function using $script:
# state - NOT a closure: GetNewClosure() rebinds $script: to the closure's own module scope,
# which silently broke $script:iconDlg/$script:iconPick inside the click handler.
function Fill-IconGrid {
    $flow = $script:iconFlow
    if (-not $flow) { return }
    $q = [string]$script:iconSearch.Text
    $flow.SuspendLayout()
    $old = @($flow.Controls)
    $flow.Controls.Clear()
    foreach ($o in $old) { $o.Dispose() }
    # Best match first; "No icon" only on an empty query so it never outranks a real hit.
    $matches = if ([string]::IsNullOrWhiteSpace($q)) { $script:iconEntries } else {
        $script:iconEntries | Where-Object { $_.name } |
            ForEach-Object { $sc = Get-IconMatchScore $q $_.name; if ($null -ne $sc) { [pscustomobject]@{ e = $_; s = $sc } } } |
            Sort-Object s, @{ e = { $_.e.name } } | ForEach-Object { $_.e }
    }
    foreach ($e in @($matches)) {
        $ib = New-Object System.Windows.Forms.Button
        $ib.Width = S 46; $ib.Height = S 46
        $ib.Margin = New-Object System.Windows.Forms.Padding((S 3))
        $ib.FlatStyle = 'Flat'; $ib.FlatAppearance.BorderSize = 0
        $ib.BackColor = if ($e.name -eq $script:iconCurrent) { [System.Drawing.Color]::FromArgb(120, 88, 44) } else { [System.Drawing.Color]::FromArgb(52, 51, 48) }
        $ib.ForeColor = [System.Drawing.Color]::FromArgb(224, 220, 212)
        if ($e.glyph) {
            # Draw the glyph with the SAME faux-bold the strip uses, so the picker previews the
            # true stroke weight; the offset scales with this larger font to match proportionally.
            $ib.Font = $script:iconBig; $ib.Text = ''
            $ib.add_Paint({
                param($src, $pe)
                $gl = Get-IconGlyph ([string]$this.Tag)
                if (-not $gl) { return }
                $gr = $pe.Graphics
                $gr.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
                $sf = New-Object System.Drawing.StringFormat
                $sf.Alignment = [System.Drawing.StringAlignment]::Center
                $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
                $br = New-Object System.Drawing.SolidBrush($this.ForeColor)
                $o = 0.3 * ($this.Font.Size / 9.0)
                foreach ($d in @(@(-$o, 0.0), @($o, 0.0), @(0.0, -$o), @(0.0, $o), @(0.0, 0.0))) {
                    $r = New-Object System.Drawing.RectangleF($d[0], $d[1], $this.Width, $this.Height)
                    $gr.DrawString($gl, $this.Font, $br, $r, $sf)
                }
                $br.Dispose(); $sf.Dispose()
            })
        }
        else { $ib.Font = New-Object System.Drawing.Font('Segoe UI', 7.5); $ib.Text = 'abc' }
        $ib.Tag = $e.name
        # No closure: $this must resolve to the clicked button at event time, and $script: must
        # reach the real script scope so the dialog refs below are visible.
        $ib.add_Click({ $script:iconPick = [string]$this.Tag; $script:iconDlg.DialogResult = 'OK'; $script:iconDlg.Close() })
        $script:iconTip.SetToolTip($ib, $(if ($e.name) { $e.name } else { 'No icon (text label)' }))
        [void]$flow.Controls.Add($ib)
    }
    $flow.ResumeLayout()
}

function Show-IconPicker([string]$current) {
    if (-not $script:iconFont) { return $null }
    $dlg = New-Object System.Windows.Forms.Form
    $script:iconDlg = $dlg
    $dlg.Text = L 'iconTitle'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 39, 37)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 400), (S 356))
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point((S 8), (S 8))
    $search.Size = New-Object System.Drawing.Size((S 384), (S 24))
    $search.BackColor = [System.Drawing.Color]::FromArgb(30, 29, 28)
    $search.ForeColor = [System.Drawing.Color]::FromArgb(224, 220, 212)
    $search.BorderStyle = 'FixedSingle'
    $search.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location = New-Object System.Drawing.Point((S 8), (S 40))
    $flow.Size = New-Object System.Drawing.Size((S 384), (S 272))
    $flow.AutoScroll = $true
    $flow.BackColor = $dlg.BackColor
    $script:iconPick = $null
    $script:iconBig = New-Object System.Drawing.Font($script:iconFontName, 15)
    $script:iconTip = New-Object System.Windows.Forms.ToolTip   # one shared tooltip, not one per icon
    $script:iconSearch = $search
    $script:iconFlow = $flow
    $script:iconCurrent = $current
    # "No icon" first, then all mapped icons
    $script:iconEntries = @(@{ name = ''; glyph = $null }) + (@($script:iconMap.Keys) | Sort-Object | ForEach-Object { @{ name = $_; glyph = (Get-IconGlyph $_) } })
    Fill-IconGrid                                     # initial (unfiltered) grid
    $search.add_TextChanged({ Fill-IconGrid })        # live fuzzy filter as you type
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'dlgCancel'; $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = [System.Drawing.Color]::FromArgb(62, 60, 56)
    $cancel.ForeColor = [System.Drawing.Color]::FromArgb(220, 216, 208)
    $cancel.Location = New-Object System.Drawing.Point((S 300), (S 320)); $cancel.Size = New-Object System.Drawing.Size((S 92), (S 28))
    $dlg.Controls.AddRange(@($search, $flow, $cancel))
    $dlg.CancelButton = $cancel
    # Make sure the dialog appears in front and takes focus (the panel window never activates,
    # so a child dialog can otherwise open behind and block the panel modally out of sight).
    $dlg.add_Shown({ [CkWin]::DarkTitle($this.Handle); [CkWin]::DarkScroll($script:iconFlow.Handle); $this.Activate(); $this.BringToFront() })
    $res = $dlg.ShowDialog()
    $out = if ($res -eq 'OK') { $script:iconPick } else { $null }
    $script:iconTip.Dispose(); $script:iconBig.Dispose()
    $dlg.Dispose()
    $script:iconDlg = $null; $script:iconFlow = $null; $script:iconSearch = $null; $script:iconEntries = $null
    return $out
}

# (removed: the Escape-SendKeys note - there is no typing path any more, see the top)


function Get-ShortLabel($b) {
    if ($b.short) { return [string]$b.short }
    $l = [string]$b.label
    $first = ($l -split ' ')[0]
    if ($first.Length -le 8) { return $first }
    return $l.Substring(0, 8) + [char]0x2026
}

function Get-DisplayLabel($b) {
    if ($script:compact) { Get-ShortLabel $b } else { [string]$b.label }
}

function Get-PillWidth([string]$label) {
    ([System.Windows.Forms.TextRenderer]::MeasureText($label, $script:btnFont)).Width + 2 * $script:padX
}

# Same formula Rebuild-Buttons uses, so the compact switch triggers precisely
function Get-StripWidth([bool]$useShort) {
    $total = (S 14) + 4 * (S 2) + (S 8)  # grip + panel padding + safety margin
    foreach ($b in $script:config.buttons) {
        if (-not (Test-ChatButtonVisible $b)) { continue }
        if ($b.icon -and (Get-IconGlyph ([string]$b.icon))) {
            $total += $pillH + 2 * (S 2)   # icon buttons are circular: width = height
            continue
        }
        $label = if ($useShort) { Get-ShortLabel $b } else { [string]$b.label }
        $total += (Get-PillWidth $label) + 2 * (S 2)
    }
    return $total
}

# Set a pill's normal face (icon glyph or text label) - used at build, disarm and toggle
function Set-PillFace($btn) {
    $b = $btn.Tag
    $glyph = if ($b.icon) { Get-IconGlyph ([string]$b.icon) } else { $null }
    if ($glyph) {
        $btn.Font = $script:iconFont
        $btn.Text = $glyph
        $btn.Width = $pillH
    } else {
        $btn.Font = $script:btnFont
        $btn.Text = Get-DisplayLabel $b
        $btn.Width = Get-PillWidth $btn.Text
    }
}

function Read-ActiveSession {
    try {
        $item = Get-Item $activePath -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        if ($item.LastWriteTimeUtc -eq $script:activeTime) { return $false }
        $data = Get-Content $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:activeTime = $item.LastWriteTimeUtc
        try { $script:activeTs = [DateTime]::Parse([string]$data.ts).ToUniversalTime() } catch { $script:activeTs = $item.LastWriteTimeUtc }
        if ($data.session_id -and $data.session_id -ne $script:activeSession) {
            $script:activeSession = [string]$data.session_id
            return $true
        }
    } catch {}
    return $false
}

# ---------- UIA: read the displayed chat + chat-area geometry from the app's own UI ----------
$script:uiaTitle = $null      # title of the chat shown in the FIRST pane (primary strip)
$script:paneRect = $null      # first chat pane relative to the window
$script:rowCenterOff = $null  # bottom buttons' vertical center, measured from the pane bottom
$script:leftEdgeOff = $null   # right edge of the pane's left button cluster, from window left
$script:paneBottomOff = 0     # first pane's bottom edge, measured up from the window bottom
$script:panes = @()           # ALL chat panes (side-by-side / grid view) - one strip per pane
$script:uiaDirty = $false
$script:uiaLast = Get-Date '2000-01-01'
$script:uiaInterval = 1500    # ms between UIA passes; backs off once geometry is stable
$script:uiaStable = 0

# One reusable UIA cache: FindAll/FindFirst under this request populate each element's
# .Cached Name + BoundingRectangle in a single cross-process batch, instead of a round-trip
# per .Current.* read (the FindAll over the app's a11y tree was the panel's biggest cost).
$script:uiaCache = New-Object System.Windows.Automation.CacheRequest
$script:uiaCache.Add([System.Windows.Automation.AutomationElement]::NameProperty)
$script:uiaCache.Add([System.Windows.Automation.AutomationElement]::BoundingRectangleProperty)

# Measure one chat pane: geometry, displayed chat title, bottom button row.
# Must run inside an active $script:uiaCache scope (reads .Cached.*).
function Measure-Pane($pane, $wr, $btnCond) {
    $pr = $pane.Cached.BoundingRectangle
    $paneBottom = $pr.Y + $pr.Height
    $info = @{
        OffL = [int]($pr.X - $wr.Left); OffT = [int]($pr.Y - $wr.Top); Width = [int]$pr.Width
        BottomOff = [int][Math]::Max(0, $wr.Bottom - $paneBottom)
        Title = $null; RowCenter = $null; LeftOff = $null
    }
    $btns = $pane.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    # Chat title = leftmost named button in the pane's top strip
    $best = $null; $bestX = [double]::MaxValue
    foreach ($b in $btns) {
        $br = $b.Cached.BoundingRectangle
        if ($br.Y -ge $pr.Y -and $br.Y -lt ($pr.Y + (SW $script:zoneTop)) -and $br.X -lt $bestX -and $b.Cached.Name) { $best = $b; $bestX = $br.X }
    }
    if ($best) { $info.Title = [string]$best.Cached.Name }
    # Bottom-left button cluster within THIS pane (grid panes have their own bottom bars)
    $sumY = 0.0; $n = 0; $rightEdge = $null
    foreach ($b in $btns) {
        $br = $b.Cached.BoundingRectangle
        $cy = $br.Y + $br.Height / 2
        if ($cy -gt ($paneBottom - (SW $script:zoneBottom)) -and $cy -lt $paneBottom -and $br.X -ge $pr.X -and $br.X -lt ($pr.X + $pr.Width / 2)) {
            $sumY += $cy; $n++
            $re = $br.X + $br.Width
            if ($null -eq $rightEdge -or $re -gt $rightEdge) { $rightEdge = $re }
        }
    }
    if ($n -gt 0) {
        $info.RowCenter = [int]($paneBottom - ($sumY / $n))
        $info.LeftOff = [int]($rightEdge - $wr.Left)
    }
    return $info
}

# Turn ON Chromium's web accessibility tree (off by default until an AT client requests the
# render-widget root). Without this the whole web UI is a single opaque Document and we can
# see nothing inside. Continuous UIA polling in Update-UiaInfo keeps it from auto-disabling.
$script:a11yTarget = [IntPtr]::Zero
function Enable-WebA11y {
    if ($script:target -eq [IntPtr]::Zero -or $script:a11yTarget -eq $script:target) { return }
    try {
        foreach ($rw in [CkChild]::RenderWidgets($script:target)) {
            try { [void][System.Windows.Automation.AutomationElement]::FromHandle($rw) } catch {}
        }
        [void][System.Windows.Automation.AutomationElement]::FromHandle($script:target)
        $script:a11yTarget = $script:target
    } catch {}
}

# The chat composers: keyboard-focusable Groups named "Prompt", one per pane. Their positions
# ARE the pane layout (works for any split/grid), and each is the focus target for sending.
function Get-Composers($root) {
    $out = @()
    try {
        # Height ceiling scales with the window. The composer GROWS as you type or paste, and a
        # fixed 220px cap made a large pasted prompt stop matching - the pane dropped out and its
        # strip vanished until the text was sent. Anything taller than most of the window is a
        # container rather than an input, so cap at 60% of the window height.
        $maxH = 700
        try { $rb = $root.Current.BoundingRectangle; if ($rb.Height -gt 100) { $maxH = [int]($rb.Height * 0.6) } } catch {}
        $grpT  = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group)
        $nameC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $script:uiaComposerName)
        $cond  = New-Object System.Windows.Automation.AndCondition($grpT, $nameC)
        $els = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($e in $els) {
            $b = $e.Current.BoundingRectangle
            if ($b.Width -lt 200 -or $b.Height -lt 20 -or $b.Height -gt $maxH) { continue }
            $out += [pscustomobject]@{ El = $e; X = [int]$b.X; Y = [int]$b.Y; W = [int]$b.Width; H = [int]$b.Height }
        }
    } catch {}
    return @($out)
}

function Update-UiaInfo {
    if (((Get-Date) - $script:uiaLast).TotalMilliseconds -lt $script:uiaInterval) { return }
    $script:uiaLast = Get-Date
    try {
        if ($script:target -eq [IntPtr]::Zero) { throw 'no window' }
        Enable-WebA11y   # turn the web AXTree on (idempotent per window); this poll keeps it alive
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:target)
        $wr = New-Object CkWin+RECT
        [void][CkWin]::GetWindowRect($script:target, [ref]$wr)
        $grpType = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group)

        # Two signatures: CONTENT (which buttons each strip shows) vs GEOMETRY (where they sit).
        # Only a content change rebuilds buttons; geometry changes just reposition (no flicker).
        $prevContentSig = "$($script:panes.Count)|" + (($script:panes | ForEach-Object { $_.Title }) -join '|')
        $prevGeoSig = ($script:panes | ForEach-Object { "$($_.OffL),$($_.OffT),$($_.Width),$($_.RowCenter)" }) -join '|'

        $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

        # Activate the property cache for every UIA query below (root, panes, buttons).
        $cacheScope = $script:uiaCache.Activate()
        try {
        # Strategy 0 (primary): the chat composers ("Prompt" groups) ARE the panes - one per
        # chat, in any split/grid layout. Their positions define where to dock each strip and
        # give us the exact element to focus when a button on that strip is clicked.
        # Sort into ROWS by a coarse Y band (so 1px render jitter between same-row panes can't
        # flip their order and swap strips), then left-to-right by X within each row.
        $composers = @(Get-Composers $root | Sort-Object @{ e = { [int]($_.Y / 50) } }, @{ e = { $_.X } })
        $newPanes = @()
        # Once composer detection has worked, losing it means the composers left the tree - a
        # Claude modal/menu is up. Do NOT fall back to legacy positioning then: that parks the
        # strips at the pane's left edge on top of the dialog. Hide them instead.
        if ($composers.Count -gt 0) { $script:composerSeen = $true; $script:composerLost = $false }
        elseif ($script:composerSeen) { $script:composerLost = $true }
        if ($composers.Count -gt 0) {
            # All buttons once (cached); per composer, find its control row (the Auto/+/mic bar
            # just below the input) so we dock the strip AFTER that left cluster, on that row -
            # exactly where it sat before, but per pane.
            $allBtns = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
            foreach ($c in $composers) {
                $cBottom = $c.Y + $c.H
                # Collect the control-row buttons just below this composer (its left half).
                $rowBtns = @()
                foreach ($b in $allBtns) {
                    $bb = $b.Cached.BoundingRectangle
                    $bcy = $bb.Y + $bb.Height / 2
                    if ($bcy -gt $cBottom -and $bcy -lt ($cBottom + (SW 64)) -and $bb.X -ge ($c.X - 12) -and $bb.X -lt ($c.X + $c.W * 0.6)) {
                        $rowBtns += [pscustomobject]@{ X = [double]$bb.X; R = [double]($bb.X + $bb.Width); CY = $bcy }
                    }
                }
                # Drop wrapper nodes: a "button" whose rect fully contains a smaller one in the
                # same row is a grouping element, not a control. It shows up only in some reads,
                # and its far right edge was dragging the dock past the mic (random displacement).
                $rowBtns = @($rowBtns | Where-Object {
                    $a = $_
                    -not ($rowBtns | Where-Object { $_ -ne $a -and $_.X -ge $a.X -and $_.R -le $a.R -and (($_.R - $_.X) -lt ($a.R - $a.X)) })
                })
                # Dock after the CONTIGUOUS left cluster (Auto/+/mic/...), not the rightmost
                # button: walk left-to-right and stop at the first real gap. The genuine controls
                # sit ~6px apart, so a tight threshold keeps out anything further right (a send/
                # stop control that appears while typing, or the model label).
                $rightEdge = $c.X; $sumY = 0.0; $n = 0
                foreach ($rb in ($rowBtns | Sort-Object X)) {
                    if ($n -eq 0 -or $rb.X -le ($rightEdge + (SW 20))) {
                        if ($rb.R -gt $rightEdge) { $rightEdge = $rb.R }
                        $sumY += $rb.CY; $n++
                    } else { break }
                }
                $dockX = if ($n -gt 0) { [int]$rightEdge } else { [int]$c.X }
                $dockY = if ($n -gt 0) { [int]($sumY / $n) } else { [int]($cBottom + (SW 20)) }
                $newPanes += @{
                    OffL = $c.X - $wr.Left; OffT = $c.Y - $wr.Top; Width = $c.W
                    BottomOff = 0; Title = $null; RowCenter = $null; LeftOff = $null
                    Cx = $c.X; Cy = $c.Y; Cw = $c.W; Ch = $c.H; Composer = $c.El
                    DockX = $dockX; DockY = $dockY
                    # Dock point stored RELATIVE to the composer, so the per-tick geometry
                    # refresh can recompute it live without redoing the expensive tree walk.
                    DockDX = $dockX - [int]$c.X
                    DockDY = $dockY - [int]($c.Y + $c.H)
                    # Did we find the control-row buttons we dock after? When a Claude modal
                    # (settings, connectors, a menu) is open they leave the tree, which both
                    # slides the strip to the pane's left edge and means the composer is not
                    # really usable - so the strip hides instead of floating over the dialog.
                    Anchored = ($n -gt 0)
                }
            }
        } elseif ($script:composerSeen) {
            # Composers were there and vanished (modal/menu open): no panes -> every strip hides.
        } else {
            # Fallback (accessibility not yet built, or an unexpected layout): legacy pane groups.
            $allGroups = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $grpType)
            $found = @()
            foreach ($gp in $allGroups) {
                $gn = $gp.Cached.Name
                if ($gn -and ($gn -match $script:uiaPaneMatch) -and $gp.Cached.BoundingRectangle.Width -gt (SW 250)) { $found += $gp }
            }
            if ($found.Count -gt 0) {
                foreach ($p in $found) { $newPanes += (Measure-Pane $p $wr $btnCond) }
                $newPanes = @($newPanes | Sort-Object @{ e = { [int]($_.OffT / 100) } }, @{ e = { $_.OffL } })
            }
        }
        } finally { $cacheScope.Dispose() }
        $script:panes = $newPanes

        # Primary aliases = first pane (kept for the main strip and pinning)
        if ($newPanes.Count -gt 0) {
            $p0 = $newPanes[0]
            $script:paneRect = @{ OffL = $p0.OffL; Width = $p0.Width }
            $script:rowCenterOff = $p0.RowCenter
            $script:leftEdgeOff = $p0.LeftOff
            $script:paneBottomOff = $p0.BottomOff
            $script:paneComposer = $p0.Composer   # composer rect (screen px) for the primary strip
            if ($p0.Cx) { $script:paneCRect = @{ X = $p0.Cx; Y = $p0.Cy; W = $p0.Cw; H = $p0.Ch; DockX = $p0.DockX; DockY = $p0.DockY; Anchored = $p0.Anchored } } else { $script:paneCRect = $null }
            if ($p0.Title -ne $script:uiaTitle) { $script:uiaTitle = $p0.Title; $script:uiaDirty = $true }
        } else {
            $script:paneRect = $null; $script:rowCenterOff = $null; $script:leftEdgeOff = $null; $script:paneBottomOff = 0
            $script:paneComposer = $null; $script:paneCRect = $null
            if ($null -ne $script:uiaTitle) { $script:uiaTitle = $null; $script:uiaDirty = $true }
        }

        # Rebuild buttons ONLY when content changes (pane count or a pane's chat title).
        # Geometry drift (dragging, resizing) must NOT rebuild - the tick repositions instead.
        $newContentSig = "$($newPanes.Count)|" + (($newPanes | ForEach-Object { $_.Title }) -join '|')
        if ($newContentSig -ne $prevContentSig) { $script:uiaDirty = $true }

        # Back off polling once geometry is fully stable; any change resumes fast polling
        $newGeoSig = ($newPanes | ForEach-Object { "$($_.OffL),$($_.OffT),$($_.Width),$($_.RowCenter)" }) -join '|'
        if ($newGeoSig -eq $prevGeoSig -and $newContentSig -eq $prevContentSig) {
            if ($script:uiaStable -lt 6) { $script:uiaStable++ }
        } else { $script:uiaStable = 0 }
        $script:uiaInterval = if ($script:uiaStable -ge 6) { 5000 } else { 1500 }
    } catch {
        if ($null -ne $script:uiaTitle) { $script:uiaDirty = $true }
        $script:uiaTitle = $null
        $script:paneRect = $null
        $script:rowCenterOff = $null
        $script:leftEdgeOff = $null
        $script:paneBottomOff = 0
        $script:panes = @()
        $script:uiaInterval = 1500; $script:uiaStable = 0
    }
}

function Test-ChatButtonVisible($b) {
    if (-not $b.chat -and -not $b.chatTitle) { return $true }        # global
    if ($b.chatTitle -and $script:uiaTitle) {
        return ($b.chatTitle -eq $script:uiaTitle)                    # precise: the chat being displayed
    }
    if ($b.chat) {
        if ($script:activeExpired) { return $false }                  # fallback: last chat messaged
        return ($b.chat -eq $script:activeSession)
    }
    return $false
}

# ---------- Warm color palette (matches the app's dark theme) ----------
$colBar   = [System.Drawing.Color]::FromArgb(29, 29, 28)   # 1d1d1c - matches Claude's bottom bar
$colFill  = [System.Drawing.Color]::FromArgb(48, 47, 44)
$colHover = [System.Drawing.Color]::FromArgb(48, 48, 47)   # 30302f - matches Claude's own icon hover
$colDown  = [System.Drawing.Color]::FromArgb(58, 58, 56)   # a touch brighter for press feedback
$colText  = [System.Drawing.Color]::FromArgb(214, 210, 202)
$colIcon  = [System.Drawing.Color]::FromArgb(168, 168, 168)   # a8a8a8 - icon glyphs + kebab dots (soft grey, like Claude's own)
$colAccent = [System.Drawing.Color]::FromArgb(198, 146, 78)   # border on per-chat buttons (brightened for WCAG 1.4.11)
$pillH = S(27)   # square icon buttons; the glyph font stays fixed, so this is padding around the icon

# Strip background color (alias kept so the transparent-strip work has one knob).
$script:barColor = $colBar

# Recomposite a layered strip: paint its controls onto a transparent ARGB bitmap (button
# pixels at alpha=1 stay clickable but invisible) and push it to the window. A layered
# per-pixel-alpha window ignores normal WM_PAINT, so this replaces control painting.
function Update-LayeredStrip($frm, $pnl) {
    if (-not $frm -or -not $frm.IsHandleCreated) { return }
    $w = $frm.Width; $h = $frm.Height
    if ($w -le 0 -or $h -le 0) { return }
    $bmp = $null; $g = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        foreach ($ctrl in $pnl.Controls) {
            if ($ctrl -is [PillButton] -or $ctrl -is [GripHandle]) {
                $ctrl.RenderTo($g, ($pnl.Left + $ctrl.Left), ($pnl.Top + $ctrl.Top))
            }
        }
        [Layered]::Push($frm.Handle, $bmp, $frm.Left, $frm.Top)
    } catch { Write-CkLog "Update-LayeredStrip error: $($_.Exception.Message)" }
    finally { if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() } }
}
# Re-push the strip that owns a control (fired from a button's Repaint event on hover/toggle).
function Render-StripFor($ctrl) {
    if (-not $ctrl) { return }
    $pnl = $ctrl.Parent
    if ($pnl) { Update-LayeredStrip $pnl.FindForm() $pnl }
}

# ---------- UI ----------
$form = New-Object LayeredForm
$form.Text = 'Claude Buttons'
$form.TopMost = $true
# TopMost + the occlusion probe below. Do NOT try to attach these to Claude's owner chain
# (GWLP_HWNDPARENT): it hung claude.exe (Windows "stopped communicating", event 1002) because
# this UI thread blocks on synchronous UIA/SendKeys work, and the window manager then waits on
# it for the owner chain's z-order/activation. Verified by crash log, not theory.
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.AutoSize = $true
$form.AutoSizeMode = 'GrowAndShrink'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
# Layered forms draw via UpdateLayeredWindow (see Update-LayeredStrip); no Opacity/BackColor.

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.FlowDirection = 'LeftToRight'
$panel.WrapContents = $false
$panel.AutoSize = $true
$panel.AutoSizeMode = 'GrowAndShrink'
$panel.Padding = New-Object System.Windows.Forms.Padding(0, (S(2)), (S(3)), (S(2)))
[System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($panel, $true, $null)
$form.Controls.Add($panel)

# Dark theme on all menus (applies to the whole process)
[System.Windows.Forms.ToolStripManager]::Renderer = New-Object CkRenderer

# Custom hover tooltip - the built-in WinForms ToolTip is unreliable on a
# window that never takes focus, so we draw our own themed tip form.
$tipForm = New-Object NoActivateForm
$tipForm.FormBorderStyle = 'None'
$tipForm.TopMost = $true
$tipForm.ShowInTaskbar = $false
$tipForm.StartPosition = 'Manual'
$tipForm.AutoSize = $true
$tipForm.AutoSizeMode = 'GrowAndShrink'
$tipForm.BackColor = [System.Drawing.Color]::FromArgb(46, 45, 43)
$tipForm.Padding = New-Object System.Windows.Forms.Padding((S 9), (S 6), (S 9), (S 6))
$tipLbl = New-Object System.Windows.Forms.Label
$tipLbl.AutoSize = $true
$tipLbl.MaximumSize = New-Object System.Drawing.Size((S 360), 0)
$tipLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
$tipLbl.ForeColor = [System.Drawing.Color]::FromArgb(216, 212, 204)
$tipLbl.BackColor = $tipForm.BackColor
$tipLbl.Location = New-Object System.Drawing.Point((S 9), (S 6))
$tipForm.Controls.Add($tipLbl)

$script:hoverCtrl = $null
$script:hoverAt = Get-Date '2000-01-01'
$script:balloonShown = $false
$script:tipUntil = $null

function Show-TipForm([string]$text, $anchorCtrl) {
    try {
        $tipLbl.Text = $text
        $p = $anchorCtrl.PointToScreen([System.Drawing.Point]::Empty)
        $af = $anchorCtrl.FindForm()
        if (-not $af) { $af = $form }
        $x = $p.X
        $y = $af.Top - $tipForm.Height - (S 7)   # above the strip the control sits in
        if ($y -lt 0) { $y = $af.Bottom + (S 7) }
        $tipForm.Location = New-Object System.Drawing.Point($x, $y)
        if (-not $tipForm.Visible) { $tipForm.Show() }
    } catch {}
}

# A send was abandoned - say so where the user is already looking. Every other failure in this
# path only ever reached the log file, which means "I clicked and nothing happened" was
# indistinguishable from success. Reuses the tooltip window so nothing takes focus.
function Show-SendWarning([string]$text) {
    try {
        $anchor = if ($script:lastClickedBtn) { $script:lastClickedBtn } else { $grip }
        # Reuse $script:tipUntil: the tick checks it BEFORE the hover branch, so the warning
        # stays put for its full duration instead of being replaced the moment the pointer
        # moves - and the existing timeout logic hides it, with no second mechanism to keep
        # in sync.
        $script:tipUntil = (Get-Date).AddSeconds(8)
        Show-TipForm $text $anchor
    } catch {}
}

# Hover-tekst for en knap: valgfri "desc"-forklaring + kommando + scope + betjening
function Get-TipText($b) {
    $head = if ($b.icon) { "$($b.label): $($b.text)" } else { [string]$b.text }
    $head = $head -replace "`r`n", ' ' -replace "`n", ' '
    if ($head.Length -gt 140) { $head = $head.Substring(0, 140) + [char]0x2026 }
    $scope = if ($b.chat -or $b.chatTitle) {
        $sl = if ($b.chatTitle) { $b.chatTitle } elseif ($b.chatLabel) { $b.chatLabel } else { $null }
        if ($sl) { (L 'tipChatIn') -f $sl } else { L 'tipChatOnly' }
    } else { L 'tipGlobal' }
    $enter = if ($b.toggle) { L 'tipToggle' } elseif ($b.submit -and -not $b.chat) { L 'tipSends' } else { L 'tipInserts' }
    $out = ''
    if ($b.desc) { $out = "$($b.desc)`n" }
    # Only advertise Shift-click on buttons that would otherwise send.
    $shiftHint = if ($b.submit -and -not $b.chat) { "`n$(L 'tipShift')" } else { '' }
    "$out$head`n$scope - $enter$shiftHint`n$(L 'tipRemove')"
}

# Grip
$grip = New-Object GripHandle
$grip.BackColor = $script:barColor
$grip.DotColor = $colIcon
$grip.HoverFill = $colHover
$grip.DownFill = $colDown
$grip.Width = $pillH
$grip.Height = $pillH
$grip.Margin = New-Object System.Windows.Forms.Padding((S(3)))
$grip.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
$grip.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })
$grip.add_Repaint({ Render-StripFor $this })

# ---------- Instant pin menu (no Claude involved) ----------
function Get-PinCatalog {
    $cat = if ($script:lang -eq 'da') { @(
        @{ text = '/code-review'; label = 'Code review'; short = 'Review' },
        @{ text = '/simplify'; label = 'Forenkl koden'; short = 'Forenkl' },
        @{ text = '/verify'; label = 'Verificér ændring'; short = 'Verify' },
        @{ text = 'fortsæt'; label = 'Fortsæt'; short = 'Fortsæt' }
    ) } else { @(
        @{ text = '/code-review'; label = 'Code review'; short = 'Review' },
        @{ text = '/simplify'; label = 'Simplify code'; short = 'Simplify' },
        @{ text = '/verify'; label = 'Verify change'; short = 'Verify' },
        @{ text = 'continue'; label = 'Continue'; short = 'Cont.' }
    ) }
    $known = @($cat | ForEach-Object { $_.text })
    # Your own skills under ~/.claude/skills appear in the menu automatically
    try {
        Get-ChildItem (Join-Path $env:USERPROFILE '.claude\skills') -Directory -ErrorAction Stop | ForEach-Object {
            $t = "/$($_.Name)"
            $confirm = ($_.Name -match 'close-pc|shutdown|delete|deploy')
            if ($known -notcontains $t) { $cat += @{ text = $t; label = $_.Name; short = $null; confirm = $confirm } }
        }
    } catch {}
    return $cat
}

function Add-PinnedButton($entry, [bool]$global) {
    try {
        $chatId = ''
        if (-not $global) {
            if ($script:uiaTitle) {
                if ($script:activeSession -and -not $script:activeExpired) { $chatId = $script:activeSession }
            } elseif ($script:activeSession -and -not $script:activeExpired) {
                $chatId = $script:activeSession
            } else {
                [void][System.Windows.Forms.MessageBox]::Show((L 'noActive'), 'Claude Buttons', 'OK', 'Warning')
                return
            }
        }
        foreach ($b in $script:config.buttons) {
            if ($b.text -eq $entry.text -and ([string]$b.chat -eq $chatId)) {
                [void][System.Windows.Forms.MessageBox]::Show((L 'dupPin'), 'Claude Buttons', 'OK', 'Information')
                return
            }
        }
        Write-CkLog "Pinning button: label='$($entry.label)' global=$global chatScoped=$([bool]$chatId)"
        $new = [ordered]@{ label = [string]$entry.label; text = [string]$entry.text; submit = $true }
        if ($entry.short) { $new.short = [string]$entry.short }
        if ($entry.confirm) { $new.confirm = $true }
        if ($chatId) { $new.chat = $chatId }
        if (-not $global -and $script:uiaTitle) { $new.chatTitle = $script:uiaTitle }  # bind to the DISPLAYED chat
        $newObj = [pscustomobject]$new
        if (Update-Buttons { param($btns) @($btns) + $newObj }) { Rebuild-Buttons }
    } catch { Write-CkLog "Add-PinnedButton error: $($_.Exception.Message)" }
}

function Set-CkLang([string]$l) {
    try { $script:lang = $l; Save-PanelState; Rebuild-Buttons } catch { Write-CkLog "Set-CkLang error: $($_.Exception.Message)" }
}

$gripMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miPin = New-Object System.Windows.Forms.ToolStripMenuItem 'Pin new button'
[void]$gripMenu.Items.Add($miPin)
$miLang = New-Object System.Windows.Forms.ToolStripMenuItem 'Language'
$subEn = New-Object System.Windows.Forms.ToolStripMenuItem 'English'
$subEn.add_Click({ Set-CkLang 'en' })
$subDa = New-Object System.Windows.Forms.ToolStripMenuItem 'Dansk'
$subDa.add_Click({ Set-CkLang 'da' })
[void]$miLang.DropDownItems.Add($subEn)
[void]$miLang.DropDownItems.Add($subDa)
[void]$gripMenu.Items.Add($miLang)
$miTips = New-Object System.Windows.Forms.ToolStripMenuItem 'Hover tooltips'
$miTips.CheckOnClick = $true
$miTips.Checked = -not $script:tipsOff
$miTips.add_Click({
    $script:tipsOff = -not $this.Checked
    if ($script:tipsOff -and $tipForm.Visible) { $tipForm.Hide(); $script:tipCtrl = $null }
    Save-PanelState
})
[void]$gripMenu.Items.Add($miTips)
[void]$gripMenu.Items.Add('-')
$miClose = $gripMenu.Items.Add('Close panel')
$miClose.add_Click({ $form.Close() })
[void]$gripMenu.Items.Add('-')
$miVer = $gripMenu.Items.Add("Claude Buttons v$CB_VERSION")
$miVer.Enabled = $false
$grip.ContextMenuStrip = $gripMenu
# Open the grip menu on left-click too (the grip looks clickable)
$grip.add_MouseUp({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $gripMenu.Show($grip, $_.Location) } })

# Fill a scope submenu ("this chat" / "global") with the whole catalog + a custom option.
# Picking a command pins it with that scope in ONE click - no separate scope toggle.
function Fill-PinScope($sub, [bool]$isGlobal) {
    $sub.DropDownItems.Clear()
    foreach ($entry in (Get-PinCatalog)) {
        $ci = New-Object System.Windows.Forms.ToolStripMenuItem ("$($entry.label)   ($($entry.text))")
        $ci.Tag = @{ entry = $entry; global = $isGlobal }
        $ci.add_Click({ $t = $this.Tag; Add-PinnedButton $t.entry $t.global })
        [void]$sub.DropDownItems.Add($ci)
    }
    [void]$sub.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $cust = New-Object System.Windows.Forms.ToolStripMenuItem (L 'custom')
    $cust.Tag = $isGlobal
    $cust.add_Click({
        $g = [bool]$this.Tag
        $txt = Show-TextDialog (L 'pinTitle') (L 'askText') ''
        if ([string]::IsNullOrWhiteSpace($txt)) { return }
        $suggest = ($txt -split "`n")[0].Trim(); if ($suggest.Length -gt 30) { $suggest = $suggest.Substring(0, 30) }
        $lbl = Show-InputDialog (L 'pinTitle') (L 'askLabel') $suggest
        if ($null -eq $lbl) { return }   # cancelled
        if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = $suggest }
        Add-PinnedButton @{ text = $txt.Trim(); label = $lbl.Trim(); short = $null } $g
    })
    [void]$sub.DropDownItems.Add($cust)
}

$piThis = New-Object System.Windows.Forms.ToolStripMenuItem (L 'onlyChat')
$piGlob = New-Object System.Windows.Forms.ToolStripMenuItem (L 'globalScope')
[void]$miPin.DropDownItems.Add($piThis)
[void]$miPin.DropDownItems.Add($piGlob)

# Rebuilt fresh every time the menu opens (reflects new skills, pinned buttons and language)
$gripMenu.add_Opening({
    [void][CkWin]::GetAsyncKeyState(0x01); [void][CkWin]::GetAsyncKeyState(0x02)
    $miPin.Text = L 'pinNew'
    $miClose.Text = L 'closePanel'
    $miLang.Text = L 'language'
    $subEn.Checked = ($script:lang -eq 'en')
    $subDa.Checked = ($script:lang -eq 'da')
    $piThis.Text = L 'onlyChat'; $piGlob.Text = L 'globalScope'
    Fill-PinScope $piThis $false
    Fill-PinScope $piGlob $true
})

# ---------- Button context menu (capture source on right mouse-down) ----------
$script:menuSource = $null
$btnMenu = New-Object System.Windows.Forms.ContextMenuStrip
$btnMenu.add_Opening({
    [void][CkWin]::GetAsyncKeyState(0x01); [void][CkWin]::GetAsyncKeyState(0x02)
    if ($this.SourceControl) { $script:menuSource = $this.SourceControl }
    $miRename.Text = L 'rename'
    $miEdit.Text = L 'editText'
    $miIcon.Text = L 'setIcon'
    $miToggle.Text = L 'toggleMode'
    $miLeft.Text = L 'moveLeft'
    $miRight.Text = L 'moveRight'
    $miRemove.Text = L 'remove'
    $miIcon.Enabled = ($null -ne $script:iconFont)
    if ($script:menuSource -and $script:menuSource.Tag) { $miToggle.Checked = [bool]$script:menuSource.Tag.toggle } else { $miToggle.Checked = $false }
})

$miRename = $btnMenu.Items.Add('Rename...')
$miEdit   = $btnMenu.Items.Add('Edit text/prompt...')
$miIcon   = $btnMenu.Items.Add('Set icon...')

$miEdit.add_Click({
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $t = $src.Tag
        $val = Show-TextDialog (L 'editTextTitle') (L 'askText') ([string]$t.text)
        if ($null -eq $val -or [string]::IsNullOrWhiteSpace($val)) { return }
        $ok = Update-Buttons { param($btns)
            foreach ($b in $btns) { if (Same-Button $b $t) { $b.text = $val.Trim() } }
            $btns
        }
        if ($ok) { Rebuild-Buttons }
    } catch { Write-CkLog "Edit text error: $($_.Exception.Message)" }
})
$miToggle = $btnMenu.Items.Add('On/off (toggle) mode')
$miLeft   = $btnMenu.Items.Add('Move left')
$miRight  = $btnMenu.Items.Add('Move right')
[void]$btnMenu.Items.Add('-')
$miRemove = $btnMenu.Items.Add('Remove this button')

$miIcon.add_Click({
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $t = $src.Tag
        $val = Show-IconPicker ([string]$t.icon)
        if ($null -eq $val) { return }   # cancelled
        $ok = Update-Buttons { param($btns)
            foreach ($b in $btns) {
                if (Same-Button $b $t) {
                    if ($val) { $b | Add-Member -NotePropertyName icon -NotePropertyValue $val -Force }
                    else { $b.PSObject.Properties.Remove('icon') }
                }
            }
            $btns
        }
        if ($ok) { Rebuild-Buttons }
    } catch { Write-CkLog "Set icon error: $($_.Exception.Message)" }
})

$miToggle.add_Click({
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $t = $src.Tag
        $ok = Update-Buttons { param($btns)
            foreach ($b in $btns) {
                if (Same-Button $b $t) {
                    if ($b.toggle) { $b.PSObject.Properties.Remove('toggle') }
                    else { $b | Add-Member -NotePropertyName toggle -NotePropertyValue $true -Force }
                }
            }
            $btns
        }
        if ($ok) { $script:toggleState.Remove((Get-ButtonKey $t)); Rebuild-Buttons }
    } catch { Write-CkLog "Toggle mode error: $($_.Exception.Message)" }
})

$miRemove.add_Click({
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $t = $src.Tag
        if (Update-Buttons { param($btns) $btns | Where-Object { -not (Same-Button $_ $t) } }) {
            Rebuild-Buttons   # fjerner ogsaa kloner paa spejl-strimlerne
        }
    } catch { Write-CkLog "Remove error: $($_.Exception.Message)" }
})

$miRename.add_Click({
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $t = $src.Tag
        $new = Show-InputDialog (L 'renameTitle') (L 'renameAsk') ([string]$t.label)
        if ([string]::IsNullOrWhiteSpace($new)) { return }
        if (Update-Buttons { param($btns) foreach ($b in $btns) { if (Same-Button $b $t) { $b.label = $new } }; $btns }) {
            Rebuild-Buttons
        }
    } catch { Write-CkLog "Rename error: $($_.Exception.Message)" }
})

function Move-PinButton([int]$dir) {
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $hostPanel = $src.Parent   # the strip that was right-clicked (primary or mirror)
        $idx = $hostPanel.Controls.IndexOf($src)
        $newIdx = $idx + $dir
        if ($newIdx -lt 1 -or $newIdx -ge $hostPanel.Controls.Count) { return }  # index 0 is the grip
        $neighbor = $hostPanel.Controls[$newIdx].Tag
        $t = $src.Tag
        $ok = Update-Buttons {
            param($btns)
            $btns = @($btns)
            $i1 = -1; $i2 = -1
            for ($i = 0; $i -lt $btns.Count; $i++) {
                if (Same-Button $btns[$i] $t) { $i1 = $i }
                elseif (Same-Button $btns[$i] $neighbor) { $i2 = $i }
            }
            if ($i1 -ge 0 -and $i2 -ge 0) { $tmp = $btns[$i1]; $btns[$i1] = $btns[$i2]; $btns[$i2] = $tmp }
            $btns
        }
        if ($ok) { Rebuild-Buttons }   # sync the order across all strips
    } catch { Write-CkLog "Move error: $($_.Exception.Message)" }
}
$miLeft.add_Click({ Move-PinButton -1 })
$miRight.add_Click({ Move-PinButton 1 })

# ---------- Click behavior ----------
function Test-CursorInDropDown($dd) {
    if (-not $dd.Visible) { return $false }
    $p = [System.Windows.Forms.Cursor]::Position
    if ($dd.Bounds.Contains($p)) { return $true }
    foreach ($it in $dd.Items) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.DropDown -and $it.DropDown.Visible) {
            if (Test-CursorInDropDown $it.DropDown) { return $true }
        }
    }
    return $false
}

$script:sending = $false
$script:menuAway = 0
$script:armedBtn = $null
$script:armedAt = Get-Date '2000-01-01'
$script:stateGlobLast = Get-Date '2000-01-01'

function Test-TargetForeground {
    [CkWin]::GetForegroundWindow() -eq $script:target
}

# Best-effort: focus the message box of the SPECIFIC pane whose strip was clicked, so in a
# multi-pane grid the keystrokes land in that pane's chat and not wherever focus drifted.
# The composer sits just above the clicked strip, so we pick the editable control that is
# above the strip and nearest it horizontally. Fails safe: if none is found, focus is left
# alone and the send proceeds exactly as before (no regression).
# The pane a strip is BOUND to (main strip = first pane, mirror i = pane i+1). The send path
# must target this pane's own composer element, not re-derive one from geometry: in a tight
# grid an adjacent pane's composer can score closer and the text lands in the wrong chat.
function Get-PaneForForm($frm) {
    if (-not $frm) { return $null }
    if ($frm -eq $form) { if ($script:panes.Count -gt 0) { return $script:panes[0] }; return $null }
    for ($i = 0; $i -lt $script:mirrors.Count; $i++) {
        if ($script:mirrors[$i].Form -eq $frm) {
            $idx = $i + 1
            if ($idx -lt $script:panes.Count) { return $script:panes[$idx] }
            return $null
        }
    }
    return $null
}

# Current text of a composer, read through UIA TextPattern. Chromium exposes contenteditables
# as a read-only TextPattern, which is enough to see what actually landed. Verified on this
# app: the pattern resolves directly on the "Prompt" group. Returns $null when nothing is
# readable - which must be treated as "unknown", never as "empty".
function Get-ComposerText($el) {
    if (-not $el) { return $null }
    try {
        $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp) { return [string]$tp.DocumentRange.GetText(-1) }
    } catch {}
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
        $d = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($d) {
            $tp2 = $d.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            if ($tp2) { return [string]$tp2.DocumentRange.GetText(-1) }
        }
    } catch {}
    return $null
}
# WHY THE COMPARISON IS NOT TEXT EQUALITY.
#
# MEASURED against the live app, not assumed. Pasting a 12,752-character markdown button and
# reading the composer back gave 12,259 characters, and the read-back diverged at character 62:
#
#   payload : ...AI-agentpanel ```text Du skal gennemfoere...
#   composer: ...AI-agentpanel Du skal gennemfoere...
#
# The composer RENDERS markdown. A fenced code block loses its backticks AND its language word;
# bold loses its asterisks. The accessibility layer exposes rendered content, not source. So the
# payload and the read-back differ in their CHARACTERS, and no amount of whitespace normalising
# can reconcile them - two earlier attempts at exactly that both shipped a panel that refused to
# send every formatted button.
#
# What IS reliable is the words. Rendering deletes a few of them (fence languages) and reflows
# the rest, but it does not invent words and it does not reorder them. So:
#
#   (a) COVERAGE - the payload's words must appear in the read-back, in order, allowing a small
#       shortfall for the ones rendering eats.
#   (b) SIZE     - the read-back must not be materially larger than baseline+payload.
#
# Both are required. Coverage alone is satisfied by "stale clipboard text THEN our payload",
# because an in-order walk simply skips the prefix; the size bound is what catches that. Size
# alone is satisfied by any text of roughly the right length.
#
# Measured on the real capture: genuine paste 99.93% coverage / 1.0000 size. Stale clipboard
# instead of the payload 0% / 0.002. Stale text prepended 0% / 1.145. Half the payload 47.88% /
# 0.493. Only the genuine one passes both bounds.
# The two directions are NOT symmetric, and treating them as one percentage was wrong.
#
# TOO SMALL is caused by rendering, which only ever deletes. It is not a safety problem: if our
# text did not land, coverage collapses and we refuse anyway.
# TOO BIG means content we did not paste is in the box - a stale clipboard alongside our text.
# That is the leak this whole function exists to stop, so the ceiling is tight.
#
# Both need an ABSOLUTE allowance as well as a proportional one. A percentage alone fails on
# short payloads: a five-word button containing one code fence loses 20% of its words to
# rendering and was refused, while the same fence in a 1,416-word button costs 0.07%.
$script:MaxMissingWords    = 3      # or 2% of the payload's words, whichever is larger,
$script:MaxMissingFraction = 0.02   # but NEVER more than half the payload (see below)
# Rendering only ever DELETES characters, so ANY growth beyond baseline+payload is content we
# did not paste. A proportional allowance is therefore wrong in principle and was wrong in
# practice: at 1% it let 99 stray characters into a 12k payload undetected - a small clipboard
# leak, which is the exact thing being defended against. The allowance is a rounding margin, not
# a tolerance.
$script:ExtraCharsAllowed  = 2
$script:ExtraFraction      = 0.0
$script:MinSizeFraction    = 0.60   # below this, too little landed to be our payload at all

function Get-CompareWords([string]$s) {
    @([regex]::Matches($s, '[\p{L}\p{N}]+') | ForEach-Object { $_.Value.ToLowerInvariant() })
}
function Get-AlnumLength([string]$s) { ($s -replace '[^\p{L}\p{N}]', '').Length }

# In-order word coverage with a bounded look-ahead on BOTH sides. A strict two-pointer walk
# deadlocks: the payload word 'text' (a fence language) is absent from the read-back, so the
# payload pointer never advanced past it and a PERFECT paste measured 0.64% coverage.
function Get-WordCoverage($payloadWords, $observedWords) {
    # Re-wrap in @(). PowerShell UNROLLS a single-element array when it is passed as an
    # argument, so a one-word payload arrives here as a bare string - and indexing a string
    # yields CHARACTERS. A one-word payload then measured 0% coverage and the panel refused a
    # perfectly good paste. Same family as the if-expression unrolling fixed in Get-JsonDepth.
    $pw = @($payloadWords)
    $ow = @($observedWords)
    if ($pw.Count -eq 0) { return 0.0 }
    $W = 6
    $i = 0; $j = 0; $hit = 0
    while ($i -lt $pw.Count -and $j -lt $ow.Count) {
        if ($ow[$j] -ceq $pw[$i]) { $i++; $j++; $hit++; continue }
        $found = -1
        for ($k = 1; $k -le $W -and ($j + $k) -lt $ow.Count; $k++) {
            if ($ow[$j + $k] -ceq $pw[$i]) { $found = $j + $k; break }
        }
        if ($found -ge 0) { $j = $found + 1; $i++; $hit++ }   # junk in the read-back
        else { $i++ }                                          # payload word was rendered away
    }
    return ($hit / $pw.Count)
}

function Test-PasteLanded([string]$baseline, [string]$payload, [string]$observed) {
    $pw = @(Get-CompareWords $payload)
    if ($pw.Count -eq 0) { return $false }
    $coverage = Get-WordCoverage $pw (Get-CompareWords $observed)
    $missing  = $pw.Count - ($coverage * $pw.Count)
    # Cap the allowance at half the payload. Without this a one-word payload could go entirely
    # missing and still pass, because the absolute floor of 3 exceeded the whole word count -
    # "secret token" in the box instead of "/review" was Confirmed.
    $allowedMissing = [Math]::Min(
        [Math]::Max($script:MaxMissingWords, $pw.Count * $script:MaxMissingFraction),
        [Math]::Floor($pw.Count / 2))
    if ($missing -gt $allowedMissing) { return $false }

    $expected = (Get-AlnumLength $baseline) + (Get-AlnumLength $payload)
    if ($expected -le 0) { return $false }
    $actual  = Get-AlnumLength $observed
    $ceiling = $expected + [Math]::Max($script:ExtraCharsAllowed, $expected * $script:ExtraFraction)
    if ($actual -gt $ceiling) { return $false }               # something else is in the box
    if ($actual -lt ($expected * $script:MinSizeFraction)) { return $false }
    return $true
}

# Wait until the composer holds the baseline plus our payload, judged by word coverage and
# size (see Test-PasteLanded above for why text equality cannot work here).
#
# Ctrl+V is asynchronous: the keystroke is queued and the app reads the clipboard later. If the
# clipboard is restored before that read, the app pastes the USER'S clipboard instead - the
# wrong message, and their copied data leaked into an AI conversation. A fixed delay cannot
# make that safe; only observing the result can.
#
# Returns: 'Confirmed'    - the composer holds baseline+payload. Safe to restore and submit.
#          'Mismatch'     - readable, but the content is not what we intended. Something else
#                           landed (e.g. a stale clipboard). FAIL CLOSED.
#          'Unverifiable' - the composer exposed no readable text at all. We do not know.
#
# The size bound is what makes this stricter than "contains the payload". A bare containment
# probe passes when a stale clipboard is pasted ALONGSIDE our text, which is precisely the leak
# this function exists to stop.
function Wait-PasteLanded($el, $baseline, [string]$payload, [int]$timeoutMs = 1200) {
    # Normalize the baseline BEFORE concatenating. An "empty" Chromium composer does not read
    # as "" - it reads as "\n" - and a draft reads as "draft\n". Concatenating raw put that
    # terminator in the MIDDLE of the expected string ("draft\n/cmd") while the paste appends
    # before it ("draft/cmd"), so every click with a draft in the box compared unequal and
    # refused to send. The empty case only passed because Trim() happened to eat both newlines.
    # KNOWN LIMITATION: this assumes the paste APPENDS at the end. If the caret sits mid-draft,
    # or text is selected (paste replaces the selection), the result is not baseline+payload and
    # this returns Mismatch - a refusal on a legitimate action. Refusing is the safe direction,
    # but it is a real usability cost and it is not automatically testable here, because
    # positioning a caret requires synthetic input.
    $base = [string]$baseline
    # A payload with no words at all can never be verified: coverage is undefined and the poll
    # would otherwise confirm a paste that never happened, then submit whatever the user already
    # had in the box. Refuse instead.
    if ((Get-CompareWords $payload).Count -eq 0) { return 'Mismatch' }
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $sawText = $false
    while ((Get-Date) -lt $deadline) {
        $now = Get-ComposerText $el
        if ($null -ne $now) {
            $sawText = $true
            if (Test-PasteLanded $base $payload ([string]$now)) { return 'Confirmed' }
        }
        Start-Sleep -Milliseconds 15
    }
    if ($sawText) { return 'Mismatch' }
    return 'Unverifiable'
}

# Test seam. Wait-PasteLanded is the whole safety decision, and grepping the source for its
# shape proved almost worthless: six of nine injected defects survived, including one that
# reinstated the leak. Driving the real function with a stubbed composer reader exercises the
# actual state machine. -PasteProbe takes a JSON file {baseline, payload, observed} where
# `observed` is what the composer will report, and prints the resulting state.
function Invoke-PasteProbe([string]$jsonPath) {
    $c = [IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json
    $script:probeObserved = $c.observed          # $null in JSON => unreadable composer
    # Shadow the UIA reader for the duration of the probe.
    function script:Get-ComposerText($el) { $script:probeObserved }
    $base = if ($null -eq $c.baseline) { $null } else { [string]$c.baseline }
    # Emit the elapsed time alongside the state, measured INSIDE this process. Timing it from
    # the caller measured powershell.exe startup (~1.5s, +/-200ms) instead of the poll, which
    # made the "does it actually wait?" test both vacuous and, once differential, flaky.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $state = Wait-PasteLanded $null $base ([string]$c.payload) 120
    $sw.Stop()
    [Console]::Out.Write("$state|$($sw.ElapsedMilliseconds)")
    exit 0
}

# Runs here, not at the top of the file: it needs Wait-PasteLanded to be defined. The form and
# controls above have been CONSTRUCTED by this point but none has been shown, and this exits
# before the message loop, so nothing appears on screen and nothing takes focus. (It is also
# before Write-InstallMarker, which is why that guard does not need to list -PasteProbe - move
# either one and that stops being true.)
if (-not [string]::IsNullOrEmpty($PasteProbe)) { Invoke-PasteProbe $PasteProbe }

function Focus-ChatInput($stripCenterX, $stripTopY) {
    try {
        if ($script:target -eq [IntPtr]::Zero) { return }
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:target)
        # Each strip docks just below its pane's composer, so the composer whose bottom sits
        # just above the strip (and nearest in X) is this pane's input. Focus it directly.
        $best = $null; $bestScore = [double]::MaxValue
        foreach ($c in (Get-Composers $root)) {
            $bottom = $c.Y + $c.H
            if ($bottom -gt ($stripTopY + (SW 10))) { continue }   # composer must be above the strip
            $dx = [Math]::Abs(($c.X + $c.W / 2) - $stripCenterX)
            $dy = $stripTopY - $bottom
            $score = $dx + $dy
            if ($score -lt $bestScore) { $best = $c; $bestScore = $score }
        }
        if ($best) { $best.El.SetFocus(); return $best.El }
    } catch {}
    return $null
}

# Block until keyboard focus has ACTUALLY landed inside the given composer. SetFocus on a
# Chromium composer is asynchronous: typing straight after it sends the first characters to
# whichever chat was focused before, splitting one message across two chats. Polling the real
# focused element replaces the old fixed delay - it is both correct and snappier, since focus
# normally lands in ~20-40ms. Returns $false on timeout so the caller aborts instead of typing
# into the wrong chat. Focus often lands on an inner editable node, so a descendant whose rect
# sits inside the composer counts as focused.
function Wait-ComposerFocus($composerEl, [int]$timeoutMs = 800) {
    if (-not $composerEl) { return $false }
    try { $cr = $composerEl.Current.BoundingRectangle } catch { return $false }
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $f = [System.Windows.Automation.AutomationElement]::FocusedElement
            if ($f) {
                if ([System.Windows.Automation.Automation]::Compare($f, $composerEl)) { return $true }
                $fr = $f.Current.BoundingRectangle
                if ($fr.Width -gt 0 -and $fr.Height -gt 0 -and
                    $fr.X -ge ($cr.X - 4) -and $fr.Y -ge ($cr.Y - 4) -and
                    ($fr.X + $fr.Width) -le ($cr.X + $cr.Width + 4) -and
                    ($fr.Y + $fr.Height) -le ($cr.Y + $cr.Height + 4)) { return $true }
            }
        } catch {}
        Start-Sleep -Milliseconds 12
    }
    return $false
}

$script:toggleState = @{}   # in-memory on/off state for toggle buttons (per panel run)
function Get-ButtonKey($b) { "$($b.label)|$($b.text)|$($b.chat)" }

# A toggle button's TRUE state. With "stateGlob" set, the filesystem is the truth
# (the button stays honest even when an agent/hook changes the state behind our back).
function Get-ToggleState($item) {
    if ($item.stateGlob) {
        try { return [bool](Test-Path ([Environment]::ExpandEnvironmentVariables([string]$item.stateGlob))) } catch { return $false }
    }
    return ($script:toggleState[(Get-ButtonKey $item)] -eq $true)
}

# Commit a toggle's on/off state to memory + every clone across all strips. Called immediately
# before the actual send so an aborted click never flips state (H7 - no residual desync window).
function Set-ToggleFace($item, [bool]$on) {
    $script:toggleState[(Get-ButtonKey $item)] = $on
    foreach ($pnl in (@($panel) + @($script:mirrors | ForEach-Object { $_.Panel }))) {
        foreach ($c in $pnl.Controls) {
            if ($c -is [PillButton] -and $c.Tag -and (Same-Button $c.Tag $item)) { $c.Toggled = $on }
        }
    }
}

function Invoke-PillClick($btn) {
    if ($script:sending) { return }   # guard against reentrancy while a send is in progress
    $script:lastClickedBtn = $btn     # so an abandoned send can warn next to the button clicked
    # Shift-click = insert the text but do NOT press Enter, so it can be edited or extended
    # first. Read it up front: Shift may be released during the focus + paste round-trip.
    $holdShift = ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -ne 0
    if ($tipForm.Visible) { $tipForm.Hide() }
    try {
        $item = $btn.Tag
        # Two-click confirmation for destructive buttons (within 3 s).
        # Asymmetric for toggles: confirm gates switching ON only - disarming is never gated.
        $needConfirm = [bool]$item.confirm
        if ($item.toggle -and (Get-ToggleState $item)) { $needConfirm = $false }
        if ($needConfirm) {
            if ($script:armedBtn -ne $btn -or ((Get-Date) - $script:armedAt).TotalSeconds -gt 3) {
                if ($script:armedBtn) { Set-PillFace $script:armedBtn }
                $script:armedBtn = $btn
                $script:armedAt = Get-Date
                $btn.Font = $script:btnFont
                $btn.Text = L 'confirm'
                $btn.Width = Get-PillWidth $btn.Text
                return
            }
            $script:armedBtn = $null
            Set-PillFace $btn
        }
        # Work out what this click WOULD send, WITHOUT mutating state yet (H7: the toggle
        # flip must not happen if the send is aborted because Claude isn't foreground).
        $isToggle = [bool]$item.toggle
        $newOn = $null
        $textToSend = [string]$item.text
        if ($isToggle) {
            $newOn = -not (Get-ToggleState $item)
            $textToSend = if ($newOn) { if ($item.textOn) { [string]$item.textOn } else { [string]$item.text } }
                          else { [string]$item.textOff }
        }
        $script:sending = $true
        try {
            Start-Sleep -Milliseconds 40
            # Focus THIS pane's composer first. SetFocus on the composer pulls Claude forward and
            # puts the caret in the right box even if Claude was not the active window - so you can
            # click a button from another window. Then WAIT for focus to actually land in that
            # composer: a foreground check alone is not enough, because when Claude is already
            # foreground with another chat focused it passes instantly and the first characters
            # go to the wrong chat. Abort if focus never lands rather than type into the wrong box.
            $sf = $btn.FindForm()
            # Target the composer this strip is BOUND to. Geometric re-discovery is only a
            # fallback for a dead element - picking by nearest-rect can select the neighbouring
            # pane's composer in a tight grid and send the text to the wrong chat.
            $composerEl = $null
            $pane = Get-PaneForForm $sf
            if ($pane -and $pane.Composer) {
                try { $pane.Composer.SetFocus(); $composerEl = $pane.Composer }
                catch { $composerEl = $null }   # element died (pane closed/re-mounted)
            }
            if (-not $composerEl -and $sf) {
                Write-CkLog 'Bound composer unavailable; falling back to geometric focus'
                $composerEl = Focus-ChatInput ($sf.Left + $sf.Width / 2) $sf.Top
            }
            if (-not (Wait-ComposerFocus $composerEl)) {
                Write-CkLog 'Send aborted: focus never landed in this pane composer'
                return
            }
            if (-not (Test-TargetForeground)) { return }   # focus didn't reach Claude - don't type elsewhere
            # Toggle with nothing to send (off, no textOff): flip only, we're foreground.
            if ($isToggle -and [string]::IsNullOrEmpty($textToSend)) { Set-ToggleFace $item $newOn; return }

            # ALWAYS paste via the clipboard rather than typing: it lands instantly instead of
            # animating key-by-key, and it is ATOMIC - a focus change mid-send can no longer
            # split one message across two chats. There is no typing fallback: if the clipboard
            # is unavailable the send is ABANDONED and the user is told (see the top of file).
            # Re-check foreground BEFORE touching the clipboard so an aborted send never leaves
            # it clobbered, and restore it in finally so it survives an exception.
            if (-not (Test-TargetForeground)) { return }
            # A payload that is only whitespace can never be verified (it normalizes away),
            # and buttons.json is hand-editable, so this is reachable. Refuse it up front.
            if ([string]::IsNullOrWhiteSpace($textToSend)) {
                Write-CkLog 'Refusing a blank payload'
                Show-SendWarning (L 'sendBlank')   # the one abandoned path that was still silent
                return
            }
            # Baseline BEFORE the clipboard is touched, so we can prove afterwards that exactly
            # our payload was added and nothing else. $null means the composer is unreadable,
            # which is not the same as empty - see the Unverifiable branch below.
            $baseline = Get-ComposerText $composerEl
            # Initialised so an exception before the paste (e.g. another app holding the
            # clipboard open) is distinguishable from a paste that went wrong. Left $null it
            # fell to the Mismatch branch, which told the user to inspect a composer that
            # nothing had been written to.
            $pasteState = 'NotAttempted'
            $backup = $null; $snapOk = $false; $pasted = $false
            try {
                $old = [System.Windows.Forms.Clipboard]::GetDataObject()
                $backup = New-Object System.Windows.Forms.DataObject
                if ($old) { foreach ($fmt in $old.GetFormats()) { try { $backup.SetData($fmt, $old.GetData($fmt)) } catch {} } }
                $snapOk = $true   # empty snapshot = "was empty"; restoring it re-empties correctly
            } catch { $snapOk = $false }
            $seqAfterSet = $null
            try {
                # Mark the payload so Windows keeps it OUT of clipboard history (Win+V) and out
                # of Cloud Clipboard sync. Button prompts are standing text the user never chose
                # to copy; without this every click is archived and may sync to their other
                # devices. Restoring the old clipboard does not remove a history entry.
                $dobj = New-Object System.Windows.Forms.DataObject
                $dobj.SetText(($textToSend -replace "`r`n", "`n"))
                foreach ($fmt in @('ExcludeClipboardContentFromMonitorProcessing',
                                   'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard')) {
                    try {
                        $ms = New-Object System.IO.MemoryStream
                        $ms.Write([byte[]]@(0, 0, 0, 0), 0, 4)
                        $dobj.SetData($fmt, $ms)
                    } catch {}
                }
                [System.Windows.Forms.Clipboard]::SetDataObject($dobj, $true)
                $seqAfterSet = [CkWin]::GetClipboardSequenceNumber()
                [System.Windows.Forms.SendKeys]::SendWait('^v')
                # Do not restore the clipboard until the payload is OBSERVED in the composer.
                # The finally block below runs straight after this, so this wait is the only
                # thing standing between our paste and the user's clipboard going back.
                # Always wait, even when the composer is unreadable. Short-circuiting to
                # 'Unverifiable' meant the restore in the finally below ran with NO delay at
                # all - strictly worse than the fixed 90ms it replaced, on the one path where
                # we cannot see what happened. Wait-PasteLanded polls for its full timeout and
                # returns 'Unverifiable' by itself when nothing is readable.
                $pasteState = Wait-PasteLanded $composerEl $baseline $textToSend
                $pasted = ($pasteState -eq 'Confirmed')
            } catch {
                Write-CkLog "Clipboard unavailable; nothing was pasted or sent: $($_.Exception.Message)"
            } finally {
                # M1: restore the full prior clipboard - but only if nothing else wrote to it
                # meanwhile, or we would clobber another app's copy with stale content. If the
                # snapshot itself failed we leave our text rather than guess.
                if ($snapOk) {
                    $seqNow = [CkWin]::GetClipboardSequenceNumber()
                    if ($null -eq $seqAfterSet -or $seqNow -eq $seqAfterSet) {
                        try { [System.Windows.Forms.Clipboard]::SetDataObject($backup, $true) } catch {}
                    } else {
                        Write-CkLog 'Clipboard changed by another app mid-send; left it alone'
                    }
                }
            }
            # FAIL CLOSED. Do not type, do not press Enter, do not undo, do not clear.
            #
            # The old code typed the correct text whenever the paste could not be confirmed -
            # and THAT is what turned a detected problem into a sent one. If a stale clipboard
            # had landed in the box, typing appended the right text underneath it and Enter
            # shipped both, leaking whatever the user had copied into the conversation.
            #
            # Undo is not an option either: if the user typed after the bad paste, Ctrl+Z takes
            # THEIR text, and no amount of checking afterwards can give it back.
            #
            # So we leave the composer exactly as it is. Whatever is in there stays visible and
            # unsent, and the user decides. That is the only outcome that cannot lose their
            # data or say something on their behalf.
            if (-not $pasted) {
                if ($pasteState -eq 'NotAttempted') {
                    # Nothing was ever pasted, so telling the user to inspect the box for
                    # contamination would send them hunting for something that cannot be there.
                    Write-CkLog 'Clipboard was unavailable; nothing was pasted or sent'
                    Show-SendWarning (L 'sendNoClipboard')
                } elseif ($pasteState -eq 'Unverifiable') {
                    Write-CkLog 'Paste could not be verified (composer text unreadable); not sending'
                    Show-SendWarning (L 'sendUnverified')
                } else {
                    Write-CkLog 'Paste did not land as expected; composer left untouched and NOT sent'
                    Show-SendWarning (L 'sendMismatch')
                }
                return
            }
            # F4: flip the toggle only once the text is actually delivered. Flipping before the
            # send left it inverted with nothing sent whenever the paste threw and the typing
            # fallback then aborted on the foreground re-check. On a Shift-click the command is
            # only parked in the box, not run, so the state must not flip either.
            if ($isToggle -and -not $holdShift) { Set-ToggleFace $item $newOn }
            # Per-chat buttons never auto-send: the user must see the text before Enter.
            # Shift-click suppresses the send too, leaving the text ready to edit.
            if ($item.submit -and -not $item.chat -and -not $holdShift) {
                Start-Sleep -Milliseconds 90
                if (-not (Test-TargetForeground)) { return }
                [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            }
        } finally {
            $script:sending = $false
        }
    } catch { $script:sending = $false; Write-CkLog "Click error: $($_.Exception.Message)" }
}

# Mirror strips: one extra strip per additional chat pane in side-by-side/grid view
$script:mirrors = @()

function New-MirrorStrip {
    $mf = New-Object LayeredForm
    $mf.Text = 'Claude Buttons'
    $mf.TopMost = $true   # see the main form
    $mf.FormBorderStyle = 'None'
    $mf.ShowInTaskbar = $false
    $mf.AutoSize = $true
    $mf.AutoSizeMode = 'GrowAndShrink'
    $mf.StartPosition = 'Manual'
    $mf.Location = New-Object System.Drawing.Point(-4000, -4000)
    $mf.BackColor = $script:barColor
    $mp = New-Object System.Windows.Forms.FlowLayoutPanel
    $mp.FlowDirection = 'LeftToRight'
    $mp.WrapContents = $false
    $mp.AutoSize = $true
    $mp.AutoSizeMode = 'GrowAndShrink'
    $mp.Padding = New-Object System.Windows.Forms.Padding((S(3)), (S(2)), (S(3)), (S(2)))
    [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($mp, $true, $null)
    $mf.Controls.Add($mp)
    $mg = New-Object GripHandle
    $mg.BackColor = $script:barColor
    $mg.DotColor = $colIcon
    $mg.HoverFill = $colHover
    $mg.DownFill = $colDown
    $mg.Width = $pillH
    $mg.Height = $pillH
    $mg.Margin = New-Object System.Windows.Forms.Padding((S(3)))
    $mg.ContextMenuStrip = $gripMenu
    $mg.add_MouseUp({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $gripMenu.Show($this, $_.Location) } })
    $mg.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
    $mg.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })
    $mg.add_Repaint({ Render-StripFor $this })
    @{ Form = $mf; Panel = $mp; Grip = $mg }
}

# Fill one strip panel with the buttons visible for a given pane
function Build-StripPanel($destPanel, $destGrip, [string]$paneTitle, [bool]$isPrimary) {
    $destPanel.SuspendLayout()
    $old = @($destPanel.Controls | Where-Object { $_ -ne $destGrip })
    $destPanel.Controls.Clear()
    $destPanel.Controls.Add($destGrip)
    foreach ($b in $script:config.buttons) {
        $visible = if (-not $b.chat -and -not $b.chatTitle) { $true }                 # global: every pane
                   elseif ($b.chatTitle) { $paneTitle -and ($b.chatTitle -eq $paneTitle) }
                   elseif ($isPrimary) { Test-ChatButtonVisible $b }                  # session-id fallback: primary only
                   else { $false }
        if (-not $visible) { continue }
        $btn = New-Object PillButton
        $btn.Tag = $b
        $btn.Height = $pillH
        Set-PillFace $btn
        if ($b.toggle) { $btn.Toggled = (Get-ToggleState $b) }
        $btn.Margin = New-Object System.Windows.Forms.Padding((S(3)))
        $btn.BackColor = $script:barColor
        # Icon glyphs use a soft grey (like Claude's own toolbar icons, not stark white);
        # text buttons stay the warmer off-white so long labels are less harsh.
        $btn.ForeColor = if ($b.icon) { $colIcon } else { $colText }
        # Icon buttons carry no pill background (they blend into the bar like Claude's own
        # toolbar icons, with only a hover highlight); text buttons keep the subtle fill.
        $btn.Fill = if ($b.icon) { $script:barColor } else { $colFill }
        $btn.Bold = [bool]$b.icon   # thicker strokes on icon glyphs
        $btn.HoverFill = $colHover
        $btn.DownFill = $colDown
        if ($b.chat) { $btn.Accent = $colAccent }
        # Accessible name for screen readers: the label (not the icon glyph), + scope + toggle state.
        $an = [string]$b.label
        if ($b.toggle) { $an += if ($btn.Toggled) { ', on' } else { ', off' } }
        if ($b.chat -or $b.chatTitle) { $an += ', this chat' } else { $an += ', global' }
        $btn.AccessibleName = $an
        $btn.ContextMenuStrip = $btnMenu
        $btn.add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $script:menuSource = $this } })
        $btn.add_Click({ Invoke-PillClick $this })
        $btn.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
        $btn.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })
        $btn.add_Repaint({ Render-StripFor $this })   # recomposite the layered strip on hover/toggle/press
        $destPanel.Controls.Add($btn)
    }
    $destPanel.ResumeLayout()
    foreach ($o in $old) { $o.Dispose() }
}

function Rebuild-Buttons {
    $script:armedBtn = $null
    $script:menuSource = $null
    $script:hoverCtrl = $null
    if ($tipForm.Visible) { $tipForm.Hide() }
    $form.SuspendLayout()
    Build-StripPanel $panel $grip $script:uiaTitle $true
    $form.ResumeLayout()
    Update-LayeredStrip $form $panel
    for ($i = 0; $i -lt $script:mirrors.Count; $i++) {
        $mTitle = if (($i + 1) -lt $script:panes.Count) { $script:panes[$i + 1].Title } else { $null }
        $script:mirrors[$i].Form.SuspendLayout()
        Build-StripPanel $script:mirrors[$i].Panel $script:mirrors[$i].Grip $mTitle $false
        $script:mirrors[$i].Form.ResumeLayout()
        Update-LayeredStrip $script:mirrors[$i].Form $script:mirrors[$i].Panel
    }
}
[void](Read-ActiveSession)
Rebuild-Buttons

# ---------- Window tracking ----------
$script:target = [IntPtr]::Zero
$script:targetPid = [uint32]0
$script:myPid = [uint32](Get-Process -Id $PID).Id
$script:autoMove = $false

# Is a pane's spot on Claude actually visible (vs covered by another app)? The strips are
# TopMost so they never flash on focus change; this is what stops them bleeding through a
# window that covers Claude - we hide a strip whose pane is occluded. Fails OPEN (show) so a
# probe glitch never hides a valid strip. Our own strip windows at the point count as visible
# (Claude is behind them).
function Test-PaneVisible([int]$x, [int]$y) {
    $root = [CkWin]::RootAtPoint($x, $y)
    if ($root -eq [IntPtr]::Zero -or $root -eq $script:target) { return $true }
    $p = [uint32]0
    [void][CkWin]::GetWindowThreadProcessId($root, [ref]$p)
    if ($p -eq $script:targetPid -or $p -eq $script:myPid) { return $true }
    if ([CkWin]::IsTopmost($root)) { return $true }   # transient top-most overlay (e.g. screen snip)
    return $false
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.add_Tick({
    if ($script:sending) { return }   # don't touch the UI mid-send
    try {
        # Close open menus when the mouse leaves them (the window never takes focus,
        # so Windows' own click-outside dismissal is unreliable here)
        $menusOpen = @(@($gripMenu, $btnMenu) | Where-Object { $_.Visible })
        if ($menusOpen.Count -gt 0) {
            $p = [System.Windows.Forms.Cursor]::Position
            $inside = $form.Bounds.Contains($p)
            if (-not $inside) {
                foreach ($ms in $script:mirrors) { if ($ms.Form.Bounds.Contains($p)) { $inside = $true; break } }
            }
            if (-not $inside) {
                foreach ($m in $menusOpen) { if (Test-CursorInDropDown $m) { $inside = $true; break } }
            }
            $click = (([CkWin]::GetAsyncKeyState(0x01) -band 0x8001) -ne 0) -or (([CkWin]::GetAsyncKeyState(0x02) -band 0x8001) -ne 0)
            if ($inside) {
                $script:menuAway = 0
            } else {
                $script:menuAway++
                if ($click -or $script:menuAway -ge 10) {   # click outside OR ~2 s away
                    foreach ($m in $menusOpen) { $m.Close() }
                    $script:menuAway = 0
                }
            }
        } else {
            $script:menuAway = 0
        }

        # Reset the "Confirm?" state after 3 s
        if ($script:armedBtn -and ((Get-Date) - $script:armedAt).TotalSeconds -gt 3) {
            try { Set-PillFace $script:armedBtn } catch {}
            $script:armedBtn = $null
        }

        # Find/validate the Claude window FIRST (HWND can be reused - check PID still matches).
        # Doing the visibility gate up here means the expensive UIA pass below is skipped
        # entirely while the panel is hidden (Claude backgrounded) - big battery/CPU win.
        if ($script:target -ne [IntPtr]::Zero) {
            $p = [uint32]0
            [void][CkWin]::GetWindowThreadProcessId($script:target, [ref]$p)
            if (-not [CkWin]::IsWindow($script:target) -or $p -ne $script:targetPid) { $script:target = [IntPtr]::Zero }
        }
        if ($script:target -eq [IntPtr]::Zero) {
            $script:target = [CkWin]::FindTarget($targetTitle, $targetProcess)
            if ($script:target -ne [IntPtr]::Zero) {
                $p = [uint32]0
                [void][CkWin]::GetWindowThreadProcessId($script:target, [ref]$p)
                $script:targetPid = $p
                [WinHook]::TargetPid = $p   # scope object-event noise to Claude's process
                [WinHook]::Touch()          # a freshly (re)found window needs a full pass
            }
        }
        # Show whenever Claude is on-screen (not minimized), even if it is not the active window -
        # so the strips stay available and you can click a button from another window; the click
        # then pulls Claude forward and focuses that pane's composer before typing.
        $show = ($script:target -ne [IntPtr]::Zero) -and
                (-not [CkWin]::IsIconic($script:target)) -and
                [CkWin]::IsWindowVisible($script:target)
        if (-not $show) {
            if ($form.Visible) { $form.Hide() }
            foreach ($ms in $script:mirrors) { if ($ms.Form.Visible) { $ms.Form.Hide() } }
            if ($tipForm.Visible) { $tipForm.Hide() }
            if ($gripMenu.Visible) { $gripMenu.Close() }
            if ($btnMenu.Visible) { $btnMenu.Close() }
            return
        }

        # --- from here the panel IS showing; the per-tick work below only runs then ---

        # Keep per-window scale current (the window may move between monitors)
        $ws = [CkWin]::WindowScale($script:target)
        if ($ws -gt 0) { $script:winScale = $ws }

        # stateGlob poll (~1 s): keep glob-backed toggle buttons truthful even when
        # an agent, hook or another machine changes the state behind our back
        if (((Get-Date) - $script:stateGlobLast).TotalMilliseconds -ge 1000) {
            $script:stateGlobLast = Get-Date
            $allPanels = @($panel) + @($script:mirrors | ForEach-Object { $_.Panel })
            foreach ($pnl in $allPanels) {
                foreach ($c in $pnl.Controls) {
                    if ($c -is [PillButton] -and $c.Tag -and $c.Tag.toggle -and $c.Tag.stateGlob) {
                        $truth = Get-ToggleState $c.Tag
                        if ($c.Toggled -ne $truth) { $c.Toggled = $truth }
                    }
                }
            }
        }

        # Reload buttons.json on change (e.g. /pin), or keep retrying during the self-heal window
        # after a startup fallback (real file may be unchanged after a transient lock).
        $wt = (Get-Item $configPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
        $dirty = $false
        $healing = $script:cfgHealUntil -and ((Get-Date) -lt $script:cfgHealUntil)
        if ($wt -and ($wt -ne $script:cfgTime -or $healing)) {
            $new = Read-FreshConfig
            if ($new) { $script:config = $new; $script:cfgTime = $wt; $script:cfgHealUntil = $null; $dirty = $true }
        }
        if ($script:cfgHealUntil -and (Get-Date) -ge $script:cfgHealUntil) { $script:cfgHealUntil = $null }  # give up healing
        if (Read-ActiveSession) { $dirty = $true }
        # Hide chat buttons when the "active chat" signal is older than 10 min
        $exp = $false
        if ($script:activeSession -and $script:activeTs) {
            $exp = ([DateTime]::UtcNow - $script:activeTs).TotalMinutes -gt 10
        }
        if ($exp -ne $script:activeExpired) { $script:activeExpired = $exp; $dirty = $true }
        # Read the displayed chat + chat area from the app's UI (cached, backs off when stable).
        # A Claude window event (move/resize/show/hide/name/foreground) lets this walk run
        # NOW instead of waiting out its 1.5s->5s stability backoff, so the strip re-aligns
        # promptly after Claude moves or the displayed chat switches. When no event arrived,
        # the existing backoff stands untouched - events only ever make it re-read SOONER,
        # never more often while nothing is happening, so idle cost is unchanged.
        if ([WinHook]::Consume()) { $script:uiaLast = [DateTime]'2000-01-01'; $script:uiaStable = 0 }
        Update-UiaInfo
        if ($script:uiaDirty) { $script:uiaDirty = $false; $dirty = $true }

        # A Claude modal/menu is covering the composers: hide every strip, but keep the mirrors
        # alive and KEEP POLLING. This deliberately sits AFTER Update-UiaInfo - gating it in the
        # $show check above would return before the UIA read, so the strips could never notice
        # the dialog closing and would stay hidden forever.
        if ($script:composerLost) {
            if ($form.Visible) { $form.Hide() }
            foreach ($ms in $script:mirrors) { if ($ms.Form.Visible) { $ms.Form.Hide() } }
            if ($tipForm.Visible) { $tipForm.Hide() }
            if ($gripMenu.Visible) { $gripMenu.Close() }
            if ($btnMenu.Visible) { $btnMenu.Close() }
            $script:uiaInterval = 400   # re-check often so they come back promptly
            return
        }

        # One mirror strip per ADDITIONAL pane (side-by-side / grid view)
        $wantMirrors = [Math]::Max(0, $script:panes.Count - 1)
        while ($script:mirrors.Count -lt $wantMirrors) {
            $script:mirrors = @($script:mirrors) + (New-MirrorStrip)
            $dirty = $true
        }
        while ($script:mirrors.Count -gt $wantMirrors) {
            $m = $script:mirrors[$script:mirrors.Count - 1]
            $script:mirrors = @($script:mirrors | Select-Object -First ($script:mirrors.Count - 1))
            try { $m.Form.Close(); $m.Form.Dispose() } catch {}
            $dirty = $true
        }
        if ($dirty) { Rebuild-Buttons }

        # LIVE geometry, every tick. Discovering which panes exist needs a full tree walk, which
        # is expensive and therefore throttled - but where they ARE must never lag, or the strip
        # trails behind a composer that just grew from typing/pasting. Re-reading one cached
        # element's rectangle per pane is cheap, and the dock point is stored relative to the
        # composer, so this tracks it exactly without redoing the walk.
        foreach ($pn in $script:panes) {
            if (-not $pn.Composer -or $null -eq $pn.DockDX) { continue }
            try {
                $cb = $pn.Composer.Current.BoundingRectangle
                if ($cb.Width -gt 0 -and $cb.Height -gt 0) {
                    $pn.Cx = [int]$cb.X; $pn.Cy = [int]$cb.Y
                    $pn.Cw = [int]$cb.Width; $pn.Ch = [int]$cb.Height
                    $pn.DockX = [int]$cb.X + $pn.DockDX
                    $pn.DockY = [int]($cb.Y + $cb.Height) + $pn.DockDY
                }
            } catch {}
        }
        if ($script:panes.Count -gt 0 -and $script:panes[0].Cx) {
            $p0 = $script:panes[0]
            $script:paneCRect = @{ X = $p0.Cx; Y = $p0.Cy; W = $p0.Cw; H = $p0.Ch; DockX = $p0.DockX; DockY = $p0.DockY; Anchored = $p0.Anchored }
        }

        $r = New-Object CkWin+RECT
        if (-not [CkWin]::GetWindowRect($script:target, [ref]$r)) { return }
        $winW = $r.Right - $r.Left

        # Center over the chat area (Primary pane), not the whole window, when known
        $areaL = $r.Left; $areaW = $winW
        if ($script:paneRect) {
            $areaL = $r.Left + $script:paneRect.OffL
            $areaW = $script:paneRect.Width
        }

        # Compact mode with hysteresis (measured against the NARROWEST pane in grid view)
        $minPaneW = $areaW
        foreach ($pn in $script:panes) { if ($pn.Width -lt $minPaneW) { $minPaneW = $pn.Width } }
        $avail = $minPaneW - (S $script:reservedW)
        $newCompact = $script:compact
        if (-not $script:compact -and (Get-StripWidth $false) -gt $avail) { $newCompact = $true }
        elseif ($script:compact -and (Get-StripWidth $false) -lt ($avail - (S(60)))) { $newCompact = $false }
        if ($newCompact -ne $script:compact) { $script:compact = $newCompact; Rebuild-Buttons }

        # Static dock: always on the primary pane's composer control row, after the mic.
        if ($null -ne $script:paneCRect) {
            $c = $script:paneCRect
            $startX = $c.DockX + (SW $script:stripGap)
            $room = [Math]::Max(1, ($c.X + $c.W) - $startX - $form.Width)
            $x = $startX + [int]($script:relX * $room)
            $y = $c.DockY - [int]($form.Height / 2) + (SW $script:vNudge)
        } else {
            # Legacy: dock on the app's own bottom button row.
            $paneBottom = $r.Bottom - $script:paneBottomOff
            $startX = if ($null -ne $script:leftEdgeOff) { $r.Left + $script:leftEdgeOff + (SW $script:stripGap) } else { $areaL }
            $room = [Math]::Max(1, ($areaL + $areaW) - $startX - $form.Width)
            $x = $startX + [int]($script:relX * $room)
            if ($null -ne $script:rowCenterOff) {
                $y = $paneBottom - $script:rowCenterOff - [int]($form.Height / 2)
            } else {
                $y = $paneBottom - (SW $script:fallbackRow) - [int]($form.Height / 2)
            }
            $y += (SW $script:vNudge)   # user vertical nudge
        }
        $x = [Math]::Max($r.Left + 4, [Math]::Min($x, $r.Right - $form.Width - 4))
        $y = [Math]::Max($r.Top + 4, [Math]::Min($y, $r.Bottom - $form.Height - 2))
        # Hide this strip if its pane on Claude is covered by another app (no bleed-through).
        # Probe on the control row just LEFT of the strip (over Claude's mic) - that's adjacent
        # to the strip, so coverage of the strip is detected immediately, not only once the
        # composer's center gets covered.
        $mainVis = $true
        if ($script:paneCRect) {
            # Anchor gone = a Claude modal/menu is over the composer: hide rather than drift left.
            if (-not $script:paneCRect.Anchored) { $mainVis = $false }
            else { $mainVis = Test-PaneVisible ([int]($script:paneCRect.DockX - 5)) ([int]$script:paneCRect.DockY) }
        }
        if (-not $mainVis) {
            if ($form.Visible) { $form.Hide() }
        } else {
            $desired = New-Object System.Drawing.Point($x, $y)
            if ($form.Location -ne $desired) {
                $script:autoMove = $true
                $form.Location = $desired
                $script:autoMove = $false
            }
            if (-not $form.Visible) { $form.Show(); Update-LayeredStrip $form $panel }
        }

        # Mirror strips: dock each under its own pane
        for ($i = 0; $i -lt $script:mirrors.Count; $i++) {
            $mForm = $script:mirrors[$i].Form
            if (($i + 1) -ge $script:panes.Count) { if ($mForm.Visible) { $mForm.Hide() }; continue }
            $pi = $script:panes[$i + 1]
            if ($pi.Cx) {
                # Composer mode: dock on this pane's control row, after its own buttons.
                $startX = $pi.DockX + (SW $script:stripGap)
                $room = [Math]::Max(1, ($pi.Cx + $pi.Cw) - $startX - $mForm.Width)
                $mx = $startX + [int]($script:relX * $room)
                $my = $pi.DockY - [int]($mForm.Height / 2) + (SW $script:vNudge)
            } else {
                $paneL = $r.Left + $pi.OffL
                $paneBottom = $r.Bottom - $pi.BottomOff
                $startX = if ($null -ne $pi.LeftOff) { $r.Left + $pi.LeftOff + (SW $script:stripGap) } else { $paneL }
                $room = [Math]::Max(1, ($paneL + $pi.Width) - $startX - $mForm.Width)
                $mx = $startX + [int]($script:relX * $room)
                $my = if ($null -ne $pi.RowCenter) { $paneBottom - $pi.RowCenter - [int]($mForm.Height / 2) + (SW $script:vNudge) }
                      else { $paneBottom - (SW $script:fallbackRow) - [int]($mForm.Height / 2) + (SW $script:vNudge) }
            }
            $mx = [Math]::Max($r.Left + 4, [Math]::Min($mx, $r.Right - $mForm.Width - 4))
            $my = [Math]::Max($r.Top + 4, [Math]::Min($my, $r.Bottom - $mForm.Height - 2))
            # Hide this mirror if its pane on Claude is covered by another app (probe just
            # left of the strip, on the control row - see the primary strip above).
            $mVis = $true
            if ($pi.Cx) {
                if (-not $pi.Anchored) { $mVis = $false }   # Claude modal over this pane's composer
                else { $mVis = Test-PaneVisible ([int]($pi.DockX - 5)) ([int]$pi.DockY) }
            }
            if (-not $mVis) {
                if ($mForm.Visible) { $mForm.Hide() }
            } else {
                $mDesired = New-Object System.Drawing.Point($mx, $my)
                if ($mForm.Location -ne $mDesired) { $mForm.Location = $mDesired }
                if (-not $mForm.Visible) { $mForm.Show(); Update-LayeredStrip $mForm $script:mirrors[$i].Panel }
            }
        }

        # Fast hover-clear: WM_MOUSELEAVE can lag on a layered window, so proactively drop
        # the highlight on any button/kebab the cursor is no longer over (renders only on change).
        $cp = [System.Windows.Forms.Cursor]::Position
        foreach ($pnl in (@($panel) + @($script:mirrors | ForEach-Object { $_.Panel }))) {
            foreach ($c in $pnl.Controls) {
                if ($c -is [PillButton] -or $c -is [GripHandle]) {
                    try { if (-not $c.RectangleToScreen($c.ClientRectangle).Contains($cp)) { $c.ClearHover() } } catch {}
                }
            }
        }

        # Hover tooltip + one-time first-run hint (our own tip box - the built-in ToolTip
        # does not show reliably on a window without focus)
        if (-not $script:balloonShown -and ($panel.Controls.Count -le 1)) {
            $script:balloonShown = $true
            $script:tipUntil = (Get-Date).AddSeconds(6)
            Show-TipForm (L 'firstRun') $grip
        }
        if ($script:tipUntil) {
            if ((Get-Date) -gt $script:tipUntil) { $script:tipUntil = $null; if ($tipForm.Visible) { $tipForm.Hide() } }
        } elseif (-not $script:tipsOff -and $menusOpen.Count -eq 0 -and $script:hoverCtrl) {
            # The first tip waits out the hover delay; but once a tip is already showing,
            # moving to a DIFFERENT control switches to it immediately. Without this the tip
            # stayed stuck on the first button and the next button's tip never appeared.
            $switching = $tipForm.Visible -and $script:tipCtrl -ne $script:hoverCtrl
            $firstShow = (-not $tipForm.Visible) -and (((Get-Date) - $script:hoverAt).TotalMilliseconds -gt 500)
            if ($switching -or $firstShow) {
                $txt = if ($script:hoverCtrl -eq $grip) { L 'gripTip' } else { Get-TipText $script:hoverCtrl.Tag }
                Show-TipForm $txt $script:hoverCtrl
                $script:tipCtrl = $script:hoverCtrl
            }
        } elseif ($tipForm.Visible) {
            $tipForm.Hide()
            $script:tipCtrl = $null
        }
    } catch {
        Write-CkLog "Tick error: $($_.Exception.Message)"
    }
})

$form.add_FormClosing({ Save-PanelState })

if ($SmokeTest) {
    Write-Output "SMOKE-OK v$CB_VERSION`: $($panel.Controls.Count - 1) buttons, target='$targetTitle'/'$targetProcess', scale=$($script:scale), stripWidth=$(Get-StripWidth $false)px"
    exit 0
}

# Single instance (acquired before the message loop; a crash releases it via the OS)
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeButtonsPanel', [ref]$created)
if (-not $created) { Write-CkLog 'Another instance is already running - exiting' ; exit 0 }

# Only now: this process is THE panel for this session, so its path is the authoritative one.
Write-InstallMarker

[WinHook]::Start()   # let Windows push window move/resize/foreground/chat-switch events
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
[WinHook]::Stop()
