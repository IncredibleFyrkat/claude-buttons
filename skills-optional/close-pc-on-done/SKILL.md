---
description: Shut down the PC when Claude finishes working (this session only)
disable-model-invocation: true
allowed-tools: PowerShell(Set-Content "$env:USERPROFILE\.claude\close-pc-on-done.flag" *)
---
Enable "shut down PC when done" — bound to THIS session so other chats cannot trigger it:

1. Read `%USERPROFILE%\.claude\active-session.json` and take `session_id` (a hook updated this file when the user sent this message). Check that its `ts` is under 2 minutes old — if it is older or missing, tell the user you cannot safely bind the shutdown to this session and stop.
2. Write the session_id as the content of the flag file `%USERPROFILE%\.claude\close-pc-on-done.flag` (PowerShell: `Set-Content "$env:USERPROFILE\.claude\close-pc-on-done.flag" -Value "<session_id>" -Encoding UTF8`).
3. Continue with any ongoing or outstanding work in the conversation.
4. When completely done, end the turn as usual — the Stop hook shuts down only if the session that stops matches the flag file's session_id, with 60 seconds' notice.
5. Tell the user: the PC will shut down ~60 seconds after this session finishes. Cancel with `/cancel-close-pc` or `shutdown /a`.
