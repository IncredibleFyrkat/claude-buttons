---
description: Pin a command as a button in the Claude Buttons panel (this chat, or global)
disable-model-invocation: true
---
The user wants to pin a command as a button in the Claude Buttons panel: $ARGUMENTS

Do the following:

1. Locate buttons.json: read the install marker at `%USERPROFILE%\.claude\claude-buttons-path.txt` — its content is the full path to buttons.json. If the marker is missing, tell the user Claude Buttons is not installed and stop.
2. Parse the arguments: the first token (possibly quoted) is the text the button types into the chat (e.g. `/code-review` or plain text). An optional second argument is the button label. Without a label, use the text as the label.
3. **Scope**: ALWAYS ask one clickable question with the AskUserQuestion tool: "Where should the button appear?" with two options: "Only this chat (Recommended)" (first) and "Global (all chats)". Skip the question ONLY if the user already stated the scope in the command. If the user does not actively choose global, it is this-chat only.
4. For per-chat scope: read `%USERPROFILE%\.claude\active-session.json` and use its `session_id` as the button's `chat` value (a hook updated this file when the user sent this message). Sanity-check: if the file's `ts` is more than 2 minutes old, do not trust it — ask the user, or pin globally with a note.
5. Read the buttons.json found in step 1. If a button with the same `text` and same scope already exists, say so and stop.
6. Otherwise append to the `buttons` array:
   - Per-chat: `{ "label": "<label>", "short": "<short>", "text": "<text>", "submit": true, "chat": "<session_id>", "chatTitle": "<the current chat's displayed title, if known>" }`
   - Global: same but without `chat`/`chatTitle`.
   - `short` is a very short version of the label (max ~8 chars) shown when the window is too narrow.
   - If the command is destructive or irreversible (shutdown, delete, deploy, etc.), add `"confirm": true` — the panel then requires two clicks before firing.
   - Note: per-chat buttons never auto-send (the panel only inserts the text), regardless of `submit`.
7. Save the file as valid JSON (preserve all existing fields and buttons). The panel reloads itself within ~1 second.
8. Confirm briefly: button name + whether it is pinned to this chat or globally.

**If there are no arguments**: show a clickable menu with AskUserQuestion (multiSelect). Offer the most relevant available slash commands as options; then pin the chosen ones as above. Also mention that the fastest way to pin is to right-click the panel's dot-grip and choose "Pin new button".
