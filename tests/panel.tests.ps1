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
function PasteState([string]$json, [switch]$Raw) {
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
Check 'a clean paste into an EMPTY composer is Confirmed' `
    ((PasteState '{"baseline":"\n","payload":"/review","observed":"/review\n"}') -eq 'Confirmed')
# The regression that would have made the panel useless in daily use: an "empty" Chromium
# composer reads as "\n" and a draft as "draft\n", so concatenating the raw baseline put that
# terminator mid-string and every click with a draft in the box refused to send.
Check 'a clean paste on top of a USER DRAFT is Confirmed (not refused)' `
    ((PasteState '{"baseline":"udkast\n","payload":"/review","observed":"udkast/review\n"}') -eq 'Confirmed')
Check 'a stale clipboard landing instead of the payload is a Mismatch' `
    ((PasteState '{"baseline":"\n","payload":"/review","observed":"secret token\n"}') -eq 'Mismatch')
# The exact shape reported in PR #4: stale text prepended, our payload also present. A
# "contains the payload" probe would call this a success and submit both.
Check 'stale text PLUS our payload is still a Mismatch' `
    ((PasteState '{"baseline":"\n","payload":"/review","observed":"secret token/review\n"}') -eq 'Mismatch')
# A payload that normalizes away would make want == baseline, satisfying the poll on its first
# read - confirming a paste that never happened and submitting whatever the user already had.
Check 'a whitespace-only payload can never be Confirmed' `
    ((PasteState '{"baseline":"udkast\n","payload":"   ","observed":"udkast\n"}') -eq 'Mismatch')
Check 'an unreadable composer is Unverifiable, never Confirmed' `
    ((PasteState '{"baseline":"\n","payload":"/review","observed":null}') -eq 'Unverifiable')

# Source invariants that cannot be probed: what the caller DOES with the state.
Check 'nothing is submitted unless the paste was Confirmed' `
    ($srcText -match "\`$pasted = \(\`$pasteState -eq 'Confirmed'\)")
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
$failBlock = [regex]::Match($srcText, "(?s)if \(-not \`$pasted\) \{(.*?)\r?\n            \}").Groups[1].Value
Check 'the fail-closed block was located' ($failBlock.Length -gt 40)
Check 'the fail-closed block ends by returning' ($failBlock -match '(?m)^\s*return\s*$')
Check 'no undo/select-all recovery was introduced (it would eat a user draft)' `
    (-not ($srcText -match "SendWait\('\^z'\)|SendWait\('\^a'\)"))
# Both abandoned-send branches must TELL the user. Without this the failure is silent except
# for a log line nobody reads, and "I clicked and nothing happened" is indistinguishable from
# a successful send - which is how this class of bug stayed invisible in the first place.
# F17: these three fixes were real but unguarded - reverting each passed the whole suite.
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
$unverRaw = PasteState '{"baseline":"\n","payload":"/review","observed":null}' -Raw
$quickRaw = PasteState '{"baseline":"\n","payload":"/review","observed":"/review\n"}' -Raw
$unver = ($unverRaw -split '\|')[0]; $unverMs = [int]($unverRaw -split '\|')[1]
$quick = ($quickRaw -split '\|')[0]; $quickMs = [int]($quickRaw -split '\|')[1]
Check 'an unreadable composer returns Unverifiable' ($unver -eq 'Unverifiable')
Check "an unreadable composer polls until its timeout (${unverMs}ms of a 120ms budget)" `
    ($unverMs -ge 100)
Check "a confirmed paste returns without waiting out the timeout (${quickMs}ms)" `
    (($quick -eq 'Confirmed') -and ($quickMs -lt 60))

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
    ((PasteState '{"baseline":"\n","payload":"## Titel\n\n```text\nDu skal svare.\n```","observed":"## Titel\nDu skal svare.\n"}') -eq 'Confirmed')
Check 'rendered bold (asterisks eaten) still confirms' `
    ((PasteState '{"baseline":"\n","payload":"gør det **nu** og grundigt","observed":"gør det nu og grundigt\n"}') -eq 'Confirmed')
# PowerShell unrolls a single-element array when it is passed as an argument, so a one-word
# payload reached the coverage walk as a bare string and it indexed CHARACTERS. A perfect paste
# measured 0% coverage and was refused. Caught by the existing draft test; pinned here too.
Check 'a ONE-WORD payload confirms (single-element array unrolling)' `
    ((PasteState '{"baseline":"\n","payload":"continue","observed":"continue\n"}') -eq 'Confirmed')
Check 'markdown whose blank lines the composer collapsed still confirms' `
    ((PasteState '{"baseline":"\n","payload":"## Heading\n\nBody text.\n\n- item","observed":"## Heading\nBody text.\n- item\n"}') -eq 'Confirmed')
# Coverage alone is satisfied by "stale clipboard THEN our payload" - an in-order walk just
# skips the prefix. The size bound is the half that catches it, so it needs its own test.
# THE COVERAGE HALF WAS ENTIRELY UNPINNED. Five mutants passed all 85 tests: raising
# MaxMissingWords to 99, MaxMissingFraction to 0.90, ExtraFraction to 0.50, deleting the coverage
# check, and making Get-WordCoverage return 1.0. Every 'Confirmed' case above is also satisfied
# by a comparator that always passes on words, and every 'Mismatch' case was caught by the SIZE
# bound - so nothing measured coverage at all. These cases hold size constant and vary only the
# words, so they can ONLY be caught by coverage.
Check 'a substituted word at the SAME length is a Mismatch (coverage, not size)' `
    ((PasteState '{"baseline":"\n","payload":"send nu","observed":"send bad\n"}') -eq 'Mismatch')
Check 'a wholly different text of the same size is a Mismatch (coverage)' `
    ((PasteState '{"baseline":"\n","payload":"gennemgaa min kode","observed":"kontonummer 5479 1122\n"}') -eq 'Mismatch')
Check 'words in the WRONG ORDER are a Mismatch (coverage is ordered)' `
    ((PasteState '{"baseline":"\n","payload":"alfa beta gamma delta epsilon zeta","observed":"zeta epsilon delta gamma beta alfa\n"}') -eq 'Mismatch')
# Non-alnum growth was unbounded: the ceiling counted letters and digits only, so a clipboard of
# emoji or punctuation rode in at any length and was Confirmed.
# The three cases above are all SHORT, so the floor(n/4) cap decides them and MaxMissingWords /
# MaxMissingFraction stay inert - raising them to 99 and 0.90 passed the whole suite. This one is
# 20 words with 4 substituted: the cap allows 5, so only the allowance of 3 can refuse it.
Check 'four substituted words in a twenty-word payload is a Mismatch (MaxMissingWords binds)' `
    ((PasteState '{"baseline":"\n","payload":"et to tre fire fem seks syv otte ni ti elleve tolv tretten fjorten femten seksten sytten atten nitten tyve","observed":"et to xyz fire fem seks qqq otte ni ti zzzzzz tolv tretten fjorten wwwwww seksten sytten atten nitten tyve\n"}') -eq 'Mismatch')
# Likewise every size-based Mismatch above overshoots the ceiling so far that ExtraFraction stayed
# inert - 0.0 -> 0.50 passed everything. This appends ~30% extra, which only the tight ceiling refuses.
Check 'a 30% overshoot is a Mismatch (ExtraFraction binds, not just the absolute margin)' `
    ((PasteState '{"baseline":"\n","payload":"alfa beta gamma delta epsilon zeta eta theta","observed":"alfa beta gamma delta epsilon zeta eta theta kodeord1234\n"}') -eq 'Mismatch')
Check 'injected punctuation/symbols are a Mismatch (non-alnum ceiling)' `
    ((PasteState '{"baseline":"\n","payload":"gennemgaa min kode","observed":"gennemgaa min kode !!! ??? ---> @@@ *** ~~~ %%%\n"}') -eq 'Mismatch')
# The false refusal that shipped twice, in its remaining form: each fence language counted as a
# missing payload word, so four or more fenced blocks in a short button exceeded the allowance.
Check 'a button with FOUR fenced code blocks still confirms' `
    ((PasteState '{"baseline":"\n","payload":"Kør disse:\n```powershell\nGet-Date\n```\n```powershell\nGet-Host\n```\n```json\n{}\n```\n```bash\nls\n```","observed":"Kør disse:\nGet-Date\nGet-Host\n{}\nls\n"}') -eq 'Confirmed')
Check 'a short button that is ONLY a fenced block still confirms' `
    ((PasteState '{"baseline":"\n","payload":"```json\n{\"a\":1}\n```","observed":"{\"a\":1}\n"}') -eq 'Confirmed')
Check 'stale clipboard text pasted ALONGSIDE the payload is a Mismatch (size bound)' `
    ((PasteState '{"baseline":"\n","payload":"## Titel\n\nDu skal svare.","observed":"kodeord hemmeligt kontonummer 4471 privat besked\n## Titel\nDu skal svare.\n"}') -eq 'Mismatch')
Check 'a multi-line payload with blank lines confirms' `
    ((PasteState '{"baseline":"\n","payload":"line one\n\nline three","observed":"line one\nline three\n"}') -eq 'Confirmed')
Check 'a multi-line payload missing its last line is still a Mismatch' `
    ((PasteState '{"baseline":"\n","payload":"line one\n\nline three","observed":"line one\n\n\n"}') -eq 'Mismatch')
# Collapsing whitespace must not blunt contamination detection: stale clipboard text differs in
# its characters, not its spacing, so it must still fail however the composer reflowed it.
Check 'stale clipboard text is a Mismatch even after whitespace collapsing' `
    ((PasteState '{"baseline":"\n","payload":"## Heading\n\nBody text.","observed":"secret token\n## Heading\nBody text.\n"}') -eq 'Mismatch')
Check 'a payload of only newlines is refused, not confirmed by collapsing' `
    ((PasteState '{"baseline":"udkast\n","payload":"\n\n  \n","observed":"udkast\n"}') -eq 'Mismatch')
# Assert the STRING TABLE, not any mention of the key: the previous version matched the
# Show-SendWarning call sites, so deleting every string still passed while the user would have
# got a blank tooltip.
$stringsOk = $true
foreach ($lang in @('en', 'da')) {
    $block = [regex]::Match($srcText, "(?s)\b$lang\s*=\s*@\{(.*?)\r?\n\s*\}").Groups[1].Value
    # sendNoPane joined these when the wrong-chat hazard was fixed: it is the string the user
    # sees when a side-bar send is abandoned because no composer could be identified safely.
    # Without it in this list the feature ships with a blank tooltip in one or both languages.
    foreach ($k in @('sendMismatch', 'sendUnverified', 'sendNoPane')) {
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
$holder = Start-Job -ArgumentList $cfgFile, $readyFile -ScriptBlock {
    param($cfg, $ready)
    $m = New-Object System.Threading.Mutex($false, 'Local\ClaudeButtonsConfig')
    [void]$m.WaitOne(5000)
    try {
        # READ, then think, then write - the classic lost-update shape, and exactly what the
        # skills used to do by hand. Without the lock the CLI's write lands inside this gap
        # and is overwritten by the stale copy read before it.
        $o = Get-Content $cfg -Raw | ConvertFrom-Json
        [IO.File]::WriteAllText($ready, 'held')   # signal AFTER the read, while still holding
        Start-Sleep -Milliseconds 1200
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
try {
    $env:USERPROFILE = Join-Path $dir 'home'
    $lockOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') `
                   -AddButton (Join-Path $dir 'pay.json') 2>&1
} finally { $env:USERPROFILE = $prevHome }
Wait-Job $holder -Timeout 20 | Out-Null
Remove-Job $holder -Force
$finalLabels = ((Get-Content $cfgFile -Raw | ConvertFrom-Json).buttons | ForEach-Object { $_.label }) -join ','
Remove-Item $dir -Recurse -Force

Check 'the CLI waits for the lock and reports success' ("$lockOut" -match 'ADDED')
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
$script:ckLog = @(); $script:rebuilt = 0; $script:flyForm = $null; $script:menuSource = $null
# A test-private mutex name. Taking the panel's real 'Local\ClaudeButtonsConfig' here would
# contend with the user's running panel for no benefit - the lock's own behaviour is covered
# by the concurrent-writer test above.
$script:cfgLock = New-Object System.Threading.Mutex($false, "Local\CbTests-$PID")

# Load, and FAIL LOUDLY if a name has moved. A silent `if ($node)` skip is how a test file
# ends up asserting nothing: rename the function and every test below would pass vacuously
# against whatever definition happened to be left over.
$panelFns = @('Get-ButtonBlocks', 'Get-ButtonBar', 'Same-Button', 'Get-ColorKind', 'Get-KindColor',
              'Read-FreshConfig', 'Write-ConfigAtomic', 'Update-Buttons', 'Update-Config',
              'Set-ButtonBar', 'Set-ButtonGroup', 'Set-KindColor', 'Move-GroupMember', 'Move-PinButton')
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
# The dissolve action is a click handler, not a function, so it is extracted as the
# scriptblock argument of $miDissolve.add_Click({...}) and invoked as-is.
$dissolveNode = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq '$miDissolve' -and $n.Member.Extent.Text -eq 'add_Click' }, $true)
Check 'the dissolve click handler was located in the source' ($null -ne $dissolveNode -and $dissolveNode.Arguments.Count -eq 1)
$dissolveAction = if ($dissolveNode) { [scriptblock]::Create($dissolveNode.Arguments[0].ScriptBlock.EndBlock.Extent.Text) } else { $null }

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
        $ret = & $Action
        $raw = Get-Content $script:configPath -Raw
        [pscustomobject]@{ Cfg = ($raw | ConvertFrom-Json); Raw = $raw; Ret = $ret; Rebuilt = $script:rebuilt }
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
$r = Invoke-PanelEdit $dissJson ([pscustomobject]@{ __isGroup = $true; group = 'g' }) $dissolveAction
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
$r = Invoke-PanelEdit $dissJson ([pscustomobject]@{ label = 'A'; text = '/a' }) $dissolveAction
Check 'dissolve on a non-group target changes nothing' `
    ((@($r.Cfg.buttons | Where-Object { $_.group -ceq 'g' }).Count) -eq 2)

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

# --- Update-Config: it writes the WHOLE config under the lock ---
# Zero references before this. Update-Config is the most damaging thing here that had no
# coverage at all: a bad transform does not just misdraw a button, it persists a corrupt
# config file over the user's real one.
$cfgOnlyJson = '{"schemaVersion":1,"buttons":[{"label":"A","text":"/a"}],"targetTitle":"Claude"}'
$r = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) $c | Add-Member -NotePropertyName marker -NotePropertyValue 'set' -Force; $c } }
Check 'Update-Config persists a whole-config change' (($r.Ret -eq $true) -and ($r.Cfg.marker -eq 'set'))
Check 'Update-Config preserves the fields the transform did not touch' `
    (($r.Cfg.targetTitle -eq 'Claude') -and ((Labels $r.Cfg) -eq 'A'))
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
#
# *** THIS CHECK IS CURRENTLY RED. It is a real, reproducible defect in Update-Config, not a
# broken test. The fix is one line in claude-buttons.ps1 - tighten the existing guard to
#     if (-not $fresh -or -not $fresh.PSObject.Properties['buttons']) { return $false }
# - which this file cannot make, because it does not own the panel script. ***
$rShape = Invoke-PanelEdit $cfgOnlyJson $null { Update-Config { param($c) 'totally not a config' } }
Check 'a transform returning a WRONG-SHAPED object is refused, not written' `
    (($rShape.Ret -eq $false) -or ($null -ne $rShape.Cfg.PSObject.Properties['buttons']))
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
foreach ($fn in @('Resolve-StripForm', 'Get-PaneForForm', 'Get-StripWidth', 'Get-PillWidth',
                  'Get-ShortLabel', 'Get-GroupDef', 'Get-IconGlyph', 'Test-ChatButtonVisible', 'S')) {
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
$unguarded = @(); $guardVars = @()
foreach ($fc in $focusCalls) {
    $p = $fc.Parent; $guarded = $false
    while ($p -and $p -ne $pillFn) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            $guarded = $true
            $guardVars += @($p.Clauses[0].Item1.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                ForEach-Object { $_.Extent.Text })
        }
        $p = $p.Parent
    }
    if (-not $guarded) { $unguarded += $fc.Extent.Text }
}
Check 'the geometric fallback is not reachable unconditionally from Invoke-PillClick' ($unguarded.Count -eq 0)
# ...and the guard must be computed from the row-strip identity, not hardcoded. Every guard
# variable is traced back to its assignment inside Invoke-PillClick; at least one must be
# derived from $form or $script:mirrors, which is what "this is a row strip" means here.
$guardVars = @($guardVars | Sort-Object -Unique)
$rowDerived = $false
foreach ($gv in $guardVars) {
    $asns = @($pillFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $gv }, $true))
    foreach ($a in $asns) {
        if ($a.Right.Extent.Text -match '\$script:mirrors|\$form\b') { $rowDerived = $true }
    }
}
Check "the fallback guard is derived from the row-strip identity (vars: $($guardVars -join ', '))" $rowDerived
# And the refusal must be VISIBLE. A silent return is indistinguishable from a successful
# send - which is how this whole class of bug stayed invisible: "I clicked and nothing
# happened" reads as a flaky panel, not as a refusal that protected the user.
Check 'the abandoned side-bar send warns the user (sendNoPane)' ($srcText -match "Show-SendWarning \(L 'sendNoPane'\)")

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
