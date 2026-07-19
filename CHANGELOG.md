# Changelog

## 1.10.0 — 2026-07-19

**Side bars, groups, and per-kind colours.** Contributed by
[@RasmusKD](https://github.com/RasmusKD) in [#5](https://github.com/IncredibleFyrkat/claude-buttons/pull/5),
with fixes on top before merging.

- **Vertical side bars.** Buttons can move to a strip in the left or right pane margin, so a
  long row does not have to stay a long row. The kebab can move there too. Buttons reorder
  within a bar with move up/down.
- **Groups.** Several buttons collapse into one face on the bar; hovering opens a flyout with
  the members. A group carries its own icon and label. "Move to group" is a submenu of the
  groups that exist rather than a box you type a name into — a group shows as a glyph, so its
  name was not written anywhere on screen and a typo silently created a second group.
- **Per-kind colours.** Prompts, slash commands, groups and toggles can each take a colour.
  Kind is derived rather than stored, so a newly pinned slash command picks up the command
  colour automatically. The toggle ON state is deliberately not colourable: white on its fill
  is 5.11:1, and every palette entry lands at 1.97–2.44:1, so there is no choice that is not a
  contrast regression.
- **Reordering moves blocks, not entries.** Move left/right used to swap two adjacent array
  entries, which dragged one member out of a group and left the rest behind, or landed a plain
  button *inside* a group. A group is now one block sitting at its first member.
- **Icons are optically centred.** `DrawString` centres the font's metrics box — advance width
  plus full line height — not the ink. The download glyph sat exactly 1px high and the kebab
  dots a row low. Ink bounds are now measured once per glyph and cached.
- Group buttons could not be edited at all: the flyout covered the button, and "Set icon" and
  "Rename" wrote through a path that walks the buttons array, which a synthetic group face is
  never in. Both reported success and saved nothing.

Fixed before merging, found by review:

- **Buttons on a side bar could send to the wrong chat**, and usually did nothing at all. The
  pane resolver knew only the row strip and its mirrors, so a side-bar click fell through to a
  geometric guess whose own comment warns it "can select the neighbouring pane's composer".
  The guess is now refused from a side strip — the send is abandoned and says so.
- **`Update-Config` could destroy every pinned button.** Its guard rejected only `$null`, so a
  transform returning anything else wrote that over `buttons.json` — after which the panel
  falls back to defaults, so it reads as a spontaneous reset rather than as a failure.
- **The colour picker showed no colours.** Every swatch rendered grey, so you picked blind.
- **Hover and the toggle ON state were invisible inside the flyout** (1.04:1 and 2.69:1). Fixed
  with a state ring rather than a brighter fill — a fill bright enough to clear 3:1 against
  that surface would have dragged the icon on top of it below 4.5:1.
- **Dissolving a group** discarded its icon and label permanently, with no confirmation, from a
  menu item sitting next to "Remove this button". It confirms now.
- **Group names are case-insensitive, deliberately** — unlike button labels, which are
  case-sensitive because a label+text *is* the prompt that gets sent. A group name is a JSON
  key, and PowerShell's JSON reader throws on keys differing only in case, so a case-sensitive
  group name would let the panel write a config it could never read back.

**Config keys added:** `bar` and `group` on a button, plus `groups`, `colors` and `kebabBar` at
the top level. A config written by this version still loads and round-trips through 1.7.3
without losing them.

## 1.9.1 — 2026-07-19

**1.8.0 and 1.8.1 both shipped a panel that refused to send any formatted button. This is the
fix, and it is based on measurement rather than on a third guess about why.**

The composer **renders markdown**, and the accessibility layer exposes the rendered result, not
the source. Pasting a 12,752-character button and reading the box back gave 12,259 characters
that diverged at character 62:

```
payload : ...AI-agentpanel ```text Du skal gennemføre...
composer: ...AI-agentpanel Du skal gennemføre...
```

A fenced code block loses its backticks *and* its language word; bold loses its asterisks. So
the two strings differ in their characters, and no amount of whitespace normalisation can
reconcile them — which is exactly what 1.8.0 (exact equality) and 1.8.1 (collapsed whitespace)
each tried. Every button containing markdown was refused, every time.

Verification now compares **words and size** instead of characters:

- **Coverage** — the payload's words must appear in the read-back, in order. Rendering deletes a
  few (fence languages) but never invents or reorders any, so a small shortfall is allowed:
  three words, or 2%, whichever is larger, and never more than a quarter of the payload. (At a
  half, a two-word button tolerated one substituted word: "send nu" read back as "send bad" was
  confirmed and would have been submitted.)
- **Size** — the read-back must not be larger than baseline+payload by more than a rounding
  margin. Rendering only ever *deletes*, so any growth is content nobody pasted. Letters/digits
  and everything else (punctuation, symbols, emoji, whitespace) are bounded **separately**: with
  a single alphanumeric bound, a clipboard of pure punctuation was unbounded and rode in at any
  length.

Both must hold. Coverage alone is satisfied by "stale clipboard, then our text", because an
in-order walk skips the prefix; the size ceiling is what catches that.

Fenced code blocks are stripped from the button's text before any of this, because the renderer
consumes the whole ```` ```lang ```` line. Counting the language as a payload word charged one
missing word per fence, so a button with four or more fenced blocks was refused — the same
false refusal as 1.8.0, narrowed rather than removed.

Measured against the real 12,752-character paste: genuine paste confirmed; stale clipboard
instead, before, or after the payload all refused; half the payload refused; eleven stray
characters refused; ten substituted words refused.

**Known limits, stated plainly.** This is a similarity check, not a content signature. A
substitution that swaps words while preserving the total length can stay inside the coverage
allowance, and **the allowance is much larger on short buttons than on long ones**. It is
`min(max(3, 2%·n), floor(n/4))` words out of `n`, which works out as:

| button length | words that may differ undetected |
|---|---|
| 2–3 words | 0 |
| 4–11 words | 1 — i.e. **up to 25%** |
| 12–149 words | 3 |
| 150+ words | 2% |

Measured: a four-word button reading back with one word changed is confirmed and sent. Two
earlier drafts of this paragraph were wrong about this — one claimed such a substitution "is not
reachable by a stale clipboard" (a review then demonstrated a 156-character clipboard-shaped
append that passed), and one quoted the 2% figure as if it applied generally, understating the
real allowance for typical buttons by an order of magnitude.

The separate size bounds are a second lock and a stronger one: anything that changes the total
length is caught, so exploiting the above requires a length-preserving substitution. The
non-alphanumeric bound closes the punctuation and emoji case. Verification also still assumes
the paste is the only change to the box while it is happening.

## 1.8.1 — 2026-07-19

**Fixes a defect introduced by 1.8.0: long markdown buttons refused to send.**

1.8.0 required the composer to read back character-for-character identical to what was pasted.
It does not, and never did. The composer is a tree of block elements, and the accessibility
layer joins consecutive blocks with a single newline — so a blank line *inside* a paragraph
survives the round-trip, but a blank line *between* a heading and its paragraph does not.
Reading a 482-line prompt back out of the live composer returned 480 lines.

The result was that any button containing markdown headings compared unequal, was treated as a
failed paste, and was never sent. The log line was `Paste did not land as expected; composer
left untouched and NOT sent`. Nothing was lost or leaked — the refusal is the safe direction —
but the button was unusable.

Comparison now collapses runs of whitespace on both sides. Stale clipboard content differs in
its characters rather than its spacing, so contamination is still caught; what is forgiven is
only the composer's own re-flowing of blank lines. A whitespace-only payload still collapses to
nothing and is still refused.

This was shipped because every test stubbed the composer reader and fed back an `observed`
value equal to the payload — a shape the real composer never produces. The tests now use the
measured shape, and reverting the comparator fails them.

## 1.8.0 — 2026-07-19

**A button can now refuse to send.** That is a deliberate, user-visible behaviour change, and
it is why this is a minor bump rather than a patch.

Reported by [@RasmusKD](https://github.com/RasmusKD) in #4, who also disclosed that his earlier
PR made it substantially more likely by cutting a post-paste wait from 300ms to 90ms.

- **A button could paste your clipboard instead of its own text.** `Ctrl+V` is asynchronous:
  the keystroke is queued and the app reads the clipboard some time later. The panel set the
  clipboard, sent `^v`, waited a fixed 90ms, then restored what you had copied — and if that
  restore won the race, the app pasted **your** clipboard. Wrong message, and whatever you had
  copied went into an AI conversation. A fixed delay cannot make this safe.
- **The panel now reads the message box back** through the accessibility tree and only restores
  your clipboard once it can see exactly its own text in there.
- **If it cannot confirm that, it sends nothing.** It does not type, does not press Enter, does
  not undo, does not clear. Whatever is in the box stays there, visible and unsent, and you
  decide. The old code typed the correct text whenever the paste could not be confirmed and
  then submitted — which is precisely what turned a detected problem into a sent one, because
  the right text landed underneath the contamination and both went out together.
- **Abandoned sends now say so in the panel** instead of only reaching the log, with a distinct
  message for each cause: nothing pasted, could not verify, did not land as expected, or the
  button has no text. Previously "I clicked and nothing happened" was indistinguishable from a
  successful send.
- **The keystroke encoder is gone.** It existed only to feed the typing fallback; with that
  removed it was dead code, so it was deleted rather than left in place untested. The panel now
  synthesises exactly two keystrokes, `^v` and `{ENTER}`. A test parses the script and fails if
  any other input-synthesis call is added, so a typing path cannot come back unnoticed. (The
  earlier claim that "no third keystroke can appear" was too strong: that test searched for one
  spelling of one API, and four other ways of sending a keystroke got past it.)

Known limitations, stated rather than buried:

- Verification assumes the paste appends at the end of the box. If your caret is in the middle
  of a draft, or text is selected, the result will not match and the send is refused.
- Verification polls on the UI thread, so a failed send can freeze the strip for up to 1.2s.
- The root cause is still open. The leading hypothesis is that a `Ctrl+V` from an *earlier*
  click is still pending inside the app and consumes the restored clipboard — which the panel's
  reentrancy guard does not prevent, because it only covers its own handler.

## 1.7.3 — 2026-07-19

**Security release.** Found by an independent auditor reviewing the published v1.7.2 with no
knowledge of the project — after four internal review rounds had taken the arming gate's
"two principals" design at face value. **If you use shutdown-on-done, upgrade.**

- **`MACHINE-ARMED` was a second key with no lock on it.** Arming required *either* a standing
  request *or* the machine switch — but the switch is a zero-byte file with no allow-rule and
  no content check. An agent that had read untrusted content could create it (it is not a
  shutdown command and does not read like one), and that alone re-opened the gate that
  withholding `request-on` from `permissions.allow` exists to close, because `on --this-turn`
  *is* pre-authorised. A standing request is now the only key.
  **Behaviour change:** an external/physical trigger must now write both the `MACHINE-ARMED`
  marker and a `<session>.request` file. That is what keeps the two sides in different hands.
- **The wake message no longer names the arm command.** It fires because a file exists — and
  that file may exist because of injected content — so spelling out the exact pre-authorised
  command turned the tool into an amplifier for the injection its gate exists to stop. It now
  describes the state and explicitly warns against arming a shutdown the user did not request.
- **Session ids are validated before becoming filenames.** `session_id` came from hook stdin
  and reached `rmSync(force, recursive)`, so `../../x` escaped the flag directory and could
  delete an arbitrary file or directory tree. No attacker channel was found (Claude Code mints
  UUIDs), but a hook that deletes derived paths should not depend on its caller.

Documentation, from the same outside review:

- **The install disclosure said "two permission allow-rules"; it grants eight.** Nothing
  improper is granted and the set is correctly scoped — but that sentence is what a cautious
  reader uses to decide whether to enable a feature that powers off their PC. It now states
  the real number, lists the four subcommands, and explains that `request-on` is deliberately
  withheld so the approval prompt *is* the consent.
- **`uiaComposerName` is now in the shipped default config.** The troubleshooting section calls
  it "the knob to try first" when the strip vanishes, and it was absent from
  `buttons.default.json` — so a user following the top recovery instruction would not find the
  key. The two genuinely dead knobs (`uiaPaneName`, `uiaSidebarName`) are no longer shipped.
- A new test guards the whole class: every knob in the default config must actually be read by
  the panel, and the documented first-resort recovery knob must be present in it.

152 tests (45 engine + 50 panel + 57 installer). The three security fixes were each verified to
fail against v1.7.2.

## 1.7.2 — 2026-07-18

**Safety release for the optional shutdown-on-done feature.** A ten-agent audit found five
ways the power-off path could fire when it should not, or report success without disarming.
If you use shutdown-on-done, upgrade. The button panel itself is unaffected by these bugs.

Every fix below ships with a regression test that was verified to **fail** against 1.7.1 —
17 of the 18 new engine tests do (the eighteenth guards an invariant 1.7.1 already held).

- **A corrupt arm flag no longer shuts the PC down.** `skip: 0` is the fire sentinel, and it
  was also the default when the flag could not be parsed — so a truncated, empty, or
  malformed flag powered the machine off. No attacker required: the flag was written
  non-atomically, and this tool cuts power mid-write by design. The engine now fails closed,
  consumes the bad flag, disarms, and says so. Flag writes are atomic (temp + rename).
- **A re-entered Stop hook no longer burns the grace turn.** Any hook returning
  `decision: "block"` re-runs Stop hooks within the same user-visible turn — including this
  engine's own MACHINE-ARMED wake. The skip counter decremented twice and fired one response
  early, which is precisely the mid-work shutdown `toggle on` promises not to do.
- **`toggle --off` no longer reports success while leaving the machine armed.** Dash-prefixed
  typos were filtered out as "flags" before the verb check and fell through to the status
  report: exit 0, no stderr, still armed. Unknown options and stray arguments now exit 1.
- **`request-off` now drops the arm it authorised.** The panel's power button watches
  `*.request`, so clearing only that marker made the button go dark while the chat stayed
  armed — the UI asserting "not armed" about a machine that was.
- **The arming gate now has two sides.** `toggle on` refuses without a standing `*.request`,
  but `request-on` creates that marker and both were pre-authorised in `settings.json` — so
  the gate was satisfiable by exactly the thing it was meant to stop, in two unattended
  commands with no prompt. `request-on` is no longer allow-listed: arming costs one approval,
  which the user is present to give. Disarming stays friction-free.
- **The skill no longer re-grants `toggle *`.** Its frontmatter reinstated the wildcard the
  installer deliberately removed, so the narrowing was only half-applied.
- **The test runner no longer reports success when it skipped the engine tests.** With Node
  absent it printed `ALL TESTS PASSED` having run none of the suite that guards the power-off
  path. It now fails closed (`CB_ALLOW_NO_NODE=1` to opt out deliberately).
- **The 1.7.1 modal-latch guard was itself evadable** — it checked the flag's setting side
  only, and passed against a mutant that deleted the clearing side, fully reintroducing the
  1.7.0 deadlock. Now guarded too. (Still a source-text proxy; a behavioural test needs the
  tick decomposed, which is tracked separately.)

### Data safety and the installer

- **`settings.json` is now written atomically and validated first.** It was rewritten with a
  plain `WriteAllText`, which truncates the target and then streams into it — on a file Claude
  Code also writes. A crash or a concurrent write could leave the user with no working Claude
  Code config. Writes now go to a temp file, must parse back, and are swapped in atomically.
- **A too-deeply-nested `settings.json` is refused rather than silently mangled.** PowerShell's
  `ConvertTo-Json` does not error past `-Depth`; it stringifies the over-deep node into
  `"@{k=v}"`, quietly destroying MCP server definitions while still emitting valid JSON. Depth
  raised to 100 *and* the result is rejected if it shows that stringification.
- **Install and uninstall pre-flight `settings.json`.** An invalid or locked file used to abort
  the run half-way — on uninstall that left the skills and engine deleted but the hooks still
  present and pointing at missing files. It now fails before anything is touched.
- **`/pin` and `/unpin` no longer edit `buttons.json` by hand.** The panel guards that file with
  a mutex and merges against a fresh read, but the skills did a plain read-modify-write — so a
  panel edit landing inside a skill's think-time was silently destroyed. Both now call
  `claude-buttons.ps1 -AddButton|-RemoveButton <file.json>`, which takes the same lock and the
  same merge path. Payloads are passed as a file, since a button's text can be a whole prompt.
- **`buttons.json` is written without a BOM**, as the installer's own comment always said it
  should be, and at depth 100 for the same reason as above.

### Accessibility and rendering

- **A lit toggle is now readable.** The active fill paired with the standard foreground measured
  **1.96:1** for an icon glyph — below AA, on the button whose lit state means "this PC is armed
  to power off". The fill is slightly darker and the label draws in white: **5.1:1** readable,
  **3.3:1** state cue. Both are now asserted by the test suite, so the README's contrast claim
  cannot drift away from the code again.
- **Fixed a GDI handle leak that could kill the panel.** In the layered-window push, the device
  contexts were acquired *before* the `try` that frees them, so every failed push leaked two
  handles — and pushes fail precisely when GDI is already under pressure, making it a death
  spiral toward the 10,000-handle ceiling. Failed pushes now also raise a real Win32 error
  instead of failing silently.

### Documentation

- **Two documented config knobs were dead code.** `uiaPaneName` and `uiaSidebarName` were
  parsed and never read again — and the troubleshooting section told users to edit them to
  recover from a Claude app update. Removed **from the documentation**; the parsing is kept so
  an existing `buttons.json` containing them still loads. Troubleshooting now leads with
  `uiaComposerName`, which is the knob that actually matters.
- **Corrected the contrast and target-size claims.** The stated contrast range did not cover the
  states it described; the target-size note claimed a WCAG failure the code does not commit
  (buttons are 27px, meeting SC 2.5.8).
- **Documented shift-click** (shipped in 1.7.1 with no README coverage) and the `vNudge` /
  `tipsOff` fields.
- **New CI-checked invariants** so this class of drift stops recurring: `CB_VERSION` must match
  the newest CHANGELOG heading, no documented config field may be dead code, and any
  interaction advertised in a tooltip must appear in both READMEs.

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
