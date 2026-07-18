# Changelog

## 1.7.1 — 2026-07-18

Follow-up fixes from [@RasmusKD](https://github.com/RasmusKD) (PR #3). **Two of these are
regressions in 1.7.0 as shipped** — upgrade if you installed 1.7.0.

- **Strips could stay hidden forever after a Claude modal closed.** `composerLost` was part of
  the `$show` gate, and that gate's early `return` fires *before* `Update-UiaInfo` — the only
  place that clears the flag. So the first modal/menu that hid the strips kept them hidden until
  the panel was restarted. The hide now runs after the UIA read, mirrors stay alive, and the
  re-check pins to 400ms while hidden. A regression test now guards both source invariants.
- **The icon picker crashed on click.** The 1.7.0 fuzzy-search rewrite wrapped the grid builder
  in `.GetNewClosure()`, which rebinds `$script:` to the closure's own module scope, so
  `$script:iconDlg` / `$script:iconPick` were `$null` in the click handler. Rebuilt without
  closures, on the idiom the rest of the file uses.
- **Send could target the wrong pane.** The send path re-derived its composer by nearest-rect
  score, which in a tight grid can pick a neighbouring pane. Strips now focus the composer they
  are bound to; the geometric search remains a logged fallback for a dead element.
- **Clipboard privacy.** Button prompts were enrolled into Windows clipboard history (Win+V) and
  Cloud Clipboard sync — and restoring the previous clipboard does *not* remove the history
  entry. Payloads now carry `ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory=0` and `CanUploadToCloudClipboard=0`, and the restore is skipped
  (and logged) if another app wrote to the clipboard mid-send.
- **Shift-click inserts without sending**, so a prompt can be extended before it goes. Toggles
  deliberately do not flip on a Shift-click (the command is parked, not executed).
- **A large pasted prompt no longer makes the strip vanish.** The composer's fixed 220px height
  ceiling stopped matching once the box grew; it now scales to 60% of the window height.
- **The strip tracks a growing composer live.** The dock point is stored relative to the composer
  so each tick can refresh geometry from one cached rectangle instead of redoing the tree walk.
- **`uiaComposerName`** is configurable in `buttons.json`, so an aria-label rename on Claude's
  side is self-healable without a code change.
- Toggles now flip *after* delivery rather than before, so a failed paste plus an aborted
  fallback can no longer leave a button lit with nothing sent.

## 1.7.0 — 2026-07-18

Incorporates the community rework from [@RasmusKD](https://github.com/RasmusKD) (PR #2) — thank you.
All four tiers were taken; the 1.6.x hardening (clipboard-restore, mutex handling, config
self-heal, accessibility names/roles) was preserved and the rework builds on top of it.

- **Composer-anchored docking (Tier 3).** The strip now docks to the chat's *composer* group
  in the Chromium accessibility tree rather than measuring the pane and scanning the button row.
  This naturally follows split/stacked panes and keeps the strip under the chat when an in-chat
  panel is open — the case 1.6.1 clamped for — without the width-heuristic.
- **Transparent layered strips (Tier 3).** Each strip is a per-pixel-alpha layered window
  (`UpdateLayeredWindow`) that sits directly on the bottom bar with no visible backing rectangle,
  so the buttons read as native chrome. The dot-grip is replaced by a **⋮ kebab menu**.
- **Reliable send (Tier 2).** Composer detection makes typing target the real prompt box;
  the send path was reworked to survive the app's focus model.
- **WinEvent-driven refresh (Tier 2).** Foreground/location changes drive redraws via
  WinEvent hooks instead of polling alone, cutting latency and idle wakeups.
- **Safe-gains bundle (Tier 1).** Expanded icon set (~134 Segoe Fluent glyphs), plus the
  smaller robustness fixes from the fork.
- **Engine + installer hardening carried forward.** Arm-requires-intent gate (a bare
  `toggle on` is refused without a standing request or fresh machine switch), per-chat disarm,
  absolute `shutdown.exe`, 12h machine-switch stale guard, smoke-test-gated install.
- **Tests:** 16 engine + 16 panel tests (adds the arm-gate, per-chat, unknown-verb, and
  Escape-SendKeys encoding cases); CI runs the suite + PSScriptAnalyzer on `windows-latest`.

## 1.6.1 — 2026-07-18

- **Strip no longer drifts when an in-chat panel is open.** Background tasks / preview panels
  live *inside* the same "… pane" accessibility group as the chat, so the pane's width spanned
  chat + panel and the strip was placed midway between them. `Measure-Pane` now clamps each
  pane's effective width to its "Chat messages" column (when one is present and a panel clearly
  occupies the right side), so the strip docks under the chat itself. The bottom button-row
  scan uses the clamped width too, keeping the vertical anchor on the chat's own buttons.
  The accessibility name is configurable via `uiaChatName` in `buttons.json` (default
  `"Chat messages"`).

## 1.6.0 — 2026-07-17

Final review band — accessibility + an actual test suite:

- **Accessibility**: owner-drawn buttons now expose an accessible role and name (label + scope +
  on/off state) and the grip announces as "Claude Buttons menu" (WCAG 4.1.2). Per-chat buttons get
  a brighter, thicker border and toggle-on buttons show a filled dot, so scope/state aren't
  color-only (1.4.11, 1.4.1). Keyboard-only limits and the native-size trade-off are documented.
- **Tests**: a real suite under `tests/` — 12 engine tests (`node --test`, exercising the whole
  shutdown-on-done state machine against a throwaway USERPROFILE, nothing shuts down), 10 panel
  config-lifecycle tests through `-SmokeTest`, and static parse checks. `tests\run-all.ps1` runs
  everything; a GitHub Actions workflow runs it on `windows-latest`.

## 1.5.1 — 2026-07-17

Fixes for regressions the adversarial verification panel found in the 1.4.3–1.5.0 changes:

- **Clipboard clobber fixed.** The long/multiline paste checked the foreground *after* it had
  already overwritten the clipboard, so an aborted paste discarded the user's clipboard. It now
  checks foreground before touching the clipboard and restores in a `finally`.
- **Toggle desync window closed.** The on/off flip now happens immediately before each actual
  send (after the per-path foreground re-check), so no abort can leave a non-`stateGlob` toggle
  showing the wrong state.
- **Abandoned-mutex handled.** `AbandonedMutexException` (a prior lock holder died) is now treated
  as "acquired" so the lock is released, instead of being leaked.
- **Config self-heal is time-bounded.** A transient startup lock still self-heals, but a
  permanently corrupt `buttons.json` no longer makes every tick re-read the file forever.
- **Machine-wide shutdown wake path** now emits a forward-slash script path so it matches the
  scoped allow-rules (was a latent slash mismatch).

## 1.5.0 — 2026-07-17

Technical-debt band from the 8-agent review — mostly performance:

- **The expensive UI Automation pass is skipped entirely while the panel is hidden.** The window
  find + foreground gate now runs before the UIA walk, so when Claude is backgrounded the panel
  does no accessibility-tree work at all (previously it kept polling ~every 1.5–5 s, burning
  battery for no visible benefit).
- **UIA reads are cached.** Pane/button geometry and names are fetched in one batched cross-process
  request (`CacheRequest`) instead of a round-trip per property.
- **A transient config-lock at startup now self-heals**: if `buttons.json` was momentarily locked
  and the panel fell back to defaults, it now reliably reloads the real file on the next tick.
- **Icon-picker resource leak fixed**: one shared tooltip instead of ~40, and the large icon font
  is disposed.
- Removed dead code (leftover scope-toggle localization strings).

Deliberately **not** done (documented as accepted debt): the full decomposition of the timer tick
and the ~40 script-scope globals into state objects, and per-button GUID ids. On a working
single-file tool these are high-churn/low-user-value refactors whose regression risk outweighs the
maintainability gain — the targeted fixes above capture the real wins.

## 1.4.4 — 2026-07-17

Second hardening band from the 8-agent review ("should fix before next release"):

- **Toggle no longer desyncs on an aborted send.** The on/off flip now happens *after* the
  foreground check, so a click that lands while Claude isn't foreground no longer leaves a
  non-`stateGlob` toggle stuck in the wrong state.
- **Clipboard fully preserved for long/multiline pastes.** The prior clipboard is now snapshotted
  across all formats (images, files, rich data) and restored — not just plain text.
- **Foreground re-checked immediately before each send/paste** (tighter TOCTOU window).
- **Config mutex only released when actually acquired** (a busy lock no longer risks releasing a
  mutex the panel doesn't own).
- **Docs:** README gains a full `buttons.json` config reference (top-level + per-button fields),
  the complete 42-icon list, `uiaPaneMatch` added to troubleshooting, and a keyboard/AT note. The
  Danish README is rewritten to match current behavior (it still described the superseded v1
  shutdown and omitted icons/toggles/multi-pane).

## 1.4.3 — 2026-07-17

Hardening from an 8-agent code review (the "must fix before wider distribution" set):

- **Corrupt buttons.json no longer kills the panel.** An unreadable/locked config now falls
  back to the shipped defaults (then an empty config), logs it, and keeps running instead of
  throwing — previously the hidden-launched panel just never appeared. The bad file is left
  untouched on disk.
- **`install.ps1 -Update` now refreshes the shutdown engine + skill** if the feature is already
  installed (it was silently left stale before).
- **settings.json is written without a BOM** (plain UTF-8) for maximum JSON-reader compatibility.
- **Shutdown allow-rules are scoped to the exact subcommands** the skill runs (request-on,
  request-off, on --this-turn, off, status) instead of a blanket `toggle *` wildcard.
- **Stale machine-wide switch is ignored.** The shutdown engine now ignores (and clears) a
  `MACHINE-ARMED` file older than 12 h, so a forgotten switch can't power off an unrelated
  session later. Shutdown fires and machine-wake events are logged to
  `~/.claude/shutdown-on-done/shutdown-on-done.log`; a leading BOM on the hook payload is stripped.
- **The install smoke test now gates**: install aborts (without launching) if the panel doesn't
  print `SMOKE-OK`.

## 1.4.2 — 2026-07-17

- **Dark scrollbars.** The multiline prompt editor and the icon grid showed a white classic
  scrollbar; they now use the dark Explorer scrollbar theme (`SetWindowTheme DarkMode_Explorer`).

## 1.4.1 — 2026-07-17

- **Dark dialogs.** The "type your own command" and rename flows used the plain white Windows
  `InputBox`. Replaced with a dark themed single-line dialog, and gave all dialogs (icon picker,
  prompt editor, input) a dark title bar via DWM. No more white boxes.

## 1.4.0 — 2026-07-17

- **Reworked the pin menu.** *Pin new button* now has two submenus — **Only this chat** and
  **Global (all chats)** — each holding the full command list. Pick scope and command in one
  motion; no more scope toggle that closed the menu and forced you to reopen it.
- **Fix: the panel vanished while pinning.** The old "keep menu open" trick reopened the menu
  as an unowned popup, which stole foreground from Claude and made the panel hide until you
  clicked back into the chat. That trick is gone, and the panel now stays visible whenever its
  own menu or a dialog is open. Pins now show up immediately.

## 1.3.4 — 2026-07-17

- **Fix: the icon picker did nothing (and could freeze the menu).** The grid's click handler
  used `.GetNewClosure()`, which captured `$this` as `$null`, so clicking any icon cleared the
  icon instead of setting it. The picker (and the text/prompt dialog) now also activate and come
  to the front, so they can't open behind another window and block the panel modally out of sight.

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
