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

   It prints `REMOVED: <n>` or `NOTFOUND: no button matched.` The panel reloads automatically.
4. Confirm briefly. If nothing matches, show the buttons visible in this chat (global + this chat's) instead.

Tip to mention to the user: you can also just right-click a button in the panel and choose "Remove this button".

**If there are no arguments**: show the list and ask which button to remove (AskUserQuestion, multiSelect), then remove the chosen ones.
