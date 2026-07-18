# Run the whole test suite. Exits non-zero if anything fails (used by CI).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0

Write-Host "== Engine tests (node --test) ==" -ForegroundColor Cyan
if (Get-Command node -ErrorAction SilentlyContinue) {
    & node --test (Join-Path $PSScriptRoot 'engine.test.mjs')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} else {
    # Fail CLOSED. A skipped suite is not a passed suite, and this is the one that guards
    # the component that can power the PC off - reporting ALL TESTS PASSED having run none
    # of it is worse than reporting nothing. Set CB_ALLOW_NO_NODE=1 to opt out deliberately.
    Write-Host "  Node.js NOT FOUND - engine tests could not run" -ForegroundColor Red
    if ($env:CB_ALLOW_NO_NODE -eq '1') {
        Write-Host "  CB_ALLOW_NO_NODE=1 set - continuing without them (engine is UNVERIFIED)" -ForegroundColor Yellow
    } else {
        Write-Host "  Install Node.js, or set CB_ALLOW_NO_NODE=1 to skip deliberately." -ForegroundColor Yellow
        $fail = 1
    }
}

Write-Host ""
Write-Host "== Panel config-lifecycle tests ==" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'panel.tests.ps1')
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ""
Write-Host "== Installer behaviour tests ==" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.tests.ps1')
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ""
Write-Host "== Static checks ==" -ForegroundColor Cyan
foreach ($f in @('claude-buttons.ps1', 'install.ps1')) {
    try { [void][ScriptBlock]::Create((Get-Content (Join-Path $root $f) -Raw)); Write-Host "  ok  $f parses" -ForegroundColor DarkGreen }
    catch { Write-Host "  FAIL $f does not parse: $($_.Exception.Message)" -ForegroundColor Red; $fail = 1 }
}
if (Get-Command node -ErrorAction SilentlyContinue) {
    & node --check (Join-Path $root 'engine\shutdown-on-done.mjs')
    if ($LASTEXITCODE -eq 0) { Write-Host "  ok  engine/shutdown-on-done.mjs parses" -ForegroundColor DarkGreen } else { $fail = 1 }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "TESTS FAILED" -ForegroundColor Red; exit 1 }
