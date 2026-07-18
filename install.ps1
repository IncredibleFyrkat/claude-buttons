<#
  Claude Buttons - installer
  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    ... -Update       (refresh program files + skills, keep your buttons.json)
    ... -Uninstall    (remove everything this installer added)
    ... -InstallDir "C:\path"   (override install location)
    ... -Shutdown     (also install the optional shutdown feature without prompting)
    ... -NoAutostart / -Autostart   (skip / force the startup shortcut without prompting)

  What it does (core):
    - Copies the panel to %LOCALAPPDATA%\Programs\ClaudeButtons (outside any cloud-synced folder)
    - Installs the /pin and /unpin skills into ~/.claude/skills
    - Merges ONE hook (UserPromptSubmit) into ~/.claude/settings.json (backed up first)
  Optional (only if you opt in):
    - The shutdown feature (requires Node.js): the shutdown-on-done engine - a
      /shutdown-on-done skill, a completion-judged Stop hook and a stateful power
      button in the panel. OFF by default and always asks first.
#>
[CmdletBinding()]
param(
    [switch]$Update,
    [switch]$Uninstall,
    [string]$InstallDir,
    [switch]$Shutdown,
    [switch]$Autostart,
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeButtons' }
$claudeDir   = Join-Path $env:USERPROFILE '.claude'
$skillsDir   = Join-Path $claudeDir 'skills'
$settingsPath= Join-Path $claudeDir 'settings.json'
$startupLnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Buttons.lnk'
$panelName   = 'claude-buttons.ps1'

function Write-Utf8Bom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($path, $text, $enc)
}
# settings.json must be plain UTF-8 (no BOM): a leading BOM breaks strict JSON
# readers. PS 5.1 reads the .ps1 fine either way, so only JSON files use this.
function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, $text, $enc)
}
# Atomic, validated write for JSON we must never leave half-written. WriteAllText truncates
# the target and THEN streams into it, so a crash - or Claude Code writing settings.json at
# the same moment - could leave the user with an empty or truncated config and no working
# Claude Code. Write to a temp file, prove it parses back, then swap it in atomically.
function Write-JsonAtomic([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)   # JSON: never a BOM
    $tmp  = "$path.tmp.$PID"
    $swap = "$path.replacing.$PID"   # per-PID: a fixed name collides between concurrent runs,
                                     # and a stale read-only one wedges every future write
    try {
        [IO.File]::WriteAllText($tmp, $text, $enc)
        # Prove it parses back AND is actually an object. ConvertFrom-Json returns $null for
        # '', '   ' and 'null' without throwing, and `$null | ConvertTo-Json` is the empty
        # string - so a null object would otherwise be written as a 0-byte file and certified
        # valid by its own safety net. That is the exact corruption this function exists to stop.
        $parsed = $null
        try { $parsed = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json } catch {
            throw "Refusing to write $path - the JSON it produced did not parse back. Your file was NOT modified."
        }
        if ($null -eq $parsed -or $parsed -is [string] -or $parsed -is [ValueType]) {
            throw "Refusing to write $path - the JSON it produced was empty or not an object. Your file was NOT modified."
        }
        if (Test-Path $path) {
            Remove-Item $swap -Force -ErrorAction SilentlyContinue
            # Replace is atomic, but unlike WriteAllText it fails if ANY other process holds
            # the file open - even a reader. Retry briefly: Defender, a backup agent or an
            # editor holding a transient handle is common and self-clearing.
            $done = $false
            for ($i = 0; $i -lt 5 -and -not $done; $i++) {
                try { [IO.File]::Replace($tmp, $path, $swap); $done = $true }
                catch { if ($i -eq 4) { throw }; Start-Sleep -Milliseconds (120 * ($i + 1)) }
            }
            Remove-Item $swap -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item $tmp $path -Force
        }
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue   # never leave .tmp litter behind
        throw
    }
}

function Stop-Panel {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$panelName*" } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
}

# ---- settings.json hook helpers (safe merge, never clobber existing config) ----
function Get-Settings {
    if (Test-Path $settingsPath) {
        try { return (Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { throw "settings.json is not valid JSON - fix or remove it, then re-run." }
    }
    return (New-Object psobject)
}
# Pre-flight, run BEFORE anything is written or deleted. settings.json is touched late in
# both install and uninstall, so a file that is invalid or locked used to abort the run
# half-way - on uninstall that left the skills and engine deleted but the hooks still in
# settings.json, pointing at files that no longer exist, with no self-service way back.
# Failing here costs nothing, because nothing has happened yet.
function Test-SettingsUsable {
    if (-not (Test-Path $settingsPath)) { return }
    $parsed = $null
    try { $parsed = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "~/.claude/settings.json is not valid JSON. NOTHING has been changed. Fix or remove it, then re-run." }
    # '' , '   ' and 'null' all parse to $null WITHOUT throwing, so a 0-byte or null-only
    # settings.json used to walk straight past this gate and then abort the run half-way
    # through with "Cannot index into a null array" - after files had already been deleted.
    if ($null -eq $parsed -or $parsed -is [string] -or $parsed -is [ValueType]) {
        throw "~/.claude/settings.json is empty or is not a JSON object. NOTHING has been changed. Restore it (see $settingsPath.orig.bak) or delete it, then re-run."
    }
    # Check nesting HERE, before anything is deleted or written. Doing it at write time meant
    # the throw landed after the uninstall had already removed the skills and the engine,
    # stranding the user with hooks pointing at files that no longer exist.
    Assert-JsonDepthSafe $parsed
    try { $fs = [IO.File]::Open($settingsPath, 'Open', 'ReadWrite', 'None'); $fs.Close() }
    catch { throw "~/.claude/settings.json is locked (is Claude Code running?). NOTHING has been changed. Close it and re-run." }
}
# Measure the REAL nesting depth of the object graph.
#
# PS 5.1's ConvertTo-Json does not error when nesting exceeds -Depth: it stringifies the
# over-deep node into "@{k=v}" or "System.Object[]" and still emits valid JSON, silently
# destroying MCP server definitions. The obvious guard - searching the serialized text for
# those markers - is wrong in BOTH directions: it refuses valid configs whose hook commands
# or env values legitimately contain "@{", and it misses an over-deep array of strings, which
# collapses to a space-joined string with no marker at all. So measure the structure instead.
function Get-JsonDepth($o, [int]$d = 0) {
    if ($d -gt 120) { return $d }                              # cycle guard
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { return $d }
    $max = $d
    if ($o -is [System.Collections.IDictionary]) {
        foreach ($k in @($o.Keys)) {
            $cd = Get-JsonDepth $o[$k] ($d + 1); if ($cd -gt $max) { $max = $cd }
        }
    }
    elseif ($o -is [System.Collections.IList]) {
        # Index $o directly; do NOT collect the children into a variable first. Measured:
        # `$kids = if (...) { $o } else { ... }` routes the value through the pipeline, which
        # UNROLLS a single-element array into its element - so an array-of-arrays loses one
        # level per recursion and a 10-deep chain measures 6 instead of 11. (@() and foreach
        # are innocent; both measure 11 on their own. It is specifically the assignment from
        # an if-expression.) `hooks` is an array of objects containing arrays of objects, so
        # this is exactly the shape the guard exists to measure.
        for ($i = 0; $i -lt $o.Count; $i++) {
            $cd = Get-JsonDepth $o[$i] ($d + 1); if ($cd -gt $max) { $max = $cd }
        }
    }
    else {
        foreach ($p in $o.PSObject.Properties) {
            $cd = Get-JsonDepth $p.Value ($d + 1); if ($cd -gt $max) { $max = $cd }
        }
    }
    return $max
}
function Assert-JsonDepthSafe($obj) {
    # Threshold calibrated by measurement, not by matching -Depth: with `-Depth 100`,
    # ConvertTo-Json actually starts stringifying at depth 102, and ConvertFrom-Json refuses
    # to parse at 102 as well - so the corruption window is unreachable from a settings.json
    # file at all. Blocking at 100 was over-strict by exactly 2 in the safe direction; 102
    # matches where the damage really begins.
    if ((Get-JsonDepth $obj) -ge 102) {
        throw ("~/.claude/settings.json nests deeper than this installer can safely rewrite. " +
               "NOTHING has been changed - add the hook manually (see README). " +
               "Pristine backup: $settingsPath.orig.bak")
    }
}
# A FUNCTION, not an inline loop, so a test can execute it and assert on the rules that are
# actually granted. The previous test grepped the source for `request-on` near an
# Ensure-AllowRule line, which a two-line variant defeated:
#     $rv = 'request' + '-on'
#     Ensure-AllowRule $settings "Bash(node $scriptFwd toggle $rv)"
# - the grant line does not contain the literal, and the line that does is not a grant line.
# Testing the resulting permission set is immune to how the verb is spelled.
function Grant-ShutdownAllowRules($settings, [string]$scriptFwd) {
    Remove-AllowRules $settings 'shutdown-on-done.mjs'   # drop any old wildcard rule first
    # request-on is deliberately absent - see the SEC-01 note at the call site.
    foreach ($verb in @('request-off', 'on --this-turn', 'off', 'status')) {
        Ensure-AllowRule $settings "Bash(node `"$scriptFwd`" toggle $verb)"
        Ensure-AllowRule $settings "Bash(node $scriptFwd toggle $verb)"
    }
}
# Also a function, for the same reason: the marker records where this install keeps
# buttons.json, and /pin and /unpin cannot find the panel without it. It was previously a bare
# call in the main flow, which the AST test seam cannot reach - so deleting it, or pointing it
# at the wrong path, left the whole suite green.
function Write-InstallMarker([string]$claudeDir, [string]$cfgPath) {
    Write-Utf8NoBom (Join-Path $claudeDir 'claude-buttons-path.txt') $cfgPath
}
function Save-Settings($obj) {
    if (Test-Path $settingsPath) {
        # Preserve the PRISTINE original once, write-once: a full install calls
        # Save-Settings more than once, so the rolling .bak is an already-modified
        # copy by the second call. The .orig.bak is the user's settings from before
        # this tool ever touched them, which is what restoring from backup wants.
        if (-not (Test-Path "$settingsPath.orig.bak")) { Copy-Item $settingsPath "$settingsPath.orig.bak" -Force }
        Copy-Item $settingsPath "$settingsPath.bak" -Force
    }
    # PS 5.1's ConvertTo-Json does NOT error when nesting exceeds -Depth: it stringifies the
    # over-deep node into "@{k=v}" or "System.Object[]", silently destroying MCP server
    # definitions while still emitting valid JSON. The depth is checked on the OBJECT GRAPH,
    # not on the serialized text: an earlier version of this guard searched the text for
    # "@{ and refused perfectly valid configs, because a hook command, an env value or a
    # statusLine may legitimately contain those characters. String content and structural
    # damage are indistinguishable once serialized.
    Assert-JsonDepthSafe $obj
    Write-JsonAtomic $settingsPath ($obj | ConvertTo-Json -Depth 100)
}
function Ensure-HookArray($settings, [string]$event) {
    if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member hooks (New-Object psobject) -Force }
    if (-not $settings.hooks.PSObject.Properties[$event]) { $settings.hooks | Add-Member $event @() -Force }
}
function Hook-Exists($settings, [string]$event, [string]$marker) {
    if (-not $settings.hooks.PSObject.Properties[$event]) { return $false }
    foreach ($grp in @($settings.hooks.$event)) {
        foreach ($h in @($grp.hooks)) { if ("$($h.command)" -like "*$marker*") { return $true } }
    }
    return $false
}
function Remove-Hook($settings, [string]$event, [string]$marker) {
    if (-not $settings.hooks.PSObject.Properties[$event]) { return }
    $kept = @()
    foreach ($grp in @($settings.hooks.$event)) {
        $keepHooks = @($grp.hooks | Where-Object { "$($_.command)" -notlike "*$marker*" })
        if ($keepHooks.Count -gt 0) { $grp.hooks = $keepHooks; $kept += $grp }
    }
    $settings.hooks.$event = $kept
}

$activeHookCmd = "`$i=[Console]::In.ReadToEnd()|ConvertFrom-Json; @{session_id=`$i.session_id; ts=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content -Path (Join-Path `$env:USERPROFILE '.claude\active-session.json') -Encoding UTF8"

function Ensure-AllowRule($settings, [string]$rule) {
    if (-not $settings.PSObject.Properties['permissions']) { $settings | Add-Member permissions (New-Object psobject) -Force }
    if (-not $settings.permissions.PSObject.Properties['allow']) { $settings.permissions | Add-Member allow @() -Force }
    if (@($settings.permissions.allow) -notcontains $rule) { $settings.permissions.allow = @($settings.permissions.allow) + $rule }
}
function Remove-AllowRules($settings, [string]$marker) {
    if ($settings.PSObject.Properties['permissions'] -and $settings.permissions.PSObject.Properties['allow']) {
        $settings.permissions.allow = @($settings.permissions.allow | Where-Object { $_ -notlike "*$marker*" })
    }
}

# =================== UNINSTALL ===================
if ($Uninstall) {
    Write-Host "Uninstalling Claude Buttons..." -ForegroundColor Cyan
    Test-SettingsUsable   # fail before deleting anything, not after
    Stop-Panel
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }
    foreach ($s in @('pin','unpin','close-pc-on-done','cancel-close-pc','shutdown-on-done')) {
        $d = Join-Path $skillsDir $s
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Remove-Item (Join-Path $claudeDir 'claude-buttons-path.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $claudeDir 'hooks\shutdown-on-done.mjs') -Force -ErrorAction SilentlyContinue
    if (Test-Path $settingsPath) {
        $settings = Get-Settings
        Remove-Hook $settings 'UserPromptSubmit' 'active-session.json'
        Remove-Hook $settings 'Stop' 'close-pc-on-done.flag'
        Remove-Hook $settings 'Stop' 'shutdown-on-done.mjs'
        Remove-AllowRules $settings 'shutdown-on-done.mjs'
        Save-Settings $settings
    }
    $keep = Read-Host "Remove the program folder and your buttons.json too? ($InstallDir) [y/N]"
    if ($keep -eq 'y') { if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force } }
    Write-Host "Done. (A settings.json.bak backup was left in ~/.claude if changes were made.)" -ForegroundColor Green
    return
}

# =================== INSTALL / UPDATE ===================
Write-Host "Installing Claude Buttons to $InstallDir" -ForegroundColor Cyan
Test-SettingsUsable   # fail before writing anything, not half-way through
Stop-Panel
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 1) Program files (always overwrite)
Copy-Item (Join-Path $src $panelName) (Join-Path $InstallDir $panelName) -Force
Copy-Item (Join-Path $src 'Launch.vbs') (Join-Path $InstallDir 'Launch.vbs') -Force

# 2) buttons.json - only create if missing (never wipe the user's buttons); migrate in place otherwise
$cfgPath = Join-Path $InstallDir 'buttons.json'
if (-not (Test-Path $cfgPath)) {
    Copy-Item (Join-Path $src 'buttons.default.json') $cfgPath -Force
} else {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $cfg.PSObject.Properties['schemaVersion']) { $cfg | Add-Member schemaVersion 1 -Force; Write-JsonAtomic $cfgPath ($cfg | ConvertTo-Json -Depth 100) }
    } catch {}
}

# 3) Skills (core) - substitute nothing hardcoded; they read the marker file at runtime
New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
foreach ($s in @('pin','unpin')) {
    $dst = Join-Path $skillsDir $s
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item (Join-Path $src "skills\$s\SKILL.md") (Join-Path $dst 'SKILL.md') -Force
}

# 4) Marker so skills find buttons.json without any hardcoded path
Write-InstallMarker $claudeDir $cfgPath

# 5) Core hook (UserPromptSubmit) - merged safely
$settings = Get-Settings
if (-not (Hook-Exists $settings 'UserPromptSubmit' 'active-session.json')) {
    Ensure-HookArray $settings 'UserPromptSubmit'
    $grp = [pscustomobject]@{ hooks = @([pscustomobject]@{ type='command'; shell='powershell'; async=$true; timeout=10; command=$activeHookCmd }) }
    $settings.hooks.UserPromptSubmit = @($settings.hooks.UserPromptSubmit) + $grp
    Save-Settings $settings
    Write-Host "  + Added UserPromptSubmit hook (tracks which chat is active - no side effects)." -ForegroundColor DarkGray
}

# 6) OPTIONAL shutdown feature - opt-in only, loudly disclosed.
# On -Update, refresh the engine + skill if the feature is already installed (H4).
$wantShutdown = $Shutdown
if ($Update -and (Test-Path (Join-Path $claudeDir 'hooks\shutdown-on-done.mjs'))) {
    $wantShutdown = $true
    Write-Host "  Refreshing the already-installed shutdown-on-done engine." -ForegroundColor DarkGray
}
if (-not $Shutdown -and -not $Update) {
    Write-Host ""
    Write-Host "Optional feature: 'Shutdown on done' (requires Node.js)." -ForegroundColor Yellow
    Write-Host "  Installs the shutdown-on-done engine: a /shutdown-on-done command, a Stop hook"
    Write-Host "  and a panel toggle button. The agent keeps working and powers the PC off only"
    Write-Host "  at verified full completion (60s grace, 'shutdown -a' aborts)."
    $ans = Read-Host "  Install the shutdown feature? [y/N]"
    $wantShutdown = ($ans -eq 'y')
}
if ($wantShutdown) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host "  ! Node.js not found on PATH - the shutdown feature requires it. Skipped." -ForegroundColor Yellow
    } else {
        $hooksDir = Join-Path $claudeDir 'hooks'
        New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
        Copy-Item (Join-Path $src 'engine\shutdown-on-done.mjs') (Join-Path $hooksDir 'shutdown-on-done.mjs') -Force
        $scriptFwd = ((Join-Path $hooksDir 'shutdown-on-done.mjs') -replace '\\', '/')
        # Skill from template (script path substituted per user)
        $dst = Join-Path $skillsDir 'shutdown-on-done'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $tpl = Get-Content (Join-Path $src 'skills-optional\shutdown-on-done\SKILL.md') -Raw -Encoding UTF8
        Write-Utf8Bom (Join-Path $dst 'SKILL.md') ($tpl -replace '\{\{SCRIPT\}\}', $scriptFwd)
        # Settings: migrate off the legacy hook, add engine hook + the allow rules the
        # agent needs to run the shutdown flow unattended.
        $settings = Get-Settings
        Remove-Hook $settings 'Stop' 'close-pc-on-done.flag'   # legacy v1 hook, superseded
        if (-not (Hook-Exists $settings 'Stop' 'shutdown-on-done.mjs')) {
            Ensure-HookArray $settings 'Stop'
            $grp = [pscustomobject]@{ hooks = @([pscustomobject]@{ type='command'; command="node `"$scriptFwd`""; timeout=15 }) }
            $settings.hooks.Stop = @($settings.hooks.Stop) + $grp
        }
        # H1: scope the allow-rules to the exact subcommands the skill runs instead of a
        # blanket `toggle *` wildcard (which pre-authorized any future/unexpected subcommand).
        #
        # SEC-01: `request-on` is deliberately NOT allow-listed. The engine refuses to arm
        # without a standing *.request, but request-on is what CREATES that marker - so
        # pre-authorizing both made the gate satisfiable by whoever it was meant to stop:
        # two consecutive unattended Bash calls (`request-on` then `on --this-turn`) walked
        # injected instructions all the way to a real power-off with no prompt. Leaving
        # request-on off the list costs the legitimate flow exactly one approval, which the
        # user is present to give (they just clicked the button), and restores the gate's
        # two sides to different principals. Disarming stays friction-free on purpose.
        Grant-ShutdownAllowRules $settings $scriptFwd
        Save-Settings $settings
        # Legacy skills out (superseded by /shutdown-on-done)
        foreach ($s in @('close-pc-on-done','cancel-close-pc')) {
            $d = Join-Path $skillsDir $s
            if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        }
        # Default stateful power button (mirrors the .request marker; added once)
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $cfg.buttons) { $cfg | Add-Member buttons @() -Force }
            if (-not (@($cfg.buttons) | Where-Object { $_.text -eq '/shutdown-on-done on' })) {
                $cfg.buttons = @($cfg.buttons) + [pscustomobject]@{
                    label = 'Shutdown on done'; short = 'Shutdown'; icon = 'power'
                    desc = 'Shuts the PC down once this chat is COMPLETELY done with all its work (agent-judged, 60 s grace). Lit while a request is standing; click again to cancel.'
                    toggle = $true; confirm = $true
                    stateGlob = '%USERPROFILE%\.claude\shutdown-on-done\*.request'
                    text = '/shutdown-on-done on'; textOff = '/shutdown-on-done off'; submit = $true }
                Write-JsonAtomic $cfgPath ($cfg | ConvertTo-Json -Depth 100)
            }
        } catch {}
        Write-Host "  + Shutdown-on-done engine installed (completion-judged; power button added to the panel)." -ForegroundColor DarkGray
    }
}

# 7) Autostart
$wantAuto = $false
if ($Autostart) { $wantAuto = $true }
elseif (-not $NoAutostart -and -not $Update) {
    $ans = Read-Host "Start Claude Buttons automatically at logon? [Y/n]"
    $wantAuto = ($ans -ne 'n')
}
if ($wantAuto) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($startupLnk)
    $lnk.TargetPath = Join-Path $InstallDir 'Launch.vbs'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Description = 'Claude Buttons'
    $lnk.Save()
    Write-Host "  + Autostart shortcut created." -ForegroundColor DarkGray
}

# 8) Verify + launch. M4: the smoke test must actually gate - only launch and
# report success if it prints SMOKE-OK.
$smoke = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir $panelName) -SmokeTest 2>&1
Write-Host "  $smoke" -ForegroundColor DarkGray
if ("$smoke" -notmatch 'SMOKE-OK') {
    Write-Host ""
    Write-Host "Install verification FAILED - the panel did not load cleanly (no SMOKE-OK above)." -ForegroundColor Red
    Write-Host "Files are in place but the panel was NOT started. Check the output above and %LOCALAPPDATA%\claude-buttons.log." -ForegroundColor Red
    exit 1
}
Start-Process wscript.exe -ArgumentList "`"$(Join-Path $InstallDir 'Launch.vbs')`""

Write-Host ""
Write-Host "Done. Claude Buttons is running." -ForegroundColor Green
Write-Host "  - Switch to the Claude desktop app; the strip appears in its bottom bar."
Write-Host "  - Click the kebab (three dots) at the left of the strip to pin buttons."
Write-Host "  - Restart the Claude app once so the /pin and /unpin skills load."
Write-Host "  - Uninstall anytime:  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
