# Panel config-lifecycle tests, driven through the panel's -SmokeTest switch (which parses
# buttons.json, normalizes it, builds the controls, and prints "SMOKE-OK ... N buttons ...").
# No Pester dependency. Each case runs the real script against a crafted buttons.json in a
# throwaway temp dir - the installed config and ~/.claude are never touched.
# Run standalone:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\panel.tests.ps1
$ErrorActionPreference = 'Stop'
$repo   = Split-Path $PSScriptRoot -Parent
$panel  = Join-Path $repo 'claude-buttons.ps1'
$defCfg = Join-Path $repo 'buttons.default.json'
$fails  = 0
$count  = 0

# ---- Never take the user's PRODUCTION config lock during a test run ----
# The panel serialises config writes on a named mutex. This file used to hold that exact name
# for ~1.2s per run, and Update-Config gives up after 2000ms by DISCARDING the user's edit with
# only a log line - so running the suite on a machine with the panel open could silently throw
# away a pin, a colour choice or a dissolve. It also made two concurrent suite runs fight each
# other, and the loser exits non-zero while printing no FAIL line, which is exactly the shape
# that fakes a CAUGHT verdict in mutation testing.
# Every child powershell.exe INHERITS this variable, so CLI invocations lock on the test name.
# Start-Job does NOT inherit it - job-based holders must be passed $cbLockName explicitly.
$cbProdLock = 'Local\ClaudeButtonsConfig'
$cbLockName = "Local\CbTests-$PID-" + [Guid]::NewGuid().ToString('N').Substring(0,8)
$env:CB_CONFIG_LOCK = $cbLockName

function Run-Smoke([string]$json) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("cb-panel-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $panel  (Join-Path $dir 'claude-buttons.ps1') -Force
    Copy-Item $defCfg (Join-Path $dir 'buttons.default.json') -Force
    [IO.File]::WriteAllText((Join-Path $dir 'buttons.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    # Redirect LOCALAPPDATA/USERPROFILE too: the panel logs to %LOCALAPPDATA%\claude-buttons.log,
    # so every test run was appending to the developer's real log file.
    $prevLocal = $env:LOCALAPPDATA; $prevHome = $env:USERPROFILE
    try {
        $env:LOCALAPPDATA = $dir; $env:USERPROFILE = $dir
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') -SmokeTest 2>&1
        $code = $LASTEXITCODE
    } finally { $env:LOCALAPPDATA = $prevLocal; $env:USERPROFILE = $prevHome }
    $left = (Get-Content (Join-Path $dir 'buttons.json') -Raw)  # to assert bad file untouched
    Remove-Item $dir -Recurse -Force
    [pscustomobject]@{ Out = "$out"; Code = $code; FileAfter = $left }
}
function Buttons([string]$out) { if ($out -match 'SMOKE-OK[^:]*:\s*(\d+)\s+buttons') { [int]$Matches[1] } else { -1 } }

function Check([string]$name, [bool]$cond) {
    $script:count++
    if ($cond) { Write-Host "  ok  $name" -ForegroundColor DarkGreen }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fails++ }
}

Write-Host "Panel config-lifecycle tests"

$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a"}, {"label":"B","text":"/b"} ] }'
Check 'valid config -> SMOKE-OK, 2 buttons' (($r.Out -match 'SMOKE-OK') -and (Buttons $r.Out) -eq 2 -and $r.Code -eq 0)

$r = Run-Smoke '{ "buttons": [] }'
Check 'empty buttons array -> 0 buttons' ((Buttons $r.Out) -eq 0 -and $r.Code -eq 0)

$r = Run-Smoke '{ "targetTitle": "Claude" }'
Check 'missing buttons property -> normalized to 0' ((Buttons $r.Out) -eq 0 -and $r.Code -eq 0)

$r = Run-Smoke 'THIS IS NOT VALID JSON }}}['
Check 'corrupt JSON -> falls back, does NOT throw (exit 0)' (($r.Out -match 'SMOKE-OK') -and $r.Code -eq 0)
Check 'corrupt file left untouched on disk' ($r.FileAfter -eq 'THIS IS NOT VALID JSON }}}[')

$r = Run-Smoke '{ "buttons": [ {"label":"Dup","text":"/x"}, {"label":"Dup","text":"/x"} ] }'
Check 'duplicate buttons both kept (no silent dedupe)' ((Buttons $r.Out) -eq 2)

$r = Run-Smoke '{ "buttons": [ {"label":"Emoji 🚀 日本語","text":"line1\nline2 {curly} +caret"} ] }'
Check 'unicode + special chars + newline text builds' ((Buttons $r.Out) -eq 1 -and $r.Code -eq 0)

$long = '{ "buttons": [ {"label":"Long","text":"' + ('x' * 2000) + '"} ] }'
$r = Run-Smoke $long
Check '2000-char prompt builds' ((Buttons $r.Out) -eq 1 -and $r.Code -eq 0)

$r = Run-Smoke '{ "buttons": [ {"label":"P","icon":"power","toggle":true,"text":"/p"}, {"label":"Bad","icon":"nope","text":"/b"}, {"label":"Hex","icon":"E7E8","text":"/h"} ] }'
Check 'icon (name), unknown icon (fallback), raw-hex icon, toggle build' ((Buttons $r.Out) -eq 3 -and $r.Code -eq 0)

$r = Run-Smoke '{ "buttons": [ {"label":"C","text":"/c","chat":"sess","chatTitle":"Some chat"} ] }'
Check 'per-chat button builds (chat-scoped hidden until its chat shows)' ($r.Code -eq 0)

# (The Escape-SendKeys encoder tests lived here. The encoder existed to feed the typing
# fallback, the fallback was the leak, and with it gone the function was dead code - so it and
# its -EscapeProbe hook were deleted rather than left as an untested loaded gun. The
# whole-file SendWait assertions below replace them: they prove the script can synthesise no
# keystroke other than '^v' and '{ENTER}', which is a stronger claim than checking how a
# now-nonexistent encoder escaped its input.)

# --- Tick-ordering invariant: the modal-hide must never latch the strips off ---
# Regression guard for the v1.7.0 deadlock. `composerLost` was part of the $show gate, and that
# gate's early `return` fires BEFORE Update-UiaInfo - the only place that ever clears the flag.
# So the first Claude modal that hid the strips kept them hidden until the panel was restarted.
# Two source invariants keep it fixed; they are checked statically because the live tick needs a
# real Claude window (the same blind spot that let the bug ship).
$src = @(Get-Content $panel)
$showLine = ($src | Select-String -Pattern '^\s*\$show = ' | Select-Object -First 1).LineNumber
$uiaLine  = ($src | Select-String -Pattern '^\s*Update-UiaInfo\s*$' | Select-Object -First 1).LineNumber
$hideLine = ($src | Select-String -Pattern '^\s*if \(\$script:composerLost\)' | Select-Object -First 1).LineNumber

$showExpr = if ($showLine) { ($src[($showLine - 1)..([Math]::Min($showLine + 4, $src.Count - 1))] -join ' ') } else { '' }
Check 'the $show gate does not consult composerLost (else the strips latch off)' (($showLine -gt 0) -and ($showExpr -notmatch 'composerLost'))
Check 'the modal-hide runs AFTER Update-UiaInfo (so the flag can clear again)' (($uiaLine -gt 0) -and ($hideLine -gt 0) -and ($hideLine -gt $uiaLine))

# The two checks above guard the SETTING side of the latch. They both passed against a
# mutant that simply deleted the CLEAR side - so the flag could never become false again
# and the v1.7.0 deadlock was fully reintroduced with a green suite. Guard the clear too.
# NOTE: this is still a source-text proxy, not a behavioural test. The real fix is to
# extract the visibility decision into a pure function and test the state machine.
$clearsFlag = @($src | Select-String -Pattern '\$script:composerLost\s*=\s*\$false').Count
Check 'composerLost is cleared somewhere (else it latches on forever)' ($clearsFlag -ge 1)

# --- Fail-closed send path ---
$srcText2 = (Get-Content $PSCommandPath) -join "`n"   # this test file, for self-checks
$srcText = $src -join "`n"   # defined here too: these checks run before the doc-vs-code block
# Ctrl+V is asynchronous. If the clipboard is restored before the app reads it, the app pastes
# the USER'S clipboard: wrong message, and their copied data leaked into an AI conversation.
# The old code typed the correct text whenever the paste could not be confirmed - and THAT is
# what turned a detected problem into a sent one, because it appended the right text under the
# contamination and pressed Enter. These guard the invariant that replaced it: on anything
# other than a confirmed paste, type nothing, send nothing, change nothing.
# BEHAVIOURAL, via the -PasteProbe seam: the real Wait-PasteLanded is driven with a stubbed
# composer reader. The first version of these checks grepped the source instead, and six of
# nine injected defects survived - including one that reinstated the leak verbatim, and two
# i18n "tests" whose regex was satisfied by the CALL SITES rather than the string table, so
# deleting every string still passed.
# WHAT AN EMPTY COMPOSER ACTUALLY READS AS. This is the single most expensive fact in this file.
#
# Three separate times a fixture here has fed the comparator a baseline the real composer never
# produces - "" and then "\n" - and each time a fully green suite certified a panel that could
# not send. 1.10.2 is the third: it added a prefix check, every fixture said an empty composer
# reads as "\n", and every real click into an empty composer was refused.
#
# MEASURED read-only through UIA against the running app: an EMPTY composer's TextPattern returns
# the PLACEHOLDER, "Type / for commands\n" - 20 characters, UIA children
# [Text 'Type / for commands', Text '\n' (class ProseMirror-trailingBreak)]. It does not read as
# empty and it never has.
#
# So fixtures do not write a baseline shape any more. They write the TOKEN <EMPTY>, which says
# what is meant - "the composer was empty" - and this one constant decides what that looks like.
# When the placeholder changes (it is English prose and will), it changes in exactly one place,
# and the guards below fail loudly if it is ever quietly reverted to a shape reality does not
# produce. A fixture you have to READ to validate is what kept failing here; these are checked.
$script:EmptyComposerReadback = "Type / for commands`n"
# Derived, never typed twice: two hand-escaped copies of the same string is one more thing that
# can drift apart silently.
$script:EmptyComposerJson = ($script:EmptyComposerReadback | ConvertTo-Json).Trim('"')

function PasteState([string]$json, [switch]$Raw) {
    # Expand the <EMPTY> token to the measured placeholder before the probe ever sees the JSON.
    $json = $json.Replace('<EMPTY>', $script:EmptyComposerJson)
    # Run from a throwaway dir with its own config and LOCALAPPDATA. Running the panel out of
    # the repo made every test run append "buttons.json unreadable at startup" to the
    # developer's real %LOCALAPPDATA%\claude-buttons.log.
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("cb-pp-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $panel  (Join-Path $dir 'claude-buttons.ps1') -Force
    Copy-Item $defCfg (Join-Path $dir 'buttons.default.json') -Force
    Copy-Item $defCfg (Join-Path $dir 'buttons.json') -Force
    $f = Join-Path $dir 'probe.json'
    [IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
    $prevLocal = $env:LOCALAPPDATA
    $prevHome  = $env:USERPROFILE
    try {
        $env:LOCALAPPDATA = $dir
        $env:USERPROFILE  = $dir
        # The probe emits "state|elapsedms"; -Raw callers want both, everyone else just the state.
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') -PasteProbe $f 2>$null) -join ''
        if ($Raw) { $out } else { ($out -split '\|')[0] }
    } finally {
        $env:LOCALAPPDATA = $prevLocal; $env:USERPROFILE = $prevHome
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# --- GUARDS ON THE FIXTURES THEMSELVES ---------------------------------------------------
# The failure mode this file keeps hitting is not a wrong assertion, it is a fixture that is
# internally consistent and describes a composer that does not exist. These three checks are
# aimed at the fixtures rather than at the panel, so the shape cannot silently drift back.

# 1. An empty composer is NOT empty. If <EMPTY> is ever redefined to "", "\n" or any other
#    whitespace, this fails - the placeholder is prose and must contain words.
Check 'the EMPTY-composer fixture reads as placeholder TEXT, not as whitespace' `
    (($script:EmptyComposerReadback.Trim().Length -gt 0) -and
     ($script:EmptyComposerReadback -match '[\p{L}]'))

# 2. No fixture may hand-write the old fake shape. This is the exact literal that shipped three
#    regressions; it is now a test failure rather than a code review someone has to catch.
$fakeBaselines = @([regex]::Matches(
    [IO.File]::ReadAllText($PSCommandPath), '"baseline":"(\\n)?"').Count)
Check 'no fixture hardcodes an empty/newline-only baseline (use <EMPTY>)' `
    ($fakeBaselines[0] -eq 0)

# 3. THE ONE THAT WOULD HAVE CAUGHT 1.10.2. With a real empty composer the read-back after a
#    paste does NOT start with the baseline - the placeholder is replaced, not appended to. So
#    the empty-composer fixtures must exercise the NON-prefix path. If <EMPTY> is reverted to
#    "\n" the fixtures still "pass" their own assertions but stop testing the real code path,
#    and this check is what notices.
$emptyLanded = $script:EmptyComposerJson.Replace('\n','') # placeholder without its terminator
Check 'the EMPTY-composer fixtures exercise the replaced-placeholder path, not append' `
    (-not ('/review').StartsWith($emptyLanded, [StringComparison]::Ordinal))

Check 'a clean paste into an EMPTY composer is Confirmed' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"/review\n"}') -eq 'Confirmed')
# The genuine 12,752-character button the user actually clicks, and the genuine 12,259-character
# read-back UIA returned for it (rendering ate the fence markers and languages). Recorded live.
# This is a REAL shape, not a constructed one - which is the whole point of it being here.
Check 'a real markdown button pasted into an empty composer is Confirmed' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"# Titel\n\n**fed** tekst\n\n```powershell\nGet-Date\n```\n\n- punkt et\n- punkt to","observed":"# Titel\nfed tekst\nGet-Date\n- punkt et\n- punkt to\n"}') -eq 'Confirmed')
# ...and the same empty composer where the paste never landed: the placeholder is still all
# that is in the box. This must NEVER confirm - it is defect 3 in its empty-composer form.
Check 'an empty composer where NOTHING landed is a Mismatch' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"<EMPTY>"}') -eq 'Mismatch')
# The regression that would have made the panel useless in daily use: an "empty" Chromium
# composer reads as "\n" and a draft as "draft\n", so concatenating the raw baseline put that
# terminator mid-string and every click with a draft in the box refused to send.
Check 'a clean paste on top of a USER DRAFT is Confirmed (not refused)' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"udkast/review\n"}') -eq 'Confirmed')
Check 'a stale clipboard landing instead of the payload is a Mismatch' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"secret token\n"}') -eq 'Mismatch')
# The exact shape reported in PR #4: stale text prepended, our payload also present. A
# "contains the payload" probe would call this a success and submit both.
Check 'stale text PLUS our payload is still a Mismatch' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"secret token/review\n"}') -eq 'Mismatch')
# A payload that normalizes away would make want == baseline, satisfying the poll on its first
# read - confirming a paste that never happened and submitting whatever the user already had.
Check 'a whitespace-only payload can never be Confirmed' `
    ((PasteState '{"baseline":"udkast\n","payload":"   ","observed":"udkast\n"}') -eq 'Mismatch')
Check 'an unreadable composer is Unverifiable, never Confirmed' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":null}') -eq 'Unverifiable')

# --- AN UNREADABLE BASELINE. The OTHER direction, and it reopened defect 3. -----------------
# The case above is a readable baseline with an unreadable OBSERVATION. Nothing covered the
# reverse, and the reverse is the dangerous one. Get-ComposerText documents $null as a real
# return - "unknown", never "empty" - but Wait-PasteLanded did `$base = [string]$baseline`, and
# [string]$null is ''. EVERY string starts with '', so the prefix check passed trivially and the
# WHOLE read-back became the delta. Measured through this seam before the fix:
#
#   {"baseline":null,"payload":"/review","observed":"/review\n"}  ->  Confirmed
#
# The live sequence: the composer already holds /review; the baseline read fails transiently; no
# paste happens; a later read succeeds; the panel confirms and Enter sends the user's own draft.
# That is "confirm a paste that never happened", arriving through the one input the delta logic
# cannot see, and it must be Unverifiable - we cannot know the delta, and saying 'Mismatch' would
# send the user hunting for contamination we never actually detected.
Check 'an UNREADABLE BASELINE can never be Confirmed (delta is unknowable)' `
    ((PasteState '{"baseline":null,"payload":"/review","observed":"/review\n"}') -eq 'Unverifiable')
# The same shape where the read-back is NOT payload-derived. Still Unverifiable, not Mismatch:
# with no baseline there is nothing to compare against, so the verdict cannot depend on what
# happens to be in the box. A fix that merely reordered the checks would fail this.
Check 'an unreadable baseline is Unverifiable regardless of the read-back' `
    ((PasteState '{"baseline":null,"payload":"/review","observed":"noget helt andet\n"}') -eq 'Unverifiable')
# ...and it must NOT be reached by short-circuiting. The caller restores the user's clipboard the
# instant this returns, and Ctrl+V is read asynchronously, so returning early hands the app the
# USER'S clipboard to paste. The unreadable-baseline path must hold the clipboard for the full
# budget exactly like the unreadable-composer path above. (Same measurement as F8; a `return
# 'Unverifiable'` placed before the poll would pass the two checks above and fail this one.)
$nullBaseRaw = PasteState '{"baseline":null,"payload":"/review","observed":"/review\n"}' -Raw
$nullBaseMs  = [int]($nullBaseRaw -split '\|')[1]
Check "an unreadable baseline still polls until its timeout (${nullBaseMs}ms of a 120ms budget)" `
    ($nullBaseMs -ge 100)
# The control: a READABLE baseline of the same shape must still Confirm. Without this, "return
# Unverifiable always" passes every check above.
Check 'a readable baseline with the same read-back still Confirms (the gate is not blanket)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"/review\n"}') -eq 'Confirmed')

# --- INTERLEAVING: words and symbols were checked as INDEPENDENT sequences ------------------
# Derivation ran one ordered-subset walk over the words and a separate one over the symbols, so a
# read-back could satisfy both while ordering the symbols differently against the words. All three
# of these have the payload's exact word sequence, the payload's exact symbol sequence and
# identical sizes in both character classes - so (a), (b), (c) and (d) are all satisfied - and all
# three were Confirmed through this seam before the combined-stream check was added.
Check 'a symbol moved to the front of a word is a Mismatch (interleaving)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"alfa /beta","observed":"/alfa beta\n"}') -eq 'Mismatch')
Check 'a colon moved to the end of the line is a Mismatch (interleaving)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"gennemgaa: min kode","observed":"gennemgaa min kode:\n"}') -eq 'Mismatch')
Check 'a quote moved across a word is a Mismatch (interleaving)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"sig \"ja\" nu","observed":"\"sig ja\" nu\n"}') -eq 'Mismatch')
# The combined check must not have been bought by refusing legitimate rendering. Markdown
# rendering only DELETES tokens, which an ordered-subset walk permits freely, so a fenced and
# bolded button still confirms - and the real 12k pair below is the load-bearing version of this.
Check 'the combined-stream check still Confirms a fenced, bolded button' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"# Titel\n\n**fed** tekst\n\n```powershell\nGet-Date\n```\n\n- punkt et\n- punkt to","observed":"# Titel\nfed tekst\nGet-Date\n- punkt et\n- punkt to\n"}') -eq 'Confirmed')

# Source invariants that cannot be probed: what the caller DOES with the state.
# (The "nothing is submitted unless Confirmed" invariant used to live here as a regex for the
# assignment `$pasted = ($pasteState -eq 'Confirmed')`. That asserted a LINE EXISTS, not that the
# dangerous path is unreachable: moving the whole submit block above the fail-closed guard left
# the assignment untouched and passed all 332 tests while a Mismatch pressed Enter. It is now an
# AST DOMINATOR check further down - search for "structurally dominated".)
# Assert the fail-closed block sends NOTHING - no keystrokes of any kind. Grepping for the
# literal `Escape-SendKeys $textToSend` was defeated by binding to a variable first
# (`$esc = Escape-SendKeys $textToSend; SendWait $esc`), and a regex requiring "some return
# before some ENTER" cannot express "no Enter BEFORE the return" - the reinstated leak passed
# all 64 tests. A block that contains no send at all cannot leak, however it is spelled.
# WHOLE-FILE, brace-independent. Extracting the fail-closed block by brace matching and
# grepping inside it was evaded three ways: moving the send into a helper whose name contains
# none of the searched words; sending BEFORE the block under an equivalent condition; and
# closing a brace early so the non-greedy regex truncated the extracted region. All three
# reinstated type-then-Enter and passed the whole suite.
#
# There is no typing path any more, so the script should synthesise exactly two keystrokes.
#
# Counting `SendKeys]::SendWait(` with a regex was NOT enough: it pins one spelling of one
# method on one type, so the count stays at two while a leak is reinstated as
# `SendKeys::Send($esc)` (a real .NET method with identical delivery), or by aliasing the type
# to a variable first, or via `New-Object -ComObject WScript.Shell`, or by reflection. All four
# passed the whole suite. So the guard works on TOKENS and the AST instead of on source text.
#
# Token gate (load-bearing): outside comments, the input-synthesis APIs may be NAMED exactly
# twice in the whole file. Aliasing, reflection and COM all have to name the type somewhere, so
# they cannot get under this - it does not care how the call is spelled or where it sits.
$srcTok = $null; $srcErr = $null
$srcAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $panel).Path, [ref]$srcTok, [ref]$srcErr)
$inputApiTokens = @($srcTok | Where-Object {
    $_.Kind -ne 'Comment' -and $_.Text -match 'SendKeys|WScript|VisualBasic|keybd_event|mouse_event|SendInput|ValuePattern|InvokePattern'
})
$tokNames = @($inputApiTokens | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Text)" }) -join ' | '
Check "input-synthesis APIs are named exactly twice outside comments (found: $tokNames)" `
    ($inputApiTokens.Count -eq 2 -and @($inputApiTokens | Where-Object { $_.Text -eq 'System.Windows.Forms.SendKeys' }).Count -eq 2)
# COM would let a keystroke API be built from a concatenated string, which no token names.
Check 'no COM object is created (WScript.Shell would synthesise keystrokes unnamed)' `
    (-not ($srcText -match '-ComObject'))
# P/Invoke is the one bypass a maintainer might reach for WITHOUT meaning to obfuscate - the
# thought is "SendKeys is flaky, I'll post WM_CHAR myself", and none of the tokens above appear.
# The panel legitimately imports ~30 user32 functions, so this denies the input-synthesis ones
# by name rather than trying to allowlist the rest.
$inputImports = @([regex]::Matches($srcText,
    '\b(SendInput|keybd_event|mouse_event|SendMessage\w*|PostMessage\w*|SetForegroundWindow|AttachThreadInput|BlockInput)\b'
) | ForEach-Object { $_.Value } | Sort-Object -Unique)
Check "no input-synthesis function is imported via P/Invoke (found: $($inputImports -join ', '))" `
    ($inputImports.Count -eq 0)
# AST gate: both mentions must be direct static SendWait calls, and the only two keystrokes
# they may send are Ctrl+V and Enter. A literal-looking variable or a concatenation fails here.
$sendCalls = @($srcAst.FindAll({
    $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
}, $true) | Where-Object { $_.Expression.Extent.Text -match 'SendKeys' })
Check "exactly two SendKeys calls exist in the AST (found $($sendCalls.Count))" ($sendCalls.Count -eq 2)
$badMember = @($sendCalls | Where-Object { $_.Member.Extent.Text -ne 'SendWait' -or -not $_.Static })
Check "both are static ::SendWait (offenders: $(@($badMember | ForEach-Object { $_.Extent.Text }) -join ', '))" `
    ($badMember.Count -eq 0)
$sendArgs = @($sendCalls | ForEach-Object {
    if ($_.Arguments.Count -ne 1) { '<not-one-arg>' }
    elseif ($_.Arguments[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { '<not-a-literal>' }
    else { $_.Arguments[0].Value }
}) | Sort-Object
Check "the only keystrokes sent are '^v' and '{ENTER}' (found: $($sendArgs -join ' | '))" `
    (($sendArgs -join ' | ') -eq '^v | {ENTER}')
Check 'the SendKeys text encoder is gone (it existed only to feed the typing fallback)' `
    (-not ($srcText -match 'function Escape-SendKeys'))
# --- Enter is STRUCTURALLY DOMINATED by Confirmed ---
# The invariant is not "a correct-looking comparison appears somewhere in the file"; it is "the
# Enter keystroke is UNREACHABLE unless the paste was confirmed". The old regex asserted the
# former, and this mutation passed all 332 tests: take the submit block (Start-Sleep 90 ->
# Test-TargetForeground -> SendWait('{ENTER}')) and move it up to immediately after the
# `$pasted = ...` assignment, i.e. ABOVE the fail-closed guard. The assignment still matched, so
# the suite stayed green while a Mismatch pressed Enter and shipped the wrong content. Confirmed
# by running it, not predicted.
#
# So: find the '{ENTER}' SendWait in the AST and require an enclosing `if` whose condition is
# EXACTLY `$pasteState -ceq 'Confirmed'`. Exact text is deliberate - it forbids `-or`
# (`if ($pasteState -ceq 'Confirmed' -or $x)`), it forbids the case-insensitive `-eq`, and it
# forbids indirection through a variable that some other line could set. Moving the block
# anywhere outside that `if` leaves it with no such ancestor and fails here.
$enterCall = @($sendCalls | Where-Object {
    $_.Arguments.Count -eq 1 -and
    $_.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $_.Arguments[0].Value -ceq '{ENTER}'
})
Check "the Enter keystroke was located in the AST (found $($enterCall.Count))" ($enterCall.Count -eq 1)
$enterGuards = @()
if ($enterCall.Count -eq 1) {
    $p = $enterCall[0].Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            $enterGuards += ($p.Clauses[0].Item1.Extent.Text -replace '\s+', ' ').Trim()
        }
        $p = $p.Parent
    }
}
Check "Enter is structurally dominated by `$pasteState -ceq 'Confirmed' (guards: $($enterGuards -join ' / '))" `
    ($enterGuards -contains "`$pasteState -ceq 'Confirmed'")
# ...AND by a re-verification that focus is STILL IN THIS COMPOSER. A confirmed paste proves what
# is in the box, not where the caret is. Between the paste and the keystroke we wait for the
# paste to be observed and then sleep 90ms, and focus can move in that window - the user
# clicking, or Claude re-rendering. Test-TargetForeground does NOT cover this: it asks whether
# Claude is the foreground WINDOW and says nothing about which control holds keyboard focus, so
# in a multi-pane grid it passes while the caret sits in a different chat's composer. Enter goes
# wherever focus is, so pressing it blind can submit ANOTHER conversation's half-written draft.
#
# A dominator, not a `if (-not ...) { return }` above the keystroke: that shape is exactly what
# was hopped once before by moving the submit block above its guard, with the suite still green.
Check "Enter is structurally dominated by a focus re-check (guards: $($enterGuards -join ' / '))" `
    ($enterGuards -contains 'Wait-ComposerFocus $composerEl 250')
# The re-check must target the composer we PASTED into. `Wait-ComposerFocus $best` or any other
# element would re-verify the wrong box and pass while focus sits elsewhere.
Check 'the focus re-check names the composer that was pasted into' `
    ($srcText -match 'if \(Wait-ComposerFocus \$composerEl 250\) \{')
Check 'losing focus before Enter warns the user rather than failing silently' `
    ($srcText -match "Show-SendWarning \(L 'sendFocusLost'\)")
# ...and that state may only ever be produced by the verifier. If anything else could assign
# 'Confirmed', the dominator above would be satisfiable without a verified paste.
$confirmAssigns = @($srcAst.FindAll({
    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $args[0].Right.Extent.Text -match "'Confirmed'"
}, $true) | ForEach-Object { $_.Extent.Text })
Check "nothing assigns 'Confirmed' outside Wait-PasteLanded's own returns (found: $($confirmAssigns -join ', '))" `
    ($confirmAssigns.Count -eq 0)
Check 'no undo/select-all recovery was introduced (it would eat a user draft)' `
    (-not ($srcText -match "SendWait\('\^z'\)|SendWait\('\^a'\)"))
# Both abandoned-send branches must TELL the user. Without this the failure is silent except
# for a log line nobody reads, and "I clicked and nothing happened" is indistinguishable from
# a successful send - which is how this class of bug stayed invisible in the first place.
# F17: these three fixes were real but unguarded - reverting each passed the whole suite.
# The warning branches are now what FOLLOWS the confirmed block rather than a `-not $pasted`
# block, so they are located by the state they test rather than by brace matching.
$failBlock = [regex]::Match($srcText,
    "(?s)if \(\`$pasteState -ceq 'Confirmed'\) \{.*?\r?\n            \}\r?\n(.*?)\r?\n            return\r?\n").Groups[1].Value
Check 'the fail-closed region was located' ($failBlock.Length -gt 40)
Check 'the fail-closed region presses no keys at all' (-not ($failBlock -match 'SendWait|SendKeys'))
Check 'a clipboard failure is distinguishable from a bad paste (NotAttempted state)' `
    (($srcText -match "\`$pasteState = 'NotAttempted'") -and ($failBlock -match "Show-SendWarning \(L 'sendNoClipboard'\)"))
$blankBlock = [regex]::Match($srcText, "(?s)IsNullOrWhiteSpace\(\`$textToSend\)\) \{(.*?)\r?\n            \}").Groups[1].Value
Check 'the blank-payload path warns the user too (it was the one silent abandon)' `
    ($blankBlock -match "Show-SendWarning \(L 'sendBlank'\)")
# F18: without the redirect every test run appended to the developer's real
# %LOCALAPPDATA%\claude-buttons.log. Both harnesses must isolate it.
foreach ($fn in @('Run-Smoke', 'PasteState')) {
    $body = [regex]::Match($srcText2, "(?s)function $fn\(.*?\r?\n\}").Value
    Check "$fn redirects LOCALAPPDATA so tests never write the real log" ($body -match '\$env:LOCALAPPDATA = \$dir')
}
Check 'the Mismatch branch warns the user' ($failBlock -match "Show-SendWarning \(L 'sendMismatch'\)")
Check 'the Unverifiable branch warns the user' ($failBlock -match "Show-SendWarning \(L 'sendUnverified'\)")
$blankLine = ($src | Select-String -Pattern 'IsNullOrWhiteSpace\(\$textToSend\)' | Select-Object -First 1).LineNumber
$clipLine  = ($src | Select-String -Pattern 'Clipboard\]::GetDataObject' | Select-Object -First 1).LineNumber
Check 'a blank payload is refused BEFORE the clipboard is touched' `
    (($blankLine -gt 0) -and ($clipLine -gt 0) -and ($blankLine -lt $clipLine))

# F7: the call site, not just the function. The original defect was short-circuiting to
# 'Unverifiable' when the baseline was unreadable, which skipped the wait entirely and let the
# clipboard be restored with no delay at all. The probe drives Wait-PasteLanded directly, so it
# cannot see that - this asserts the caller always goes through the wait.
# F15: a `notmatch` against ONE literal spelling was evaded twice - by rewording the
# short-circuit at the call site, and by putting an early `return 'Unverifiable'` at the top of
# Wait-PasteLanded itself, which is the actual defect (clipboard restored with no delay on the
# one path where we cannot see what happened). Assert the STRUCTURE instead: the call must be
# unconditional, and the function must reach its polling loop before it can return anything.
$callLine = ($src | Select-String -Pattern '^\s*\$pasteState = Wait-PasteLanded \$composerEl \$baseline \$textToSend\s*$' | Select-Object -First 1)
Check 'the caller invokes Wait-PasteLanded unconditionally (no inline short-circuit)' ($null -ne $callLine)
$fnBody = [regex]::Match($srcText, '(?s)function Wait-PasteLanded.*?\r?\n\}').Value
$loopIdx = $fnBody.IndexOf('while ((Get-Date) -lt $deadline)')
Check 'Wait-PasteLanded contains its polling loop' ($loopIdx -gt 0)
$beforeLoop = if ($loopIdx -gt 0) { $fnBody.Substring(0, $loopIdx) } else { $fnBody }
Check 'Wait-PasteLanded cannot return Unverifiable before it has polled' `
    (-not ($beforeLoop -match "return 'Unverifiable'"))

# F8: the wait must actually wait. The probe passes an explicit short timeout, so neither the
# default nor the delay's existence was covered - setting the default to 0 passed everything.
$toMatch = [regex]::Match($srcText, '\[int\]\$timeoutMs = (\d+)')
Check 'Wait-PasteLanded has a non-trivial default timeout' `
    ($toMatch.Success -and ([int]$toMatch.Groups[1].Value -ge 300))
# MEASURED IN-PROCESS. Timing this from here spawned a powershell.exe per case, so ~1.5s of
# startup swamped the ~120ms poll: as an absolute threshold it could never fail, and made
# differential it was flaky in BOTH directions - three runs on a clean tree gave +112ms, -60ms
# and +252ms, so it red-lighted good code and could pass a real defect. The probe now reports
# its own elapsed time, which contains only the poll.
$unverRaw = PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":null}' -Raw
$quickRaw = PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"/review\n"}' -Raw
$unver = ($unverRaw -split '\|')[0]; $unverMs = [int]($unverRaw -split '\|')[1]
$quick = ($quickRaw -split '\|')[0]; $quickMs = [int]($quickRaw -split '\|')[1]
Check 'an unreadable composer returns Unverifiable' ($unver -eq 'Unverifiable')
Check "an unreadable composer polls until its timeout (${unverMs}ms of a 120ms budget)" `
    ($unverMs -ge 100)
# RELATIVE to the timeout case, not an absolute millisecond count. An absolute `< 60ms` failed at
# 69ms purely because the machine was busy - four review agents and a mutation run at once - which
# is a false alarm about the product, and the third time a timing assertion in this file has been
# either vacuous or flaky. Both numbers are now measured INSIDE the probe process, so they share
# whatever slowdown is going on and their ratio still means something: the confirmed path must
# return well before the poll would have timed out.
Check "a confirmed paste returns well inside the timeout (${quickMs}ms vs ${unverMs}ms)" `
    (($quick -eq 'Confirmed') -and ($quickMs -lt ($unverMs * 0.75)))

# F6: the user's own flagship button is a 12,752-character, 482-line prompt. Every other probe
# case is a single short line, so multi-line round-tripping through the UIA read-back was
# entirely unexercised.
#
# These two cases were WRONG until the button was tried for real. They fed back an `observed`
# equal to the payload, which the composer never produces: reading that 482-line prompt out of
# the live composer returned 480 lines, because TextPattern joins block elements with a single
# "\n" and the blank line between a heading and its paragraph is not a character in any block.
# Exact equality therefore refused to send EVERY time - the log said "Paste did not land as
# expected" and nothing was submitted. The `observed` values below are the shape the composer
# actually returns.
# THE CASE THAT WAS SHIPPED BROKEN TWICE. Measured against the live app: pasting the user's
# 12,752-char button gave a 12,259-char read-back that diverged at character 62, because the
# composer RENDERS markdown - a ```text fence loses its backticks AND the word "text". No
# whitespace normalisation can reconcile that, which is what 1.8.0 and 1.8.1 both tried.
Check 'a rendered code fence (backticks AND language word gone) still confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"## Titel\n\n```text\nDu skal svare.\n```","observed":"## Titel\nDu skal svare.\n"}') -eq 'Confirmed')
Check 'rendered bold (asterisks eaten) still confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"gør det **nu** og grundigt","observed":"gør det nu og grundigt\n"}') -eq 'Confirmed')
# PowerShell unrolls a single-element array when it is passed as an argument, so a one-word
# payload reached the coverage walk as a bare string and it indexed CHARACTERS. A perfect paste
# measured 0% coverage and was refused. Caught by the existing draft test; pinned here too.
Check 'a ONE-WORD payload confirms (single-element array unrolling)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"continue","observed":"continue\n"}') -eq 'Confirmed')
Check 'markdown whose blank lines the composer collapsed still confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"## Heading\n\nBody text.\n\n- item","observed":"## Heading\nBody text.\n- item\n"}') -eq 'Confirmed')
# Coverage alone is satisfied by "stale clipboard THEN our payload" - an in-order walk just
# skips the prefix. The size bound is the half that catches it, so it needs its own test.
# THE COVERAGE HALF WAS ENTIRELY UNPINNED. Five mutants passed all 85 tests: raising
# MaxMissingWords to 99, MaxMissingFraction to 0.90, ExtraFraction to 0.50, deleting the coverage
# check, and making Get-WordCoverage return 1.0. Every 'Confirmed' case above is also satisfied
# by a comparator that always passes on words, and every 'Mismatch' case was caught by the SIZE
# bound - so nothing measured coverage at all. These cases hold size constant and vary only the
# words, so they can ONLY be caught by coverage.
Check 'a substituted word at the SAME length is a Mismatch (coverage, not size)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"send nu","observed":"send bad\n"}') -eq 'Mismatch')
Check 'a wholly different text of the same size is a Mismatch (coverage)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"gennemgaa min kode","observed":"kontonummer 5479 1122\n"}') -eq 'Mismatch')
Check 'words in the WRONG ORDER are a Mismatch (coverage is ordered)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"alfa beta gamma delta epsilon zeta","observed":"zeta epsilon delta gamma beta alfa\n"}') -eq 'Mismatch')
# Non-alnum growth was unbounded: the ceiling counted letters and digits only, so a clipboard of
# emoji or punctuation rode in at any length and was Confirmed.
# The three cases above are all SHORT, so the floor(n/4) cap decides them and MaxMissingWords /
# MaxMissingFraction stay inert - raising them to 99 and 0.90 passed the whole suite. This one is
# 20 words with 4 substituted: the cap allows 5, so only the allowance of 3 can refuse it.
Check 'four substituted words in a twenty-word payload is a Mismatch (MaxMissingWords binds)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"et to tre fire fem seks syv otte ni ti elleve tolv tretten fjorten femten seksten sytten atten nitten tyve","observed":"et to xyz fire fem seks qqq otte ni ti zzzzzz tolv tretten fjorten wwwwww seksten sytten atten nitten tyve\n"}') -eq 'Mismatch')
# Likewise every size-based Mismatch above overshoots the ceiling so far that ExtraFraction stayed
# inert - 0.0 -> 0.50 passed everything. This appends ~30% extra, which only the tight ceiling refuses.
Check 'a 30% overshoot is a Mismatch (ExtraFraction binds, not just the absolute margin)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"alfa beta gamma delta epsilon zeta eta theta","observed":"alfa beta gamma delta epsilon zeta eta theta kodeord1234\n"}') -eq 'Mismatch')
Check 'injected punctuation/symbols are a Mismatch (non-alnum ceiling)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"gennemgaa min kode","observed":"gennemgaa min kode !!! ??? ---> @@@ *** ~~~ %%%\n"}') -eq 'Mismatch')
# The false refusal that shipped twice, in its remaining form: each fence language counted as a
# missing payload word, so four or more fenced blocks in a short button exceeded the allowance.
Check 'a button with FOUR fenced code blocks still confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"Kør disse:\n```powershell\nGet-Date\n```\n```powershell\nGet-Host\n```\n```json\n{}\n```\n```bash\nls\n```","observed":"Kør disse:\nGet-Date\nGet-Host\n{}\nls\n"}') -eq 'Confirmed')
Check 'a short button that is ONLY a fenced block still confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"```json\n{\"a\":1}\n```","observed":"{\"a\":1}\n"}') -eq 'Confirmed')
Check 'stale clipboard text pasted ALONGSIDE the payload is a Mismatch (size bound)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"## Titel\n\nDu skal svare.","observed":"kodeord hemmeligt kontonummer 4471 privat besked\n## Titel\nDu skal svare.\n"}') -eq 'Mismatch')
Check 'a multi-line payload with blank lines confirms' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"line one\n\nline three","observed":"line one\nline three\n"}') -eq 'Confirmed')
Check 'a multi-line payload missing its last line is still a Mismatch' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"line one\n\nline three","observed":"line one\n\n\n"}') -eq 'Mismatch')
# Collapsing whitespace must not blunt contamination detection: stale clipboard text differs in
# its characters, not its spacing, so it must still fail however the composer reflowed it.
Check 'stale clipboard text is a Mismatch even after whitespace collapsing' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"## Heading\n\nBody text.","observed":"secret token\n## Heading\nBody text.\n"}') -eq 'Mismatch')
Check 'a payload of only newlines is refused, not confirmed by collapsing' `
    ((PasteState '{"baseline":"udkast\n","payload":"\n\n  \n","observed":"udkast\n"}') -eq 'Mismatch')

# --- The DELTA must derive from the payload (aggregates could not prove this) ---
# Every check above this point compared AGGREGATES over the whole read-back: word coverage
# between the payload and all of `observed`, plus size ceilings on the total. All three cases
# below returned Confirmed against that, verified through this same -PasteProbe seam. They are
# the reason Test-PasteLanded now subtracts the baseline and judges only what the paste ADDED.
#
# 1. Two foreign characters rode in under the 2-character absolute size allowance.
Check 'two foreign characters riding in with the payload is a Mismatch (delta derivation)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review","observed":"xx/review\n"}') -eq 'Mismatch')
# 2. One substituted word out of four sat inside the floor(n/4) missing-word cap. Size is
#    IDENTICAL here (omega and alpha are both five letters), so only derivation can refuse it.
Check 'one substituted word of four is a Mismatch (same size, only derivation sees it)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"send alpha beta gamma","observed":"send omega beta gamma\n"}') -eq 'Mismatch')
# 3. THE BLOCKER. Nothing landed at all. The user's own draft already contained the payload's
#    words, so coverage was satisfied, and the baseline alone cleared the 60% size floor. The
#    panel confirmed a paste that never happened and pressed Enter on the user's draft. No
#    threshold can fix this, because the aggregate never looked at what CHANGED - which is why
#    the delta is now the unit of measurement.
Check 'an UNCHANGED composer whose draft already contains the payload words is a Mismatch' `
    ((PasteState '{"baseline":"review review\n","payload":"/review","observed":"review review\n"}') -eq 'Mismatch')
# The same shape WITH a real paste must still confirm, or the fix above is just a refusal of
# everything. This is the pair that makes case 3 a real discrimination and not a blanket ban.
Check 'the same draft WITH a real paste still confirms (delta is not just "refuse everything")' `
    ((PasteState '{"baseline":"review review\n","payload":"/review","observed":"review review/review\n"}') -eq 'Confirmed')
# The narrow way the placeholder fallback could reintroduce defect 3, and the reason the fallback
# is tried INSTEAD of the delta rather than AFTER it. This draft is a perfect ordered subset of
# the button's text and clears every size bound on its own, so if a rejected delta were allowed a
# second attempt against the WHOLE read-back, a paste that never happened would be Confirmed and
# the user's draft submitted. The delta is empty here; that must remain the only verdict taken.
Check 'a draft that IS the button text, with nothing pasted, is a Mismatch' `
    ((PasteState '{"baseline":"review\n","payload":"/review","observed":"review\n"}') -eq 'Mismatch')

# --- A DECISION, PINNED SO IT IS NOT MISTAKEN FOR AN OVERSIGHT ------------------------------
# A draft that was REPLACED rather than appended to takes the fallback (the read-back does not
# start with the baseline), the whole box is payload-derived, and it Confirms - so the draft is
# gone and the button's text is sent. That is accepted deliberately; it is not the same bug as
# the three above, and it must not be "fixed" without reading the long note in the source.
#
# The reviewer's proposal was to hardcode the measured placeholder and refuse the fallback for
# any other baseline. THE FALLBACK IS THE DOMINANT PATH: an empty composer reads as its
# placeholder, the paste REPLACES it, so every ordinary click into an empty box lands here.
# Gating it on correctly identifying an English prose string gates EVERY SEND on that string
# surviving app updates and localisation - the total-loss-of-function regression this file has
# already shipped three times, where only a human clicking a button ever noticed.
#
# And refusing would not save the draft: by the time we read the box the draft is already gone,
# destroyed by the Ctrl+V that hit a select-all or a remounted composer. Refusing preserves only
# the chance to Ctrl+Z, at the cost of the button not working. What gets sent is verified
# payload-derived - the text of the button the user just clicked - so no foreign content can ride
# in; the leak classes above are still refused by derivation.
Check 'a REPLACED draft still Confirms (deliberate: the fallback is the ordinary path)' `
    ((PasteState '{"baseline":"bevar dette udkast\n","payload":"/review","observed":"/review\n"}') -eq 'Confirmed')
# The guard on that decision: the fallback stays a FULL-STRENGTH gate, not a soft one. If the
# whole read-back is not payload-derived, replacement is refused like anything else - so
# "accepting the fallback" never means "accepting whatever replaced the draft".
Check 'a draft replaced by something FOREIGN is still a Mismatch' `
    ((PasteState '{"baseline":"bevar dette udkast\n","payload":"/review","observed":"helt andet indhold\n"}') -eq 'Mismatch')
# A delta that is pure punctuation is invisible to the word checks - the word sequence is
# perfectly derived. The symbol side of the derivation check is the only thing that refuses it.
Check 'punctuation appended after a correct paste is a Mismatch (symbol derivation)' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"udkast/review!!!???\n"}') -eq 'Mismatch')
# ...and the SAME NUMBER of symbols, substituted. The case above overshoots the symbol COUNT, so
# it is caught by the size ceiling and leaves the symbol SEQUENCE check inert - deleting that
# check passed the whole suite. Here the counts are identical (one symbol either way) and only
# the ordered-subset rule can tell '?' from '/'.
Check 'a SUBSTITUTED symbol at the same count is a Mismatch (symbol sequence, not symbol count)' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"udkast?review\n"}') -eq 'Mismatch')
# Conversely the non-alnum CEILING is not redundant, because Get-CompareSymbols ignores
# whitespace and the ceiling does not. Injected whitespace has a perfectly derived word sequence
# AND a perfectly derived symbol sequence; only the ceiling sees it. Deleting the ceiling passed
# the whole suite until this case existed.
Check 'injected whitespace after a correct paste is a Mismatch (non-alnum ceiling)' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"udkast/review            \n"}') -eq 'Mismatch')
# The alnum ceiling has one narrow window of its own, and it is a real leak. Get-CompareWords AND
# Get-CompareSymbols both strip fence info-strings, so content smuggled onto a ``` line in the
# read-back is invisible to BOTH derivation checks - the word sequence and the symbol sequence are
# each perfectly derived. Get-AlnumLength does not strip fences, so the ceiling is the only thing
# that sees it. The non-alnum ceiling usually catches such a line on the ``` characters alone,
# which is why widening the alnum bound by 50 characters passed the whole suite; here the payload
# has trailing whitespace that the composer collapses, leaving enough non-alnum headroom to
# absorb the fence and exposing the alnum bound as the last check standing.
Check 'content hidden on a fence line is a Mismatch (alnum ceiling, invisible to both derivations)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review          ","observed":"```hemmeligtkodeord44\n/review\n"}') -eq 'Mismatch')
# The same payload pasted cleanly must still confirm, or the check above is passing for the
# trivial reason that trailing whitespace breaks everything.
Check 'a payload with trailing whitespace still confirms when the composer collapses it' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"/review          ","observed":"/review\n"}') -eq 'Confirmed')
# MaxMissingWords itself. The pre-existing test for it used four SUBSTITUTED words in a twenty
# word payload - but substitution is now refused by the derivation check long before the
# allowance is consulted, so raising MaxMissingWords from 3 to 99 passed the whole suite. What
# the allowance actually governs now is DELETION. Twenty equal-length words with five missing:
# floor(20/4) is 5, so the quarter cap permits it and only the absolute limit of 3 refuses it.
# The delta still carries 75% of the characters, so the size floor cannot decide this either.
Check 'five missing words in a twenty-word payload is a Mismatch (MaxMissingWords binds)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp qqqq rrrr ssss tttt","observed":"aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo\n"}') -eq 'Mismatch')
# ...and three missing words - what a few rendered-away fence languages actually look like - must
# still confirm, or the allowance has been tightened into the false-refusal regression instead.
Check 'three missing words in the same payload still confirms (the allowance is real)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp qqqq rrrr ssss tttt","observed":"aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp qqqq\n"}') -eq 'Confirmed')
# The size FLOOR is the only check that refuses a paste which landed with most of its characters
# missing but few enough WORDS missing to clear the coverage allowance. Eight words, the last two
# carrying most of the length: two missing words is exactly floor(8/4), so coverage permits it.
Check 'a paste missing most of its CHARACTERS but few words is a Mismatch (size floor)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"a b c d e f gggggggggggggggggggggggggggggg hhhhhhhhhhhhhhhhhhhhhhhhhhhhhh","observed":"a b c d e f\n"}') -eq 'Mismatch')
# Coverage must be measured on the DELTA, not on the whole read-back. Here the user's draft
# already ends with the payload's opening words and only the tail of the payload landed. Measured
# over `observed` the coverage is a perfect 100% and this confirms; measured over the delta three
# words are missing against an allowance of two, and it is correctly refused. The delta still
# carries 81% of the payload's characters, so the size floor cannot catch this one - coverage on
# the delta is the only thing that does.
Check 'a partial paste onto a draft that supplies the missing words is a Mismatch (coverage on the DELTA)' `
    ((PasteState '{"baseline":"alfa beta gamma\n","payload":"alfa beta gamma deltaord epsilonord zetaord etaord thetaord iotaord kappaord","observed":"alfa beta gamma deltaord epsilonord zetaord etaord thetaord iotaord kappaord\n"}') -eq 'Mismatch')
# DIRECTION of the derivation check. `delta subset-of payload` is not the same relation as
# `payload subset-of delta`, and every case above is satisfied by BOTH - so swapping the
# arguments passed the whole suite. They differ exactly where rendering DELETES a payload word
# that Remove-FenceInfoStrings does not account for: a markdown link renders to its label and the
# URL's words disappear. The correct direction still confirms this; the flipped one refuses it,
# which is the false-refusal regression that shipped twice.
Check 'a markdown LINK whose URL words are rendered away still confirms (derivation direction)' `
    ((PasteState '{"baseline":"<EMPTY>","payload":"Du skal gennemgaa hele mit projekt og laese [dokumentet](x.dk) foerst, og derefter skrive et kort resume af hvad du fandt, saaledes at en anden laeser kan forstaa det uden at aabne noget som helst andet end dit svar her","observed":"Du skal gennemgaa hele mit projekt og laese dokumentet foerst, og derefter skrive et kort resume af hvad du fandt, saaledes at en anden laeser kan forstaa det uden at aabne noget som helst andet end dit svar her\n"}') -eq 'Confirmed')
# The paste must APPEND. A composer whose content no longer starts with the baseline cannot be
# attributed to this paste at all, so it is refused. See the KNOWN LIMITATION in the panel: a
# caret parked mid-draft lands here and is refused rather than guessed at. Refusing is the safe
# direction and this pins that it stays a refusal rather than quietly becoming a confirmation.
Check 'a paste that did NOT append (baseline no longer a prefix) is a Mismatch' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"ud/reviewkast\n"}') -eq 'Mismatch')
# The user's draft being partly deleted must not confirm either - the delta check must not be
# satisfiable by SHRINKING the box.
Check 'a composer that shrank below the baseline is a Mismatch' `
    ((PasteState '{"baseline":"mit lange udkast\n","payload":"/review","observed":"mit lange\n"}') -eq 'Mismatch')

# --- The real flagship button, at full size ---
# F6: the user's own flagship button is a 12,752-character, 482-line markdown prompt whose live
# read-back is 12,259 characters (a 0.961 ratio) - fences lose their backticks AND their language
# word, bold loses its asterisks, blank lines collapse. Every other probe case here is a handful
# of words, so nothing exercised the delta machinery at that scale, and a rule that is correct on
# "continue" can still be quadratic or subtly wrong on 12k. The fixture below is generated to the
# same shape and the same ratio rather than pasted as a 12k literal.
function New-BigButtonFixture {
    $NL = [string][char]10
    $F  = [string][char]96 + [string][char]96 + [string][char]96   # ``` without escaping games
    $pay = New-Object Text.StringBuilder
    $obs = New-Object Text.StringBuilder
    [void]$pay.Append('# AI-agentpanel' + $NL + $NL); [void]$obs.Append('AI-agentpanel' + $NL)
    $filler = 'Du skal gennemfoere hvert trin i raekkefoelge og dokumentere hvad du fandt undervejs, ' +
              'saaledes at en anden laeser kan gentage arbejdet uden at gaette sig frem til noget som helst. ' +
              'Skriv kortfattet og undlad at gentage spoergsmaalet i dit svar til brugeren her.'
    $i = 0
    while ($pay.Length -lt 12400) {
        $i++
        [void]$pay.Append('## Afsnit ' + $i + $NL + $NL)          # heading marker eaten
        [void]$obs.Append('Afsnit ' + $i + $NL)
        [void]$pay.Append($filler + ' Trin ' + $i + ' er **vigtigt**.' + $NL + $NL)   # bold eaten
        [void]$obs.Append($filler + ' Trin ' + $i + ' er vigtigt.' + $NL)
        if ($i % 5 -eq 0) {                                        # fence + language word eaten
            [void]$pay.Append($F + 'text' + $NL + 'koer kommando ' + $i + ' nu' + $NL + $F + $NL + $NL)
            [void]$obs.Append('koer kommando ' + $i + ' nu' + $NL)
        }
    }
    @{ P = $pay.ToString(); O = $obs.ToString() }
}
$big = New-BigButtonFixture
$bigRatio = [Math]::Round($big.O.Length / $big.P.Length, 3)
# Assert the FIXTURE is the shape it claims to be. Without this the two checks below could pass
# on a fixture that silently degenerated to a short string - the vacuous-green failure mode this
# file has hit repeatedly.
Check "the big-button fixture matches the real one's scale and ratio ($($big.P.Length) -> $($big.O.Length), ratio $bigRatio)" `
    (($big.P.Length -gt 12000) -and ($big.O.Length -gt 11500) -and ($bigRatio -gt 0.94) -and ($bigRatio -lt 0.98))
Check 'the 12k markdown flagship button confirms (fences, bold and blank lines all rendered away)' `
    ((PasteState (@{ baseline = $script:EmptyComposerReadback; payload = $big.P; observed = $big.O } | ConvertTo-Json -Compress -Depth 3)) -eq 'Confirmed')
# ...and the same button with a clipboard leak in it must NOT. A 12k payload is exactly where a
# proportional allowance hides a small contamination, so this is the case that keeps the delta
# bound honest at scale.
Check 'the same 12k button with stale clipboard text prepended is a Mismatch' `
    ((PasteState (@{ baseline = $script:EmptyComposerReadback; payload = $big.P
                     observed = "kodeord hemmeligt kontonummer 4471`n" + $big.O } | ConvertTo-Json -Compress -Depth 3)) -eq 'Mismatch')
Check 'the same 12k button with stale clipboard text APPENDED is a Mismatch' `
    ((PasteState (@{ baseline = $script:EmptyComposerReadback; payload = $big.P
                     observed = $big.O + "kodeord hemmeligt kontonummer 4471`n" } | ConvertTo-Json -Compress -Depth 3)) -eq 'Mismatch')
# Assert the STRING TABLE, not any mention of the key: the previous version matched the
# Show-SendWarning call sites, so deleting every string still passed while the user would have
# got a blank tooltip.
$stringsOk = $true
foreach ($lang in @('en', 'da')) {
    $block = [regex]::Match($srcText, "(?s)\b$lang\s*=\s*@\{(.*?)\r?\n\s*\}").Groups[1].Value
    # sendNoPane joined these when the wrong-chat hazard was fixed: it is the string the user
    # sees when a side-bar send is abandoned because no composer could be identified safely.
    # Without it in this list the feature ships with a blank tooltip in one or both languages.
    # sendFocusLost joined them when the pre-Enter focus re-check was added: the paste succeeded,
    # so the user sees their text sitting in the box and needs to be told why it was not sent.
    foreach ($k in @('sendMismatch', 'sendUnverified', 'sendNoPane', 'sendFocusLost')) {
        if ($block -notmatch "$k\s*=\s*'[^']{10,}'") { $stringsOk = $false }
    }
}
Check 'both abandoned-send strings are defined with real text in EN and DA' $stringsOk

# --- Version discipline ---
# v1.7.0 shipped reporting "1.6.0" because a merge resolution silently reverted the bump,
# and the tag had to be force-moved after release. CB_VERSION is what the panel shows in its
# menu and what the installer's smoke test prints, so it is the only way a bug report can
# identify the running build. Nothing referenced it from tests or CI, so the identical
# mistake would have recurred unnoticed.
$verMatch = [regex]::Match(($src -join "`n"), "(?m)^\`$CB_VERSION\s*=\s*'([^']+)'")
Check 'CB_VERSION is defined' ($verMatch.Success)
$ver = $verMatch.Groups[1].Value
# Compare against the HIGHEST version in the file, not the first heading in file order: a
# newer section appended at the bottom would otherwise pass silently.
$chgAll = [regex]::Matches((Get-Content (Join-Path $repo 'CHANGELOG.md') -Raw), '(?m)^##\s+([0-9]+\.[0-9]+\.[0-9]+)')
Check 'CHANGELOG has at least one versioned heading' ($chgAll.Count -gt 0)
$newest = ($chgAll | ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Descending)[0].ToString()
Check "CB_VERSION ($ver) matches the newest CHANGELOG version ($newest)" ($ver -eq $newest)

# --- Contrast invariants ---
# The README states a contrast figure, and a lit toggle used to measure 1.96:1 against it -
# on the button that means "this PC is armed to power off". Assert the pairs the code
# actually renders, so the claim cannot drift away from the colours again.
function Ratio($a, $b) {
    $lin = { param($v) $v = $v / 255; if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) } }
    $la = 0.2126 * (& $lin $a[0]) + 0.7152 * (& $lin $a[1]) + 0.0722 * (& $lin $a[2])
    $lb = 0.2126 * (& $lin $b[0]) + 0.7152 * (& $lin $b[1]) + 0.0722 * (& $lin $b[2])
    $hi = [Math]::Max($la, $lb); $lo = [Math]::Min($la, $lb)
    ($hi + 0.05) / ($lo + 0.05)
}
function ArgbFrom([string]$pattern) {
    $m = [regex]::Match(($src -join "`n"), $pattern)
    if (-not $m.Success) { return $null }
    @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
}
$togFill = ArgbFrom 'ToggleFill\s*=\s*Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$togFore = ArgbFrom 'ToggleFore\s*=\s*Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$bar     = ArgbFrom '\$colBar\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
Check 'toggle colours are parseable from source' ($togFill -and $togFore -and $bar)
if ($togFill -and $togFore -and $bar) {
    $fg = Ratio $togFore $togFill
    $cue = Ratio $togFill $bar
    Check ("toggle-ON label is readable: {0:N2}:1 >= 4.5 (WCAG 1.4.3)" -f $fg) ($fg -ge 4.5)
    Check ("toggle-ON state cue holds: {0:N2}:1 >= 3.0 (WCAG 1.4.11)" -f $cue) ($cue -ge 3.0)
    # The filled dot is the NON-COLOUR cue for the on-state, and it was failing at 2.93:1
    # before the fill was darkened - it passes now only by 0.20. Assert it, or the next fill
    # tweak silently re-breaks the one cue a colour-blind user relies on.
    #
    # NOTE ON THE SHAPE OF THIS CHECK: the first version of it had the regex written in the
    # wrong source order, so it never matched - and because it fell back to a hardcoded
    # literal on failure, it silently compared two constants written in this file and asserted
    # nothing about the code at all. A parse failure must FAIL the test, never substitute the
    # expected answer. There is no fallback here for that reason.
    $dotMatches = [regex]::Matches(($src -join "`n"),
        'new SolidBrush\(Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)\)+\s*\r?\n\s*g\.FillEllipse')
    Check 'the toggle dot colour is parseable from BOTH paint paths' ($dotMatches.Count -ge 2)
    foreach ($dm in $dotMatches) {
        $dot = @([int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value)
        $dotCue = Ratio $dot $togFill
        Check ("toggle-ON dot (non-colour cue): {0:N2}:1 >= 3.0 (WCAG 1.4.11)" -f $dotCue) ($dotCue -ge 3.0)
    }
}

# --- Docs must describe code that exists ---
# The README documented two config knobs (uiaPaneName, uiaSidebarName) that were parsed and
# then never read again - and the troubleshooting section told users to edit them to recover
# from a Claude app update. Inert advice at exactly the moment the tool is broken. A field
# that is only ever assigned appears once for the default and once for the config override;
# a field that is genuinely used appears at least three times.
$srcText = $src -join "`n"
$readmeText = Get-Content (Join-Path $repo 'README.md') -Raw
$documented = [regex]::Matches($readmeText, '(?m)^\|\s*`(\w+)`\s*\|') | ForEach-Object { $_.Groups[1].Value }
$perButton = @('label','short','text','submit','confirm','icon','toggle','textOn','textOff',
               'stateGlob','chat','chatTitle','chatLabel','desc','schemaVersion','buttons')
$dead = @()
foreach ($f in ($documented | Sort-Object -Unique)) {
    if ($perButton -contains $f) { continue }   # per-button fields are read off the button object
    # Count the bare identifier, not "$script:<name>": some fields are read through an implicit
    # script-scope variable ($targetTitle) and counting only the qualified form reported them as
    # dead. A live field appears at least 3 times - default, config override, and a real use.
    # A dead one appears exactly twice (default + override), which is what this catches.
    # 0 refs is the WORST case (documented but never even parsed) and must not be skipped.
    $uses = ([regex]::Matches($srcText, "\b$([regex]::Escape($f))\b")).Count
    if ($uses -lt 3) { $dead += "$f ($uses refs)" }
}
Check ("no documented config field is dead code" + $(if ($dead) { ": $($dead -join ', ')" } else { '' })) ($dead.Count -eq 0)

# ...and the shipped default config must not contain dead knobs either. The check above guards
# documented -> used; this guards shipped -> used. An outside reviewer found the gap: the
# troubleshooting section names uiaComposerName as "the knob to try first", and it was absent
# from buttons.default.json - so a user whose strip had just vanished would open their config,
# follow the top recovery instruction, and not find the key. Meanwhile two genuinely dead knobs
# WERE shipped, inviting them to tune things that do nothing.
$defJson = Get-Content $defCfg -Raw | ConvertFrom-Json
$shippedDead = @()
foreach ($k in $defJson.PSObject.Properties.Name) {
    if ($k -in @('buttons', 'schemaVersion')) { continue }
    if (([regex]::Matches($srcText, "\b$([regex]::Escape($k))\b")).Count -lt 3) { $shippedDead += $k }
}
Check ("buttons.default.json ships no dead knobs" + $(if ($shippedDead) { ": $($shippedDead -join ', ')" } else { '' })) ($shippedDead.Count -eq 0)
Check 'the documented first-resort recovery knob is IN the shipped default config' `
    ([bool]$defJson.PSObject.Properties['uiaComposerName'])

# Every interaction the UI advertises in a tooltip must also exist in the README. Shift-click
# shipped in 1.7.1 with a CHANGELOG entry and a tooltip string and no README coverage at all.
if ($srcText -match "tipShift\s*=") {
    Check 'shift-click is documented in README.md' ($readmeText -match '(?i)shift-click')
    $readmeDa = Get-Content (Join-Path $repo 'README.da.md') -Raw
    Check 'shift-click is documented in README.da.md' ($readmeDa -match '(?i)shift-klik')
}

# --- Locked CLI entry point for the skills (DATA-01) ---
# The /pin and /unpin skills used to read-modify-write buttons.json by hand while the panel
# wrote the same file under a mutex, so a panel edit landing inside the skill's think-time was
# silently destroyed. These assert the CLI merges rather than overwrites, and - the part that
# actually bit - that a DECLINED change (duplicate / not found) leaves the file intact.
function Invoke-CbCli([string]$json, [string]$switchName, [string]$startCfg) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("cb-cli-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $panel  (Join-Path $dir 'claude-buttons.ps1') -Force
    Copy-Item $defCfg (Join-Path $dir 'buttons.default.json') -Force
    [IO.File]::WriteAllText((Join-Path $dir 'buttons.json'), $startCfg, (New-Object System.Text.UTF8Encoding($false)))
    # Pass the payload as a FILE, the way the skills are told to - inline JSON does not survive
    # PowerShell argument parsing once the text contains quotes.
    $pay = Join-Path $dir 'payload.json'
    [IO.File]::WriteAllText($pay, $json, (New-Object System.Text.UTF8Encoding($false)))
    # Redirect USERPROFILE: the panel writes ~/.claude/claude-buttons-path.txt on a real launch,
    # and this test previously repointed the DEVELOPER's live install marker at a temp folder
    # that is deleted moments later - breaking /pin and /unpin on their own machine, silently,
    # on every test run. Belt and braces alongside the guard in the script itself.
    $fakeHome = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null
    $prevHome = $env:USERPROFILE
    $prevEap  = $ErrorActionPreference
    try {
        $env:USERPROFILE = $fakeHome
        # PS 5.1 wraps a native command's stderr in ErrorRecords, which under
        # $ErrorActionPreference='Stop' terminate the whole test run. Several of these cases
        # deliberately exercise stderr paths (AMBIGUOUS, bad payload), so relax it here only.
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') $switchName $pay 2>&1
        $code = $LASTEXITCODE
    } finally { $env:USERPROFILE = $prevHome; $ErrorActionPreference = $prevEap }
    $after = Get-Content (Join-Path $dir 'buttons.json') -Raw
    Remove-Item $dir -Recurse -Force
    # Exit code is part of the contract: skills/pin and skills/unpin document a table that a
    # skill branches on (0 = done or declined, 2 = bad payload, 3 = ambiguous). Nothing
    # asserted it, so changing `exit 3` to `exit 0` passed.
    [pscustomobject]@{ Out = "$out"; Code = $code; Labels = (($after | ConvertFrom-Json).buttons | ForEach-Object { $_.label }) -join ',' }
}
$start = '{"schemaVersion":1,"buttons":[{"label":"Kept","text":"/kept"}]}'

$r = Invoke-CbCli '{"label":"New","text":"/new"}' '-AddButton' $start
Check 'CLI add merges instead of overwriting (existing button survives)' ($r.Labels -eq 'Kept,New')
Check 'CLI add reports ADDED with exit 0' (($r.Out -match 'ADDED') -and ($r.Code -eq 0))

$r = Invoke-CbCli '{"label":"Other","text":"/kept"}' '-AddButton' $start
Check 'CLI add refuses a duplicate (exit 0, nothing changed)' (($r.Out -match 'DUPLICATE') -and ($r.Code -eq 0))
Check 'a DECLINED add leaves the file intact (must not write a null entry)' ($r.Labels -eq 'Kept')

$r = Invoke-CbCli '{"label":"Kept","text":"/kept"}' '-RemoveButton' $start
Check 'CLI remove deletes the matching button' (($r.Out -match 'REMOVED') -and ($r.Labels -eq ''))

$r = Invoke-CbCli '{"label":"Ghost","text":"/ghost"}' '-RemoveButton' $start
Check 'CLI remove of a missing button reports NOTFOUND with exit 0' (($r.Out -match 'NOTFOUND') -and ($r.Code -eq 0))
Check 'a DECLINED remove leaves the file intact' ($r.Labels -eq 'Kept')

# Identity is CASE-SENSITIVE. PowerShell's -eq is not, so unpinning "Deploy" also deleted a
# genuinely different button "deploy" carrying a different prompt - with no backup and no undo.
$cased = '{"buttons":[{"label":"Deploy","text":"/deploy prod"},{"label":"deploy","text":"/DEPLOY PROD"},{"label":"Safe","text":"/safe"}]}'
$r = Invoke-CbCli '{"label":"Deploy","text":"/deploy prod"}' '-RemoveButton' $cased
Check 'remove is case-SENSITIVE: the other-case button survives' ($r.Labels -eq 'deploy,Safe')
$r = Invoke-CbCli '{"label":"DEPLOY","text":"/deploy prod"}' '-RemoveButton' $cased
Check 'a wrong-case payload matches nothing rather than the wrong button' `
    (($r.Out -match 'NOTFOUND') -and ($r.Labels -eq 'Deploy,deploy,Safe'))

# An ambiguous delete must refuse, not guess. skills/unpin/SKILL.md documents exit 3 for this.
$dupes = '{"buttons":[{"label":"Dup","text":"/x"},{"label":"Dup","text":"/x"},{"label":"Keep","text":"/k"}]}'
$r = Invoke-CbCli '{"label":"Dup","text":"/x"}' '-RemoveButton' $dupes
Check 'an ambiguous remove is REFUSED (exit 3) and deletes nothing' `
    (($r.Out -match 'AMBIGUOUS') -and ($r.Code -eq 3) -and ($r.Labels -eq 'Dup,Dup,Keep'))

# --- The suite must never take the user's PRODUCTION config lock (data-loss guard) ---
# Holding 'Local\ClaudeButtonsConfig' during a run makes the live panel's Update-Config time out
# after 2000ms and DISCARD the user's edit with only a log line. These four checks are the ones
# that stay red if anyone reintroduces the hardcoded name on either side.
Check 'the suite runs under a non-production config lock name' `
    (($env:CB_CONFIG_LOCK) -and ($env:CB_CONFIG_LOCK -ne $cbProdLock))
$panelSrc = Get-Content $panel -Raw -Encoding UTF8
# The panel must build its mutex from the overridable NAME, never from a literal.
Check 'the panel builds its config mutex from an overridable name, not a literal' `
    ($panelSrc -match [regex]::Escape('New-Object System.Threading.Mutex($false, $script:cfgLockName)'))
Check 'the panel honours CB_CONFIG_LOCK' ($panelSrc -match [regex]::Escape('$env:CB_CONFIG_LOCK'))
# ...and no test file may construct a mutex on the production name. `-eq` is case-insensitive in
# PS 5.1 and so is this match, which is what we want: a case variant names the same kernel object.
$testSrcAll = (Get-ChildItem (Join-Path $repo 'tests') -Filter *.ps1 |
               ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n"
Check 'no test constructs a mutex on the production config lock name' `
    (-not ($testSrcAll -match ('Mutex\([^)]*' + [regex]::Escape($cbProdLock))))

# --- Does the lock actually LOCK? (QA-2/QA-3) ---
# The battery above proves add/remove works with a single writer. It does NOT prove the mutex
# does anything: with the lock removed entirely, every one of those assertions still passed.
# This is the test that fails if the merge protocol is dropped. A second writer takes the same
# named mutex, holds it while it appends a button, and releases; the CLI must BLOCK, then merge
# against the file as it is AFTER that write - not against the copy it read before.
$dir = Join-Path ([IO.Path]::GetTempPath()) ("cb-lock-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'home\.claude') | Out-Null
Copy-Item $panel  (Join-Path $dir 'claude-buttons.ps1') -Force
Copy-Item $defCfg (Join-Path $dir 'buttons.default.json') -Force
$cfgFile = Join-Path $dir 'buttons.json'
[IO.File]::WriteAllText($cfgFile, '{"schemaVersion":1,"buttons":[{"label":"Start","text":"/start"}]}',
                        (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $dir 'pay.json'), '{"label":"FromCli","text":"/cli"}',
                        (New-Object System.Text.UTF8Encoding($false)))

$readyFile = Join-Path $dir 'holder-ready.flag'
# $cbLockName is passed EXPLICITLY. Start-Job does not inherit the parent's environment, so a
# holder that read $env:CB_CONFIG_LOCK itself would find it empty, fall back to the production
# name, and contend with the user's live panel again - while this file looked fixed.
$holder = Start-Job -ArgumentList $cfgFile, $readyFile, $cbLockName -ScriptBlock {
    param($cfg, $ready, $lockName)
    $m = New-Object System.Threading.Mutex($false, $lockName)
    [void]$m.WaitOne(5000)
    try {
        # READ, then think, then write - the classic lost-update shape, and exactly what the
        # skills used to do by hand. Without the lock the CLI's write lands inside this gap
        # and is overwritten by the stale copy read before it.
        $o = Get-Content $cfg -Raw | ConvertFrom-Json
        [IO.File]::WriteAllText($ready, 'held')   # signal AFTER the read, while still holding
        # The hold MUST stay under the panel's own 2000ms lock timeout. Raising it to 5s to make
        # the race deterministic was tried and is wrong: the CLI then legitimately gives up,
        # prints "Could not write buttons.json (locked or unreadable)" and exits 1 - which is
        # finding A's data-loss mechanism itself, not a passing test.
        # So this integration check stays timing-sensitive by nature, and the DETERMINISTIC proof
        # that contention is really observed lives in the in-process contention test below.
        # 800ms rather than 1200ms: under heavy parallel load (six suites at once during mutation
        # testing) a 1200ms hold plus child-process startup pushed the CLI past its 2000ms budget,
        # so it failed closed and this test went red for a mutation that had not broken anything -
        # a FALSE CAUGHT, the one outcome that makes a mutation table lie. 800ms leaves 1200ms of
        # headroom. Detection of a wrongly-named holder does not rest on this timing anyway: it is
        # the structural "no mutex from a string literal" check that catches that, deterministically.
        Start-Sleep -Milliseconds 800
        $b = [pscustomobject]@{ label = 'FromPanel'; text = '/panel' }
        $o.buttons = @($o.buttons) + $b
        [IO.File]::WriteAllText($cfg, ($o | ConvertTo-Json -Depth 100),
                                (New-Object System.Text.UTF8Encoding($false)))
    } finally { $m.ReleaseMutex() }
}
# Handshake, not a sleep. A fixed 300ms sleep made this test timing-dependent: under load the
# job took up to 12s to acquire, so the CLI ran to completion first and the test "passed"
# having exercised no concurrency at all - it passed identically with the mutex removed.
# Waiting for the holder to signal guarantees the lock IS held (and the stale read IS taken)
# before the CLI starts, so the CLI can only succeed by genuinely waiting and re-reading.
$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-Path $readyFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
Check 'the concurrent holder acquired the lock before the CLI started' (Test-Path $readyFile)
$prevHome = $env:USERPROFILE
$lockSw = [Diagnostics.Stopwatch]::StartNew()
try {
    $env:USERPROFILE = Join-Path $dir 'home'
    $lockOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') `
                   -AddButton (Join-Path $dir 'pay.json') 2>&1
} finally { $env:USERPROFILE = $prevHome }
$lockSw.Stop()
Wait-Job $holder -Timeout 20 | Out-Null
Remove-Job $holder -Force
$finalLabels = ((Get-Content $cfgFile -Raw | ConvertFrom-Json).buttons | ForEach-Object { $_.label }) -join ','
Remove-Item $dir -Recurse -Force

Check 'the CLI waits for the lock and reports success' ("$lockOut" -match 'ADDED')
# (No "elapsed > 0" assertion here: the CLI must finish INSIDE the panel's 2000ms lock timeout,
# so there is no elapsed threshold that separates a blocked run from an unblocked one. A check
# that cannot fail is worse than no check - the deterministic contention proof is further down.)
# A mutex name in a test must NEVER be a string literal - it has to come from $cbLockName, which
# is per-run and non-production. A literal is how this file took the user's live config lock for
# ~1.2s every run, and Update-Config discards the user's edit after 2000ms with only a log line.
# This also catches the specific trap that Start-Job does not inherit $env:CB_CONFIG_LOCK, so a
# holder job that was never passed the name would fall back to a hardcoded one.
$literalMutex = [regex]::Matches($testSrcAll, "New-Object\s+System\.Threading\.Mutex\(\s*\`$false\s*,\s*['`"]")
Check "no test builds a mutex from a string literal (found $($literalMutex.Count))" ($literalMutex.Count -eq 0)
# Assert MEMBERSHIP, not order. Which writer wins the mutex is a legitimate race; losing a
# button is not. Asserting the exact sequence would fail on a correctly-merged run that simply
# interleaved the other way - a flaky test that punishes the behaviour it is meant to protect.
$lockSet = @($finalLabels -split ',')
Check "no button is lost under concurrent writers (got: $finalLabels)" `
    (($lockSet.Count -eq 3) -and ($lockSet -contains 'Start') -and ($lockSet -contains 'FromPanel') -and ($lockSet -contains 'FromCli'))

# The skills must route through the locked entry point, not edit the JSON themselves.
foreach ($s in @('pin', 'unpin')) {
    $sk = Get-Content (Join-Path $repo "skills\$s\SKILL.md") -Raw
    Check "the /$s skill uses the locked CLI entry point" ($sk -match '-(Add|Remove)Button')
    Check "the /$s skill is told not to write buttons.json itself" ($sk -match '(?i)do NOT (read, edit or )?write buttons\.json')
}
# =====================================================================================
# --- The REAL ordering / bar / group transforms, loaded out of the panel source ---
# =====================================================================================
# THIS BLOCK EXISTS BECAUSE THE TESTS BELOW USED TO RE-IMPLEMENT THE PRODUCT. The file
# defined its own Swap-Blocks / Reorder-InBar / Move-ToBar / Dissolve / Same-Button /
# Get-ButtonBar - hand-copies of the bodies of Move-PinButton, Set-ButtonBar and the
# dissolve handler. Reference counts against the real source were: Move-PinButton 0,
# Set-ButtonBar 0, Move-GroupMember 0, Update-Config 0. Consequently twelve of sixteen
# mutations to the shipped code left the suite fully green, including:
#   - Move-PinButton reduced to `$out += $blk.items[0]`, which loses every group member
#     but the first - missed by the test literally named "never loses a button";
#   - the move direction reversed ($bi + $dir -> $bi - $dir);
#   - the out-of-range guard turned from a no-op into a clamp - missed by the test named
#     "an out-of-range move is a no-op rather than a truncation";
#   - an early `return` making Set-ButtonBar, Move-PinButton and Move-GroupMember
#     unconditional no-ops: three whole features dead, 119 green;
#   - the orphan-group prune gutted;
#   - dissolve additionally stripping `bar`, scattering the members.
# Every one of those is now caught, because the tests call the shipped functions.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($panel, [ref]$null, [ref]$null)

# Stubs for the GUI/logging edges the transforms touch. NOT stubs for any transform: the
# rule is that nothing which decides the SHAPE of the buttons array may be re-implemented
# here. Update-Buttons and Update-Config are loaded for real (they carry the orphan-group
# prune and the null-transform guard), and so are Read-FreshConfig / Write-ConfigAtomic, so
# every assertion below is made against what actually landed on disk.
function Write-CkLog([string]$m) { $script:ckLog += , $m }
function Hide-GroupFlyout { $script:rebuilt++ }
function Rebuild-Buttons { $script:rebuilt++ }
# The dissolve item's CAPTION is a GUI edge (it writes $miDissolve.Text), so it is stubbed like
# the others. The two-click DECISION that calls it is not stubbed - it stays in the handler and
# is what the confirm tests below actually exercise.
function Set-DissolveLabel([string]$key) { $script:dissolveLabel = $key }
# The user-visible warning surface. Stubbed as a RECORDER, not as a no-op: a refused write that
# tells nobody is the failure mode these tests exist to catch, so the tests have to be able to
# see whether anything was said. The string it is handed comes from the real `L` lookup against
# the real string table (both loaded below), so an empty or missing table entry shows up here as
# an empty warning rather than passing silently.
function Show-SendWarning([string]$text) { $script:warned += , $text }
$script:warned = @()
$script:ckLog = @(); $script:rebuilt = 0; $script:flyForm = $null; $script:menuSource = $null
$script:dissolveLabel = ''; $script:dissolveArmedFor = $null; $script:dissolveArmedAt = Get-Date '2000-01-01'
# A test-private mutex name. Taking the panel's real production lock here would contend with the
# user's running panel for no benefit - the lock's own behaviour is covered by the concurrent-
# writer test above. This now reuses the SAME per-run name the panel picks up from
# $env:CB_CONFIG_LOCK, so the in-process transforms and the child CLI agree on one lock.
$script:cfgLock = New-Object System.Threading.Mutex($false, $cbLockName)

# Load, and FAIL LOUDLY if a name has moved. A silent `if ($node)` skip is how a test file
# ends up asserting nothing: rename the function and every test below would pass vacuously
# against whatever definition happened to be left over.
$panelFns = @('Get-ButtonBlocks', 'Get-ButtonBar', 'Same-Button', 'Get-ColorKind', 'Get-KindColor',
              'Read-FreshConfig', 'Write-ConfigAtomic', 'Update-Buttons', 'Update-Config',
              'Set-ButtonBar', 'Set-ButtonGroup', 'Set-KindColor', 'Move-GroupMember', 'Move-PinButton',
              'Get-GroupNames', 'Resolve-GroupName', 'Set-GroupProp', 'Get-GroupDef',
              'Clear-FlyoutForForm',
              # Row identity (the "Remove this button" fix) and the lost-update guard's
              # user-facing half. NOT `L`: an echo stub for it is defined further down for the
              # New-ButtonGroup fixture and would shadow the real one anyway, so loading it here
              # would only look like coverage that is not in force.
              'Get-TagIndex', 'Get-TargetIndex', 'Notify-ConfigClobber')
$missingFns = @()
foreach ($fn in $panelFns) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    if ($node) { Invoke-Expression $node.Extent.Text } else { $missingFns += $fn }
}
Check ("every transform under test was found in the panel source" + $(if ($missingFns) { ": MISSING $($missingFns -join ', ')" } else { '' })) `
    ($missingFns.Count -eq 0)
# Script-scope tables the loaded functions read. Extracted, not retyped: $script:ckBars is
# what Get-ButtonBar validates against and $script:ckPalette is the colour table, so copying
# either here would reintroduce exactly the "fixture asserts the fixture" defect.
Add-Type -AssemblyName System.Drawing   # $script:ckPalette is a table of [System.Drawing.Color]
$missingVars = @()
foreach ($vn in @('$script:ckBars', '$script:ckPalette')) {
    $asn = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $vn }, $true)
    if ($asn) { Invoke-Expression $asn.Extent.Text } else { $missingVars += $vn }
}
Check ("the bar list and colour palette were extracted from source" + $(if ($missingVars) { ": MISSING $($missingVars -join ', ')" } else { '' })) `
    ($missingVars.Count -eq 0)

# =====================================================================================
# Clear-FlyoutForForm: a pinned flyout must not outlive the strip that owns it
# =====================================================================================
# This is the whole round-1 disposal fix and it had NO tests at all - `grep Clear-FlyoutForForm
# tests/` returned nothing, so every one of the branches below could have been deleted silently.
# The flyout records its owning strip in $flyForm.Tag. When the pane count shrinks, the owning
# strip form is hard-disposed in the tick; if the flyout is not torn down with it, it stays on
# screen with Tag pointing at a dead form and clicking a member resolves to no pane at all.
# Hide-GroupFlyout is the stub above, so $script:rebuilt counts "the flyout was torn down".
$ownerA = [pscustomobject]@{ Name = 'stripA' }
$ownerB = [pscustomobject]@{ Name = 'stripB' }

# 1. Owner MATCHES -> tear down: Tag cleared AND Hide-GroupFlyout called.
$script:flyForm = [pscustomobject]@{ Tag = $ownerA }
$script:rebuilt = 0
Clear-FlyoutForForm $ownerA
Check 'Clear-FlyoutForForm tears the flyout down when the owner matches' ($script:rebuilt -eq 1)
Check '...and clears the Tag so nothing can resolve through the dead form' ($null -eq $script:flyForm.Tag)

# 2. Owner does NOT match -> leave a flyout belonging to a DIFFERENT, still-live strip alone.
# Without this branch, disposing any one strip would close a flyout the user has open elsewhere.
$script:flyForm = [pscustomobject]@{ Tag = $ownerA }
$script:rebuilt = 0
Clear-FlyoutForForm $ownerB
Check 'a flyout owned by a DIFFERENT strip is left alone' ($script:rebuilt -eq 0)
Check '...and that flyout keeps its Tag' ($script:flyForm.Tag -eq $ownerA)

# 3. Owner already DISPOSED - the REAL shipped sequence. The tick disposes the strip form and
# then calls this with it, so the argument is routinely a dead object. Reference identity still
# holds after Dispose(), so the flyout must still be recognised as belonging to it and torn down.
# If it were not, the flyout would survive its owner - which is the entire bug this function
# exists to prevent.
# A real Form is used, not a mock. It is never Show()n, never parented and never focused;
# constructing and disposing one creates no visible window.
Add-Type -AssemblyName System.Windows.Forms
$deadOwner = New-Object System.Windows.Forms.Form
$deadOwner.Dispose()
$script:flyForm = [pscustomobject]@{ Tag = $deadOwner }
$script:rebuilt = 0
$disposedThrew = $false
try { Clear-FlyoutForForm $deadOwner } catch { $disposedThrew = $true }
Check 'a DISPOSED owner still tears its flyout down (identity survives Dispose)' `
    ((-not $disposedThrew) -and ($script:rebuilt -eq 1))
Check '...and the Tag pointing at the dead form is cleared' ($null -eq $script:flyForm.Tag)
# NOTE, measured: the `try { $same = ... } catch {}` around the Tag comparison in
# Clear-FlyoutForForm is NOT reachable from a test. PowerShell 5.1 turns a failing property GET
# into $null instead of a propagating exception - verified against a disposed Form, a disposed
# MemoryStream and a ScriptProperty that throws outright, all under $ErrorActionPreference=Stop;
# none of them threw. So no test here can make that catch fire, and a mutant deleting it
# correctly SURVIVES. It is left in place as cheap insurance on a disposal path, not because
# it is covered - saying otherwise would be the kind of claim this round exists to remove.

# 4. $null in, and no flyout open at all. Both are ordinary states - the tick calls this for
# every strip it disposes, whether or not a flyout is up.
$script:flyForm = [pscustomobject]@{ Tag = $ownerA }
$script:rebuilt = 0
$nullThrew = $false
try { Clear-FlyoutForForm $null } catch { $nullThrew = $true }
Check 'a $null form is ignored without throwing' ((-not $nullThrew) -and ($script:rebuilt -eq 0))
Check '...and the open flyout is untouched' ($script:flyForm.Tag -eq $ownerA)
$script:flyForm = $null
$script:rebuilt = 0
$noFlyThrew = $false
try { Clear-FlyoutForForm $ownerA } catch { $noFlyThrew = $true }
Check 'no flyout open is a no-op, not an error' ((-not $noFlyThrew) -and ($script:rebuilt -eq 0))
$script:flyForm = $null

# The two shipped callsites must actually route through it, or the function is dead code that
# passes its own tests. Both strip-disposal paths (pinned strip, side bar) have to call it.
$clearCalls = [regex]::Matches($srcText, 'Clear-FlyoutForForm\s+\$\w+\.Form').Count
Check "both strip-disposal paths call Clear-FlyoutForForm (found $clearCalls)" ($clearCalls -eq 2)

# =====================================================================================
# F1: the colour picker must actually SHOW its colours, and they must be readable
# =====================================================================================
# Fill-ColorMenu sets $mi.ForeColor per swatch, but CkRenderer.OnRenderItemText overwrote
# e.TextColor unconditionally - and since ToolStripManager.Renderer is set globally and a
# ContextMenuStrip defaults to ManagerRenderMode, EVERY swatch rendered in the same grey. The
# picker whose whole job is to show the colour showed none of them.
# MUTATION: restore the unconditional `e.TextColor = ...` and the first check goes red.
$renderText = [regex]::Match($srcText, '(?s)protected override void OnRenderItemText\(.*?\n    \}').Value
Check 'the menu renderer was located in source' ($renderText.Length -gt 60)
Check 'the menu renderer READS the item ForeColor instead of always overwriting it' `
    ($renderText -match 'e\.Item\.ForeColor' -and $renderText -match 'e\.TextColor = own')
Check 'a disabled item is still forced to the greyed colour (an unusable row must not shout)' `
    ($renderText -match 'e\.Item\.Enabled')
# ...and the picker must still be the thing that sets those colours.
Check 'Fill-ColorMenu still colours each swatch from the palette' `
    ($srcText -match '\$mi\.ForeColor = \$script:ckPalette\[\$n\]')

# Now that the swatches render in their own colours, they are TEXT (WCAG 1.4.3, 4.5:1) against
# the menu rows - including the SELECTED row, which is the binding case because a row has to be
# hovered to be clicked. Both row colours are parsed from the code that paints them, so the
# assertion cannot drift away from the rendering.
$rowHi   = ArgbFrom 'e\.Item\.Selected \|\| e\.Item\.Pressed\) \? Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$rowNorm = ArgbFrom 'e\.Item\.Pressed\) \? Color\.FromArgb\(\d+,\s*\d+,\s*\d+\) : Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
Check 'both menu row colours are parseable from the renderer' ($rowHi -and $rowNorm)
Check 'the palette actually has entries to measure' ($script:ckPalette.Keys.Count -ge 6)
if ($rowHi -and $rowNorm) {
    foreach ($pn in $script:ckPalette.Keys) {
        $pc = $script:ckPalette[$pn]
        $rgb = @([int]$pc.R, [int]$pc.G, [int]$pc.B)
        # MUTATION: revert red to (224,138,123) or blue to (107,166,232) and the highlighted-row
        # check goes red at 4.24:1 and 4.32:1 respectively.
        $rn = Ratio $rgb $rowNorm
        $rh = Ratio $rgb $rowHi
        Check ("colour-picker swatch '$pn' is readable on a resting menu row: {0:N2}:1 >= 4.5" -f $rn) ($rn -ge 4.5)
        Check ("colour-picker swatch '$pn' is readable on a HIGHLIGHTED menu row: {0:N2}:1 >= 4.5" -f $rh) ($rh -ge 4.5)
    }
}

# =====================================================================================
# F2 + F3: state cues inside the group flyout are measured against the FLYOUT's surface
# =====================================================================================
# The flyout surface (46,45,43) is lighter than the bar (29,29,28), and the bar's hover fill
# measured 1.04:1 on it - on a 27px icon with no label, where hover is the only signal that a
# member is live. The toggled fill measured 2.69:1 there, below the 3:1 a colour-only state cue
# needs. Every colour below is parsed from the source that uses it.
$flySurface = ArgbFrom 'public Color Surface = Color\.FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$flyHover     = ArgbFrom '\$colFlyHover\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$flyDown      = ArgbFrom '\$colFlyDown\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$flyHoverRing = ArgbFrom '\$colFlyHoverRing\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$flyDownRing  = ArgbFrom '\$colFlyDownRing\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$flyTogRing   = ArgbFrom '\$colFlyToggleRing\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
$iconGrey     = ArgbFrom '\$colIcon\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)'
Check 'every flyout state colour is parseable from source' `
    ($flySurface -and $flyHover -and $flyDown -and $flyHoverRing -and $flyDownRing -and $flyTogRing -and $iconGrey)
if ($flySurface -and $flyHoverRing -and $flyDownRing -and $flyTogRing -and $iconGrey -and $togFill) {
    # MUTATION: point $colFlyHoverRing back at $colHover (48,48,47) and this goes red at 1.04:1.
    $hr = Ratio $flyHoverRing $flySurface
    $dr = Ratio $flyDownRing $flySurface
    Check ("flyout HOVER ring against the flyout's own surface: {0:N2}:1 >= 3.0 (WCAG 1.4.11)" -f $hr) ($hr -ge 3.0)
    Check ("flyout PRESS ring against the flyout's own surface: {0:N2}:1 >= 3.0 (WCAG 1.4.11)" -f $dr) ($dr -ge 3.0)
    # Press must be distinguishable from hover, or the press cue says nothing new.
    Check ("the press ring is visibly brighter than the hover ring ({0:N2} vs {1:N2})" -f $dr, $hr) ($dr -ge $hr * 1.3)
    # MUTATION: set $colFlyToggleRing to Color.Empty / the ToggleFill and this goes red at 2.69:1.
    $tr = Ratio $flyTogRing $flySurface
    $trf = Ratio $flyTogRing $togFill
    Check ("flyout TOGGLE-ON ring against the flyout surface: {0:N2}:1 >= 3.0 (WCAG 1.4.11)" -f $tr) ($tr -ge 3.0)
    Check ("the toggle ring also separates from the toggle FILL: {0:N2}:1 >= 3.0" -f $trf) ($trf -ge 3.0)
    # The reason this is a RING and not simply a brighter fill. A fill that clears 3:1 against
    # the flyout surface reaches ~(120,117,112), and the icon glyph on top of it measures
    # 1.93:1 - the exact trap the ToggleFill comment describes. Pin the glyph legibility so a
    # future "just brighten the fill" change cannot pass.
    # MUTATION: set $colFlyHover to (120,117,112) and this goes red at 1.93:1.
    $gh = Ratio $iconGrey $flyHover
    $gd = Ratio $iconGrey $flyDown
    Check ("the icon glyph stays readable on the flyout hover fill: {0:N2}:1 >= 4.5" -f $gh) ($gh -ge 4.5)
    Check ("the icon glyph stays readable on the flyout press fill: {0:N2}:1 >= 4.5" -f $gd) ($gd -ge 4.5)
    # The ON state is still not user-colourable, and white-on-amber must stay where it was.
    Check ("toggle-ON label on the unchanged fill is still {0:N2}:1 >= 4.5" -f (Ratio $togFore $togFill)) `
        ((Ratio $togFore $togFill) -ge 4.5)
}
# The colours have to be WIRED to the flyout, not merely defined. The bar's own buttons must
# keep using the bar colours, so this is asserted as a pairing, not a global replace.
# MUTATION: revert the flyout member to $colHover/$colDown and the first check goes red.
$flyFn = [regex]::Match($srcText, '(?s)function Show-GroupFlyout.*?\n\}').Value
Check 'Show-GroupFlyout was located' ($flyFn.Length -gt 200)
Check 'flyout members take the flyout hover/press fills, not the bar''s' `
    ($flyFn -match '\$mb\.HoverFill = \$colFlyHover' -and $flyFn -match '\$mb\.DownFill = \$colFlyDown')
Check 'flyout members get hover, press AND toggle rings' `
    ($flyFn -match '\$mb\.HoverRing = \$colFlyHoverRing' -and
     $flyFn -match '\$mb\.DownRing = \$colFlyDownRing' -and
     $flyFn -match '\$mb\.ToggleRing = \$colFlyToggleRing')
Check 'the bar keeps its own hover colours (the flyout fix is not a global repaint)' `
    ($srcText -match '\$btn\.HoverFill = \$colHover')
# A ring drawn in only one paint path is invisible where it matters: the flyout composites
# through RenderTo (layered window), the bar through OnPaint.
# MUTATION: delete the ring block from RenderTo and this goes red.
$ringDraws = [regex]::Matches($srcText, 'Color (?:ring|ring2) = StateRing\(\);').Count
Check "the state ring is drawn in BOTH paint paths (found $ringDraws)" ($ringDraws -eq 2)
Check 'the ring precedence is press > hover > toggle' `
    ($srcText -match '(?s)Color StateRing\(\) \{\s*if \(down\) return DownRing;\s*if \(hover\) return HoverRing;\s*if \(toggled\) return ToggleRing;')
# Default Color.Empty means the bar opts out entirely and is pixel-identical to before.
Check 'the ring fields default to Color.Empty so the bar is unchanged' `
    ($srcText -match 'public Color HoverRing = Color\.Empty' -and
     $srcText -match 'public Color DownRing = Color\.Empty' -and
     $srcText -match 'public Color ToggleRing = Color\.Empty')

# --- The state ring must not OVERDRAW the per-chat accent (measured in PIXELS) ---
# Accent and ring both drew on rcEdge at 2f with the ring second, so on a flyout member that
# belongs to a chat, any hover/press/toggle painted the ring straight over the accent and the
# per-chat cue disappeared - at exactly the moment the user was about to click it.
# This is asserted by RENDERING, not by reading the source: a source-text check would pass
# against any expression that merely mentions Inflate. The button is composited onto an
# offscreen Bitmap - no window is created, shown, focused, or given input.
# MUTATION: drop the `if (Accent != Color.Empty)` inset line from RenderTo and this goes red
# (measured pre-fix: the outer edge pixel is the RING 236,200,130 and accent-ish pixels fall
# from 274 to 76, those 76 being corner anti-aliasing only).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$csBlock = [regex]::Match($srcText,
    '(?s)Add-Type -ReferencedAssemblies System\.Windows\.Forms, System\.Drawing -TypeDefinition @"\r?\n(.*?)\r?\n"@')
Check 'the panel C# block was located for offscreen rendering' ($csBlock.Success)
if ($csBlock.Success) {
    if (-not ('PillButton' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $csBlock.Groups[1].Value
    }
    # The real shipped colours, parsed out of source rather than retyped.
    $accentCol = [System.Drawing.Color]::FromArgb(198, 146, 78)
    $tRingCol  = [System.Drawing.Color]::FromArgb(236, 200, 130)
    $tFillCol  = [System.Drawing.Color]::FromArgb(144, 102, 36)
    $pb = New-Object PillButton
    $pb.Width = 27; $pb.Height = 27
    $pb.Accent = $accentCol
    $pb.ToggleRing = $tRingCol
    $pb.ToggleFill = $tFillCol
    # Toggled is a plain public property - no synthetic mouse input is involved anywhere here.
    $pb.Toggled = $true
    $bmp = New-Object System.Drawing.Bitmap 27, 27, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $pb.RenderTo($gfx, 0, 0)
    $gfx.Dispose()
    function Near-Color($p, $c, $tol) {
        ([Math]::Abs($p.R - $c.R) -le $tol) -and ([Math]::Abs($p.G - $c.G) -le $tol) -and ([Math]::Abs($p.B - $c.B) -le $tol)
    }
    # Mid-height on the left edge: straight vertical run, no corner rounding, no anti-aliasing.
    $edgePx = $bmp.GetPixel(0, 13)
    Check ("the accent survives on the OUTER edge under a toggle ring (got $($edgePx.R),$($edgePx.G),$($edgePx.B))") `
        (Near-Color $edgePx $accentCol 12)
    # ...and the ring is still drawn, just inset - both cues visible at once, which is the point.
    $ringSeen = $false
    foreach ($x in 2..5) { if (Near-Color ($bmp.GetPixel($x, 13)) $tRingCol 12) { $ringSeen = $true } }
    Check 'the state ring is still drawn, inset just inside the accent' $ringSeen
    # The two bands must not be ADJACENT. Ring and accent are only 1.73:1 apart, so a 1px inset
    # would read as a single thick band. There is no pure-FILL pixel between them - a 2f
    # antialiased pen bleeds into its neighbours, so x1/x2 are blends, measured, not assumed -
    # but the pure ring pixel must sit at least 3px in from the pure accent pixel.
    Check 'the ring does not touch the accent (no ring pixel in the outer 2px)' `
        (-not ((Near-Color ($bmp.GetPixel(0, 13)) $tRingCol 12) -or (Near-Color ($bmp.GetPixel(1, 13)) $tRingCol 12)))
    # Control: with NO accent the ring must still sit on the OUTER edge, so the bar and every
    # non-chat flyout member are unchanged by this fix.
    $pb2 = New-Object PillButton
    $pb2.Width = 27; $pb2.Height = 27
    $pb2.ToggleRing = $tRingCol; $pb2.ToggleFill = $tFillCol; $pb2.Toggled = $true
    $bmp2 = New-Object System.Drawing.Bitmap 27, 27, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gfx2 = [System.Drawing.Graphics]::FromImage($bmp2)
    $pb2.RenderTo($gfx2, 0, 0)
    $gfx2.Dispose()
    $edge2 = $bmp2.GetPixel(0, 13)
    Check ("with no accent the ring stays on the outer edge (got $($edge2.R),$($edge2.G),$($edge2.B))") `
        (Near-Color $edge2 $tRingCol 12)
    # The SAME assertion against the OTHER paint path. RenderTo composites the flyout; OnPaint
    # paints the bar. Only RenderTo can show a ring today (the bar leaves every ring Color.Empty),
    # but the ring block exists in both - see "the state ring is drawn in BOTH paint paths" above
    # - so the inset has to exist in both too, or the next control that sets a ring on the bar
    # silently loses its accent. Mutation proved this is not theoretical: with only the RenderTo
    # test, deleting the OnPaint inset left the suite fully green.
    # DrawToBitmap renders through OnPaint into a bitmap. No window is shown, focused or given
    # input; the control is never parented and never made visible.
    $pb3 = New-Object PillButton
    $pb3.Width = 27; $pb3.Height = 27
    $pb3.BackColor = [System.Drawing.Color]::FromArgb(46, 45, 43)
    $pb3.Accent = $accentCol; $pb3.ToggleRing = $tRingCol; $pb3.ToggleFill = $tFillCol
    $pb3.Toggled = $true
    $bmp3 = New-Object System.Drawing.Bitmap 27, 27
    $pb3.DrawToBitmap($bmp3, (New-Object System.Drawing.Rectangle 0, 0, 27, 27))
    $edge3 = $bmp3.GetPixel(0, 13)
    Check ("OnPaint keeps the accent on the outer edge too (got $($edge3.R),$($edge3.G),$($edge3.B))") `
        (Near-Color $edge3 $accentCol 12)
    $ring3 = $false
    foreach ($x in 2..5) { if (Near-Color ($bmp3.GetPixel($x, 13)) $tRingCol 12) { $ring3 = $true } }
    Check 'OnPaint still draws the ring, inset' $ring3
    $bmp3.Dispose(); $pb3.Dispose()

    $bmp.Dispose(); $bmp2.Dispose(); $pb.Dispose(); $pb2.Dispose()
}

# =====================================================================================
# F8: no unbounded debug line in a hover path
# =====================================================================================
# Show-GroupFlyout is bound to MouseEnter on every group button, and this line embedded changing
# screen coordinates, so Write-CkLog's identical-message dedupe never fired: the log grew with
# mouse movement alone. MUTATION: put the line back and this goes red.
Check 'the per-hover flyout geometry trace is gone from the log path' ($srcText -notmatch 'FLY btnW=')
# Count CALLS, not mentions: this file's own explanatory comments name the function too, and
# counting raw occurrences made the check depend on how the source is commented.
$flyLogCalls = @($flyFn -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'Write-CkLog' })
Check "Show-GroupFlyout logs nothing on the success path, only its catch (found $($flyLogCalls.Count))" `
    ($flyLogCalls.Count -eq 1 -and $flyLogCalls[0] -match 'catch')
# The dissolve action is a click handler, not a function, so it is extracted as the
# scriptblock argument of $miDissolve.add_Click({...}) and invoked as-is.
$dissolveNode = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq '$miDissolve' -and $n.Member.Extent.Text -eq 'add_Click' }, $true)
Check 'the dissolve click handler was located in the source' ($null -ne $dissolveNode -and $dissolveNode.Arguments.Count -eq 1)
$dissolveAction = if ($dissolveNode) { [scriptblock]::Create($dissolveNode.Arguments[0].ScriptBlock.EndBlock.Extent.Text) } else { $null }

# "Remove this button" is a click handler too, so it is extracted the same way. It is extracted
# rather than re-implemented on purpose: the removal is THE data-loss path in this file (no
# backup, no undo), and a fixture that reproduces its logic would keep passing while the shipped
# handler deleted the wrong rows - which is exactly what happened.
$removeNode = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq '$miRemove' -and $n.Member.Extent.Text -eq 'add_Click' }, $true)
Check 'the remove click handler was located in the source' ($null -ne $removeNode -and $removeNode.Arguments.Count -eq 1)
$removeAction = if ($removeNode) { [scriptblock]::Create($removeNode.Arguments[0].ScriptBlock.EndBlock.Extent.Text) } else { $null }

# Drive a real transform against a throwaway buttons.json and return the config AS WRITTEN
# TO DISK. Reading back the file rather than the in-memory return value is deliberate: a
# transform that corrupts what gets persisted is the damaging failure, and the previous
# fixtures could not see the file at all.
# LOCALAPPDATA/USERPROFILE are redirected like every other harness here - tests once appended
# to the developer's real log and once overwrote their install marker.
function Invoke-PanelEdit {
    param([string]$Json, $Target, [scriptblock]$Action)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("cb-tf-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $prevLocal = $env:LOCALAPPDATA; $prevHome = $env:USERPROFILE
    $script:configPath = Join-Path $dir 'buttons.json'
    [IO.File]::WriteAllText($script:configPath, $Json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $env:LOCALAPPDATA = $dir; $env:USERPROFILE = $dir
        $script:config = Read-FreshConfig
        $script:menuSource = [pscustomobject]@{ Tag = $Target }
        $script:rebuilt = 0
        # $Target is evaluated by the CALLER, before $script:config exists, so it can only ever
        # be a synthetic stand-in. An Action that needs the REAL array element (to exercise the
        # reference-identity hint) reassigns $script:menuSource itself - it runs after the load.
        $script:warned = @()
        $ret = & $Action
        $raw = Get-Content $script:configPath -Raw
        [pscustomobject]@{ Cfg = ($raw | ConvertFrom-Json); Raw = $raw; Ret = $ret
                           Rebuilt = $script:rebuilt; Warned = @($script:warned) }
    } finally {
        $env:LOCALAPPDATA = $prevLocal; $env:USERPROFILE = $prevHome
        $script:menuSource = $null
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Labels($cfg) { (@($cfg.buttons) | ForEach-Object { $_.label }) -join ',' }
# The standard four-button fixture: a plain button, a two-member group, a plain button.
$fixJson = '{"schemaVersion":1,"buttons":[
    {"label":"A","text":"/a"},
    {"label":"G1","text":"/g1","group":"grp"},
    {"label":"G2","text":"/g2","group":"grp"},
    {"label":"B","text":"/b"}],"groups":{"grp":{"icon":"note"}}}'
$grpTarget = [pscustomobject]@{ __isGroup = $true; group = 'grp'; label = 'grp' }

# --- Get-ButtonBlocks: a group is ONE block ---
$cfgObj = (($fixJson | ConvertFrom-Json).buttons)
$blocks = @(Get-ButtonBlocks $cfgObj)
Check 'a group collapses to one block (A, grp, B)' ($blocks.Count -eq 3 -and $blocks[1].key -eq 'g:grp' -and $blocks[1].items.Count -eq 2)

# --- Ordering: groups move as ONE block, through the REAL Move-PinButton ---
# Left/right used to swap two adjacent array entries. Once a group could span several entries
# that was wrong twice over: moving a group dragged a single member out of it, and moving a
# plain button past a group landed it in the group's middle. Both silently lose a button.
$r = Invoke-PanelEdit $fixJson $grpTarget { Move-PinButton -1 }
Check 'moving a group left keeps its members together' ((Labels $r.Cfg) -eq 'G1,G2,A,B')
# Catches: Move-PinButton emitting only $blk.items[0], which drops every member but the first.
Check 'moving a group never loses a button' (@($r.Cfg.buttons).Count -eq 4)
# Catches: an injected early `return` making the whole feature a silent no-op. Move-PinButton
# returns nothing, so the observable proof of a real write is that it rebuilt the strips AND
# that the order on disk differs from the order that was seeded.
Check 'moving a group actually writes the new order to disk' `
    (($r.Rebuilt -gt 0) -and ((Labels $r.Cfg) -ne 'A,G1,G2,B'))

$r = Invoke-PanelEdit $fixJson $grpTarget { Move-PinButton 1 }
# Catches: the direction reversed ($bi + $dir -> $bi - $dir). Left and right must differ.
Check 'moving a group right jumps the whole block past B' ((Labels $r.Cfg) -eq 'A,B,G1,G2')

# Catches: the out-of-range guard changed from a no-op into a clamp, which truncates the bar.
$r = Invoke-PanelEdit $fixJson $grpTarget { Move-PinButton -99 }
Check 'an out-of-range move is a no-op, not a truncation' `
    ((@($r.Cfg.buttons).Count -eq 4) -and ((Labels $r.Cfg) -eq 'A,G1,G2,B'))
$r = Invoke-PanelEdit $fixJson $grpTarget { Move-PinButton 99 }
Check 'an out-of-range move the other way is a no-op too' ((Labels $r.Cfg) -eq 'A,G1,G2,B')

# A plain button is identified by VALUE, a group by name - two different branches of the
# block search, so the plain-button path needs its own case.
$plain = [pscustomobject]@{ label = 'B'; text = '/b' }
$r = Invoke-PanelEdit $fixJson $plain { Move-PinButton -1 }
Check 'a plain button moved left jumps the whole group, not into it' ((Labels $r.Cfg) -eq 'A,B,G1,G2')

# --- Move-GroupMember: reordering INSIDE a group ---
# Same gesture, different neighbours. Nothing referenced this function at all, so an early
# `return` killed reordering within every flyout with a green suite.
$mem = [pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' }
$r = Invoke-PanelEdit $fixJson $mem { Move-GroupMember $script:menuSource.Tag 1 }
Check 'a group member moves down within its group' ((Labels $r.Cfg) -eq 'A,G2,G1,B')
Check 'reordering within a group is persisted (not a no-op)' ($r.Ret -eq $true)
Check 'reordering within a group loses nobody' (@($r.Cfg.buttons).Count -eq 4)
$r = Invoke-PanelEdit $fixJson $mem { Move-GroupMember $script:menuSource.Tag -1 }
Check 'the first member of a group cannot move further up' ((Labels $r.Cfg) -eq 'A,G1,G2,B')
# Members must move among THEMSELVES, never past the ungrouped neighbours.
$r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'G2'; text = '/g2'; group = 'grp' }) { Move-GroupMember $script:menuSource.Tag 1 }
Check 'the last member of a group does not swap with the button after it' ((Labels $r.Cfg) -eq 'A,G1,G2,B')

# --- Same-Button identity is CASE-SENSITIVE ---
# The old fixture here re-implemented Same-Button with -eq. The shipped function uses -ceq
# DELIBERATELY: -eq once matched "Deploy"/"/deploy prod" against a genuinely different button
# "deploy"/"/DEPLOY PROD" and deleted the wrong one, with no backup and no undo. So the
# fixture asserted the exact OPPOSITE of shipped behaviour and would have gone green on the
# revert. These call the real function.
# NOTE: PowerShell variable names are themselves case-INSENSITIVE, so $bDeploy and $bdeploy
# are ONE variable - the first draft of these checks compared a button with itself and the
# case tests passed for the wrong reason. Hence the deliberately distinct names.
$upperB = [pscustomobject]@{ label = 'Deploy'; text = '/deploy prod' }
$lowerB = [pscustomobject]@{ label = 'deploy'; text = '/DEPLOY PROD' }
Check 'Same-Button matches a button with itself' (Same-Button $upperB $upperB)
Check 'Same-Button does NOT match on label case alone (-ceq, not -eq)' (-not (Same-Button $upperB $lowerB))
Check 'Same-Button does not match on text case alone' `
    (-not (Same-Button $upperB ([pscustomobject]@{ label = 'Deploy'; text = '/DEPLOY PROD' })))
Check 'Same-Button does not match on label case alone with identical text' `
    (-not (Same-Button $upperB ([pscustomobject]@{ label = 'deploy'; text = '/deploy prod' })))
# chat scoping is part of identity: the same label+text pinned to two chats is two buttons.
Check 'Same-Button separates two chat-scoped buttons that differ only by chat' `
    (-not (Same-Button ([pscustomobject]@{ label = 'C'; text = '/c'; chat = 'one' }) ([pscustomobject]@{ label = 'C'; text = '/c'; chat = 'two' })))
Check 'Same-Button treats chat case-sensitively too' `
    (-not (Same-Button ([pscustomobject]@{ label = 'C'; text = '/c'; chat = 'Sess' }) ([pscustomobject]@{ label = 'C'; text = '/c'; chat = 'sess' })))
# And end-to-end through a transform that DELETES: a wrong-case target must change nothing.
$casedJson = '{"buttons":[{"label":"Deploy","text":"/deploy prod"},{"label":"deploy","text":"/DEPLOY PROD"}]}'
$r = Invoke-PanelEdit $casedJson ([pscustomobject]@{ label = 'deploy'; text = '/DEPLOY PROD' }) { Set-ButtonBar $script:menuSource.Tag 'left' }
Check 'a case-differing sibling is NOT dragged along by a bar move' `
    ((@($r.Cfg.buttons | Where-Object { $_.bar -eq 'left' }).Count) -eq 1 -and (@($r.Cfg.buttons | Where-Object { $_.label -ceq 'deploy' })[0].bar -eq 'left'))

# --- Bars: a button assigned to a side must LEAVE the control row ---
# The row strip and the side strips share one visibility filter. If the row stopped filtering on
# bar, a side button would render twice - once in the row and once in the margin.
$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a"}, {"label":"B","text":"/b","bar":"left"} ] }'
Check 'a left-bar button is not drawn in the control row' ((Buttons $r.Out) -eq 1)

$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a","bar":"left"}, {"label":"B","text":"/b","bar":"right"} ] }'
Check 'both sides empty the row entirely' ((Buttons $r.Out) -eq 0 -and $r.Code -eq 0)

$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a","bar":"nonsense"} ] }'
Check 'an unknown bar value falls back to the row, not nowhere' ((Buttons $r.Out) -eq 1)

$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a"}, {"label":"B","text":"/b"} ] }'
Check 'no bar field = every button stays in the row (back-compat)' ((Buttons $r.Out) -eq 2)

# --- Strip index -> pane index must TRUNCATE, not round ---
# Two side strips per pane, so strip i belongs to pane i/2. PowerShell's [int] rounds half away
# to even, so [int](3/2) is 2, not 1 - strip 3 was paired with the wrong pane, leaving one pane
# with no right bar while its neighbour drew two in the same place. Pure integer logic, and the
# symptom (a bar missing in SOME chats) looks nothing like an arithmetic bug, so pin it.
#
# DELETED HERE: two loops that compared [Math]::Floor against [Math]::Truncate and [int]
# against [Math]::Truncate. They never referenced the panel in any way - they asserted that
# .NET is .NET, and would have stayed green with the whole side-strip feature deleted.
#
# ALSO DELETED: `the source uses Floor for the strip->pane map`, which selected lines matching
# the literal '$pIdx = ' and required none of them to lack Floor. Rename the variable and ZERO
# lines are selected, so the check passed VACUOUSLY - verified by reintroducing the rounding
# bug together with a rename, which left the whole suite green.
#
# The map is computed inside a GUI tick that needs live Claude panes, so it cannot be called
# from here. Instead the index sites are DISCOVERED from the AST - every place the code indexes
# $script:panes - and the expression that produced each index is pulled out of the source and
# EVALUATED. A rename cannot hide from this, because the name is read off the indexing site
# rather than written down here; and zero sites is a FAILURE, not a pass.
$paneIdxUses = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.IndexExpressionAst] -and
    $n.Target.Extent.Text -eq '$script:panes' }, $true))
Check "the strip->pane index sites were found in the source (found $($paneIdxUses.Count))" ($paneIdxUses.Count -ge 1)
# $script:panes is indexed by several unrelated loops too. The strip->pane map is the subset
# whose index variable is computed by halving something - that is the arithmetic under test,
# and it is identified by its SHAPE, so renaming the variable cannot hide it.
$idxVarNames = @($paneIdxUses | ForEach-Object { $_.Index.Extent.Text } |
                 Where-Object { $_ -match '^\$[A-Za-z_]\w*$' } | Sort-Object -Unique)
$mapExprs = @()
foreach ($vn in $idxVarNames) {
    $mapExprs += @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq $vn -and $n.Right.Extent.Text -match '/\s*2\b' }, $true) |
        ForEach-Object { $_.Right.Extent.Text })
}
$mapExprs = @($mapExprs | Sort-Object -Unique)
# Two side strips per pane means there must be at least one such halving. Zero is a FAILURE -
# the whole point of replacing the old grep is that an empty selection can no longer pass.
Check "the strip->pane halving expressions were found (found $($mapExprs.Count): $($mapExprs -join ' ; '))" `
    ($mapExprs.Count -ge 1)
# Evaluate the SHIPPED expression for strips 0..11. Two side strips per pane, so strip i must
# map to pane i\2 - truncating. [int](3/2) is 2 in PowerShell (round-half-to-even), which
# paired strip 3 with the wrong pane: one pane got no right bar while its neighbour drew two.
$mapBad = @()
foreach ($ex in $mapExprs) {
    # Normalise whichever loop variable this site uses ($i, $si, ...) to one we control.
    # '$$' escapes to a literal '$' in a .NET replacement - a bare '$_' means "the whole input"
    # and spliced the entire expression back into itself.
    $probe = [regex]::Replace($ex, '\$[A-Za-z_]\w*', '$$__k')
    for ($k = 0; $k -lt 12; $k++) {
        $__k = $k
        $got = & ([scriptblock]::Create($probe))
        if ($got -ne [Math]::Truncate($k / 2)) { $mapBad += "$ex : i=$k gave $got, want $([Math]::Truncate($k / 2))" }
    }
}
Check ("the shipped strip->pane expression truncates for every strip 0..11" + $(if ($mapBad) { ": $($mapBad[0])" } else { '' })) `
    ($mapBad.Count -eq 0)

# --- Reordering is per-bar ---
# The bars share one array. Ordering across the whole of it would let a move on the row
# reshuffle the side bars, or land a row button in the middle of a side bar's run.
# These used to run against a local Reorder-InBar / Get-ButtonBar copied out of the source.
# They now drive the real Move-PinButton, so the per-bar restriction is genuinely covered.
$mixJson = '{"buttons":[
    {"label":"R1","text":"/r1"},
    {"label":"L1","text":"/l1","bar":"left"},
    {"label":"R2","text":"/r2"},
    {"label":"L2","text":"/l2","bar":"left"}]}'
$tL1 = [pscustomobject]@{ label = 'L1'; text = '/l1'; bar = 'left' }
$tR1 = [pscustomobject]@{ label = 'R1'; text = '/r1' }
$r = Invoke-PanelEdit $mixJson $tL1 { Move-PinButton 1 }
Check 'moving a left-bar button reorders only the left bar' ((Labels $r.Cfg) -eq 'R1,L2,R2,L1')
Check 'the row buttons keep their own positions' `
    (((@($r.Cfg.buttons | Where-Object { -not $_.bar }) | ForEach-Object { $_.label }) -join ',') -eq 'R1,R2')
$r = Invoke-PanelEdit $mixJson $tR1 { Move-PinButton 1 }
Check 'moving a row button does not disturb the side bar' `
    (((@($r.Cfg.buttons | Where-Object { $_.bar }) | ForEach-Object { $_.label }) -join ',') -eq 'L1,L2')
Check 'moving a row button does move it' ((Labels $r.Cfg) -eq 'R2,L1,R1,L2')
$r = Invoke-PanelEdit $mixJson $tL1 { Move-PinButton -1 }
Check 'the first button on a bar cannot move further down' ((Labels $r.Cfg) -eq 'R1,L1,R2,L2')
# Get-ButtonBar itself, called directly: an unknown value must fall back to the row rather
# than to nothing, or the button renders on no bar at all and looks deleted.
Check 'Get-ButtonBar accepts the three real bars' `
    (((Get-ButtonBar ([pscustomobject]@{ bar = 'left' })) -eq 'left') -and
     ((Get-ButtonBar ([pscustomobject]@{ bar = 'right' })) -eq 'right') -and
     ((Get-ButtonBar ([pscustomobject]@{ bar = 'row' })) -eq 'row'))
Check 'Get-ButtonBar falls back to row for an unset or nonsense bar' `
    (((Get-ButtonBar ([pscustomobject]@{ label = 'x' })) -eq 'row') -and
     ((Get-ButtonBar ([pscustomobject]@{ bar = 'nonsense' })) -eq 'row'))

# --- An empty group definition must not survive ---
# Groups live in config.groups, keyed by name, but a group exists only through its members.
# When the last member left, the orphaned icon/label stayed and kept appearing in
# "Move to group" as a group that renders nowhere. A config carrying such an orphan must still
# load, and the group must not be treated as real.
$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a"} ], "groups": { "ghost": { "icon": "note", "label": "Ghost" } } }'
Check 'a config with an orphaned group def still loads' (($r.Out -match 'SMOKE-OK') -and $r.Code -eq 0)
Check 'the orphan does not become a button' ((Buttons $r.Out) -eq 1)

$r = Run-Smoke '{ "buttons": [ {"label":"A","text":"/a","group":"g"} ], "groups": { "g": { "icon": "note" } } }'
Check 'a group WITH a member collapses its member behind one face' ((Buttons $r.Out) -eq 1)

# --- Moving to a bar lands at the END of that bar's run ---
# Setting the bar field alone left the button wherever it already sat in the array. Bars render
# in array order, so a button moved to a side bar arrived at the BOTTOM and shoved everything
# already there upward, reading as an insert rather than an addition.
# Through the real Set-ButtonBar. The local Move-ToBar this replaces was a hand-copy that
# omitted both of Set-ButtonBar's group rules, so neither was covered at all - and an early
# `return` injected into Set-ButtonBar killed the whole feature with a green suite.
$barJson = '{"buttons":[
    {"label":"X","text":"/x"},
    {"label":"L1","text":"/l1","bar":"left"},
    {"label":"L2","text":"/l2","bar":"left"},
    {"label":"Y","text":"/y"}]}'
$tX = [pscustomobject]@{ label = 'X'; text = '/x' }
$tY = [pscustomobject]@{ label = 'Y'; text = '/y' }
$r = Invoke-PanelEdit $barJson $tX { Set-ButtonBar $script:menuSource.Tag 'left' }
$onLeft = @($r.Cfg.buttons | Where-Object { $_.bar -eq 'left' } | ForEach-Object { $_.label })
Check 'a button moved to a side bar lands last, not first' (($onLeft -join ',') -eq 'L1,L2,X')
Check 'nothing is lost in the move' (@($r.Cfg.buttons).Count -eq 4)
# Catches an injected early `return`: the move must reach disk, not just return quietly.
Check 'the bar move is persisted to disk' ($r.Rebuilt -gt 0 -and (Labels $r.Cfg) -eq 'L1,L2,X,Y')
$r = Invoke-PanelEdit $barJson $tY { Set-ButtonBar $script:menuSource.Tag 'right' }
Check 'the first button on an empty bar still lands there' `
    ((@($r.Cfg.buttons | Where-Object { $_.bar -eq 'right' }).Count) -eq 1)
# Moving back to the row must REMOVE the field, not set it to the string 'row' - Get-ButtonBar
# would still work, but the config grows a knob the user never chose.
$r = Invoke-PanelEdit $barJson ([pscustomobject]@{ label = 'L1'; text = '/l1'; bar = 'left' }) { Set-ButtonBar $script:menuSource.Tag 'row' }
Check 'moving back to the row drops the bar field entirely' `
    ((@($r.Cfg.buttons | Where-Object { $_.label -ceq 'L1' })[0].PSObject.Properties['bar']) -eq $null)
# A move that matches nothing must be a no-op, never an empty bar array.
$r = Invoke-PanelEdit $barJson ([pscustomobject]@{ label = 'Ghost'; text = '/ghost' }) { Set-ButtonBar $script:menuSource.Tag 'right' }
Check 'a bar move that matches no button changes nothing' ((Labels $r.Cfg) -eq 'X,L1,L2,Y')

# Group rules on Set-ButtonBar - neither was covered by the hand-copy, which had no notion
# of groups at all.
# (a) Moving a GROUP takes every member, or the group splits across two bars.
$r = Invoke-PanelEdit $fixJson $grpTarget { Set-ButtonBar $script:menuSource.Tag 'right' }
Check 'moving a group to a bar takes ALL its members' `
    ((@($r.Cfg.buttons | Where-Object { $_.bar -eq 'right' }).Count) -eq 2)
Check 'the moved group members keep their group' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'grp' }).Count) -eq 2)
# (b) Moving ONE member out of a group takes it OUT of the group. Keeping the field would
# collapse it straight back behind the group face on the new bar, so the move would look
# like it silently did nothing.
$r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' }) { Set-ButtonBar $script:menuSource.Tag 'left' }
$g1 = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'G1' })[0]
Check 'a single member moved to a bar leaves its group' ($g1.bar -eq 'left' -and -not $g1.group)
Check 'the other member stays behind, still grouped' `
    (((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'grp' }) | ForEach-Object { $_.label }) -join ',') -eq 'G2')

# --- Dissolving a group leaves its members where they were ---
# Members already carry the group's bar and already occupy the group face's slot in the array,
# so dropping the group field must be enough. If it were not, dissolving would scatter the
# buttons back to the control row.
# The local Dissolve this replaces was a hand-copy; the shipped handler additionally stripping
# `bar` (which scatters every member back to the control row) passed the whole suite.
$dissJson = '{"buttons":[
    {"label":"A","text":"/a"},
    {"label":"G1","text":"/g1","group":"g","bar":"right"},
    {"label":"G2","text":"/g2","group":"g","bar":"right"},
    {"label":"B","text":"/b"}],"groups":{"g":{"icon":"note","label":"G"}}}'
# Dissolve now takes TWO clicks (see the confirm section below), so the behaviour tests drive
# it twice. Both clicks go through the SHIPPED handler - nothing here re-implements the arming.
$dissolveTwice = { $script:dissolveArmedFor = $null; & $dissolveAction; & $dissolveAction }
$r = Invoke-PanelEdit $dissJson ([pscustomobject]@{ __isGroup = $true; group = 'g' }) $dissolveTwice
$d = @($r.Cfg.buttons)
Check 'dissolving keeps the members on their bar' ((@($d | Where-Object { $_.bar -eq 'right' }).Count) -eq 2)
Check 'dissolving keeps them in the group face position' (((($d | ForEach-Object { $_.label }) -join ',')) -eq 'A,G1,G2,B')
Check 'no member is left claiming the group' ((@($d | Where-Object { $_.group }).Count) -eq 0)
Check 'they are now separate blocks, not one' ((@(Get-ButtonBlocks $d).Count) -eq 4)
# Dissolve must be a real write, not a quiet no-op.
Check 'the dissolve reached disk' ($r.Rebuilt -gt 0)
# ...and the now-memberless group definition must be pruned by Update-Buttons, or it keeps
# appearing in "Move to group" as a group that renders nowhere.
Check 'dissolving prunes the orphaned group definition' `
    (-not ($r.Cfg.PSObject.Properties['groups'] -and $r.Cfg.groups.PSObject.Properties['g']))
# A dissolve aimed at a non-group target must do nothing at all (the handler guards on
# __isGroup; without the guard a plain right-click would dissolve whatever it landed on).
$r = Invoke-PanelEdit $dissJson ([pscustomobject]@{ label = 'A'; text = '/a' }) $dissolveTwice
Check 'dissolve on a non-group target changes nothing' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' }).Count) -eq 2)

# --- F4: dissolve is destructive, so it takes TWO clicks (the /clear convention) ---
# One click dropped `group` from every member and the orphan prune then permanently discarded
# the group's custom icon and label - recoverable only by recreating both by hand - from a menu
# item sitting directly above "Remove this button". /clear ships with confirm = $true for
# exactly this reason, so dissolve follows the same rule.
$grpT = [pscustomobject]@{ __isGroup = $true; group = 'g' }
$r = Invoke-PanelEdit $dissJson $grpT { $script:dissolveArmedFor = $null; & $dissolveAction }
# MUTATION: delete the arming branch from the handler and this goes red (it dissolves at once).
Check 'ONE click on dissolve changes nothing on disk' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' }).Count) -eq 2)
Check 'ONE click on dissolve does not write at all' ($r.Rebuilt -eq 0)
Check 'the first click relabels the item to the confirm caption' ($script:dissolveLabel -eq 'confirm')
# MUTATION: make the second click arm again (never clear $dissolveArmedFor) and this goes red.
$r = Invoke-PanelEdit $dissJson $grpT $dissolveTwice
Check 'the SECOND click within the window actually dissolves' `
    ((@($r.Cfg.buttons | Where-Object { $_.group }).Count) -eq 0)
Check 'the caption returns to the dissolve label once it fires' ($script:dissolveLabel -eq 'dissolve')
# The window is 3 s, like the button path. An arm older than that must re-arm, not fire.
# MUTATION: drop the elapsed-time test from the guard and this goes red.
$r = Invoke-PanelEdit $dissJson $grpT {
    $script:dissolveArmedFor = $null
    & $dissolveAction
    $script:dissolveArmedAt = (Get-Date).AddSeconds(-10)   # the arm goes stale
    & $dissolveAction
}
Check 'a STALE arm re-arms instead of dissolving' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' }).Count) -eq 2)
# Arming on one group must not fire on a DIFFERENT one - the menu is rebuilt per right-click and
# $menuSource changes under it. MUTATION: compare only the timestamp and this goes red.
$twoGrpJson = '{"buttons":[
    {"label":"P","text":"/p","group":"g"},
    {"label":"Q","text":"/q","group":"h"}],"groups":{"g":{"icon":"note"},"h":{"icon":"star"}}}'
$r = Invoke-PanelEdit $twoGrpJson ([pscustomobject]@{ __isGroup = $true; group = 'g' }) {
    $script:dissolveArmedFor = $null
    & $dissolveAction                                        # arms group g
    $script:menuSource = [pscustomobject]@{ Tag = [pscustomobject]@{ __isGroup = $true; group = 'h' } }
    & $dissolveAction                                        # ...must only ARM h, not dissolve it
}
Check 'an arm on one group does not dissolve a different group' `
    ((@($r.Cfg.buttons | Where-Object { $_.group }).Count) -eq 2)
# The confirm caption must exist in BOTH language tables (it is reused from the button path).
foreach ($lang in @('en', 'da')) {
    $tbl = [regex]::Match($srcText, "(?s)\b$lang = @\{(.*?)\n    \}").Groups[1].Value
    Check "the '$lang' string table has a confirm caption for the dissolve prompt" ($tbl -match "(?m)^\s*confirm\s*=")
    Check "the '$lang' string table still has the dissolve caption" ($tbl -match "(?m)^\s*dissolve\s*=")
}
# The arming click must not let the menu close, or the "Confirm?" caption is painted onto a
# menu that is already going away and there is nothing left to click.
# MUTATION: delete the Closing handler and this goes red.
$closingFn = [regex]::Match($srcText, '(?s)\$btnMenu\.add_Closing\(\{.*?\n\}\)').Value
Check 'the button menu Closing handler was located' ($closingFn.Length -gt 60)
Check 'the button menu cancels its close while a dissolve is armed' `
    ($closingFn -match 'ItemClicked' -and $closingFn -match '\$_\.Cancel = \$true')
Check 'any other close reason disarms the pending dissolve' `
    ($closingFn -match '(?s)\}\s*else\s*\{\s*\$script:dissolveArmedFor = \$null')
# The hold must be consumed by the ONE click that set it. Cancelling on "an arm is pending"
# instead would swallow the next click on any OTHER item too - the menu would refuse to close
# when the user gave up on dissolving and picked Rename instead.
# MUTATION: cancel on $script:dissolveArmedFor rather than the one-shot flag, or drop the
# `$script:dissolveHoldOpen = $false` line inside the cancel branch, and this goes red.
Check 'the menu is held open for exactly one click, not for as long as the arm lasts' `
    ($closingFn -match '\$script:dissolveHoldOpen' -and
     $closingFn -match '(?s)\$script:dissolveHoldOpen -and.*?\$script:dissolveHoldOpen = \$false\s*[^\r\n]*\r?\n\s*\$_\.Cancel = \$true')
Check 'the one-shot hold flag is armed by the dissolve handler itself' `
    ($srcText -match '\$script:dissolveHoldOpen = \$true')
# Reopening must clear BOTH the arm and the one-shot hold, or a stale hold swallows the first
# click of the next menu session.
$openingFn = [regex]::Match($srcText, '(?s)\$btnMenu\.add_Opening\(\{.*?\n\}\)').Value
Check 'the button menu Opening handler was located' ($openingFn.Length -gt 60)
Check 'reopening the button menu clears any pending dissolve arm' `
    ($openingFn -match '\$script:dissolveArmedFor = \$null')
Check 'reopening the button menu also clears the one-shot hold flag' `
    ($openingFn -match '\$script:dissolveHoldOpen = \$false')

# --- Update-Buttons prunes orphaned group definitions (whatever emptied them) ---
# The prune lives in Update-Buttons so EVERY path that edits buttons is covered. Gutting it
# left the suite green: the only test that touched orphans was a smoke run asserting a config
# containing one still LOADS, which says nothing about whether it is removed.
$orphanJson = '{"buttons":[{"label":"A","text":"/a","group":"g"},{"label":"B","text":"/b"}],
                "groups":{"g":{"icon":"note"},"keep":{"icon":"star"}}}'
# Move A out of group g by dropping its group field via the real Set-ButtonGroup.
$r = Invoke-PanelEdit $orphanJson ([pscustomobject]@{ label = 'A'; text = '/a'; group = 'g' }) { Set-ButtonGroup '' }
Check "the last member leaving a group prunes its definition" `
    (-not ($r.Cfg.groups.PSObject.Properties['g']))
# ...but the prune must be membership-driven, not "delete every group". 'keep' has no members
# in this config either, so this pair also pins that an orphan is orphaned BY MEMBERSHIP:
Check 'a group definition with no members anywhere is pruned too (both are orphans here)' `
    (-not ($r.Cfg.groups.PSObject.Properties['keep']))
# The complement: a group that still HAS a member must survive the prune.
$r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'A'; text = '/a' }) { Set-ButtonGroup 'grp' }
Check 'a group with live members is NOT pruned' ([bool]$r.Cfg.groups.PSObject.Properties['grp'])

# --- Set-ButtonGroup: joining and leaving a group ---
# Zero references from the tests before this. An early `return` was a silent no-op.
Check 'joining a group is written to disk' `
    (((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'grp' }) | ForEach-Object { $_.label }) -join ',') -eq 'A,G1,G2')
$r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' }) { Set-ButtonGroup '' }
$g1 = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'G1' })[0]
Check 'leaving a group removes the field rather than blanking it' `
    (($null -eq $g1.PSObject.Properties['group']) -and (@($r.Cfg.buttons).Count -eq 4))
# A group face is not itself groupable: the guard must hold, or a group could be nested into
# a group and neither would render.
$r = Invoke-PanelEdit $fixJson $grpTarget { Set-ButtonGroup 'other' }
Check 'a group face cannot be put into a group' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'other' }).Count) -eq 0)
# Case-sensitivity again, end to end: grouping "Deploy" must not also group "deploy".
$r = Invoke-PanelEdit $casedJson ([pscustomobject]@{ label = 'Deploy'; text = '/deploy prod' }) { Set-ButtonGroup 'g' }
Check 'grouping is case-sensitive (only the exact button joins)' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' }).Count) -eq 1)

# =====================================================================================
# F5: GROUP NAMES are matched case-INSENSITIVELY - the opposite of Same-Button, on purpose
# =====================================================================================
# The decision and its justification live in the Resolve-GroupName comment. In short: a button's
# label+text IS the prompt, so -ceq; a group name is a folder label AND a JSON key, and PS 5.1's
# ConvertFrom-Json THROWS on an object whose keys differ only in case. A case-SENSITIVE group
# would let the panel write a buttons.json it can never read back - every button gone, silently.
# The tests below pin both halves: the merge happens, and it is NOT silent (the name snaps onto
# the casing that already exists, so the user lands in the group they can see).
$caseGrpJson = '{"buttons":[
    {"label":"M","text":"/m","group":"Deploy"},
    {"label":"N","text":"/n"}],"groups":{"Deploy":{"icon":"note","label":"Deploy"}}}'
# MUTATION: make Resolve-GroupName return $name unchanged and this goes red - the button gets
# a second group literally spelled "deploy" and the config now holds two case-colliding names.
$r = Invoke-PanelEdit $caseGrpJson ([pscustomobject]@{ label = 'N'; text = '/n' }) { Set-ButtonGroup 'deploy' }
$nBtn = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'N' })[0]
Check 'joining "deploy" snaps onto the existing "Deploy" casing' ($nBtn.group -ceq 'Deploy')
Check 'both buttons end up in ONE group, not two that look identical' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'Deploy' }).Count) -eq 2)
Check 'no second case-differing group name is created' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'deploy' }).Count) -eq 0)
# Resolve-GroupName is the single point of that decision, so exercise it directly too.
$script:config = $caseGrpJson | ConvertFrom-Json
Check 'Resolve-GroupName maps a differently-cased name onto the existing one' `
    ((Resolve-GroupName 'DEPLOY') -ceq 'Deploy')
Check 'Resolve-GroupName leaves a genuinely new name alone' ((Resolve-GroupName 'Ship') -ceq 'Ship')
Check 'Resolve-GroupName passes an empty name straight through' ((Resolve-GroupName '') -eq '')

# The failure this is really guarding: Set-GroupProp is the only path that mints a key under
# config.groups, and it must never write a second key differing only in case. The proof is a
# real round-trip - PS 5.1 THROWS on parse, so if a collision were written, ConvertFrom-Json
# on the file would fail and buttons.json would be permanently unreadable.
# MUTATION: drop the $key resolution loop from Set-GroupProp (Add-Member on $name directly) and
# the round-trip below throws and this goes red.
$r = Invoke-PanelEdit $caseGrpJson ([pscustomobject]@{ label = 'N'; text = '/n' }) {
    Set-GroupProp 'deploy' 'icon' 'star'
}
$roundTripped = $true
try { [void]($r.Raw | ConvertFrom-Json) } catch { $roundTripped = $false }
Check 'setting a group property under a different casing still round-trips through ConvertFrom-Json' $roundTripped
$grpKeys = @($r.Cfg.groups.PSObject.Properties.Name)
Check "config.groups holds ONE key for the group, not two ($($grpKeys -join '/'))" ($grpKeys.Count -eq 1)
Check 'the surviving key keeps the casing that was already there' ($grpKeys[0] -ceq 'Deploy')
Check 'the property was applied to that existing group, not a new one' ($r.Cfg.groups.Deploy.icon -ceq 'star')
# And the render side reads the definition case-insensitively too, so nothing falls back to the
# generic face just because the button's field is cased differently from the definition key.
$script:config = $r.Cfg
Check 'Get-GroupDef resolves a differently-cased name to the same definition' `
    ((Get-GroupDef 'DEPLOY').icon -ceq 'star')
# Get-GroupNames must not list the same group twice under two casings.
$script:config = '{"buttons":[{"label":"M","text":"/m","group":"deploy"}],"groups":{"Deploy":{"icon":"note"}}}' | ConvertFrom-Json
Check 'Get-GroupNames lists a case-differing pair as ONE group' ((@(Get-GroupNames)).Count -eq 1)

# =====================================================================================
# F6: "Move to group" must not split a group across two bars
# =====================================================================================
# Set-ButtonGroup used to set only `group`, never `bar` - unlike Set-ButtonBar, which moves the
# whole membership precisely so a group cannot straddle two bars. Joining a row-bar button to a
# left-bar group created exactly that split, and the two strips then disagreed about the group's
# membership, so it rendered a different face on each and its members appeared twice.
$splitJson = '{"buttons":[
    {"label":"S1","text":"/s1","group":"g","bar":"left"},
    {"label":"S2","text":"/s2","group":"g","bar":"left"},
    {"label":"R","text":"/r"}],"groups":{"g":{"icon":"note"}}}'
# MUTATION: delete the $destBar block from Set-ButtonGroup and this goes red - R joins the group
# while staying on the control row.
$r = Invoke-PanelEdit $splitJson ([pscustomobject]@{ label = 'R'; text = '/r' }) { Set-ButtonGroup 'g' }
$rBtn = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'R' })[0]
Check 'joining a side-bar group moves the joiner onto that bar' ($rBtn.bar -ceq 'left')
Check 'the whole group now sits on exactly one bar' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' -and $_.bar -ceq 'left' }).Count) -eq 3)
Check 'no member of the group is left on another bar' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' -and $_.bar -ne 'left' }).Count) -eq 0)
# The mirror case: joining a ROW group from a side bar must DROP the bar field, not set it to
# the string 'row' (Get-ButtonBar would still work, but the config grows a knob nobody chose).
$rowGrpJson = '{"buttons":[
    {"label":"T1","text":"/t1","group":"g"},
    {"label":"T2","text":"/t2","bar":"right"}],"groups":{"g":{"icon":"note"}}}'
$r = Invoke-PanelEdit $rowGrpJson ([pscustomobject]@{ label = 'T2'; text = '/t2'; bar = 'right' }) { Set-ButtonGroup 'g' }
$t2 = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'T2' })[0]
Check 'joining a row group drops the bar field entirely' ($null -eq $t2.PSObject.Properties['bar'])
# Joining a group that does not exist yet must not invent a bar for the button.
$r = Invoke-PanelEdit $rowGrpJson ([pscustomobject]@{ label = 'T2'; text = '/t2'; bar = 'right' }) { Set-ButtonGroup 'brand-new' }
$t2 = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'T2' })[0]
Check 'joining a brand-new group leaves the button on the bar it was already on' ($t2.bar -ceq 'right')
# Leaving a group must still not touch the bar.
$r = Invoke-PanelEdit $splitJson ([pscustomobject]@{ label = 'S1'; text = '/s1'; group = 'g'; bar = 'left' }) { Set-ButtonGroup '' }
$s1 = @($r.Cfg.buttons | Where-Object { $_.label -ceq 'S1' })[0]
Check 'leaving a group leaves the button on its bar' (($s1.bar -ceq 'left') -and -not $s1.group)

# The render half of the same defect: the row strip filters $vis by bar BEFORE building the
# group's member list; the side strip filtered per-item and left $vis unfiltered, so a group
# split by a hand-edited config still showed off-bar members in the side flyout.
# MUTATION: move the filter back to a per-item `continue` and this goes red.
$sideFn = [regex]::Match($srcText, '(?s)function Build-SideStrip.*?\n\}').Value
Check 'Build-SideStrip was located' ($sideFn.Length -gt 200)
Check 'the side strip filters the visible set by bar BEFORE building, like the row does' `
    ($sideFn -match '\$vis = @\(Get-VisibleButtons [^\r\n]*Where-Object \{ \(Get-ButtonBar \$_\) -eq \$strip\.Side \}\)')
Check 'the side strip no longer skips off-bar buttons per item (the members list was still unfiltered)' `
    ($sideFn -notmatch '-ne \$strip\.Side\) \{ continue \}')

# =====================================================================================
# F7: a whitespace group name must not silently UNGROUP the button
# =====================================================================================
# New-ButtonGroup trims, so "   " became '' - and Set-ButtonGroup '' is the path that REMOVES a
# button from its group. Asking to create a group took the button out of the one it was in.
# Cancel ($null) was handled; empty-after-trim was not distinguished from it.
function Show-InputDialog([string]$t, [string]$m, [string]$d) { $script:dlgAnswer }
function L([string]$k) { $k }
$newGrpNode = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ButtonGroup' }, $true)
Check 'New-ButtonGroup was found in the panel source' ($null -ne $newGrpNode)
if ($newGrpNode) {
    Invoke-Expression $newGrpNode.Extent.Text
    # MUTATION: delete the IsNullOrWhiteSpace guard and this goes red - G1 loses its group.
    foreach ($blank in @('   ', '', "`t", "  `t ")) {
        $script:dlgAnswer = $blank
        $r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' }) { New-ButtonGroup }
        Check ("a whitespace-only group name ('" + ($blank -replace "`t", '\t') + "') leaves the button in its group") `
            (@($r.Cfg.buttons | Where-Object { $_.label -ceq 'G1' })[0].group -ceq 'grp')
    }
    # Cancel is still a no-op, and a REAL name must still work - the guard must not eat those.
    $script:dlgAnswer = $null
    $r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' }) { New-ButtonGroup }
    Check 'cancelling the new-group prompt still changes nothing' `
        (@($r.Cfg.buttons | Where-Object { $_.label -ceq 'G1' })[0].group -ceq 'grp')
    $script:dlgAnswer = '  shipping  '
    $r = Invoke-PanelEdit $fixJson ([pscustomobject]@{ label = 'A'; text = '/a' }) { New-ButtonGroup }
    Check 'a real group name still creates the group, trimmed' `
        (@($r.Cfg.buttons | Where-Object { $_.label -ceq 'A' })[0].group -ceq 'shipping')
}

# --- Update-Config: it writes the WHOLE config under the lock ---
# Zero references before this. Update-Config is the most damaging thing here that had no
# coverage at all: a bad transform does not just misdraw a button, it persists a corrupt
# config file over the user's real one.
$cfgOnlyJson = '{"schemaVersion":1,"buttons":[{"label":"A","text":"/a"}],"targetTitle":"Claude"}'
$r = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) $c | Add-Member -NotePropertyName marker -NotePropertyValue 'set' -Force; $c } }
Check 'Update-Config persists a whole-config change' (($r.Ret -eq $true) -and ($r.Cfg.marker -eq 'set'))
Check 'Update-Config preserves the fields the transform did not touch' `
    (($r.Cfg.targetTitle -eq 'Claude') -and ((Labels $r.Cfg) -eq 'A'))
# --- Contention is really OBSERVED, proven deterministically (no race) ---
# The concurrent-writer test above is an integration check and is timing-sensitive by nature:
# the holder must release inside the panel's own 2000ms lock timeout, so whether an UNLOCKED
# CLI reads before or after the holder's write depends on child-process startup. Mutation proved
# that is not good enough - pointing the holder at a different mutex name (i.e. no shared lock at
# all) left it green.
# This check has no race in it. A second PROCESS holds the lock for longer than the panel is
# willing to wait, and the write is made in-process, so the outcome is fixed: Update-Buttons must
# fail closed, take the full timeout, and say so. (It has to be a second process - a Windows mutex
# is REENTRANT for the thread that owns it, so a same-thread probe would assert nothing.)
$contendReady = Join-Path ([IO.Path]::GetTempPath()) ("cb-cont-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
$contendName = $cbLockName
$contender = Start-Job -ArgumentList $contendName, $contendReady -ScriptBlock {
    param($ln, $ready)
    $mx = New-Object System.Threading.Mutex($false, $ln)
    [void]$mx.WaitOne(15000)
    try { [IO.File]::WriteAllText($ready, 'held'); Start-Sleep -Milliseconds 3500 } finally { $mx.ReleaseMutex() }
}
$cDeadline = (Get-Date).AddSeconds(30)
while (-not (Test-Path $contendReady) -and (Get-Date) -lt $cDeadline) { Start-Sleep -Milliseconds 50 }
Check 'the contending process holds the config lock' (Test-Path $contendReady)
$script:ckLog = @()
$cSw = [Diagnostics.Stopwatch]::StartNew()
$rCont = Invoke-PanelEdit $cfgOnlyJson $null {
    Update-Buttons { param($b) @($b) + [pscustomobject]@{ label = 'Blocked'; text = '/blocked' } }
}
$cSw.Stop()
Wait-Job $contender -Timeout 20 | Out-Null
Remove-Job $contender -Force
Remove-Item $contendReady -Force -ErrorAction SilentlyContinue
Check 'a write blocked by another process is REFUSED, not forced' ($rCont.Ret -eq $false)
Check ("...after waiting out the 2000ms lock timeout (waited $([int]$cSw.Elapsed.TotalMilliseconds)ms)") `
    ($cSw.Elapsed.TotalMilliseconds -ge 1800)
Check '...leaving the config exactly as it was' ((Labels $rCont.Cfg) -eq 'A')
Check '...and it is logged rather than failing silently' ((@($script:ckLog) -join '|') -match 'lock busy')

# THE ONE THAT MATTERS: a transform returning $null must be REFUSED, not written. Without the
# guard the file becomes "null" (or empty) and the user loses every button they ever pinned,
# with no backup - and the panel then falls back to the shipped defaults, so the loss looks
# like a reset rather than a bug.
$r = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) $null } }
Check 'a transform returning $null is refused, not written' ($r.Ret -eq $false)
# ...and so must a WRONG-SHAPED result. `if (-not $fresh)` only rejects $null/''/0: any other
# truthy value sails through to Write-ConfigAtomic, which happily serialises it. A transform
# that returns a string writes `"totally not a config"` over buttons.json and the user loses
# every button they ever pinned - and because the panel then falls back to the shipped
# defaults, the loss reads as a spontaneous reset rather than a bug.
$rShape = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) 'totally not a config' } }
# Asserted on Ret ALONE. This used to be `($rShape.Ret -eq $false) -or (...has buttons...)`, and
# the second arm made it unfalsifiable: the file on disk still has a `buttons` property whenever
# the write was refused, so the -or was true either way.
Check 'a transform returning a WRONG-SHAPED object is refused, not written' ($rShape.Ret -eq $false)
Check 'a refused wrong-shape write leaves the file intact' `
    (((Labels $rShape.Cfg) -eq 'A') -and ($rShape.Cfg.targetTitle -eq 'Claude'))
# Presence of `buttons` is not enough - the VALUE has to be a collection. Each of these serialises
# straight over buttons.json and loses every pinned button if only presence is checked.
foreach ($bad in @(
        @{ n = '$null';    v = $null },
        @{ n = "a string"; v = 'hello' },
        @{ n = 'a number'; v = 42 },
        @{ n = 'a bool';   v = $true })) {
    # Invoke-PanelEdit runs the action with `& $Action` and passes no arguments, so the value
    # travels through script scope rather than through $args.
    $script:badButtons = $bad.v
    $rb = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) [pscustomobject]@{ buttons = $script:badButtons } } }
    Check "a transform whose buttons is $($bad.n) is refused, not written" ($rb.Ret -eq $false)
    Check "...and the one-button config survives it ($($bad.n))" ((Labels $rb.Cfg) -eq 'A')
}
# THE TRAP: PS 5.1 unrolls a single-element array out of a scriptblock, so a legitimate ONE-button
# config arrives with `buttons` as a bare PSCustomObject. A guard demanding [array] would refuse
# it and destroy the config. This check is what stops anyone "tightening" the guard that way.
$rOne = Invoke-PanelEdit '{"buttons":[{"label":"A","text":"/a"},{"label":"B","text":"/b"}],"targetTitle":"Claude"}' $null {
    Update-Config { param($c) $c.buttons = ($c.buttons | Where-Object { $_.label -eq 'A' }); $c }
}
Check 'a transform filtering down to ONE button is ACCEPTED (single-element unroll)' ($rOne.Ret -eq $true)
Check 'the surviving single button is written' ((Labels $rOne.Cfg) -eq 'A')
Check 'a refused Update-Config leaves the file byte-intact' `
    (($r.Cfg.buttons.Count -eq 1) -and ((Labels $r.Cfg) -eq 'A') -and ($r.Cfg.targetTitle -eq 'Claude'))
# A transform that throws must not half-write. Asserted on the FILE, because that is the part
# that can actually fail here: a Windows mutex is REENTRANT for the thread that owns it, so a
# same-process "does a later write still succeed?" probe would pass even with ReleaseMutex
# deleted outright - it would assert nothing. Proving the release needs a second thread, which
# the concurrent-writer test above already does for the write path.
$threwDir = Join-Path ([IO.Path]::GetTempPath()) ("cb-throw-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $threwDir | Out-Null
$prevLocal = $env:LOCALAPPDATA; $prevHome = $env:USERPROFILE
$script:configPath = Join-Path $threwDir 'buttons.json'
[IO.File]::WriteAllText($script:configPath, $cfgOnlyJson, (New-Object System.Text.UTF8Encoding($false)))
$threw = $false
try {
    $env:LOCALAPPDATA = $threwDir; $env:USERPROFILE = $threwDir
    try { Update-Config { param($c) throw 'boom' } } catch { $threw = $true }
} finally { $env:LOCALAPPDATA = $prevLocal; $env:USERPROFILE = $prevHome }
$afterThrow = Get-Content $script:configPath -Raw | ConvertFrom-Json
Remove-Item $threwDir -Recurse -Force -ErrorAction SilentlyContinue
Check 'a throwing transform propagates rather than being swallowed as success' $threw
Check 'a throwing transform leaves the config file untouched' `
    (((Labels $afterThrow) -eq 'A') -and ($afterThrow.targetTitle -eq 'Claude'))
# Set-KindColor is the shipped caller of Update-Config, and it is how a group/toggle/prompt
# colour is saved. Nothing exercised it, so an Update-Config that silently dropped its result
# would have shown up only as "my colour choice never sticks".
$r = Invoke-PanelEdit $cfgOnlyJson $null { Set-KindColor 'command' 'blue' }
Check 'Set-KindColor persists a per-kind colour through Update-Config' ($r.Cfg.colors.command -eq 'blue')
Check 'saving a colour does not disturb the buttons array' ((Labels $r.Cfg) -eq 'A')

# =====================================================================================
# DATA-02: "Remove this button" must remove exactly ONE button
# =====================================================================================
# The `L` in force from here on is the ECHO STUB defined for the New-ButtonGroup fixture above
# (`function L([string]$k) { $k }`), which shadows the panel's real lookup. The warning
# assertions below therefore prove that the handler asked for the right KEY, not what that key
# renders as - stated because the two are easy to confuse, and because a stub that stopped
# echoing would turn those assertions into `'' -eq ''` and make them pass vacuously. This guard
# is what stops that. The rendered text is covered separately, at the bottom of this block,
# against the shipped string table in BOTH languages.
Check 'the L stub in force here still echoes its key (the warning checks below depend on it)' `
    (((L 'removeAmbiguous') -eq 'removeAmbiguous') -and ((L 'cfgClobber') -eq 'cfgClobber'))
# label+text+chat is a MATCH, not an IDENTITY. Rename B to "A" and retype its text to A's, and
# the two rows are indistinguishable by that triple - and the handler filtered the array with
# `-not (Same-Button ...)`, so ONE requested deletion destroyed TWO hand-written prompts. There
# is no backup and no undo.
#
# The duplicates below carry different ICONS. Same-Button ignores `icon`, so they are still
# ambiguous by the triple, but the icon is what lets these tests say WHICH row went - with two
# byte-identical rows the assertion could only count, and "removed one" would pass even if it
# removed the wrong one.
$dupRemoveJson = '{"schemaVersion":1,"buttons":[
    {"label":"A","text":"/x","icon":"note"},
    {"label":"A","text":"/x","icon":"power"},
    {"label":"Keep","text":"/k"}]}'
function Icons($cfg) { (@($cfg.buttons) | ForEach-Object { if ($_.icon) { $_.icon } else { '-' } }) -join ',' }

# --- The reported bug. The clicked pill's Tag IS the row object, so the click resolves by
#     reference and only that row leaves.
$r = Invoke-PanelEdit $dupRemoveJson $null {
    $script:menuSource = [pscustomobject]@{ Tag = $script:config.buttons[1] }
    & $removeAction
}
Check 'removing one of two identical-triple buttons leaves the other one alone' `
    (@($r.Cfg.buttons).Count -eq 2)
Check '...and it is the row that was CLICKED that went (second: icon=power)' `
    ((Icons $r.Cfg) -eq 'note,-')
Check '...and the removal was actually persisted (strips rebuilt)' ($r.Rebuilt -gt 0)

# The other direction. Without this, "always drop the first match" would pass the case above.
$r = Invoke-PanelEdit $dupRemoveJson $null {
    $script:menuSource = [pscustomobject]@{ Tag = $script:config.buttons[0] }
    & $removeAction
}
Check 'clicking the FIRST of two identical-triple buttons removes the first, not the second' `
    ((@($r.Cfg.buttons).Count -eq 2) -and ((Icons $r.Cfg) -eq 'power,-'))

# --- No usable hint (a stale tag: the object is not in the current array) AND the triple is
#     ambiguous. This is where the GUI has no more information than the CLI, so it gives the
#     same answer the CLI gives - refuse - instead of guessing.
$r = Invoke-PanelEdit $dupRemoveJson ([pscustomobject]@{ label = 'A'; text = '/x' }) { & $removeAction }
Check 'an ambiguous remove with no usable hint deletes NOTHING' `
    ((@($r.Cfg.buttons).Count -eq 3) -and ((Icons $r.Cfg) -eq 'note,power,-'))
# ...and it must SAY so. A refusal the user cannot see is indistinguishable from a click that
# did nothing, which is how they would go on to click it again.
Check 'a refused ambiguous remove warns the user' `
    ((@($r.Warned).Count -eq 1) -and ($r.Warned[0] -eq (L 'removeAmbiguous')))

# --- Regressions: the ordinary paths must still work.
$r = Invoke-PanelEdit $dupRemoveJson ([pscustomobject]@{ label = 'Keep'; text = '/k' }) { & $removeAction }
Check 'an UNambiguous remove by value still works with no hint at all' `
    ((@($r.Cfg.buttons).Count -eq 2) -and ((Labels $r.Cfg) -eq 'A,A') -and (@($r.Warned).Count -eq 0))
$r = Invoke-PanelEdit '{"buttons":[{"label":"Only","text":"/o"}]}' ([pscustomobject]@{ label = 'Only'; text = '/o' }) { & $removeAction }
# PS 5.1 unrolls an array out of a scriptblock: an empty result must stay an empty ARRAY, not
# collapse into @($null) - a buttons array holding one null entry is a corrupt config.
Check 'removing the last button leaves an EMPTY array, not a null entry' `
    ((@($r.Cfg.buttons).Count -eq 0) -and ($r.Raw -notmatch 'null'))
$r = Invoke-PanelEdit $dupRemoveJson ([pscustomobject]@{ label = 'Ghost'; text = '/ghost' }) { & $removeAction }
Check 'removing a button that is not there changes nothing and does not warn' `
    ((@($r.Cfg.buttons).Count -eq 3) -and (@($r.Warned).Count -eq 0))
# Case-sensitivity is inherited from Same-Button and must survive the rewrite: a wrong-case
# target must match nothing rather than the genuinely different button next to it.
$r = Invoke-PanelEdit '{"buttons":[{"label":"Deploy","text":"/deploy prod"},{"label":"deploy","text":"/DEPLOY PROD"}]}' `
        ([pscustomobject]@{ label = 'DEPLOY'; text = '/deploy prod' }) { & $removeAction }
Check 'a wrong-case remove target still matches nothing' (@($r.Cfg.buttons).Count -eq 2)

# --- Get-TargetIndex directly: the -2 (ambiguous) contract the handler branches on.
$twoSame = @([pscustomobject]@{ label = 'A'; text = '/x' }, [pscustomobject]@{ label = 'A'; text = '/x' })
Check 'Get-TargetIndex reports ambiguity as -2 rather than picking one' `
    ((Get-TargetIndex $twoSame $twoSame[0] -1) -eq -2)
Check 'Get-TargetIndex honours a valid positional hint even when ambiguous' `
    ((Get-TargetIndex $twoSame $twoSame[0] 1) -eq 1)
# A hint pointing at a row that no longer matches (the file changed under the panel) must be
# DISCARDED, not used. Trusting it blindly would delete a button the user never clicked.
$shifted = @([pscustomobject]@{ label = 'New'; text = '/n' }, [pscustomobject]@{ label = 'A'; text = '/x' })
Check 'a stale hint is discarded and the unique value match wins' `
    ((Get-TargetIndex $shifted ([pscustomobject]@{ label = 'A'; text = '/x' }) 0) -eq 1)
Check 'an out-of-range hint does not throw and falls back to value matching' `
    ((Get-TargetIndex $shifted ([pscustomobject]@{ label = 'A'; text = '/x' }) 99) -eq 1)
Check 'Get-TargetIndex reports no match as -1' `
    ((Get-TargetIndex $shifted ([pscustomobject]@{ label = 'Z'; text = '/z' }) -1) -eq -1)

# =====================================================================================
# DATA-03: a hand edit must not be silently overwritten
# =====================================================================================
# The mutex only binds writers that take it. An editor saving buttons.json takes nothing, and
# Write-ConfigAtomic replaces the WHOLE file - so a save that landed between the panel's read
# and its write was erased. Read-FreshConfig inside the lock narrows the window to one
# transform; it does not close it, because nothing detected the overlap.
#
# The transform below IS the external writer, which is the exact scenario: the file is edited
# WHILE a transform is running.
$handEditJson = '{"schemaVersion":1,"buttons":[{"label":"A","text":"/a"}],"targetTitle":"Claude"}'
$r = Invoke-PanelEdit $handEditJson $null {
    Update-Buttons {
        param($b)
        [IO.File]::WriteAllText($script:configPath,
            '{"schemaVersion":1,"buttons":[{"label":"A","text":"/a"},{"label":"HandEdit","text":"/h"}],"targetTitle":"Claude"}',
            (New-Object System.Text.UTF8Encoding($false)))
        @($b) + [pscustomobject]@{ label = 'Panel'; text = '/p' }
    }
}
Check 'a write is REFUSED when the file changed after the panel read it' ($r.Ret -eq $false)
Check '...and the hand edit survives byte-intact (this is the data loss)' ((Labels $r.Cfg) -eq 'A,HandEdit')
Check '...and the panel change is genuinely absent, not merged in by accident' ((Labels $r.Cfg) -notmatch 'Panel')
# Silent discard is the failure mode this project has already shipped twice. A log line is not
# user-visible; the warning is.
Check 'a refused write TELLS the user' `
    ((@($r.Warned).Count -eq 1) -and ($r.Warned[0] -eq (L 'cfgClobber')))
Check '...and reloads, so the bar stops showing the version that lost' ($r.Rebuilt -gt 0)
Check '...and it is logged too' ((@($script:ckLog) -join '|') -match 'changed by something else')
# Update-Config takes the same guard - Set-KindColor and every group edit go through it.
$r = Invoke-PanelEdit $handEditJson $null {
    Update-Config {
        param($c)
        [IO.File]::WriteAllText($script:configPath,
            '{"schemaVersion":1,"buttons":[{"label":"A","text":"/a"},{"label":"HandEdit","text":"/h"}]}',
            (New-Object System.Text.UTF8Encoding($false)))
        $c | Add-Member -NotePropertyName colors -NotePropertyValue ([pscustomobject]@{ command = 'blue' }) -Force
        $c
    }
}
Check 'Update-Config refuses the same overwrite' (($r.Ret -eq $false) -and ((Labels $r.Cfg) -eq 'A,HandEdit'))

# THE TRAP, and the reason this needs its own check: the panel writes buttons.json on every
# single edit. A guard anchored on "has the file changed since the panel last touched it" is
# true after EVERY panel write, so the second edit in a row would be refused and the feature
# would be a brick. The guard has to anchor on the READ the pending change was computed from.
# Deleting the whole guard leaves this green - that is the point of it being separate from the
# checks above, which deleting the guard turns red.
$r = Invoke-PanelEdit $handEditJson $null {
    $a1 = Update-Buttons { param($b) @($b) + [pscustomobject]@{ label = 'One'; text = '/1' } }
    $a2 = Update-Buttons { param($b) @($b) + [pscustomobject]@{ label = 'Two'; text = '/2' } }
    $a3 = Update-Config  { param($c) $c | Add-Member -NotePropertyName lang -NotePropertyValue 'da' -Force; $c }
    , @($a1, $a2, $a3)
}
Check 'three back-to-back PANEL writes all succeed (the guard must not fire on our own writes)' `
    (($r.Ret[0] -eq $true) -and ($r.Ret[1] -eq $true) -and ($r.Ret[2] -eq $true))
Check '...and every one of them landed' (((Labels $r.Cfg) -eq 'A,One,Two') -and ($r.Cfg.lang -eq 'da'))
Check '...with no spurious warning' (@($r.Warned).Count -eq 0)

# An external write that happens to produce an IDENTICAL file is not a conflict - refusing there
# would cost the user an edit for nothing.
$r = Invoke-PanelEdit $handEditJson $null {
    Update-Buttons {
        param($b)
        [IO.File]::WriteAllText($script:configPath, $script:cfgReadRaw, (New-Object System.Text.UTF8Encoding($false)))
        @($b) + [pscustomobject]@{ label = 'Panel'; text = '/p' }
    }
}
Check 'a byte-identical rewrite is not treated as a conflict' `
    (($r.Ret -eq $true) -and ((Labels $r.Cfg) -eq 'A,Panel'))

# ...but a hand edit that changed ONLY the case of a label is a real edit and must be protected.
# PowerShell's -ne is case-INSENSITIVE, so the obvious comparison reports "unchanged" here and
# overwrites it. Same trap that made Same-Button -ceq, one layer down.
$r = Invoke-PanelEdit $handEditJson $null {
    Update-Buttons {
        param($b)
        [IO.File]::WriteAllText($script:configPath,
            $script:cfgReadRaw.Replace('"label":"A"', '"label":"a"'),
            (New-Object System.Text.UTF8Encoding($false)))
        @($b) + [pscustomobject]@{ label = 'Panel'; text = '/p' }
    }
}
Check 'a hand edit that changed only LETTER CASE is still protected' `
    (($r.Ret -eq $false) -and ((Labels $r.Cfg) -eq 'a'))

# Both new user-visible strings must exist in BOTH tables. A refusal that renders as a blank
# tooltip in Danish is a silent discard with extra steps.
$newStrOk = $true
foreach ($lang in @('en', 'da')) {
    $block = [regex]::Match($srcText, "(?s)\b$lang\s*=\s*@\{(.*?)\r?\n\s*\}").Groups[1].Value
    foreach ($k in @('removeAmbiguous', 'cfgClobber')) {
        if ($block -notmatch "$k\s*=\s*'[^']{40,}'") { $newStrOk = $false }
    }
}
Check 'removeAmbiguous and cfgClobber are defined with real text in EN and DA' $newStrOk
$r = Invoke-PanelEdit '{"buttons":[{"label":"A","text":"/a"}],"colors":{"command":"blue","text":"red"}}' $null { Set-KindColor 'command' '' }
Check 'clearing a kind colour removes only that kind' `
    (($null -eq $r.Cfg.colors.PSObject.Properties['command']) -and ($r.Cfg.colors.text -eq 'red'))

# --- Per-kind colour derivation ---
# Which slot a button draws from is decided by what it DOES. Getting Get-ColorKind wrong
# recolours whole categories at once, and none of it was covered.
Check 'a group face is the group kind' ((Get-ColorKind ([pscustomobject]@{ __isGroup = $true })) -eq 'group')
Check 'a toggle is the toggle kind even when its text is a slash command' `
    ((Get-ColorKind ([pscustomobject]@{ toggle = $true; text = '/x' })) -eq 'toggle')
Check 'a slash command is the command kind' ((Get-ColorKind ([pscustomobject]@{ text = '/review' })) -eq 'command')
Check 'leading whitespace does not hide a slash command' ((Get-ColorKind ([pscustomobject]@{ text = "  /review" })) -eq 'command')
Check 'a plain prompt is the text kind' ((Get-ColorKind ([pscustomobject]@{ text = 'gennemgaa min kode' })) -eq 'text')
# A slash that is not the FIRST thing is a prompt, not a command.
Check 'a prompt merely containing a slash is not a command' ((Get-ColorKind ([pscustomobject]@{ text = 'see a/b' })) -eq 'text')
# Get-KindColor resolves the saved name against the palette. $null means "no override", which
# is why prompts and commands look unchanged until someone picks a colour - so a mutant that
# returned a colour unconditionally would recolour every button in the bar.
$script:config = [pscustomobject]@{ colors = [pscustomobject]@{ command = 'blue'; text = 'nosuchcolour' } }
$cmdCol = Get-KindColor ([pscustomobject]@{ text = '/x' }) $false
Check 'a saved kind colour resolves to its palette entry' ($cmdCol -eq $script:ckPalette['blue'])
Check 'an unsaved kind stays null (no override, historic default kept)' `
    ($null -eq (Get-KindColor ([pscustomobject]@{ toggle = $true }) $false))
Check 'a colour name that is not in the palette falls back to null, not to a wrong colour' `
    ($null -eq (Get-KindColor ([pscustomobject]@{ text = 'plain prompt' }) $false))
# The ON state is deliberately NOT colourable: white-on-amber measures 4.67:1 and every
# palette entry measures 1.8-2.2:1 on that fill, so any pick there is a contrast regression.
Check 'the toggle ON state is never recoloured (every palette pick regresses its contrast)' `
    ($null -eq (Get-KindColor ([pscustomobject]@{ text = '/x' }) $true))

# =====================================================================================
# --- Which chat does a button belong to? (the wrong-chat send hazard) ---
# =====================================================================================
# Side strips live in their own array and are NEVER in $script:mirrors, so every left/right-bar
# button used to resolve to no pane and fall through to the GEOMETRIC guess. That guess models
# one shape only - a horizontal row strip docked just below its own composer - and scores
# composers sitting ABOVE the strip. A vertical side strip is anchored well above its own
# composer, so this pane's composer is rejected; in a vertically-staggered layout a
# NEIGHBOURING pane's composer can pass instead and take the prompt. The everyday symptom was
# that side-bar buttons silently did nothing; sending to the wrong chat was the tail case.
foreach ($fn in @('Resolve-StripForm', 'Get-PaneForForm', 'Test-CanGuessFrom', 'Get-StripWidth', 'Get-PillWidth',
                  'Get-ShortLabel', 'Get-GroupDef', 'Get-IconGlyph', 'Test-ChatButtonVisible', 'S',
                  'SW', 'Test-ComposerDockedTo')) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    if ($node) { Invoke-Expression $node.Extent.Text } else { $missingFns += $fn }
}
Check ("the pane-resolution and width functions were found in the source" + $(if ($missingFns) { ": MISSING $($missingFns -join ', ')" } else { '' })) `
    ($missingFns.Count -eq 0)

# --- Get-PaneForForm maps a side strip to ITS OWN pane ---
# Two strips per pane in pane order, so strip si belongs to pane floor(si/2). [Math]::Floor,
# not [int]: [int](3/2) is 2 in PowerShell, which pairs strip 3 with the wrong pane - i.e.
# points a button at the neighbouring chat, which is precisely the hazard being fixed.
$script:flyForm = $null
$form = [pscustomobject]@{ Name = 'main' }
$script:panes  = @(0..2 | ForEach-Object { [pscustomobject]@{ Title = "pane$_" } })
$script:mirrors = @()
$script:sideStrips = @(0..5 | ForEach-Object { [pscustomobject]@{ Form = [pscustomobject]@{ Name = "strip$_" } } })
$stripMap = @(0..5 | ForEach-Object { $p = Get-PaneForForm $script:sideStrips[$_].Form; if ($p) { $p.Title } else { 'NULL' } })
Check "strips 0..5 map to panes 0,0,1,1,2,2 (got: $($stripMap -join ','))" `
    (($stripMap -join ',') -eq 'pane0,pane0,pane1,pane1,pane2,pane2')
# A strip whose pane has closed must resolve to nothing rather than to the last pane - falling
# back to "some pane" is how the prompt reaches a chat the user was not looking at.
$script:sideStrips = @(0..7 | ForEach-Object { [pscustomobject]@{ Form = [pscustomobject]@{ Name = "strip$_" } } })
Check 'a strip beyond the last pane resolves to no pane at all' `
    ($null -eq (Get-PaneForForm $script:sideStrips[6].Form))
Check 'the main window still resolves to the primary pane' ((Get-PaneForForm $form).Title -eq 'pane0')
$script:mirrors = @([pscustomobject]@{ Form = [pscustomobject]@{ Name = 'mirror1' } })
Check 'a mirror window resolves to its own pane, offset past the primary' `
    ((Get-PaneForForm $script:mirrors[0].Form).Title -eq 'pane1')
Check 'an unknown window resolves to no pane' ($null -eq (Get-PaneForForm ([pscustomobject]@{ Name = 'stranger' })))
Check 'a null form resolves to no pane' ($null -eq (Get-PaneForForm $null))

# --- Test-CanGuessFrom: WHICH hosts may fall back to guessing at a composer ---
# This is the wrong-chat invariant, asserted by VALUE. The predicate was extracted from
# Invoke-PillClick precisely so it could be tested this way: the previous guard was pinned only
# by an AST check that a guard variable's assignment text mentioned $form or $script:mirrors,
# and this mutant satisfied it while reinstating the whole hazard -
#
#     $canGuess = ($sf -eq $form) -or ($null -ne $script:mirrors)
#
# because the surviving `$sf -eq $form` half still matched the regex. The check asserted that a
# row-derived assignment EXISTS, never that side strips are EXCLUDED. Two reviewers found that
# independently, one by mutation and one by reading the test.
#
# The geometric fallback scores candidate composers on the assumption that the strip is a
# HORIZONTAL row docked BELOW its composer. A side strip is anchored above it, so the fallback's
# model does not describe it: at best every candidate is rejected and the click silently does
# nothing; at worst, in a vertically-staggered layout, a NEIGHBOURING pane's composer scores
# best and the prompt goes into a conversation the user was not looking at.
Check 'the primary strip MAY use the geometric fallback' (Test-CanGuessFrom $form)
Check 'a mirror strip MAY use the geometric fallback' (Test-CanGuessFrom $script:mirrors[0].Form)
Check 'a SIDE strip may NOT use the geometric fallback' (-not (Test-CanGuessFrom $script:sideStrips[0].Form))
Check 'no side strip at all may use it (checked every one)' `
    (-not (@(0..7 | Where-Object { Test-CanGuessFrom $script:sideStrips[$_].Form }).Count))
Check 'an unrelated window may NOT use the geometric fallback' `
    (-not (Test-CanGuessFrom ([pscustomobject]@{ Name = 'stranger' })))
Check 'a null form may NOT use the geometric fallback' (-not (Test-CanGuessFrom $null))
# ...and specifically when the primary form does not exist yet either. Deleting the explicit
# null check SURVIVED every other case here, because with a real $form the comparison just
# returns false anyway. But during startup $form is $null too, and `$null -eq $null` is TRUE -
# so the guard would hand a nonexistent window permission to guess at a composer. Found by
# mutation; no amount of reading the function would have shown it.
$formSaved = $form
$form = $null
Check 'a null form is refused even before the primary window exists' (-not (Test-CanGuessFrom $null))
$form = $formSaved
# The mirror record itself is not a Form. `$script:mirrors -contains $sf` would compare against
# the records rather than their .Form and quietly answer the wrong question.
Check 'a mirror RECORD is not mistaken for its window' `
    (-not (Test-CanGuessFrom $script:mirrors[0]))

# --- Test-ComposerDockedTo: the geometric fallback must not reach ANOTHER CHAT'S composer ---
# Test-CanGuessFrom decides WHICH STRIPS may guess. It says a mirror may - correctly, a mirror is
# a row strip. But nothing then bounded WHAT the guess could return, and that is a wrong-chat
# hazard the moment a mirror's own composer dies:
#
#   Chats A and B side by side; B has a mirror strip. B closes, so the element the strip is bound
#   to dies. Before the next UIA refresh tears the strip down, its button is clicked. The bound
#   element fails, Test-CanGuessFrom permits the guess, and the old scorer took the best composer
#   ABOVE the strip with no maximum distance and no identity check - so with A the only survivor
#   it won by default. THE PROMPT WENT TO CHAT A.
#
# Asserted by VALUE, on the real layouts. $script:winScale is what SW scales by.
$script:winScale = 1.0
# The strip is docked to its own composer: the tick clamps its travel to the composer's X span
# and places its centre on the composer's bottom edge, so a legitimate strip top sits a few px
# BELOW that bottom (hence the +10 tolerance) and its centre X is inside the span.
$ownComposer  = [pscustomobject]@{ X = 400; Y = 700; W = 400; H = 100 }   # spans x 400..800
$dockedStripX = 600    # centre, inside 400..800
$dockedStripY = 802    # just below the composer bottom (800)
Check 'the strip''s OWN composer is accepted (the ordinary dock)' `
    (Test-ComposerDockedTo $ownComposer $dockedStripX $dockedStripY 24)
# THE FINDING. Side by side: A is at x 400..800, B at x 900..1300, both composers at the SAME
# height - so no vertical test can separate them and only the X span can. B's strip is centred
# over B, and must not match A.
$neighbourA = [pscustomobject]@{ X = 400; Y = 700; W = 400; H = 100 }
Check 'a SIDE-BY-SIDE neighbour''s composer is refused (horizontal identity)' `
    (-not (Test-ComposerDockedTo $neighbourA 1100 802 24))
Check '...and B''s own composer at the same height is still accepted' `
    (Test-ComposerDockedTo ([pscustomobject]@{ X = 900; Y = 700; W = 400; H = 100 }) 1100 802 24)
# THE MIRROR IMAGE, and it needs its own case: both checks above put the survivor to the LEFT of
# the strip, so they are decided entirely by the right-hand edge and a mutant that deletes the
# LEFT-hand one survives them both. Here the surviving chat is to the RIGHT of the dead strip -
# equally real, since which pane closes is not up to us.
Check 'a neighbour to the RIGHT of the strip is refused (left-hand identity)' `
    (-not (Test-ComposerDockedTo ([pscustomobject]@{ X = 900; Y = 700; W = 400; H = 100 }) 600 802 24))
Check 'a strip centred well to the LEFT of its composer is refused' `
    (-not (Test-ComposerDockedTo $ownComposer 340 802 24))
# STACKED: the X spans DO overlap, so identity cannot separate these - the distance bound must.
# A sits far above B's strip.
Check 'a STACKED neighbour far above the strip is refused (distance bound)' `
    (-not (Test-ComposerDockedTo ([pscustomobject]@{ X = 400; Y = 100; W = 400; H = 100 }) 600 802 24))
# Both halves are load-bearing: each layout is caught by exactly one of them, so deleting either
# check leaves one of the two cases above passing. (Deleting only the distance bound was survived
# by every side-by-side case; deleting only the identity check was survived by every stacked one.)
Check 'a composer BELOW the strip is refused (it cannot be docked above it)' `
    (-not (Test-ComposerDockedTo ([pscustomobject]@{ X = 400; Y = 900; W = 400; H = 100 }) 600 802 24))
# The strip centre exactly on the composer's edges is still its own composer, not a neighbour's.
Check 'the dock tolerates a strip centred on the composer''s left edge' `
    (Test-ComposerDockedTo $ownComposer 400 802 24)
Check 'the dock tolerates a strip centred on the composer''s right edge' `
    (Test-ComposerDockedTo $ownComposer 800 802 24)
# ...and just outside it is not. Without this, a "tolerance" of any size would pass the edge
# cases above while still reaching the neighbour.
Check 'a strip centred well outside the composer''s span is refused' `
    (-not (Test-ComposerDockedTo $ownComposer 860 802 24))
Check 'Test-ComposerDockedTo refuses a null composer' `
    (-not (Test-ComposerDockedTo $null 600 802 24))

# --- Resolve-StripForm: a flyout stands in for the strip that opened it ---
# A button inside the group flyout belongs to the pane of the strip that opened it. The flyout
# is its own window and maps to no pane, so without this it fell straight through to the
# geometric guess - the same wrong-chat path, reached from every grouped button.
Add-Type -AssemblyName System.Windows.Forms
$ownerStrip = [pscustomobject]@{ Name = 'owner'; IsDisposed = $false }
$script:flyForm = [pscustomobject]@{ Name = 'fly'; Tag = $ownerStrip }
Check 'the flyout resolves to the strip that owns it' ((Resolve-StripForm $script:flyForm).Name -eq 'owner')
# A DISPOSED owner must resolve to $null, not to a dead window: the caller treats a resolved
# form as "this is the strip", and a dead one puts it back on the geometric guess unnoticed.
$deadForm = New-Object System.Windows.Forms.Form
$deadForm.Dispose()
$script:flyForm = [pscustomobject]@{ Name = 'fly'; Tag = $deadForm }
Check 'a flyout whose owning strip has been disposed resolves to null' ($null -eq (Resolve-StripForm $script:flyForm))
$script:flyForm = [pscustomobject]@{ Name = 'fly'; Tag = $null }
Check 'a flyout with no owner at all resolves to null' ($null -eq (Resolve-StripForm $script:flyForm))
Check 'a plain strip form is returned unchanged' `
    ((Resolve-StripForm ([pscustomobject]@{ Name = 'plain' })).Name -eq 'plain')
Check 'Resolve-StripForm passes null through' ($null -eq (Resolve-StripForm $null))
$script:flyForm = $null

# --- A rebuild must dismiss the flyout, on EVERY path into it ---
# Rebuild-Buttons disposes the strip's PillButtons, but the flyout's members hold .Tag
# references into the config objects the rebuild replaces. The menu handlers each wrote
# `Hide-GroupFlyout; Rebuild-Buttons`, so the hazard only showed on the paths that DON'T:
# the tick rebuilding on a dirty buttons.json (/pin, an agent) and the compact-mode flip.
# A click-PINNED flyout is skipped by the tick's own dismissal check, so it survived both -
# left on screen offering buttons that had just been deleted from disk, owned by a control
# that no longer exists. The dismissal belongs inside the rebuild, where no caller can
# forget it, which is why this is asserted against the function body and not the call sites.
# MUTATION: delete the Hide-GroupFlyout line from Rebuild-Buttons and this goes red.
$rbNode = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Rebuild-Buttons' }, $true)
Check 'Rebuild-Buttons was located in the panel source' ($null -ne $rbNode)
if ($rbNode) {
    $rbStmts = @($rbNode.Body.EndBlock.Statements)
    Check 'Rebuild-Buttons dismisses the group flyout before it disposes the buttons' `
        ($rbStmts.Count -gt 0 -and $rbStmts[0].Extent.Text.Trim() -eq 'Hide-GroupFlyout')
}
# ...and Hide-GroupFlyout must clear the PIN, or the tick's dismissal check keeps skipping a
# flyout that is hidden but still believes it is pinned open.
$hideFn = [regex]::Match($srcText, '(?s)function Hide-GroupFlyout \{.*?\n\}').Value
Check 'Hide-GroupFlyout was located' ($hideFn.Length -gt 40)
Check 'Hide-GroupFlyout clears the pinned flag as well as hiding the window' `
    ($hideFn -match '\$script:flyPinned\s*=\s*\$false' -and $hideFn -match '\$script:flyForm\.Hide\(\)')

# --- The geometric fallback must stay GUARDED (the actual wrong-chat invariant) ---
# Invoke-PillClick runs a live UIA/window pipeline, so it cannot be called from here. What CAN
# be asserted is the shape that makes the hazard impossible: Focus-ChatInput must not be
# reachable unconditionally, and the condition that gates it must be derived from "is this a
# ROW strip?" - i.e. from $form / $script:mirrors. A guard that is merely SOME if-statement, or
# a constant $true, would let the geometric guess run for a side strip again.
$pillFn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PillClick' }, $true)
Check 'Invoke-PillClick was found in the source' ($null -ne $pillFn)
$focusCalls = @()
if ($pillFn) {
    $focusCalls = @($pillFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Focus-ChatInput' }, $true))
}
# Zero call sites must FAIL, not pass: an empty selection is exactly how the old source-grep
# checks in this file went vacuously green.
Check "the geometric fallback call site was found inside Invoke-PillClick (found $($focusCalls.Count))" ($focusCalls.Count -ge 1)
$unguarded = @(); $guardConds = @()
foreach ($fc in $focusCalls) {
    $p = $fc.Parent; $guarded = $false
    while ($p -and $p -ne $pillFn) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            $guarded = $true
            $guardConds += ,$p.Clauses[0].Item1
        }
        $p = $p.Parent
    }
    if (-not $guarded) { $unguarded += $fc.Extent.Text }
}
Check 'the geometric fallback is not reachable unconditionally from Invoke-PillClick' ($unguarded.Count -eq 0)
# ...and the guard must be the PREDICATE RESULT ALONE, which the behavioural tests above pin by
# VALUE.
#
# Two earlier versions of this check were too weak, in the same way, one level apart. The first
# accepted any guard whose assignment text merely mentioned $form or $script:mirrors - a mutant
# that repointed the membership scan to $script:sideStrips passed it. The second (this one)
# accepted any ancestor `if` as long as SOME variable in its condition had been assigned from
# Test-CanGuessFrom, so `if ($canGuess -or $somethingElse)` passed while the predicate gated
# nothing at all. Both asserted that a correct-looking thing EXISTS somewhere in the condition
# rather than that it DECIDES the condition.
#
# So the condition must be a bare variable reference - no -or, no -and, no negation, no extra
# terms - and that variable's only assignment inside Invoke-PillClick must be a direct call to
# Test-CanGuessFrom. Anything bolted on changes the condition's AST from a lone
# VariableExpressionAst and fails here.
#
# Keep BOTH checks. This one catches "the guard was inlined, widened or replaced by something the
# behavioural tests do not see"; the behavioural tests catch "the predicate itself is wrong"; and
# the reachability check above catches "the guard was deleted along with its call site". None of
# the three subsumes another.
$soleGuard = $false; $guardDesc = @()
foreach ($cond in $guardConds) {
    # Unwrap a redundant `if (($canGuess))` but nothing else.
    $c = $cond
    while ($c -is [System.Management.Automation.Language.PipelineAst] -and $c.PipelineElements.Count -eq 1) {
        $c = $c.PipelineElements[0]
    }
    if ($c -is [System.Management.Automation.Language.CommandExpressionAst]) { $c = $c.Expression }
    while ($c -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $c = $c.Pipeline
        while ($c -is [System.Management.Automation.Language.PipelineAst] -and $c.PipelineElements.Count -eq 1) { $c = $c.PipelineElements[0] }
        if ($c -is [System.Management.Automation.Language.CommandExpressionAst]) { $c = $c.Expression }
    }
    $guardDesc += "$($cond.Extent.Text) => $($c.GetType().Name)"
    if ($c -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    $gv = $c.Extent.Text
    $asns = @($pillFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $gv }, $true))
    # EXACTLY one assignment, and it must BE the predicate call - not merely mention it. A second
    # assignment anywhere in the function could overwrite the predicate's answer with anything.
    if ($asns.Count -ne 1) { continue }
    $right = ($asns[0].Right.Extent.Text -replace '\s+', ' ').Trim() -replace '^\((.*)\)$', '$1'
    if ($right -eq 'Test-CanGuessFrom $sf') { $soleGuard = $true }
}
Check "the fallback guard IS the tested predicate, alone (conds: $($guardDesc -join ' / '))" $soleGuard
# And the refusal must be VISIBLE. A silent return is indistinguishable from a successful
# send - which is how this whole class of bug stayed invisible: "I clicked and nothing
# happened" reads as a flaky panel, not as a refusal that protected the user.
Check 'the abandoned side-bar send warns the user (sendNoPane)' ($srcText -match "Show-SendWarning \(L 'sendNoPane'\)")
# The call site must hand Focus-ChatInput the strip's HEIGHT. Without it the distance bound
# degenerates to a bare margin and the stacked-layout case above stops being enforced in
# production, while Test-ComposerDockedTo's own tests still pass because they pass it directly.
Check 'the geometric fallback passes the strip height to the scorer' `
    ($srcText -match 'Focus-ChatInput \(\$sf\.Left \+ \$sf\.Width / 2\) \$sf\.Top \$sf\.Height')
# The guess is bounded now, so it can legitimately return nothing - a mirror whose chat closed
# beside a chat that is NOT its own. That must be an explicit refusal, not a fall-through into
# Wait-ComposerFocus($null), which aborts with nothing on screen to explain it.
$guessBlock = [regex]::Match($srcText, '(?s)if \(\$canGuess\) \{(.*?)\r?\n                \} else \{').Groups[1].Value
Check 'the bounded guess returning nothing was located' ($guessBlock.Length -gt 40)
Check 'a guess that identifies no docked composer is refused, and visibly' `
    (($guessBlock -match 'if \(-not \$composerEl\)') -and
     ($guessBlock -match "Show-SendWarning \(L 'sendNoPane'\)") -and
     ($guessBlock -match '\breturn\b'))

# --- Get-StripWidth measures what is actually ON the row ---
# It used to sum every visible button regardless of bar and count each group member separately.
# Moving buttons to a side bar or collapsing them into a group therefore did not shrink the
# measurement at all: the row still measured as if nothing had moved, compact mode latched on,
# and the labels still on the row shrank for no reason. The fixture below measured 887px under
# the old code and 263px under the fixed one.
# Asserted as EQUALITIES between configs rather than against those pixel numbers, which depend
# on DPI, font and theme - a hardcoded 263 would be a fixture asserting the fixture again.
$script:scale = 1.0
$script:kebabBar = 'row'
$script:iconFont = $null          # forces the text-label path, so widths are comparable
$script:uiaTitle = $null; $script:activeSession = $null; $script:activeExpired = $false
foreach ($vn in @('$script:btnFont', '$script:padX', '$pillH')) {
    $asn = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $vn }, $true)
    if ($asn) { Invoke-Expression $asn.Extent.Text } else { $missingVars += $vn }
}
Check ("the width-measurement constants were extracted from source" + $(if ($missingVars) { ": MISSING $($missingVars -join ', ')" } else { '' })) `
    ($missingVars.Count -eq 0)
function Set-WidthFixture($json) { $script:config = ($json | ConvertFrom-Json) }
# Their fixture: two plain row buttons, a three-member group, two side-bar buttons.
Set-WidthFixture '{"buttons":[
    {"label":"Review","text":"/review"},{"label":"Commit","text":"/commit"},
    {"label":"GroupOne","text":"/g1","group":"tools"},
    {"label":"GroupTwo","text":"/g2","group":"tools"},
    {"label":"GroupThree","text":"/g3","group":"tools"},
    {"label":"SideOne","text":"/s1","bar":"left"},
    {"label":"SideTwo","text":"/s2","bar":"right"}],"groups":{"tools":{"label":"Tools"}}}'
$wFull = Get-StripWidth $false
# The same row, written out as what it SHOULD measure: the two plain buttons plus ONE group
# face. If side-bar buttons or extra group members are being counted, these differ.
Set-WidthFixture '{"buttons":[
    {"label":"Review","text":"/review"},{"label":"Commit","text":"/commit"},
    {"label":"GroupOne","text":"/g1","group":"tools"}],"groups":{"tools":{"label":"Tools"}}}'
$wExpected = Get-StripWidth $false
Check "the row measures exactly its row buttons plus ONE group face ($wFull vs $wExpected)" ($wFull -eq $wExpected)
# The same seven buttons with no group and no bars - the shape the old code effectively
# measured. It must be MUCH wider, and by more than the 60px compact-mode hysteresis band, or
# collapsing a group into a face could not switch compact mode off again.
Set-WidthFixture '{"buttons":[
    {"label":"Review","text":"/review"},{"label":"Commit","text":"/commit"},
    {"label":"GroupOne","text":"/g1"},{"label":"GroupTwo","text":"/g2"},
    {"label":"GroupThree","text":"/g3"},{"label":"SideOne","text":"/s1"},
    {"label":"SideTwo","text":"/s2"}]}'
$wFlat = Get-StripWidth $false
Check "grouping and side-bars shrink the row by more than the 60px hysteresis band ($wFlat -> $wFull)" `
    (($wFlat - $wFull) -gt (S 60))
# A row with nothing on it must still measure only its padding, never a negative or a
# stale total.
Set-WidthFixture '{"buttons":[{"label":"SideOne","text":"/s1","bar":"left"}]}'
$wEmpty = Get-StripWidth $false
Check "a row containing only side-bar buttons measures just its chrome ($wEmpty)" `
    (($wEmpty -gt 0) -and ($wEmpty -lt $wFull))
# The short-label switch is what compact mode actually does, so it has to make things smaller.
Set-WidthFixture '{"buttons":[{"label":"A very long button label indeed","text":"/x"}]}'
Check 'the compact (short-label) measurement is narrower than the full one' `
    ((Get-StripWidth $true) -lt (Get-StripWidth $false))

Write-Host ""
if ($fails -eq 0) { Write-Host "Panel tests: $count passed" -ForegroundColor Green; exit 0 }
else { Write-Host "Panel tests: $fails of $count FAILED" -ForegroundColor Red; exit 1 }
