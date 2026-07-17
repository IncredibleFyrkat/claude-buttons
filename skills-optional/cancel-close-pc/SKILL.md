---
description: Cancel a scheduled PC shutdown
disable-model-invocation: true
allowed-tools: PowerShell(Remove-Item "$env:USERPROFILE\.claude\close-pc-on-done.flag" *), PowerShell(shutdown /a)
---
Cancel "shut down PC when done":

1. Delete the flag file `%USERPROFILE%\.claude\close-pc-on-done.flag` if it exists (PowerShell: `Remove-Item "$env:USERPROFILE\.claude\close-pc-on-done.flag" -Force -ErrorAction SilentlyContinue`).
2. Run `shutdown /a` to abort any shutdown timer already counting down. Ignore the error if no timer is running (that is expected).
3. Confirm to the user that the shutdown is cancelled.
