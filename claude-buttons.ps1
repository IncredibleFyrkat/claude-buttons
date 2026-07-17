param([switch]$SmokeTest)
# Claude Buttons - a slim button strip that docks onto the Claude desktop app's bottom bar.
# - Visible only when the Claude window itself is in the foreground
# - Right-click the dot-grip for the menu (pin / position / language / close)
# - Global buttons + buttons pinned to the currently displayed chat
# - buttons.json auto-reloads; all writes merge against a fresh file (atomic + retry, locked)
# - Buttons with "confirm": true require two clicks (Confirm?)
# - Per-chat buttons never auto-send (they only insert text)
# Errors are logged to %LOCALAPPDATA%\claude-buttons.log
# Requires Windows 10/11 built-in Windows PowerShell 5.1 (do not run under pwsh 7).

$ErrorActionPreference = 'Stop'
$CB_VERSION = '1.5.1'
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

public class PillButton : Control {
    public Color Fill = Color.FromArgb(48, 47, 44);
    public Color HoverFill = Color.FromArgb(60, 58, 54);
    public Color DownFill = Color.FromArgb(70, 67, 62);
    public Color ToggleFill = Color.FromArgb(128, 90, 44); // active state for toggle buttons
    public Color Accent = Color.Empty; // border on per-chat buttons
    bool toggled;
    public bool Toggled { get { return toggled; } set { toggled = value; Invalidate(); } }
    bool hover, down;
    public PillButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Cursor = Cursors.Hand;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    static GraphicsPath Pill(Rectangle r, int rad) {
        int d = rad * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 90, 180);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rc = new Rectangle(0, 0, Width - 1, Height - 1);
        using (var path = Pill(rc, (Height - 1) / 2)) {
            Color f;
            if (toggled) { f = down ? DownFill : ToggleFill; }
            else { f = down ? DownFill : (hover ? HoverFill : Fill); }
            using (var b = new SolidBrush(f)) g.FillPath(b, path);
            if (Accent != Color.Empty) using (var pen = new Pen(Accent)) g.DrawPath(pen, path);
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), ForeColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

public class GripHandle : Control {
    public Color DotColor = Color.FromArgb(122, 118, 110);
    public GripHandle() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Cursor = Cursors.Hand;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int d = Math.Max(2, Height / 9);
        int cx = Width / 2, cy = Height / 2, gap = d + 2;
        using (var b = new SolidBrush(DotColor)) {
            for (int col = -1; col <= 0; col++)
                for (int row = -1; row <= 1; row++)
                    g.FillEllipse(b, cx + col * gap + (gap / 2) - d, cy + row * gap - (d / 2), d, d);
        }
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
# without hardcoding any username or path. NOT written during -SmokeTest, so running a
# smoke test from a dev/repo folder never repoints a live install's marker.
if (-not $SmokeTest) {
    try {
        $markerDir = Join-Path $env:USERPROFILE '.claude'
        if (Test-Path $markerDir) {
            Set-Content -Path (Join-Path $markerDir 'claude-buttons-path.txt') -Value $configPath -Encoding UTF8 -ErrorAction SilentlyContinue
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
            $cfg | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
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
$script:freeX = $null   # fri placering: strimlens position relativt til vinduets top-venstre
$script:freeY = $null
if ($null -ne $script:config.freeX -and $null -ne $script:config.freeY) {
    $script:freeX = [int]$script:config.freeX
    $script:freeY = [int]$script:config.freeY
}

# ---------- Language (default: English; switch in the grip menu) ----------
$script:lang = 'en'
if ($script:config.lang) { $script:lang = [string]$script:config.lang }
$script:strings = @{
    en = @{
        rename = 'Rename...'; moveLeft = 'Move left'; moveRight = 'Move right'; remove = 'Remove this button'
        pinNew = 'Pin new button'; custom = 'Other: type your own...'; onlyChat = 'Only this chat'; globalScope = 'Global (all chats)'
        closePanel = 'Close panel'; language = 'Language'
        confirm = 'Confirm?'; gripTip = 'Right-click: menu'
        position = 'Position'; posLeft = 'Left'; posCenter = 'Center'; posRight = 'Right'
        nudgeL = 'Nudge left'; nudgeR = 'Nudge right'
        posFree = 'Free placement (move with mouse, click to drop)'; posAuto = 'Auto (dock to the bottom bar)'
        dupPin = 'That command is already pinned in this scope.'
        tipGlobal = 'Global'; tipChatOnly = 'Only in this chat'; tipChatIn = 'Only in chat: {0}'
        tipSends = 'types and sends'; tipInserts = 'inserts text only'; tipRemove = 'Right-click: rename / move / remove'
        noActive = 'The panel cannot tell which chat is active right now (send a message in the chat first). The button was NOT pinned.'
        pinTitle = 'Pin new button'; askText = 'Text/command the button should type (e.g. /my-command or plain text):'
        askLabel = 'Button name (empty = use the text):'; renameAsk = 'New name for the button:'; renameTitle = 'Rename button'
        firstRun = 'Right-click the dots to add buttons'
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
        confirm = 'Bekræft?'; gripTip = 'Højreklik: menu'
        position = 'Position'; posLeft = 'Venstre'; posCenter = 'Centreret'; posRight = 'Højre'
        nudgeL = 'Skub til venstre'; nudgeR = 'Skub til højre'
        posFree = 'Fri placering (flyt med musen, klik for at slippe)'; posAuto = 'Auto (dock i bundbjælken)'
        dupPin = 'Kommandoen er allerede pinnet i dette scope.'
        tipGlobal = 'Global'; tipChatOnly = 'Kun i denne chat'; tipChatIn = 'Kun i chatten: {0}'
        tipSends = 'skriver og sender'; tipInserts = 'indsætter kun tekst'; tipRemove = 'Højreklik: omdøb / flyt / fjern'
        noActive = 'Panelet kan ikke afgøre hvilken chat der er aktiv lige nu (send en besked i chatten først). Knappen blev IKKE pinnet.'
        pinTitle = 'Pin ny knap'; askText = 'Tekst/kommando knappen skal skrive (f.eks. /min-command eller almindelig tekst):'
        askLabel = 'Knappens navn (tom = brug teksten):'; renameAsk = 'Nyt navn til knappen:'; renameTitle = 'Omdøb knap'
        firstRun = 'Højreklik på prikkerne for at tilføje knapper'
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
        if ($null -ne $script:freeX) {
            $fresh | Add-Member -NotePropertyName freeX -NotePropertyValue $script:freeX -Force
            $fresh | Add-Member -NotePropertyName freeY -NotePropertyValue $script:freeY -Force
        } else {
            foreach ($f in @('freeX', 'freeY')) { $fresh.PSObject.Properties.Remove($f) }
        }
        foreach ($legacy in @('x', 'y', 'offsetX', 'offsetY', 'offsetBottom')) { $fresh.PSObject.Properties.Remove($legacy) }
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
    ($a.label -eq $b.label) -and ($a.text -eq $b.text) -and ([string]$a.chat -eq [string]$b.chat)
}

# ---------- Text helpers ----------
$script:btnFont = New-Object System.Drawing.Font('Segoe UI', 8.5)
$script:compact = $false
$script:padX = S(10)

# ---------- Icons (built-in Windows icon font - Lucide-style line icons, no downloads) ----------
$fams = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
$script:iconFontName = if ($fams -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' }
                       elseif ($fams -contains 'Segoe MDL2 Assets') { 'Segoe MDL2 Assets' } else { $null }
$script:iconFont = if ($script:iconFontName) { New-Object System.Drawing.Font($script:iconFontName, 10) } else { $null }
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
function Show-IconPicker([string]$current) {
    if (-not $script:iconFont) { return $null }
    $dlg = New-Object System.Windows.Forms.Form
    $script:iconDlg = $dlg
    $dlg.Text = L 'iconTitle'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 39, 37)
    $dlg.ClientSize = New-Object System.Drawing.Size((S 400), (S 320))
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location = New-Object System.Drawing.Point((S 8), (S 8))
    $flow.Size = New-Object System.Drawing.Size((S 384), (S 268))
    $flow.AutoScroll = $true
    $flow.BackColor = $dlg.BackColor
    $script:iconPick = $null
    $bigIcon = New-Object System.Drawing.Font($script:iconFontName, 15)
    $pickTip = New-Object System.Windows.Forms.ToolTip   # one shared tooltip, not one per icon
    # "No icon" first, then all mapped icons
    $entries = @(@{ name = ''; glyph = $null }) + (@($script:iconMap.Keys) | Sort-Object | ForEach-Object { @{ name = $_; glyph = (Get-IconGlyph $_) } })
    foreach ($e in $entries) {
        $ib = New-Object System.Windows.Forms.Button
        $ib.Width = S 46; $ib.Height = S 46
        $ib.Margin = New-Object System.Windows.Forms.Padding((S 3))
        $ib.FlatStyle = 'Flat'; $ib.FlatAppearance.BorderSize = 0
        $ib.BackColor = if ($e.name -eq $current) { [System.Drawing.Color]::FromArgb(120, 88, 44) } else { [System.Drawing.Color]::FromArgb(52, 51, 48) }
        $ib.ForeColor = [System.Drawing.Color]::FromArgb(224, 220, 212)
        if ($e.glyph) { $ib.Font = $bigIcon; $ib.Text = $e.glyph }
        else { $ib.Font = New-Object System.Drawing.Font('Segoe UI', 7.5); $ib.Text = 'abc' }
        $ib.Tag = $e.name
        # No GetNewClosure: $this must resolve to the clicked button at event time,
        # and each button's own name is stored in its Tag.
        $ib.add_Click({ $script:iconPick = [string]$this.Tag; $script:iconDlg.DialogResult = 'OK'; $script:iconDlg.Close() })
        $pickTip.SetToolTip($ib, $(if ($e.name) { $e.name } else { 'No icon (text label)' }))
        [void]$flow.Controls.Add($ib)
    }
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'dlgCancel'; $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = [System.Drawing.Color]::FromArgb(62, 60, 56)
    $cancel.ForeColor = [System.Drawing.Color]::FromArgb(220, 216, 208)
    $cancel.Location = New-Object System.Drawing.Point((S 300), (S 284)); $cancel.Size = New-Object System.Drawing.Size((S 92), (S 28))
    $dlg.Controls.AddRange(@($flow, $cancel))
    $dlg.CancelButton = $cancel
    # Make sure the dialog appears in front and takes focus (the panel window never activates,
    # so a child dialog can otherwise open behind and block the panel modally out of sight).
    $dlg.add_Shown({ [CkWin]::DarkTitle($this.Handle); [CkWin]::DarkScroll($flow.Handle); $this.Activate(); $this.BringToFront() })
    $res = $dlg.ShowDialog()
    $out = if ($res -eq 'OK') { $script:iconPick } else { $null }
    $pickTip.Dispose(); $bigIcon.Dispose()
    $dlg.Dispose()
    $script:iconDlg = $null
    return $out
}

function Escape-SendKeys([string]$s) {
    $s = $s -replace "`r`n", "`n" -replace "`r", "`n"
    $out = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq "`n") { [void]$out.Append('+{ENTER}') }  # Shift+Enter = newline without sending
        elseif ('+^%~(){}[]'.Contains([string]$ch)) { [void]$out.Append('{' + $ch + '}') }
        else { [void]$out.Append($ch) }
    }
    $out.ToString()
}

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

function Update-UiaInfo {
    if (((Get-Date) - $script:uiaLast).TotalMilliseconds -lt $script:uiaInterval) { return }
    $script:uiaLast = Get-Date
    try {
        if ($script:target -eq [IntPtr]::Zero) { throw 'no window' }
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
        # Strategy 1: EVERY chat pane. The app names them "Primary pane", "Secondary pane",
        # "Tertiary pane"... in split/grid view - match all Groups whose name ends with "pane".
        $allGroups = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $grpType)
        $found = @()
        foreach ($gp in $allGroups) {
            $gn = $gp.Cached.Name
            if ($gn -and ($gn -match $script:uiaPaneMatch) -and $gp.Cached.BoundingRectangle.Width -gt (SW 250)) { $found += $gp }
        }
        $newPanes = @()
        if ($found.Count -gt 0) {
            foreach ($p in $found) { $newPanes += (Measure-Pane $p $wr $btnCond) }
            # Reading order: rows top-to-bottom, then left-to-right
            $newPanes = @($newPanes | Sort-Object @{ e = { [int]($_.OffT / 100) } }, @{ e = { $_.OffL } })
        } else {
            # Strategy 2: derive a single chat area as window minus sidebar
            $sbCond = New-Object System.Windows.Automation.AndCondition($grpType,
                (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $script:uiaSidebarName)))
            $sb = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $sbCond)
            if ($sb) {
                $sr = $sb.Cached.BoundingRectangle
                $newPanes = @(@{ OffL = [int]($sr.X + $sr.Width - $wr.Left); OffT = 0; Width = [int]($wr.Right - ($sr.X + $sr.Width)); BottomOff = 0; Title = $null; RowCenter = $null; LeftOff = $null })
            }
            Write-CkLog "UIA: no pane matching '$($script:uiaPaneMatch)' found - the app may have updated (running on fallback). Adjust uiaPaneMatch in buttons.json."
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
            if ($p0.Title -ne $script:uiaTitle) { $script:uiaTitle = $p0.Title; $script:uiaDirty = $true }
        } else {
            $script:paneRect = $null; $script:rowCenterOff = $null; $script:leftEdgeOff = $null; $script:paneBottomOff = 0
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
$colBar   = [System.Drawing.Color]::FromArgb(32, 31, 30)
$colFill  = [System.Drawing.Color]::FromArgb(48, 47, 44)
$colHover = [System.Drawing.Color]::FromArgb(60, 58, 54)
$colDown  = [System.Drawing.Color]::FromArgb(70, 67, 62)
$colText  = [System.Drawing.Color]::FromArgb(214, 210, 202)
$colGrip  = [System.Drawing.Color]::FromArgb(122, 118, 110)
$colAccent = [System.Drawing.Color]::FromArgb(150, 110, 60)   # border on per-chat buttons
$pillH = S(21)

# ---------- UI ----------
$form = New-Object NoActivateForm
$form.Text = 'Claude Buttons'
$form.TopMost = $true
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.AutoSize = $true
$form.AutoSizeMode = 'GrowAndShrink'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Opacity = 0
$form.BackColor = $colBar

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.FlowDirection = 'LeftToRight'
$panel.WrapContents = $false
$panel.AutoSize = $true
$panel.AutoSizeMode = 'GrowAndShrink'
$panel.Padding = New-Object System.Windows.Forms.Padding((S(3)), (S(2)), (S(3)), (S(2)))
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
        $y = $af.Top - $tipForm.Height - (S 7)   # over den strimmel kontrollen sidder i
        if ($y -lt 0) { $y = $af.Bottom + (S 7) }
        $tipForm.Location = New-Object System.Drawing.Point($x, $y)
        if (-not $tipForm.Visible) { $tipForm.Show() }
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
    "$out$head`n$scope - $enter`n$(L 'tipRemove')"
}

# Grip
$grip = New-Object GripHandle
$grip.DotColor = $colGrip
$grip.BackColor = $colBar
$grip.Width = S(14)
$grip.Height = $pillH
$grip.Margin = New-Object System.Windows.Forms.Padding((S(2)), (S(2)), (S(2)), (S(2)))
$grip.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
$grip.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })

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
        $ny = [ordered]@{ label = [string]$entry.label; text = [string]$entry.text; submit = $true }
        if ($entry.short) { $ny.short = [string]$entry.short }
        if ($entry.confirm) { $ny.confirm = $true }
        if ($chatId) { $ny.chat = $chatId }
        if (-not $global -and $script:uiaTitle) { $ny.chatTitle = $script:uiaTitle }  # bind to the DISPLAYED chat
        $nyObj = [pscustomobject]$ny
        if (Update-Buttons { param($btns) @($btns) + $nyObj }) { Rebuild-Buttons }
    } catch { Write-CkLog "Add-PinnedButton error: $($_.Exception.Message)" }
}

function Set-CkLang([string]$l) {
    try { $script:lang = $l; Save-PanelState; Rebuild-Buttons } catch { Write-CkLog "Set-CkLang error: $($_.Exception.Message)" }
}

function Set-CkRelX([double]$v) {
    try { $script:relX = [Math]::Max(0.0, [Math]::Min(1.0, $v)); Save-PanelState } catch { Write-CkLog "Set-CkRelX error: $($_.Exception.Message)" }
}

$gripMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miPin = New-Object System.Windows.Forms.ToolStripMenuItem 'Pin new button'
[void]$gripMenu.Items.Add($miPin)
$miPos = New-Object System.Windows.Forms.ToolStripMenuItem 'Position'
$posL = New-Object System.Windows.Forms.ToolStripMenuItem 'Left';       $posL.add_Click({ Set-CkRelX 0.03 })
$posC = New-Object System.Windows.Forms.ToolStripMenuItem 'Center';     $posC.add_Click({ Set-CkRelX 0.5 })
$posR = New-Object System.Windows.Forms.ToolStripMenuItem 'Right';      $posR.add_Click({ Set-CkRelX 0.97 })
$posNL = New-Object System.Windows.Forms.ToolStripMenuItem 'Nudge left';  $posNL.add_Click({ Set-CkRelX ($script:relX - 0.05) })
$posNR = New-Object System.Windows.Forms.ToolStripMenuItem 'Nudge right'; $posNR.add_Click({ Set-CkRelX ($script:relX + 0.05) })
$posFree = New-Object System.Windows.Forms.ToolStripMenuItem 'Free placement'
$posFree.add_Click({
    $script:moveMode = $true
    $script:moveModeAt = Get-Date
    [void][CkWin]::GetAsyncKeyState(0x01)   # slug klikket der valgte menupunktet
})
$posAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto (dock)'
$posAuto.add_Click({ $script:freeX = $null; $script:freeY = $null; Save-PanelState })
foreach ($mi in @($posL, $posC, $posR)) { [void]$miPos.DropDownItems.Add($mi) }
[void]$miPos.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
foreach ($mi in @($posNL, $posNR)) { [void]$miPos.DropDownItems.Add($mi) }
[void]$miPos.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
foreach ($mi in @($posFree, $posAuto)) { [void]$miPos.DropDownItems.Add($mi) }
[void]$gripMenu.Items.Add($miPos)
$miLang = New-Object System.Windows.Forms.ToolStripMenuItem 'Language'
$subEn = New-Object System.Windows.Forms.ToolStripMenuItem 'English'
$subEn.add_Click({ Set-CkLang 'en' })
$subDa = New-Object System.Windows.Forms.ToolStripMenuItem 'Dansk'
$subDa.add_Click({ Set-CkLang 'da' })
[void]$miLang.DropDownItems.Add($subEn)
[void]$miLang.DropDownItems.Add($subDa)
[void]$gripMenu.Items.Add($miLang)
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
    $miPos.Text = L 'position'
    $posL.Text = L 'posLeft'; $posC.Text = L 'posCenter'; $posR.Text = L 'posRight'
    $posNL.Text = L 'nudgeL'; $posNR.Text = L 'nudgeR'
    $posFree.Text = L 'posFree'; $posAuto.Text = L 'posAuto'
    $posAuto.Checked = ($null -eq $script:freeX); $posFree.Checked = ($null -ne $script:freeX)
    $subEn.Checked = ($script:lang -eq 'en')
    $subDa.Checked = ($script:lang -eq 'da')
    $piThis.Text = L 'onlyChat'; $piGlob.Text = L 'globalScope'
    Fill-PinScope $piThis $false
    Fill-PinScope $piGlob $true
})

# No drag-and-drop: position is set via the menu, so nothing moves by accident
$script:dragging = $false

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
        $ny = Show-InputDialog (L 'renameTitle') (L 'renameAsk') ([string]$t.label)
        if ([string]::IsNullOrWhiteSpace($ny)) { return }
        if (Update-Buttons { param($btns) foreach ($b in $btns) { if (Same-Button $b $t) { $b.label = $ny } }; $btns }) {
            Rebuild-Buttons
        }
    } catch { Write-CkLog "Rename error: $($_.Exception.Message)" }
})

function Move-PinButton([int]$dir) {
    try {
        $src = $script:menuSource
        if (-not ($src -and $src.Tag)) { return }
        $hostPanel = $src.Parent   # den strimmel der blev hoejreklikket i (primaer eller spejl)
        $idx = $hostPanel.Controls.IndexOf($src)
        $nyIdx = $idx + $dir
        if ($nyIdx -lt 1 -or $nyIdx -ge $hostPanel.Controls.Count) { return }  # index 0 is the grip
        $neighbor = $hostPanel.Controls[$nyIdx].Tag
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
        if ($ok) { Rebuild-Buttons }   # synkroniser raekkefoelgen paa alle strimler
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
$script:moveMode = $false
$script:moveModeAt = Get-Date '2000-01-01'

function Test-TargetForeground {
    [CkWin]::GetForegroundWindow() -eq $script:target
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
    if ($script:moveMode) { return }  # the drop click must never fire a button
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
            Start-Sleep -Milliseconds 150
            if (-not (Test-TargetForeground)) { return }   # focus moved - abort BEFORE any state change
            # Toggle with nothing to send (off, no textOff): flip only, we're foreground.
            if ($isToggle -and [string]::IsNullOrEmpty($textToSend)) { Set-ToggleFace $item $newOn; return }

            if ($textToSend.Length -gt 80 -or $textToSend -match "`n") {
                # Long/multiline prompts: paste atomically via clipboard (fast, no typing race).
                # Re-check foreground BEFORE touching the clipboard so an aborted send never leaves
                # it clobbered, and restore in finally so it's restored even on an exception.
                if (-not (Test-TargetForeground)) { return }
                if ($isToggle) { Set-ToggleFace $item $newOn }   # H7: flip only now, right before the send
                $backup = $null; $snapOk = $false
                try {
                    $old = [System.Windows.Forms.Clipboard]::GetDataObject()
                    $backup = New-Object System.Windows.Forms.DataObject
                    if ($old) { foreach ($fmt in $old.GetFormats()) { try { $backup.SetData($fmt, $old.GetData($fmt)) } catch {} } }
                    $snapOk = $true   # empty snapshot = "was empty"; restoring it re-empties correctly
                } catch { $snapOk = $false }
                try {
                    [System.Windows.Forms.Clipboard]::SetText(($textToSend -replace "`r`n", "`n"))
                    [System.Windows.Forms.SendKeys]::SendWait('^v')
                    Start-Sleep -Milliseconds 300
                } finally {
                    # M1: always restore the full prior clipboard. If the snapshot itself failed we
                    # leave our text rather than guess (can't safely reconstruct unknown content).
                    if ($snapOk) { try { [System.Windows.Forms.Clipboard]::SetDataObject($backup, $true) } catch {} }
                }
            } else {
                if (-not (Test-TargetForeground)) { return }   # M2: re-check right before send
                if ($isToggle) { Set-ToggleFace $item $newOn }   # H7: flip only now, right before the send
                [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys $textToSend))
            }
            # Per-chat buttons never auto-send: the user must see the text before Enter
            if ($item.submit -and -not $item.chat) {
                Start-Sleep -Milliseconds 400
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
    $mf = New-Object NoActivateForm
    $mf.Text = 'Claude Buttons'
    $mf.TopMost = $true
    $mf.FormBorderStyle = 'None'
    $mf.ShowInTaskbar = $false
    $mf.AutoSize = $true
    $mf.AutoSizeMode = 'GrowAndShrink'
    $mf.StartPosition = 'Manual'
    $mf.Location = New-Object System.Drawing.Point(-4000, -4000)
    $mf.BackColor = $colBar
    $mp = New-Object System.Windows.Forms.FlowLayoutPanel
    $mp.FlowDirection = 'LeftToRight'
    $mp.WrapContents = $false
    $mp.AutoSize = $true
    $mp.AutoSizeMode = 'GrowAndShrink'
    $mp.Padding = New-Object System.Windows.Forms.Padding((S(3)), (S(2)), (S(3)), (S(2)))
    [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($mp, $true, $null)
    $mf.Controls.Add($mp)
    $mg = New-Object GripHandle
    $mg.DotColor = $colGrip
    $mg.BackColor = $colBar
    $mg.Width = S(14)
    $mg.Height = $pillH
    $mg.Margin = New-Object System.Windows.Forms.Padding((S(2)), (S(2)), (S(2)), (S(2)))
    $mg.ContextMenuStrip = $gripMenu
    $mg.add_MouseUp({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $gripMenu.Show($this, $_.Location) } })
    $mg.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
    $mg.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })
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
        $btn.Margin = New-Object System.Windows.Forms.Padding((S(2)))
        $btn.BackColor = $colBar
        $btn.ForeColor = $colText
        $btn.Fill = $colFill
        $btn.HoverFill = $colHover
        $btn.DownFill = $colDown
        if ($b.chat) { $btn.Accent = $colAccent }
        $btn.ContextMenuStrip = $btnMenu
        $btn.add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $script:menuSource = $this } })
        $btn.add_Click({ Invoke-PillClick $this })
        $btn.add_MouseEnter({ $script:hoverCtrl = $this; $script:hoverAt = Get-Date })
        $btn.add_MouseLeave({ if ($script:hoverCtrl -eq $this) { $script:hoverCtrl = $null } })
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
    for ($i = 0; $i -lt $script:mirrors.Count; $i++) {
        $mTitle = if (($i + 1) -lt $script:panes.Count) { $script:panes[$i + 1].Title } else { $null }
        $script:mirrors[$i].Form.SuspendLayout()
        Build-StripPanel $script:mirrors[$i].Panel $script:mirrors[$i].Grip $mTitle $false
        $script:mirrors[$i].Form.ResumeLayout()
    }
}
[void](Read-ActiveSession)
Rebuild-Buttons

# ---------- Window tracking ----------
$script:target = [IntPtr]::Zero
$script:targetPid = [uint32]0
$script:autoMove = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
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
            }
        }
        $ourUiOpen = $gripMenu.Visible -or $btnMenu.Visible -or ($null -ne $script:iconDlg) -or $script:moveMode
        $show = ($script:target -ne [IntPtr]::Zero) -and
                (-not [CkWin]::IsIconic($script:target)) -and
                [CkWin]::IsWindowVisible($script:target) -and
                (([CkWin]::GetForegroundWindow() -eq $script:target) -or $ourUiOpen)
        if (-not $show) {
            if ($form.Visible) { $form.Hide() }
            foreach ($ms in $script:mirrors) { if ($ms.Form.Visible) { $ms.Form.Hide() } }
            if ($tipForm.Visible) { $tipForm.Hide() }
            if ($gripMenu.Visible) { $gripMenu.Close() }
            if ($btnMenu.Visible) { $btnMenu.Close() }
            $script:moveMode = $false
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
            $ny = Read-FreshConfig
            if ($ny) { $script:config = $ny; $script:cfgTime = $wt; $script:cfgHealUntil = $null; $dirty = $true }
        }
        if ($script:cfgHealUntil -and (Get-Date) -ge $script:cfgHealUntil) { $script:cfgHealUntil = $null }  # give up healing
        if (Read-ActiveSession) { $dirty = $true }
        # Hide chat buttons when the "active chat" signal is older than 10 min
        $exp = $false
        if ($script:activeSession -and $script:activeTs) {
            $exp = ([DateTime]::UtcNow - $script:activeTs).TotalMinutes -gt 10
        }
        if ($exp -ne $script:activeExpired) { $script:activeExpired = $exp; $dirty = $true }
        # Read the displayed chat + chat area from the app's UI (cached, backs off when stable)
        Update-UiaInfo
        if ($script:uiaDirty) { $script:uiaDirty = $false; $dirty = $true }

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

        if ($script:moveMode) {
            # Fri flytning: strimlen foelger musen; et venstreklik slipper den
            if ($tipForm.Visible) { $tipForm.Hide() }
            $mp = [System.Windows.Forms.Cursor]::Position
            $script:autoMove = $true
            $form.Location = New-Object System.Drawing.Point(($mp.X - [int]($form.Width / 2)), ($mp.Y - (S 10)))
            $script:autoMove = $false
            $drop = (([CkWin]::GetAsyncKeyState(0x01) -band 0x8001) -ne 0)
            if ($drop -and ((Get-Date) - $script:moveModeAt).TotalMilliseconds -gt 400) {
                $script:moveMode = $false
                $script:freeX = [int]($form.Left - $r.Left)
                $script:freeY = [int]($form.Top - $r.Top)
                Save-PanelState
            }
        } else {
            if ($null -ne $script:freeX) {
                # Fri placering: fast punkt relativt til vinduet
                $x = $r.Left + $script:freeX
                $y = $r.Top + $script:freeY
            } else {
                # Horizontal: after the app's own left cluster (relX nudges within the remaining space).
                # Vertical: locked to the pane's bottom button row (self-calibrating, grid-aware).
                $paneBottom = $r.Bottom - $script:paneBottomOff
                $startX = if ($null -ne $script:leftEdgeOff) { $r.Left + $script:leftEdgeOff + (SW $script:stripGap) } else { $areaL }
                $room = [Math]::Max(1, ($areaL + $areaW) - $startX - $form.Width)
                $x = $startX + [int]($script:relX * $room)
                if ($null -ne $script:rowCenterOff) {
                    $y = $paneBottom - $script:rowCenterOff - [int]($form.Height / 2)
                } else {
                    $y = $paneBottom - (SW $script:fallbackRow) - [int]($form.Height / 2)
                }
            }
            $x = [Math]::Max($r.Left + 4, [Math]::Min($x, $r.Right - $form.Width - 4))
            $y = [Math]::Max($r.Top + 4, [Math]::Min($y, $r.Bottom - $form.Height - 2))
            $desired = New-Object System.Drawing.Point($x, $y)
            if ($form.Location -ne $desired) {
                $script:autoMove = $true
                $form.Location = $desired
                $script:autoMove = $false
            }
        }
        if (-not $form.Visible) { $form.Show() }
        if ($form.Opacity -lt 1) { $form.Opacity = 1 }

        # Mirror strips: dock each under its own pane
        for ($i = 0; $i -lt $script:mirrors.Count; $i++) {
            $mForm = $script:mirrors[$i].Form
            if (($i + 1) -ge $script:panes.Count) { if ($mForm.Visible) { $mForm.Hide() }; continue }
            $pi = $script:panes[$i + 1]
            $paneL = $r.Left + $pi.OffL
            $paneBottom = $r.Bottom - $pi.BottomOff
            $startX = if ($null -ne $pi.LeftOff) { $r.Left + $pi.LeftOff + (SW $script:stripGap) } else { $paneL }
            $room = [Math]::Max(1, ($paneL + $pi.Width) - $startX - $mForm.Width)
            $mx = $startX + [int]($script:relX * $room)
            $my = if ($null -ne $pi.RowCenter) { $paneBottom - $pi.RowCenter - [int]($mForm.Height / 2) }
                  else { $paneBottom - (SW $script:fallbackRow) - [int]($mForm.Height / 2) }
            $mx = [Math]::Max($r.Left + 4, [Math]::Min($mx, $r.Right - $mForm.Width - 4))
            $my = [Math]::Max($r.Top + 4, [Math]::Min($my, $r.Bottom - $mForm.Height - 2))
            $mDesired = New-Object System.Drawing.Point($mx, $my)
            if ($mForm.Location -ne $mDesired) { $mForm.Location = $mDesired }
            if (-not $mForm.Visible) { $mForm.Show() }
        }

        # Hover-tooltip + engangs foerstegangs-hint (egen tip-boks - indbygget ToolTip
        # viser sig ikke paalideligt paa et vindue uden fokus)
        if (-not $script:balloonShown -and ($panel.Controls.Count -le 1)) {
            $script:balloonShown = $true
            $script:tipUntil = (Get-Date).AddSeconds(6)
            Show-TipForm (L 'firstRun') $grip
        }
        if ($script:tipUntil) {
            if ((Get-Date) -gt $script:tipUntil) { $script:tipUntil = $null; if ($tipForm.Visible) { $tipForm.Hide() } }
        } elseif ($menusOpen.Count -eq 0 -and -not $script:moveMode -and $script:hoverCtrl) {
            if (((Get-Date) - $script:hoverAt).TotalMilliseconds -gt 500 -and -not $tipForm.Visible) {
                $txt = if ($script:hoverCtrl -eq $grip) { L 'gripTip' } else { Get-TipText $script:hoverCtrl.Tag }
                Show-TipForm $txt $script:hoverCtrl
            }
        } elseif ($tipForm.Visible) {
            $tipForm.Hide()
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

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
