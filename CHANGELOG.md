# Changelog

## 1.3.3 — 2026-07-17

- **Fix: strips reloaded on every pane while dragging a chat in/around.** Pane geometry and
  pane content are now tracked separately — moving or resizing panes only repositions the
  strips; buttons are rebuilt only when a pane is added/removed or a pane's chat changes. No
  more flicker across all panes during a drag.

## 1.3.2 — 2026-07-17

- **Fix: `/pin` wrote to the wrong file.** The panel rewrote the skills' path marker on every
  start — including `-SmokeTest` runs from a dev/repo folder — so a live install's marker could
  point at a non-existent buttons.json and pins silently went nowhere. The marker is now written
  only by the real running instance.
- **Visual icon picker**: *Set icon...* now shows a grid of the actual glyphs to click, instead
  of a text field of names.
- Fix: `Move left/right` used `$host`, clobbering PowerShell's automatic `$Host` variable.

## 1.3.1 — 2026-07-17

- **Fix multi-pane detection**: the app names split panes "Primary pane", "Secondary pane",
  "Tertiary pane"… — the panel only matched "Primary pane", so extra panes got no strip. Now
  matches every Group whose name ends with "pane" (configurable via `uiaPaneMatch`).

## 1.3.0 — 2026-07-17

- **Multi-pane support (side-by-side / grid view)**: the panel now detects every chat pane and
  shows a strip under each one. Global buttons appear in all panes simultaneously; per-chat
  buttons appear exactly under their own pane (matched by the pane's chat title). Toggle state,
  ordering and removal stay in sync across all strips; compact mode keys off the narrowest pane.

## 1.2.0 — 2026-07-17

- **Shutdown-on-done engine** (contributed by Rasmus) replaces the v1 Stop hook: the agent
  judges true completion (background tasks included) and arms the shutdown only as the final
  action of its final wrap-up. `/shutdown-on-done on|off|status`, machine-wide switch,
  `.request` markers for UI state, dry-run mode, 60 s grace. Installer migrates v1 installs.
- **Custom hover tooltips**: themed tip box (the built-in WinForms ToolTip is unreliable on a
  no-activate window) showing command, scope, behavior and an optional per-button `desc`.
- **Free placement**: *Position → Free placement* moves the strip with the mouse; one click
  drops it anywhere (anchored to the Claude window, persisted). *Auto* re-docks it.
- Default shutdown power button ships with the engine (stateGlob-backed, confirm-to-arm).

## 1.1.0 — 2026-07-17

- **Icon buttons** (`"icon": "mic"`): mic-sized round buttons using the built-in Segoe Fluent
  Icons font (Lucide-style names + raw hex codepoints).
- **Toggle buttons** (`"toggle": true`): mic-style on/off with `textOn`/`textOff`;
  filesystem-backed truth via `"stateGlob"`; confirm gates arming only (disarm is one click).
- **Long standard prompts**: multiline editor (*Other: type your own...* / *Edit text/prompt...*),
  atomic clipboard paste for text >80 chars or multiline, clipboard restored afterwards.
- New glyphs: broom, terminal, shield, copy, link.

## 1.0.0 — 2026-07-17

- Initial release: dockable button strip for the Claude desktop app (Windows), global and
  per-chat buttons, self-aligning via UI Automation, instant pin menu, two-click confirm,
  EN/DA UI, safe installer/uninstaller with opt-in shutdown feature.
