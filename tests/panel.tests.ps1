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
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'claude-buttons.ps1') -SmokeTest 2>&1
    $code = $LASTEXITCODE
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

# --- Escape-SendKeys: exactly what gets typed into Claude (security-relevant encoding) ---
# The input goes through a temp FILE so newlines and metacharacters survive verbatim.
function Esc([string]$in) {
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, $in, (New-Object System.Text.UTF8Encoding($false)))
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $panel -EscapeProbe $tmp 2>$null }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    if ($null -eq $o) { '' } else { -join $o }
}
Check 'plain text passes through unchanged' ((Esc 'hello world') -eq 'hello world')
Check 'SendKeys metachars are braced literal (+ ^ % ~ ( ) { } [ ])' ((Esc '+^%~(){}[]') -eq '{+}{^}{%}{~}{(}{)}{{}{}}{[}{]}')
Check 'a newline becomes Shift+Enter (never a bare submit)' ((Esc "a`nb") -eq 'a+{ENTER}b')
Check 'CRLF and CR both normalize to Shift+Enter' ((Esc "a`r`nb`rc") -eq 'a+{ENTER}b+{ENTER}c')
Check 'a slash command is not mangled' ((Esc '/shutdown-on-done on') -eq '/shutdown-on-done on')
Check 'empty text yields empty output' ((Esc '') -eq '')

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
$srcText = $src -join "`n"   # defined here too: these checks run before the doc-vs-code block
# Ctrl+V is asynchronous. If the clipboard is restored before the app reads it, the app pastes
# the USER'S clipboard: wrong message, and their copied data leaked into an AI conversation.
# The old code typed the correct text whenever the paste could not be confirmed - and THAT is
# what turned a detected problem into a sent one, because it appended the right text under the
# contamination and pressed Enter. These guard the invariant that replaced it: on anything
# other than a confirmed paste, type nothing, send nothing, change nothing.
Check 'the send path no longer types a fallback payload' `
    (-not ($srcText -match 'SendWait\(\(Escape-SendKeys \$textToSend\)\)'))
Check 'an unconfirmed paste returns instead of pressing Enter' `
    ($srcText -match '(?s)if \(-not \$pasted\).{0,600}?return')
Check 'the composer baseline is captured BEFORE the clipboard is touched' `
    ([regex]::Match($srcText, '(?s)\$baseline = Get-ComposerText.{0,400}?Clipboard\]::GetDataObject').Success)
Check 'verification compares baseline+payload exactly, not a substring' `
    (($srcText -match '\$want = Normalize-ComposerText \(\$baseline \+ \$payload\)') -and
     ($srcText -match '-eq \$want'))
Check 'an unreadable composer is treated as Unverifiable, never as empty' `
    ($srcText -match "if \(\`$null -eq \`$baseline\) \{ 'Unverifiable' \}")
Check 'the three paste outcomes are explicit states, not a nullable boolean' `
    (($srcText -match "'Confirmed'") -and ($srcText -match "'Mismatch'") -and ($srcText -match "'Unverifiable'"))
Check 'an abandoned send warns the user rather than only logging' `
    (($srcText -match 'Show-SendWarning') -and ($srcText -match 'sendMismatch') -and ($srcText -match 'sendUnverified'))
Check 'no undo/select-all recovery was introduced (it would eat a user draft)' `
    (-not ($srcText -match "SendWait\('\^z'\)|SendWait\('\^a'\)"))
foreach ($lang in @('en', 'da')) {
    Check "the abandoned-send strings exist in $lang" `
        (($srcText -match "(?s)\b$lang\s*=\s*@\{.*?sendMismatch") -and ($srcText -match "(?s)\b$lang\s*=\s*@\{.*?sendUnverified"))
}

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

Write-Host ""
if ($fails -eq 0) { Write-Host "Panel tests: $count passed" -ForegroundColor Green; exit 0 }
else { Write-Host "Panel tests: $fails of $count FAILED" -ForegroundColor Red; exit 1 }
