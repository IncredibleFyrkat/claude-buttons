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
# Trimming the baseline before concatenating discarded the user's own trailing whitespace, but
# the paste lands AFTER it and it is still in the box - so "draft " + "/cmd" expected
# "draft/cmd" while the composer read "draft /cmd". Every click on a draft ending in a space
# was refused as a failed paste. Only the composer's own terminator may be stripped.
Check 'a draft ending in a SPACE is Confirmed, not refused' `
    ((PasteState '{"baseline":"hi there \n","payload":"/review","observed":"hi there /review\n"}') -eq 'Confirmed')
Check 'leading whitespace in the draft is preserved too' `
    ((PasteState '{"baseline":"  indented\n","payload":"/review","observed":"  indented/review\n"}') -eq 'Confirmed')
# The other side of that coin: whitespace must not become a way to satisfy the check without a
# paste, or the panel would submit the user's draft on its own.
Check 'a whitespace-only payload is refused' `
    ((PasteState '{"baseline":"hi\n","payload":"   ","observed":"hi   \n"}') -eq 'Mismatch')
Check 'a paste that never landed is still a Mismatch' `
    ((PasteState '{"baseline":"hi\n","payload":"/review","observed":"hi\n"}') -eq 'Mismatch')
# An 'empty' composer does not report empty - it reports its PLACEHOLDER, because the
# TextPattern range covers the placeholder node. Treating that as content made the expected
# string placeholder+payload while the box correctly held the payload alone, so EVERY click
# into an empty composer was refused as a failed paste.
Check 'a placeholder baseline does not block the send' `
    ((PasteState '{"baseline":"Type / for commands","payload":"/review","observed":"/review"}') -eq 'Confirmed')
# That leniency must not extend to a stale clipboard: the box holding something OTHER than our
# payload is still a refusal, whatever the baseline was.
Check 'a placeholder baseline still refuses foreign text' `
    ((PasteState '{"baseline":"Type / for commands","payload":"/review","observed":"secret token"}') -eq 'Mismatch')
Check 'a placeholder baseline still refuses stale PLUS payload' `
    ((PasteState '{"baseline":"Type / for commands","payload":"/review","observed":"secret token/review"}') -eq 'Mismatch')
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
Check 'a multi-line payload with blank lines confirms' `
    ((PasteState '{"baseline":"\n","payload":"line one\n\nline three","observed":"line one\n\nline three\n"}') -eq 'Confirmed')
Check 'a multi-line payload missing its last line is a Mismatch' `
    ((PasteState '{"baseline":"\n","payload":"line one\n\nline three","observed":"line one\n\n\n"}') -eq 'Mismatch')
# Assert the STRING TABLE, not any mention of the key: the previous version matched the
# Show-SendWarning call sites, so deleting every string still passed while the user would have
# got a blank tooltip.
$stringsOk = $true
foreach ($lang in @('en', 'da')) {
    $block = [regex]::Match($srcText, "(?s)\b$lang\s*=\s*@\{(.*?)\r?\n\s*\}").Groups[1].Value
    foreach ($k in @('sendMismatch', 'sendUnverified')) {
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
# --- Ordering: groups move as ONE block ---
# Left/right used to swap two adjacent array entries. Once a group could span several entries
# that was wrong twice over: moving a group dragged a single member out of it, and moving a
# plain button past a group landed it in the group's middle. Both silently lose a button from
# the bar, so the block algebra is checked directly.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($panel, [ref]$null, [ref]$null)
foreach ($fn in @('Get-ButtonBlocks')) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    if ($node) { Invoke-Expression $node.Extent.Text }
}
function Same-Button($a, $b) { ($a.label -eq $b.label) -and ($a.text -eq $b.text) -and ([string]$a.chat -eq [string]$b.chat) }

function Swap-Blocks($btns, $key, [int]$dir) {
    $blocks = @(Get-ButtonBlocks $btns)
    $bi = -1
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        if ($blocks[$i].key -eq $key) { $bi = $i; break }
        if (-not $key -and -not $blocks[$i].key) { }
    }
    $nb = $bi + $dir
    if ($bi -lt 0 -or $nb -lt 0 -or $nb -ge $blocks.Count) { return $btns }
    $tmp = $blocks[$bi]; $blocks[$bi] = $blocks[$nb]; $blocks[$nb] = $tmp
    $out = @(); foreach ($blk in $blocks) { $out += $blk.items }
    $out
}

$cfg = @(
    [pscustomobject]@{ label = 'A'; text = '/a' },
    [pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'grp' },
    [pscustomobject]@{ label = 'G2'; text = '/g2'; group = 'grp' },
    [pscustomobject]@{ label = 'B'; text = '/b' }
)
$blocks = @(Get-ButtonBlocks $cfg)
Check 'a group collapses to one block (A, grp, B)' ($blocks.Count -eq 3 -and $blocks[1].key -eq 'g:grp' -and $blocks[1].items.Count -eq 2)

$moved = @(Swap-Blocks $cfg 'g:grp' -1)
Check 'moving a group left keeps its members together' ((($moved | ForEach-Object { $_.label }) -join ',') -eq 'G1,G2,A,B')
Check 'moving a group never loses a button' ($moved.Count -eq $cfg.Count)

$moved2 = @(Swap-Blocks $cfg 'g:grp' 1)
Check 'moving a group right jumps the whole block past B' ((($moved2 | ForEach-Object { $_.label }) -join ',') -eq 'A,B,G1,G2')

$edge = @(Swap-Blocks $cfg 'g:grp' -99)
Check 'an out-of-range move is a no-op, not a truncation' ($edge.Count -eq $cfg.Count)

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
$mapOk = $true
$roundBroke = $false
for ($i = 0; $i -lt 12; $i++) {
    if ([int][Math]::Floor($i / 2) -ne [Math]::Truncate($i / 2)) { $mapOk = $false }
    if ([int]($i / 2) -ne [Math]::Truncate($i / 2)) { $roundBroke = $true }
}
Check 'floor maps every strip index to its own pane' $mapOk
Check '[int] does NOT (guards the fix from being reverted to it)' $roundBroke
Check 'the source uses Floor for the strip->pane map' (((Get-Content $panel -Raw) -split "`n" | Where-Object { $_ -match '\$pIdx = ' } | Where-Object { $_ -notmatch 'Floor' }).Count -eq 0)

# --- Reordering is per-bar ---
# The bars share one array. Ordering across the whole of it would let a move on the row
# reshuffle the side bars, or land a row button in the middle of a side bar's run.
function Get-ButtonBar($b) { $v = [string]$b.bar; if (@('row','left','right') -contains $v) { $v } else { 'row' } }
function Reorder-InBar($btns, $t, [int]$dir) {
    $btns = @($btns)
    $bar = Get-ButtonBar $t
    $idxs = @()
    for ($i = 0; $i -lt $btns.Count; $i++) { if ((Get-ButtonBar $btns[$i]) -eq $bar) { $idxs += $i } }
    $blocks = @(Get-ButtonBlocks @($idxs | ForEach-Object { $btns[$_] }))
    $bi = -1
    for ($i = 0; $i -lt $blocks.Count; $i++) { if (Same-Button $blocks[$i].items[0] $t) { $bi = $i; break } }
    $nb = $bi + $dir
    if ($bi -lt 0 -or $nb -lt 0 -or $nb -ge $blocks.Count) { return $btns }
    $tmp = $blocks[$bi]; $blocks[$bi] = $blocks[$nb]; $blocks[$nb] = $tmp
    $out = @(); foreach ($blk in $blocks) { $out += $blk.items }
    for ($k = 0; $k -lt $idxs.Count; $k++) { $btns[$idxs[$k]] = $out[$k] }
    $btns
}
$mix = @(
    [pscustomobject]@{ label = 'R1'; text = '/r1' },
    [pscustomobject]@{ label = 'L1'; text = '/l1'; bar = 'left' },
    [pscustomobject]@{ label = 'R2'; text = '/r2' },
    [pscustomobject]@{ label = 'L2'; text = '/l2'; bar = 'left' }
)
$m = @(Reorder-InBar $mix $mix[1] 1)
Check 'moving a left-bar button reorders only the left bar' ((($m | ForEach-Object { $_.label }) -join ',') -eq 'R1,L2,R2,L1')
Check 'the row buttons keep their own positions' ((($m | Where-Object { -not $_.bar } | ForEach-Object { $_.label }) -join ',') -eq 'R1,R2')
$m2 = @(Reorder-InBar $mix $mix[0] 1)
Check 'moving a row button does not disturb the side bar' ((($m2 | Where-Object { $_.bar } | ForEach-Object { $_.label }) -join ',') -eq 'L1,L2')
$m3 = @(Reorder-InBar $mix $mix[1] -1)
Check 'the first button on a bar cannot move further down' ((($m3 | ForEach-Object { $_.label }) -join ',') -eq 'R1,L1,R2,L2')

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
function Move-ToBar($btns, $t, [string]$bar) {
    $btns = @($btns); $moving = @(); $rest = @()
    foreach ($b in $btns) {
        if (Same-Button $b $t) {
            if ($bar -eq 'row') { $b.PSObject.Properties.Remove('bar') }
            else { $b | Add-Member -NotePropertyName bar -NotePropertyValue $bar -Force }
            $moving += $b
        } else { $rest += $b }
    }
    $insertAt = -1
    for ($i = 0; $i -lt $rest.Count; $i++) { if ((Get-ButtonBar $rest[$i]) -eq $bar) { $insertAt = $i } }
    if ($insertAt -lt 0) { return @($rest) + @($moving) }
    $out = @()
    for ($i = 0; $i -lt $rest.Count; $i++) { $out += $rest[$i]; if ($i -eq $insertAt) { $out += $moving } }
    $out
}
$cfg2 = @(
    [pscustomobject]@{ label = 'X'; text = '/x' },
    [pscustomobject]@{ label = 'L1'; text = '/l1'; bar = 'left' },
    [pscustomobject]@{ label = 'L2'; text = '/l2'; bar = 'left' },
    [pscustomobject]@{ label = 'Y'; text = '/y' }
)
$moved = @(Move-ToBar $cfg2 $cfg2[0] 'left')
$onLeft = @($moved | Where-Object { $_.bar -eq 'left' } | ForEach-Object { $_.label })
Check 'a button moved to a side bar lands last, not first' (($onLeft -join ',') -eq 'L1,L2,X')
Check 'nothing is lost in the move' ($moved.Count -eq 4)
$first = @(Move-ToBar $cfg2 $cfg2[3] 'right')
Check 'the first button on an empty bar still lands there' ((@($first | Where-Object { $_.bar -eq 'right' }).Count) -eq 1)

# --- Dissolving a group leaves its members where they were ---
# Members already carry the group's bar and already occupy the group face's slot in the array,
# so dropping the group field must be enough. If it were not, dissolving would scatter the
# buttons back to the control row.
function Dissolve($btns, [string]$g) {
    $btns = @($btns)
    foreach ($b in $btns) { if ([string]$b.group -eq $g) { $b.PSObject.Properties.Remove('group') } }
    $btns
}
$grp = @(
    [pscustomobject]@{ label = 'A'; text = '/a' },
    [pscustomobject]@{ label = 'G1'; text = '/g1'; group = 'g'; bar = 'right' },
    [pscustomobject]@{ label = 'G2'; text = '/g2'; group = 'g'; bar = 'right' },
    [pscustomobject]@{ label = 'B'; text = '/b' }
)
$d = @(Dissolve $grp 'g')
Check 'dissolving keeps the members on their bar' ((@($d | Where-Object { $_.bar -eq 'right' }).Count) -eq 2)
Check 'dissolving keeps them in the group face position' ((($d | ForEach-Object { $_.label }) -join ',') -eq 'A,G1,G2,B')
Check 'no member is left claiming the group' ((@($d | Where-Object { $_.group }).Count) -eq 0)
Check 'they are now separate blocks, not one' ((@(Get-ButtonBlocks $d).Count) -eq 4)

# --- Every strip window must resolve to a pane ---
# Get-PaneForForm maps a strip's window to the pane whose composer it sends to. A window it
# does not know returns $null, and the send falls back to picking a composer by geometry - which
# in a grid is a neighbouring chat. Side strips were missing from it, so their buttons could not
# send at all. Static check: every strip collection the panel creates must appear in the lookup.
$fnSrc = ''
$astP = [System.Management.Automation.Language.Parser]::ParseFile($panel, [ref]$null, [ref]$null)
$fnNode = $astP.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PaneForForm' }, $true)
if ($fnNode) { $fnSrc = $fnNode.Extent.Text }
Check 'Get-PaneForForm was found' ($fnSrc.Length -gt 0)
Check 'it resolves the primary strip' ($fnSrc -match '\$frm -eq \$form')
Check 'it resolves mirror strips' ($fnSrc -match 'script:mirrors')
Check 'it resolves side strips (else their buttons cannot send)' ($fnSrc -match 'script:sideStrips')
Check 'it resolves flyout buttons via their owning strip' ($fnSrc -match 'flyForm')
Check 'the side-strip map truncates rather than rounds' (($fnSrc -split "`n" | Where-Object { $_ -match 'sideStrips' -or $_ -match '\$idx = ' } | Where-Object { $_ -match '\[int\]\(\$i / 2\)' }).Count -eq 0)

# --- The dock cluster is the biggest tight RUN, not the first one ---
# Measured on a live grid: controls inside a cluster sit 6-7px apart, but with the
# bypass-permissions chip on, a lone control sits ~145px to the LEFT of the real icon cluster.
# Walking from the leftmost control stopped on that stray immediately (n=1 of 4), so the strip
# docked before the app's own +/mic and drew over them - in that one pane, while the pane below
# it was fine.
function Pick-Run($items, [int]$gap) {
    $runs = @(); $cur = @(); $prevR = $null
    foreach ($rb in ($items | Sort-Object X)) {
        if ($null -ne $prevR -and $rb.X -gt ($prevR + $gap)) { if ($cur.Count) { $runs += , $cur }; $cur = @() }
        $cur += $rb
        if ($null -eq $prevR -or $rb.R -gt $prevR) { $prevR = $rb.R }
    }
    if ($cur.Count) { $runs += , $cur }
    $best = $null
    foreach ($r in $runs) { if ($null -eq $best -or $r.Count -gt $best.Count) { $best = $r } }
    $best
}
function B($x, $w) { [pscustomobject]@{ X = [double]$x; R = [double]($x + $w) } }

# stray chip at 0..30, real cluster at 175 onward (the measured 145px gap)
$bypass = @( (B 0 30), (B 175 27), (B 208 27), (B 241 27) )
$pick = @(Pick-Run $bypass 20)
Check 'the stray control is skipped for the real cluster' ($pick.Count -eq 3)
Check 'the dock lands after the cluster, not after the stray' ((($pick | Measure-Object -Property R -Maximum).Maximum) -eq 268)

# the original defect this walk exists for: one control sitting PAST the cluster
$trailing = @( (B 0 27), (B 33 27), (B 66 27), (B 200 27) )
$pick2 = @(Pick-Run $trailing 20)
Check 'a lone control past the cluster is still excluded' ($pick2.Count -eq 3)
Check 'the trailing stray does not drag the dock right' ((($pick2 | Measure-Object -Property R -Maximum).Maximum) -eq 93)

$normal = @( (B 0 27), (B 33 27), (B 66 27), (B 99 27) )
Check 'an ordinary row is one run, unchanged' ((@(Pick-Run $normal 20)).Count -eq 4)

Write-Host ""
if ($fails -eq 0) { Write-Host "Panel tests: $count passed" -ForegroundColor Green; exit 0 }
else { Write-Host "Panel tests: $fails of $count FAILED" -ForegroundColor Red; exit 1 }
