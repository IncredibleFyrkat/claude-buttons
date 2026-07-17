---
description: Remove a button from the Claude Buttons panel
disable-model-invocation: true
---
The user wants to remove a button from the Claude Buttons panel: $ARGUMENTS

Do the following:

1. Locate buttons.json via the install marker `%USERPROFILE%\.claude\claude-buttons-path.txt` (its content is the full path). Also read `%USERPROFILE%\.claude\active-session.json` (its `session_id` is this chat).
2. Find the button in the `buttons` array whose `text` or `label` matches the argument (be flexible — match with or without a leading `/`, case-insensitive). Prefer buttons pinned to this chat (`chat` == session_id), then global ones.
3. Remove it and save the file as valid JSON (preserve all other fields and buttons). The panel reloads itself automatically.
4. Confirm briefly. If nothing matches, show the buttons visible in this chat (global + this chat's) instead.

Tip to mention to the user: you can also just right-click a button in the panel and choose "Remove this button".

**If there are no arguments**: show the list and ask which button to remove (AskUserQuestion, multiSelect), then remove the chosen ones.
