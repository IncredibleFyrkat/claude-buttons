---
description: Remove a button from the Claude Buttons panel
disable-model-invocation: true
---
The user wants to remove a button from the Claude Buttons panel: $ARGUMENTS

Do the following:

1. Locate buttons.json via the install marker `%USERPROFILE%\.claude\claude-buttons-path.txt` (its content is the full path). Also read `%USERPROFILE%\.claude\active-session.json` (its `session_id` is this chat).
2. Read buttons.json to FIND the match: the button whose `text` or `label` matches the argument (be flexible — match with or without a leading `/`, case-insensitive). Prefer buttons pinned to this chat (`chat` == session_id), then global ones. Reading is fine; writing is not.
3. **Do NOT write buttons.json yourself.** The panel writes it too, under a mutex, so a
   hand-written read-modify-write silently destroys whatever the panel saved in between. Run
   the panel's own locked entry point with the matched button's `label`, `text` and `chat`
   (omit `chat` for a global button — the three fields together identify it):

   Write those fields to a temp `.json` file (UTF-8) and pass the PATH, since the text may
   contain quotes or newlines:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<install-dir>\claude-buttons.ps1" -RemoveButton "<path-to-temp.json>"
   ```

   Delete the temp file afterwards — it contains the user's prompt text.

   **Interpret the result strictly. Never claim success on anything not listed as success:**

   | Exit | Output | Meaning |
   |---|---|---|
   | 0 | `REMOVED: 1` | Done. The panel reloads automatically. |
   | 0 | `NOTFOUND: ...` | Nothing matched, nothing changed. Show the visible buttons instead. |
   | 3 | `AMBIGUOUS: ...` | Several buttons match exactly. **Nothing was removed.** Show them and ask which one. |
   | 1 | stderr | The file was locked or unreadable. **Nothing was removed.** Tell the user. |
   | 2 | stderr | Bad payload. **Nothing was removed.** |
   | anything else, or no output | — | Treat as failure. Do NOT tell the user the button was removed. |
4. Confirm briefly. If nothing matches, show the buttons visible in this chat (global + this chat's) instead.

Tip to mention to the user: you can also just right-click a button in the panel and choose "Remove this button".

**If there are no arguments**: show the list and ask which button to remove (AskUserQuestion, multiSelect), then remove the chosen ones.
