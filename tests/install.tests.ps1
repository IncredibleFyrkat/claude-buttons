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

# The pre-flight must run the depth check itself - checking it only at write time put the
# throw AFTER uninstall had already deleted the skills and engine.
Set-Settings ($deep | ConvertTo-Json -Depth 100 -Compress)
$r = Try-Call { Test-SettingsUsable }
Check 'the pre-flight runs the depth check (before anything is deleted)' ($r.Threw)

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
# Check EVERY grant site, not just the verb list. Grepping only the `foreach ($verb in @(...))`
# literal was evadable: an Ensure-AllowRule call for request-on placed anywhere OUTSIDE that
# loop left the suite green with the command fully pre-authorised. So scan all call sites, and
# separately confirm the loop still grants the disarm verbs.
$installLines = Get-Content $install
$grantSites = @($installLines | Where-Object { $_ -match 'Ensure-AllowRule' -and $_ -notmatch '^\s*#' })
Check "found the allow-rule grant sites ($($grantSites.Count))" ($grantSites.Count -ge 1)
Check 'NO grant site anywhere pre-authorises request-on (SEC-01)' `
    (-not ($grantSites | Where-Object { $_ -match 'request-on' }))
Check 'NO grant site anywhere grants a toggle wildcard' `
    (-not ($grantSites | Where-Object { $_ -match 'toggle \$?\*|toggle \*' }))

$verbLine = [regex]::Match(($installLines -join "`n"), "foreach \(\`$verb in @\(([^)]*)\)\)")
Check 'the allow-rule verb list is parseable' ($verbLine.Success)
Check 'request-on is not in the verb list either' ($verbLine.Groups[1].Value -notmatch "'request-on'")
Check 'the disarm verbs ARE allow-listed (disarming must stay friction-free)' `
    (($verbLine.Groups[1].Value -match "'off'") -and ($verbLine.Groups[1].Value -match "'status'"))

# Scope this to the frontmatter GRANT line only. The skill body must still tell the agent to
# run request-on - the point of SEC-01 is that the command prompts, not that it is forbidden.
$skillLines = Get-Content (Join-Path $repo 'skills-optional\shutdown-on-done\SKILL.md')
$allowLine = ($skillLines | Where-Object { $_ -match '^allowed-tools:' } | Select-Object -First 1)
Check 'the skill declares an allowed-tools line' ($null -ne $allowLine)
Check 'the skill does not re-grant a toggle * wildcard (SEC-02)' ($allowLine -notmatch 'toggle \*')
Check 'the skill does not pre-authorise request-on either (SEC-01)' ($allowLine -notmatch 'toggle request-on')
Check 'the skill body still instructs the agent to run request-on (it just prompts)' `
    ((($skillLines -join "`n") -match 'toggle request-on'))

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "Installer tests: $count passed" -ForegroundColor Green; exit 0 }
else { Write-Host "Installer tests: $fails of $count FAILED" -ForegroundColor Red; exit 1 }
