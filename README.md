# Claude Buttons

A slim, native-looking button strip that docks onto the **Claude desktop app**'s bottom bar
(Windows) and types slash-commands or text into the chat when you click. Pin your most-used
commands as one-click buttons — globally or scoped to a specific chat.

*(Dansk vejledning: se [README.da.md](README.da.md).)*

![The Claude Buttons strip docked in the Claude desktop app's bottom bar, showing Code review, Simplify and Continue pills next to the app's own controls](docs/screenshot.png)

## Why

The Claude desktop app has no way to pin a slash-command as a clickable button. This tool adds
that: a floating strip, styled to match the app's dark theme, that follows the Claude window and
appears only when it's in the foreground.

## Features

- **Pin any command** as a pill button — instantly, from a right-click menu on the strip (no round-trip through Claude), or via the `/pin` skill.
- **Global or per-chat** buttons. Per-chat buttons appear only when that chat is on screen (detected from the app's own accessibility tree) and never auto-send — they insert the text so you review it first.
- **Self-aligning**: reads the app's own bottom-row buttons via UI Automation and sits on exactly the same line, next to them. Follows resize, fullscreen, and DPI.
- **Two-click confirm** for destructive buttons (`"confirm": true`).
- **English / Danish** UI, switchable in the menu.
- **Resilient**: everything the app exposes (accessibility names, zones) is configurable in `buttons.json`, so an app update degrades gracefully instead of breaking.

## Requirements

- Windows 10 or 11
- The Claude desktop app
- Built-in **Windows PowerShell 5.1** (ships with Windows; do not run under PowerShell 7)
- Claude Code skills/hooks support (for the optional `/pin` and `/unpin` commands)

## Install

```powershell
# 1. Download this repo (git clone avoids the "downloaded file" SmartScreen warning):
git clone https://github.com/IncredibleFyrkat/claude-buttons.git
cd claude-buttons

# 2. Run the installer:
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Or double-click **`install.cmd`**.

The installer:
- copies the panel to `%LOCALAPPDATA%\Programs\ClaudeButtons` (kept out of any cloud-synced folder),
- installs the `/pin` and `/unpin` skills into `~/.claude/skills`,
- merges **one** hook (`UserPromptSubmit`) into `~/.claude/settings.json` — backed up first, and only if not already present,
- optionally sets up autostart at logon.

**Restart the Claude app once** after installing so the `/pin` and `/unpin` skills load.

### Optional: the shutdown feature

The installer offers — **off by default, always asks first** — a "Shut down PC when done" feature:
two extra skills and a `Stop` hook that can run `shutdown /s /t 60` (a 60-second, cancellable
shutdown) when a session *you explicitly armed* finishes. Decline it if you don't want it; it is
never installed silently.

## Usage

- Switch to the Claude app — the strip appears in the bottom bar.
- **Right-click the dot-grip** → *Pin new button* → pick a command (choose scope with the checkboxes at the top).
- **Left-click** a button to type its command; global buttons also press Enter, per-chat buttons let you review first.
- **Right-click a button** → rename, move, or remove.
- **Position** and **Language** live in the same grip menu.

## What you're running (honesty section)

This is unsigned PowerShell + a small `.vbs` launcher. That's normal for a hobby tool, but you
should know what it does before trusting it:

- `claude-buttons.ps1` — the panel. It reads the Claude window's position and accessibility tree, draws a strip, and sends keystrokes to the Claude window when you click a button. It does **not** make network connections.
- `Launch.vbs` — starts the panel with no console window (`powershell.exe -ExecutionPolicy Bypass` affects **only that one launch**, not your system policy).
- The `UserPromptSubmit` hook writes the current chat's session id to `~/.claude/active-session.json` so the panel knows which chat is on screen. Nothing else.

Read the source — it's a single, commented file. If Windows SmartScreen warns about the downloaded
scripts, that's the standard "unknown publisher" notice for unsigned scripts; `git clone` avoids it.

## Troubleshooting

- **Strip sits slightly off, or per-chat buttons misbehave, after a Claude app update** → the app's UI names/layout changed. Check `%LOCALAPPDATA%\claude-buttons.log`, then adjust the app-dependent values in `buttons.json` (`uiaPaneName`, `uiaSidebarName`, `zoneTop`, `zoneBottom`, `fallbackRow`, `stripGap`, `reservedW`). Asking Claude to "probe the app's UIA tree and update these" is the quickest fix.
- **App not in English?** Accessibility names like `Primary pane`/`Sidebar` may be localized — set `uiaPaneName`/`uiaSidebarName` to the localized names in `buttons.json`.
- **`/pin` says unknown command** → restart the Claude app so the skill loads.
- **Nothing appears** → the strip only shows when the Claude window is the foreground window.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Removes the skills, the hooks (only the ones this tool added), and the autostart shortcut, and
asks before deleting the program folder and your `buttons.json`.

## License

MIT — see [LICENSE](LICENSE).
