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
    - The shutdown feature: /close-pc-on-done + /cancel-close-pc skills and a Stop hook
      that can run `shutdown /s /t 60`. This is OFF by default and always asks first.
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
function Save-Settings($obj) {
    if (Test-Path $settingsPath) { Copy-Item $settingsPath "$settingsPath.bak" -Force }
    Write-Utf8Bom $settingsPath ($obj | ConvertTo-Json -Depth 20)
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
$shutdownHookCmd = "`$i=[Console]::In.ReadToEnd()|ConvertFrom-Json; `$f = Join-Path `$env:USERPROFILE '.claude\close-pc-on-done.flag'; if (Test-Path `$f) { `$sid=''; try { `$sid=(Get-Content `$f -Raw -ErrorAction Stop).Trim() } catch {}; if (`$sid -and `$sid -eq `$i.session_id) { shutdown /s /t 60; if (`$LASTEXITCODE -eq 0) { Remove-Item `$f -Force } } }"

# =================== UNINSTALL ===================
if ($Uninstall) {
    Write-Host "Uninstalling Claude Buttons..." -ForegroundColor Cyan
    Stop-Panel
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }
    foreach ($s in @('pin','unpin','close-pc-on-done','cancel-close-pc')) {
        $d = Join-Path $skillsDir $s
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Remove-Item (Join-Path $claudeDir 'claude-buttons-path.txt') -Force -ErrorAction SilentlyContinue
    if (Test-Path $settingsPath) {
        $settings = Get-Settings
        Remove-Hook $settings 'UserPromptSubmit' 'active-session.json'
        Remove-Hook $settings 'Stop' 'close-pc-on-done.flag'
        Save-Settings $settings
    }
    $keep = Read-Host "Remove the program folder and your buttons.json too? ($InstallDir) [y/N]"
    if ($keep -eq 'y') { if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force } }
    Write-Host "Done. (A settings.json.bak backup was left in ~/.claude if changes were made.)" -ForegroundColor Green
    return
}

# =================== INSTALL / UPDATE ===================
Write-Host "Installing Claude Buttons to $InstallDir" -ForegroundColor Cyan
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
        if (-not $cfg.PSObject.Properties['schemaVersion']) { $cfg | Add-Member schemaVersion 1 -Force; Write-Utf8Bom $cfgPath ($cfg | ConvertTo-Json -Depth 6) }
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
Write-Utf8Bom (Join-Path $claudeDir 'claude-buttons-path.txt') $cfgPath

# 5) Core hook (UserPromptSubmit) - merged safely
$settings = Get-Settings
if (-not (Hook-Exists $settings 'UserPromptSubmit' 'active-session.json')) {
    Ensure-HookArray $settings 'UserPromptSubmit'
    $grp = [pscustomobject]@{ hooks = @([pscustomobject]@{ type='command'; shell='powershell'; async=$true; timeout=10; command=$activeHookCmd }) }
    $settings.hooks.UserPromptSubmit = @($settings.hooks.UserPromptSubmit) + $grp
    Save-Settings $settings
    Write-Host "  + Added UserPromptSubmit hook (tracks which chat is active - no side effects)." -ForegroundColor DarkGray
}

# 6) OPTIONAL shutdown feature - opt-in only, loudly disclosed
$wantShutdown = $Shutdown
if (-not $Shutdown -and -not $Update) {
    Write-Host ""
    Write-Host "Optional feature: 'Shut down PC when done'." -ForegroundColor Yellow
    Write-Host "  This installs two skills and a Stop hook that can run 'shutdown /s /t 60'"
    Write-Host "  (60-second, cancellable) when a session you explicitly armed finishes."
    $ans = Read-Host "  Install the shutdown feature? [y/N]"
    $wantShutdown = ($ans -eq 'y')
}
if ($wantShutdown) {
    foreach ($s in @('close-pc-on-done','cancel-close-pc')) {
        $dst = Join-Path $skillsDir $s
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $src "skills-optional\$s\SKILL.md") (Join-Path $dst 'SKILL.md') -Force
    }
    $settings = Get-Settings
    if (-not (Hook-Exists $settings 'Stop' 'close-pc-on-done.flag')) {
        Ensure-HookArray $settings 'Stop'
        $grp = [pscustomobject]@{ hooks = @([pscustomobject]@{ type='command'; shell='powershell'; timeout=15; command=$shutdownHookCmd }) }
        $settings.hooks.Stop = @($settings.hooks.Stop) + $grp
        Save-Settings $settings
    }
    Write-Host "  + Shutdown feature installed (session-bound, cancellable)." -ForegroundColor DarkGray
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

# 8) Verify + launch
$smoke = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir $panelName) -SmokeTest 2>&1
Write-Host "  $smoke" -ForegroundColor DarkGray
Start-Process wscript.exe -ArgumentList "`"$(Join-Path $InstallDir 'Launch.vbs')`""

Write-Host ""
Write-Host "Done. Claude Buttons is running." -ForegroundColor Green
Write-Host "  - Switch to the Claude desktop app; the strip appears in its bottom bar."
Write-Host "  - Right-click the dot-grip to pin buttons."
Write-Host "  - Restart the Claude app once so the /pin and /unpin skills load."
Write-Host "  - Uninstall anytime:  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
