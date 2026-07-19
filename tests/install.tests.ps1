# Behavioural tests for install.ps1 - the file with the largest blast radius in the project,
# because it edits the user's GLOBAL ~/.claude/settings.json. Until now it had only a syntax
# parse check, and three serious defects shipped in it in a single day.
#
# The seam: install.ps1 is a script, not a module, so we extract its function definitions via
# the PowerShell AST and dot-source ONLY those. The main flow never runs, nothing is installed,
# and $settingsPath is pointed at a throwaway temp file. The real ~/.claude is never touched.
#
# Run standalone:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\install.tests.ps1
$ErrorActionPreference = 'Stop'
$repo    = Split-Path $PSScriptRoot -Parent
$install = Join-Path $repo 'install.ps1'
$fails   = 0
$count   = 0

function Check([string]$name, [bool]$cond) {
    $script:count++
    if ($cond) { Write-Host "  ok  $name" -ForegroundColor DarkGreen }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fails++ }
}

Write-Host "Installer behaviour tests"

# ---- Load the functions without executing the installer -------------------------------
$ast = [System.Management.Automation.Language.Parser]::ParseFile($install, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
Check "extracted the installer's functions ($($funcs.Count) found)" ($funcs.Count -ge 14)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cb-inst-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$settingsPath = Join-Path $sandbox 'settings.json'   # the functions close over this name

function Set-Settings([string]$text) {
    [IO.File]::WriteAllText($settingsPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Get-ChildItem $sandbox -Filter '*.bak' | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Try-Call([scriptblock]$sb) {
    try { & $sb; @{ Threw = $false; Msg = '' } } catch { @{ Threw = $true; Msg = "$($_.Exception.Message)" } }
}

# ---- Write-JsonAtomic ------------------------------------------------------------------
Set-Settings '{"keep":"me"}'
$r = Try-Call { Write-JsonAtomic $settingsPath '{"hello":"world"}' }
Check 'writes valid JSON' ((-not $r.Threw) -and ((Get-Content $settingsPath -Raw | ConvertFrom-Json).hello -eq 'world'))
Check 'writes JSON without a BOM' (([IO.File]::ReadAllBytes($settingsPath))[0] -ne 0xEF)

# The safety net must not certify a destroyed file. `$null | ConvertTo-Json` is the EMPTY
# STRING, and '' / '   ' / 'null' all parse back without throwing - so an unguarded validator
# would happily swap in a 0-byte settings.json and call it valid.
foreach ($bad in @('', '   ', 'null', '123', '"just a string"')) {
    Set-Settings '{"precious":"data"}'
    $r = Try-Call { Write-JsonAtomic $settingsPath $bad }
    $intact = (Get-Content $settingsPath -Raw) -eq '{"precious":"data"}'
    Check "refuses to write non-object payload '$($bad.Trim())' and leaves the file intact" ($r.Threw -and $intact)
}

Set-Settings '{"precious":"data"}'
$r = Try-Call { Write-JsonAtomic $settingsPath 'this is not json {{{' }
Check 'refuses to write unparseable JSON' ($r.Threw -and ((Get-Content $settingsPath -Raw) -eq '{"precious":"data"}'))
Check 'leaves no .tmp litter behind after a refusal' (-not (Get-ChildItem $sandbox -Filter '*.tmp.*' -ErrorAction SilentlyContinue))

# ---- The depth guard must not fire on legitimate STRING content -------------------------
# An earlier version searched the SERIALIZED TEXT for "@{ and so refused perfectly valid
# configs: a hook command, an env value or a statusLine may legitimately contain those
# characters. Structural damage and string content are indistinguishable once serialized.
$legit = @(
    @{ n = 'hook command containing a PowerShell hashtable'
       o = [pscustomobject]@{ hooks = [pscustomobject]@{ Stop = @([pscustomobject]@{ hooks = @([pscustomobject]@{ command = 'powershell -c "@{a=1} | ConvertTo-Json"' }) }) } } },
    @{ n = 'env value using @{...} template syntax'
       o = [pscustomobject]@{ env = [pscustomobject]@{ TPL = '@{name=$x}' } } },
    @{ n = 'allow-rule naming System.Object[]'
       o = [pscustomobject]@{ permissions = [pscustomobject]@{ allow = @('Bash(dotnet run "System.Object[]")') } } },
    @{ n = 'statusLine echoing @{branch}'
       o = [pscustomobject]@{ statusLine = [pscustomobject]@{ command = 'echo "@{branch}"' } } }
)
# Route these through Save-Settings, not Assert-JsonDepthSafe directly: the guard has to
# protect the WRITE path, and testing the helper in isolation left the old text-search version
# free to be reinstated inside Save-Settings without any test noticing.
foreach ($c in $legit) {
    Set-Settings '{"start":true}'
    $r = Try-Call { Save-Settings $c.o }
    $wrote = (Test-Path $settingsPath) -and ((Get-Content $settingsPath -Raw).Length -gt 2)
    Check "depth guard accepts a valid config, through Save-Settings: $($c.n)" ((-not $r.Threw) -and $wrote)
}

# ...and it must still reject genuinely over-deep structures.
# Assert on the MESSAGE, not merely that something threw: asserting `$r.Threw` alone passed
# even when Assert-JsonDepthSafe did not exist at all (a CommandNotFoundException is also a
# throw). That is the same tautology class that has bitten this project twice.
$deep = [pscustomobject]@{ a = $null }
$node = $deep
for ($i = 0; $i -lt 120; $i++) { $child = [pscustomobject]@{ a = $null }; $node.a = $child; $node = $child }
$r = Try-Call { Assert-JsonDepthSafe $deep }
Check 'depth guard rejects a genuinely over-deep OBJECT (with the right error)' ($r.Threw -and ($r.Msg -match 'nests deeper'))

# An over-deep ARRAY chain must be measured too. `hooks` is an array of objects containing
# arrays of objects, and walking children via @()/the pipeline UNROLLS nested arrays - a
# 10-deep array chain measured 6, so a genuinely over-deep config could slip past the guard
# and be silently stringified by ConvertTo-Json.
$deepArr = @('leaf')
for ($i = 0; $i -lt 120; $i++) { $deepArr = @(, $deepArr) }
$r = Try-Call { Assert-JsonDepthSafe $deepArr }
Check 'depth guard rejects a genuinely over-deep ARRAY (with the right error)' ($r.Threw -and ($r.Msg -match 'nests deeper'))
# Build it in a plain variable: returning the array from a scriptblock sends it through the
# pipeline, which unrolls a level - the very effect being tested for.
$a10 = @('x'); for ($i = 0; $i -lt 10; $i++) { $a10 = @(, $a10) }
Check 'a 10-deep array measures 11, not 6 (no pipeline unrolling)' ((Get-JsonDepth $a10) -eq 11)

# The REJECT path must be enforced by Save-Settings, not merely by the helper. Testing only
# the helper is what let rounds 1 and 2 ship: deleting the `Assert-JsonDepthSafe $obj` call
# from Save-Settings left the whole suite green while the write path was unprotected.
Set-Settings '{"precious":"data"}'
$r = Try-Call { Save-Settings $deep }
Check 'Save-Settings itself REFUSES an over-deep object (not just the helper)' `
    ($r.Threw -and ($r.Msg -match 'nests deeper'))
Check 'a refused Save-Settings leaves the file untouched' ((Get-Content $settingsPath -Raw) -eq '{"precious":"data"}')

# Hashtable input: a separate branch of Get-JsonDepth that nothing exercised. Unreachable from
# ConvertFrom-Json (which yields PSCustomObject) but reachable from any caller that builds one.
Check 'Get-JsonDepth measures IDictionary depth too' ((Get-JsonDepth @{a=@{b=@{c=@{d=1}}}}) -eq 4)

# The pre-flight also runs the depth check, so the throw lands before anything is deleted
# rather than half-way through an uninstall. NOT tested via a file, and deliberately so:
# measurement shows ConvertTo-Json only corrupts at depth 102, and ConvertFrom-Json REFUSES to
# parse at 102 - so a settings.json that would trip the guard cannot be read in the first place
# and Get-Settings rejects it earlier with "not valid JSON". The pre-flight's depth call is
# belt-and-braces for non-file callers. Asserting it here via a crafted file would produce a
# test that passes for the wrong reason, which is the failure mode this suite exists to avoid.
Check 'Test-SettingsUsable invokes the depth guard (unreachable from a file - see comment)' `
    ([bool]([regex]::Match((Get-Content $install -Raw),
        '(?s)function Test-SettingsUsable.*?Assert-JsonDepthSafe').Success))

# ---- Test-SettingsUsable ----------------------------------------------------------------
Set-Settings '{"valid":true}'
Check 'pre-flight accepts a valid settings.json' (-not (Try-Call { Test-SettingsUsable }).Threw)

foreach ($bad in @('', '   ', 'null')) {
    Set-Settings $bad
    $r = Try-Call { Test-SettingsUsable }
    Check "pre-flight rejects an empty/null settings.json ('$($bad.Trim())')" ($r.Threw -and ($r.Msg -match 'empty|not a JSON object'))
}

Set-Settings '{ not json at all'
$r = Try-Call { Test-SettingsUsable }
Check 'pre-flight rejects invalid JSON' ($r.Threw -and ($r.Msg -match 'not valid JSON'))
Check 'pre-flight says nothing was changed' ($r.Msg -match 'NOTHING has been changed')

Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue
Check 'pre-flight is a no-op when settings.json does not exist yet' (-not (Try-Call { Test-SettingsUsable }).Threw)

# ---- Hook merging: must never clobber a foreign hook -------------------------------------
Set-Settings '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo SOMEONE-ELSES-HOOK"}]}]}}'
$s = Get-Settings
Ensure-HookArray $s 'UserPromptSubmit'
$s.hooks.UserPromptSubmit = @($s.hooks.UserPromptSubmit) + [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'echo active-session.json' }) }
Save-Settings $s
$after = Get-Content $settingsPath -Raw
Check "merging preserves another tool's hook" ($after -match 'SOMEONE-ELSES-HOOK')
Check 'merging adds our own hook' ($after -match 'active-session\.json')

# Hook-Exists must find ours so a re-install is idempotent - AND must not claim to find a hook
# that isn't there, which would make the installer silently skip adding it.
$s2 = Get-Settings
Check 'Hook-Exists finds the hook we just added (install is idempotent)' (Hook-Exists $s2 'UserPromptSubmit' 'active-session.json')
Check 'Hook-Exists does NOT report a hook that is absent' (-not (Hook-Exists $s2 'UserPromptSubmit' 'no-such-marker-xyz'))
Check 'Hook-Exists does NOT report a hook in an event that has none' (-not (Hook-Exists $s2 'Stop' 'active-session.json'))

# First install: settings with no hooks at all. Ensure-HookArray was only ever exercised on
# settings that already had the array, where a no-op is indistinguishable from working.
$fresh = New-Object psobject
Ensure-HookArray $fresh 'UserPromptSubmit'
Check 'Ensure-HookArray creates the structure on a settings file with no hooks (first install)' `
    ($fresh.PSObject.Properties['hooks'] -and $null -ne $fresh.hooks.PSObject.Properties['UserPromptSubmit'])

# Allow-rule helpers had no behavioural coverage at all.
Set-Settings '{}'
$ar = Get-Settings
Ensure-AllowRule $ar 'Bash(echo one)'
Ensure-AllowRule $ar 'Bash(echo one)'      # idempotent
Ensure-AllowRule $ar 'Bash(other-tool)'
Check 'Ensure-AllowRule adds a rule' ([bool](@($ar.permissions.allow) | Where-Object { $_ -eq 'Bash(echo one)' }))
Check 'Ensure-AllowRule is idempotent' ((@($ar.permissions.allow) | Where-Object { $_ -eq 'Bash(echo one)' }).Count -eq 1)
Remove-AllowRules $ar 'echo one'
Check 'Remove-AllowRules removes the matching rule' (-not (@($ar.permissions.allow) | Where-Object { $_ -eq 'Bash(echo one)' }))
Check "Remove-AllowRules leaves another tool's rule alone" ([bool](@($ar.permissions.allow) | Where-Object { $_ -eq 'Bash(other-tool)' }))

# Remove-Hook must take ONLY ours
Remove-Hook $s2 'UserPromptSubmit' 'active-session.json'
Save-Settings $s2
$after2 = Get-Content $settingsPath -Raw
Check "uninstall removes our hook" ($after2 -notmatch 'active-session\.json')
Check "uninstall leaves the other tool's hook alone" ($after2 -match 'SOMEONE-ELSES-HOOK')

# ---- Backups -----------------------------------------------------------------------------
Set-Settings '{"pristine":true}'
$s = Get-Settings; $s | Add-Member first 1 -Force; Save-Settings $s
$s = Get-Settings; $s | Add-Member second 2 -Force; Save-Settings $s
$orig = "$settingsPath.orig.bak"
Check 'a pristine .orig.bak is taken' (Test-Path $orig)
Check 'a rolling .bak is also taken (the uninstall message promises it)' (Test-Path "$settingsPath.bak")
Check 'the .orig.bak is WRITE-ONCE (still the untouched original after two saves)' `
    (((Get-Content $orig -Raw | ConvertFrom-Json).PSObject.Properties.Name -join ',') -eq 'pristine')

# ---- The SEC-01 allow-rule scoping --------------------------------------------------------
# request-on must NOT be pre-authorised: it creates the marker that `toggle on` requires, so
# allow-listing both let injected instructions walk the whole chain unattended.
# Test the RESULT, not the source text. Grepping the `foreach ($verb in @(...))` literal was
# evadable: adding an Ensure-AllowRule call for request-on anywhere OUTSIDE that loop left the
# whole suite green with the command fully pre-authorised. Replay the installer's own
# allow-rule block against a sandbox settings object and assert on what it actually grants.
# EXECUTE the grant function and assert on the permissions it actually produces. Every
# source-text version of this check has been evaded: first by adding a grant outside the
# foreach loop, then by building the verb from a variable (`$rv = 'request' + '-on'`), which
# defeats any grep for the literal. Asserting the resulting permission set is immune to how
# the verb is spelled, because it inspects the outcome rather than the spelling.
Set-Settings '{}'
$granted = Get-Settings
Grant-ShutdownAllowRules $granted 'C:/Users/test/.claude/hooks/shutdown-on-done.mjs'
$rules = @($granted.permissions.allow)
Check "Grant-ShutdownAllowRules produces rules ($($rules.Count))" ($rules.Count -gt 0)
Check 'request-on is NOT pre-authorised, however it is spelled (SEC-01)' `
    (-not ($rules | Where-Object { $_ -match 'toggle\s+request-on' }))
Check 'no wildcard rule is granted (SEC-02)' (-not ($rules | Where-Object { $_ -match 'toggle\s+\*' }))
Check 'off IS pre-authorised (disarming must stay friction-free)' `
    ([bool]($rules | Where-Object { $_ -match 'toggle\s+off' }))
Check 'status IS pre-authorised' ([bool]($rules | Where-Object { $_ -match 'toggle\s+status' }))
Check 'on --this-turn IS pre-authorised (the arm itself, gated by the request marker)' `
    ([bool]($rules | Where-Object { $_ -match 'toggle\s+on\s+--this-turn' }))

# Granting twice must not duplicate: -Update re-runs this on every upgrade.
$before = @($granted.permissions.allow).Count
Grant-ShutdownAllowRules $granted 'C:/Users/test/.claude/hooks/shutdown-on-done.mjs'
Check 'granting twice is idempotent (no duplicate rules on -Update)' `
    (@($granted.permissions.allow).Count -eq $before)

# The install marker: /pin and /unpin cannot locate the panel without it, and it has already
# been broken once on this machine. It was a bare call in the main flow, which this seam
# cannot reach - so deleting it or pointing it elsewhere left the suite green.
$markerHome = Join-Path $sandbox 'markerhome'
New-Item -ItemType Directory -Force -Path $markerHome | Out-Null
Write-InstallMarker $markerHome 'C:\Some\Install\buttons.json'
$markerFile = Join-Path $markerHome 'claude-buttons-path.txt'
Check 'the install marker is written' (Test-Path $markerFile)
Check 'the marker contains the config path verbatim' (([IO.File]::ReadAllText($markerFile)) -eq 'C:\Some\Install\buttons.json')
Check 'the marker has NO BOM (the skills read it as a path)' (([IO.File]::ReadAllBytes($markerFile))[0] -ne 0xEF)

# Scope this to the frontmatter GRANT line only. The skill body must still tell the agent to
# run request-on - the point of SEC-01 is that the command prompts, not that it is forbidden.
$skillLines = Get-Content (Join-Path $repo 'skills-optional\shutdown-on-done\SKILL.md')
$allowLine = ($skillLines | Where-Object { $_ -match '^allowed-tools:' } | Select-Object -First 1)
Check 'the skill declares an allowed-tools line' ($null -ne $allowLine)
Check 'the skill does not re-grant a toggle * wildcard (SEC-02)' ($allowLine -notmatch 'toggle \*')
Check 'the skill does not pre-authorise request-on either (SEC-01)' ($allowLine -notmatch 'toggle request-on')
Check 'the skill body still instructs the agent to run request-on (it just prompts)' `
    ((($skillLines -join "`n") -match 'toggle request-on'))

# ---- Stop-Panel must kill the PANEL and nothing else (INST-01) ----------------------------
# The old filter was `CommandLine -like "*claude-buttons.ps1*"`, so ANY powershell process whose
# command line merely mentions the filename was force-killed - a grep, an AST analysis, a test
# harness. It killed this project's own tooling. These cases assert on the decision function, so
# no process is ever started or stopped by the suite.
$panelName = 'claude-buttons.ps1'   # the function's parameter, named as in the installer
$pwsh = 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe'

# MUST kill: real launches, including the exact form Launch.vbs uses.
foreach ($c in @(
    @{ n = 'Launch.vbs form (quoted path, hidden window)'
       cl = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\Users\x\AppData\Local\Programs\ClaudeButtons\claude-buttons.ps1`"" },
    @{ n = 'fully-qualified host, unquoted path'
       cl = "$pwsh -NoProfile -File C:\Tools\ClaudeButtons\claude-buttons.ps1" },
    @{ n = 'pwsh 7 host'
       cl = "pwsh.exe -NoProfile -File `"C:\p\claude-buttons.ps1`"" },
    @{ n = 'abbreviated -f switch'
       cl = "powershell.exe -NoProfile -f C:\p\claude-buttons.ps1" },
    @{ n = 'differently-cased path (Windows paths are case-insensitive)'
       cl = "powershell.exe -File C:\P\Claude-Buttons.PS1" },
    @{ n = 'launched with arguments after the script'
       cl = "powershell.exe -NoProfile -File `"C:\p\claude-buttons.ps1`" -AddButton `"C:\t\b.json`"" }
)) { Check "Stop-Panel targets a real panel launch: $($c.n)" (Test-PanelCommandLine $c.cl $panelName) }

# MUST NOT kill: every one of these merely MENTIONS the panel. Each is a real thing a
# maintainer or this repo's own tooling runs.
foreach ($c in @(
    @{ n = 'a grep over the source'
       cl = "powershell.exe -NoProfile -Command `"Select-String claude-buttons.ps1 *.md`"" },
    @{ n = 'an AST analysis one-liner'
       cl = "powershell.exe -NoProfile -Command `"[Parser]::ParseFile('claude-buttons.ps1',[ref]`$null,[ref]`$null)`"" },
    @{ n = 'the test harness running panel.tests.ps1 (which reads claude-buttons.ps1)'
       cl = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\repo\tests\panel.tests.ps1 -Target claude-buttons.ps1" },
    @{ n = 'run-all.ps1, whose static check names the panel'
       cl = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\repo\tests\run-all.ps1" },
    @{ n = 'an encoded command that happens to decode near the name'
       cl = "powershell.exe -EncodedCommand ZWNobyBjbGF1ZGUtYnV0dG9ucy5wczE= claude-buttons.ps1" },
    @{ n = 'a non-PowerShell process whose command line names the panel'
       cl = "C:\Windows\System32\notepad.exe C:\p\claude-buttons.ps1" },
    @{ n = 'a -Command payload that PRINTS a launch line (unquoted, so -File is a bare token)'
       cl = "powershell.exe -NoProfile -Command Write-Output powershell.exe -File C:\p\claude-buttons.ps1" },
    @{ n = 'an editor with the panel open'
       cl = "`"C:\Program Files\Editor\edit.exe`" -File C:\p\claude-buttons.ps1" },
    @{ n = '-File pointing at a DIFFERENT script in the panel folder'
       cl = "powershell.exe -File C:\p\claude-buttons-helper.ps1" },
    @{ n = 'the name only in a working directory, not as -File'
       cl = "powershell.exe -NoProfile -File C:\claude-buttons.ps1.bak" },
    @{ n = 'an empty command line (protected process)'
       cl = '' }
)) { Check "Stop-Panel spares a mere mention: $($c.n)" (-not (Test-PanelCommandLine $c.cl $panelName)) }

# The quote-aware splitter: an install path with spaces is the NORMAL case under
# %LOCALAPPDATA%\Programs. Splitting on whitespace alone would cut the path in half and the
# -File argument would never match, silently disabling Stop-Panel for most users.
$parts = @(Split-CommandLineArgs "powershell.exe -File `"C:\Program Files\Claude Buttons\claude-buttons.ps1`"")
Check 'Split-CommandLineArgs keeps a quoted path with spaces in one piece' `
    (($parts.Count -eq 3) -and ($parts[2] -eq 'C:\Program Files\Claude Buttons\claude-buttons.ps1'))
# PS 5.1 array traps, both of which produced a Stop-Panel that silently stopped nothing:
# `return ,$arr` adds an outer wrapper that @() collapses to ONE element, and a bare string
# passed through @() must not be enumerated into characters.
$one = @(Split-CommandLineArgs 'powershell.exe')
Check 'Split-CommandLineArgs returns whole arguments, not characters, for a single argument' `
    (($one.Count -eq 1) -and ($one[0] -eq 'powershell.exe'))
$three = @(Split-CommandLineArgs 'powershell.exe -File x.ps1')
Check 'Split-CommandLineArgs does not collapse a multi-argument line to one element' `
    (($three.Count -eq 3) -and ($three[1] -eq '-File'))
Check 'a path with spaces is still matched as the panel' `
    (Test-PanelCommandLine "powershell.exe -File `"C:\Program Files\Claude Buttons\claude-buttons.ps1`"" $panelName)

# Ancestor exclusion: the installer itself runs under powershell.exe, and it may have been
# started BY the panel (the kebab menu offers an update). Killing an ancestor kills the run
# half-way through an install.
$map = @{ 100 = 4; 200 = 100; 300 = 200; 400 = 999 }   # 300 <- 200 <- 100 <- 4(root)
$anc = @(Get-ProcessAncestry 300 $map)
Check 'Get-ProcessAncestry walks the whole parent chain' `
    (($anc -contains 300) -and ($anc -contains 200) -and ($anc -contains 100))
Check 'Get-ProcessAncestry does not include an unrelated process' (-not ($anc -contains 400))
# PID reuse can make the chain a cycle; without the visited check this hangs forever.
$cyc = @{ 10 = 20; 20 = 10 }
$r = Try-Call { $null = Get-ProcessAncestry 10 $cyc }
Check 'Get-ProcessAncestry terminates on a cyclic parent chain (PID reuse)' (-not $r.Threw)
$solo = @(Get-ProcessAncestry 4 @{})
Check 'Get-ProcessAncestry returns the pid itself for a chain of one' `
    (($solo.Count -eq 1) -and ($solo[0] -eq 4))

# Stop-Panel must actually USE the narrowing. Testing only the helper is what let earlier
# rounds ship: the helper can be perfect while Stop-Panel still calls -like on the raw string.
$stopSrc = [regex]::Match((Get-Content $install -Raw), '(?s)function Stop-Panel\s*\{.*?\n\}').Value
Check 'Stop-Panel calls the narrowed matcher' ($stopSrc -match 'Test-PanelCommandLine')
Check 'Stop-Panel no longer wildcard-matches the raw command line' `
    ($stopSrc -notmatch '-like\s*"\*')
Check 'Stop-Panel excludes itself and its ancestors' ($stopSrc -match 'Get-ProcessAncestry')

# ---- /pin and /unpin must FAIL CLOSED on a stale session file (PRIV-01) --------------------
# Reported: the user asks to pin private text "only in this chat", active-session.json is stale,
# and the instruction permitted "pin globally with a note". The button then appears in every
# conversation and a later click pastes that text into a different chat. Falling back to global
# is the opposite of what the user asked for and is the failure direction that leaks their text.
# -Encoding UTF8 explicitly: these files contain em dashes, and PS 5.1's Get-Content defaults to
# ANSI, which mangles them - a decoding accident must never be what decides a privacy assertion.
$pinSrc = Get-Content (Join-Path $repo 'skills\pin\SKILL.md') -Raw -Encoding UTF8
$staleBlock = [regex]::Match($pinSrc, '(?s)Staleness check.*?(?=\n\d+\. )').Value
Check 'the /pin skill has a staleness block' ($staleBlock.Length -gt 0)
Check 'the stale-session instruction REFUSES the pin' ($staleBlock -match 'REFUSE')
Check 'the stale-session instruction says nothing was pinned' ($staleBlock -match 'nothing was pinned')
# The defect verbatim. Any instruction that lets a stale file WIDEN the scope is the bug.
Check 'the stale-session instruction never permits a global fallback (the reported defect)' `
    ($pinSrc -notmatch '(?i)or pin globally')
Check '/pin explicitly forbids widening to global on a stale file' `
    ($staleBlock -match '(?i)never widen|do not pin globally|Never widen')
# ...and it must not pin with the untrusted id either - the other half of the same fallback.
Check '/pin also refuses the possibly-wrong session_id' `
    ($staleBlock -match '(?i)do not pin with the untrusted|possibly-wrong session id')

$unpinSrc = Get-Content (Join-Path $repo 'skills\unpin\SKILL.md') -Raw -Encoding UTF8
Check '/unpin carries the same fail-closed rule' ($unpinSrc -match '(?i)fail-closed')
# Removing a GLOBAL button on a guess is the widest action available to /unpin - the same
# class of fallback, pointed the same way.
Check '/unpin does not fall back to removing a global button on a stale session' `
    ($unpinSrc -match '(?i)not.{0,20}fall back to removing a global button')
Check '/unpin removes nothing until the user chooses' ($unpinSrc -match '(?i)Remove nothing until')

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "Installer tests: $count passed" -ForegroundColor Green; exit 0 }
else { Write-Host "Installer tests: $fails of $count FAILED" -ForegroundColor Red; exit 1 }
