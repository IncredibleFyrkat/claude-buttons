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
- **Icon buttons**: give a button an icon instead of text (`"icon": "mic"`) — a small round button the same size as the app's own mic button. Uses Windows' built-in Fluent icon font (Lucide-style line icons, no downloads).
- **Toggle (on/off) buttons** (`"toggle": true`): the button stays lit while active, like the app's mic — optionally sending different text on activate/deactivate (`textOn`/`textOff`).
- **Long standard prompts**: a button's text can be a full multi-paragraph prompt. Long/multiline text is pasted atomically via the clipboard (instant, your previous clipboard is restored). Write and edit prompts in a multiline editor: *Other: type your own...* when pinning, or right-click → *Edit text/prompt...* on any button.
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

### Optional: shutdown-on-done

The installer offers — **off by default, always asks first, requires Node.js** — the
*shutdown-on-done* engine (contributed by Rasmus): shut the PC down when a chat is COMPLETELY
done with its work. The agent judges "done" (background tasks, subagents and all) and arms the
real shutdown only as the final action of its final wrap-up — so the PC never powers off
mid-task. 60-second grace on every shutdown; `shutdown -a` aborts.

Installing it adds a `/shutdown-on-done on|off|status` command, a completion-judged `Stop` hook,
two permission allow-rules (so the agent can arm the shutdown while you sleep), and a stateful
**power toggle button** in the panel: lit exactly while a standing shutdown request exists
(mirrored from `%USERPROFILE%\.claude\shutdown-on-done\*.request` via `stateGlob`), two-click
confirm to arm, one click to cancel. It is never installed silently.

## Usage

- Switch to the Claude app — the strip appears in the bottom bar.
- **Right-click the dot-grip** → *Pin new button* → pick a command (choose scope with the checkboxes at the top).
- **Left-click** a button to type its command; global buttons also press Enter, per-chat buttons let you review first.
- **Hover a button** for a themed tooltip showing its command, scope and behavior — add your own explanation with a `"desc"` field in `buttons.json`.
- **Right-click a button** → rename, edit the text/prompt, set an icon, switch on/off (toggle) mode, move, or remove.
- **Position** and **Language** live in the same grip menu. *Position → Free placement* lets you drop the strip anywhere with the mouse (it stays anchored to the window); *Auto* re-docks it to the bottom bar.

### Icons

Right-click a button → *Set icon...* and type a name. Available names:

`mic, power, play, pause, stop, refresh, check, x, trash, settings, search, save, code, bug, star, pin, send, bell, clock, sun, moon, zap, home, folder, camera, edit, plus, download, upload, user, mail, globe, lock, heart, flag, calendar, phone, broom, terminal, shield, copy, link`

You can also give any 4-digit hex codepoint from the Segoe Fluent Icons font. Icon buttons show
their label and command in the tooltip.

### Toggle buttons

Right-click a button → *On/off (toggle) mode*. The button now lights up while active. In
`buttons.json` you can give it different texts for each direction:

```json
{ "label": "Focus", "icon": "zap", "text": "enter focus mode", "textOff": "exit focus mode",
  "toggle": true, "submit": true }
```

`textOn` (defaults to `text`) is typed when switching on, `textOff` when switching off (omit it
to make switching off silent).

**Truthful state via the filesystem** (`stateGlob`): instead of remembering its own on/off state,
a toggle button can mirror reality — it is lit if and only if a file matching a glob exists:

```json
{ "label": "Shutdown on done", "icon": "power", "toggle": true, "confirm": true,
  "stateGlob": "%USERPROFILE%\\.claude\\shutdown-on-done\\*.request",
  "text": "arm shutdown-on-done", "textOff": "cancel shutdown-on-done", "submit": true }
```

The panel polls the glob about once a second, so if an agent, hook or another surface changes the
state behind your back, the button follows within a second. Clicking still flips optimistically
for instant feedback and is corrected if reality disagrees.

**Confirm is asymmetric for toggles**: `confirm: true` gates switching **on** (two clicks) but
never switching **off** — disarming a dangerous state should always be one click.

## What you're running (honesty section)

This is unsigned PowerShell + a small `.vbs` launcher. That's normal for a hobby tool, but you
should know what it does before trusting it:

- `claude-buttons.ps1` — the panel. It reads the Claude window's position and accessibility tree, draws a strip, and sends keystrokes to the Claude window when you click a button. It does **not** make network connections.
- `Launch.vbs` — starts the panel with no console window (`powershell.exe -ExecutionPolicy Bypass` affects **only that one launch**, not your system policy).
- The `UserPromptSubmit` hook writes the current chat's session id to `~/.claude/active-session.json` so the panel knows which chat is on screen. Nothing else.

Read the source — it's a single, commented file. If Windows SmartScreen warns about the downloaded
scripts, that's the standard "unknown publisher" notice for unsigned scripts; `git clone` avoids it.

## Config reference (`buttons.json`)

The file the panel reads (created from `buttons.default.json` on first install, in
`%LOCALAPPDATA%\Programs\ClaudeButtons`). Top-level fields:

| Field | Default | Meaning |
|---|---|---|
| `schemaVersion` | `1` | Config format version. |
| `buttons` | `[]` | The button list (see below). |
| `targetTitle` | `"Claude"` | Substring the target window's title must contain. |
| `targetProcess` | `"claude"` | Process name that must own the window. |
| `uiaPaneMatch` | `" pane$"` | Regex; every Group whose accessibility name matches is treated as a chat pane (matches `Primary pane`, `Secondary pane`…). |
| `uiaPaneName` | `"Primary pane"` | Legacy exact pane name (fallback). |
| `uiaSidebarName` | `"Sidebar"` | Sidebar name, used to derive the chat area if no pane matches. |
| `zoneTop` / `zoneBottom` | `45` / `55` | Logical-px zones where the chat title tab / bottom button row live. |
| `fallbackRow` | `33` | Strip center above the window bottom when the button row can't be measured. |
| `stripGap` | `10` | Gap (px) between the app's own buttons and the strip. |
| `reservedW` | `380` | Width reserved for the app's own bar elements (compact-mode threshold). |
| `relX` | `0.0` | Horizontal position within the pane (0–1). |
| `lang` | `"en"` | UI language: `en` or `da`. |

Per-button fields:

| Field | Meaning |
|---|---|
| `label` | Display text. |
| `short` | Short label shown in compact mode (~8 chars). |
| `text` | Text typed into the chat on click (may be a long multi-line prompt). |
| `submit` | `true` = press Enter after typing (**global buttons only**; per-chat never auto-send). |
| `confirm` | `true` = two-click "Confirm?" before firing (gates ON only for toggles). |
| `icon` | Icon name (see list above) or a raw 4-hex codepoint; renders a round icon button. |
| `toggle` | `true` = on/off button (lit while on). |
| `textOn` / `textOff` | Text sent when switching on / off (`textOn` defaults to `text`; omit `textOff` for silent off). |
| `stateGlob` | Glob (env vars expanded); the toggle is lit iff a matching file exists — truthful state from the filesystem. |
| `chat` | Session id this button is scoped to (per-chat). |
| `chatTitle` | The displayed chat title this button binds to (preferred per-chat match). |
| `chatLabel` | Human description shown in the tooltip for a per-chat button. |
| `desc` | Extra explanation shown at the top of the hover tooltip. |

## Troubleshooting

- **Strip sits slightly off, or per-chat/split-view buttons misbehave, after a Claude app update** → the app's UI names/layout changed. Check `%LOCALAPPDATA%\claude-buttons.log`, then adjust the app-dependent values in `buttons.json` (`uiaPaneMatch`, `uiaPaneName`, `uiaSidebarName`, `zoneTop`, `zoneBottom`, `fallbackRow`, `stripGap`, `reservedW`). Asking Claude to "probe the app's UIA tree and update these" is the quickest fix.
- **App not in English?** Accessibility names like `Primary pane`/`Sidebar` may be localized — set `uiaPaneMatch` (and `uiaSidebarName`) to the localized names in `buttons.json`.
- **`/pin` says unknown command, or does nothing** → restart the Claude app once so the skill loads; the skill writes to the file named in `%USERPROFILE%\.claude\claude-buttons-path.txt`.
- **Nothing appears** → the strip only shows when the Claude window is the foreground window.
- **Keyboard / screen-reader users:** the strip is a mouse-driven overlay that never takes focus. Use the `/pin` and `/unpin` skills (and hand-editing `buttons.json`) as the keyboard/AT path.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Removes the skills, the hooks (only the ones this tool added), and the autostart shortcut, and
asks before deleting the program folder and your `buttons.json`.

## License

MIT — see [LICENSE](LICENSE).
