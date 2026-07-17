---
description: Shut down the PC when this chat is completely done with its work
argument-hint: on | off | status
disable-model-invocation: true
allowed-tools: Bash(node "{{SCRIPT}}" toggle *)
---
The user wants the PC to shut down when this chat's work is COMPLETELY finished. This is typically sent while you are mid-task because the user is leaving (e.g. going to sleep): keep working normally, and treat the shutdown as the very last thing that happens.

Requested action: $ARGUMENTS (if empty, report status)

**on** — the one rule: arm the shutdown only at the moment everything is truly done.
- First, in every case, run `node "{{SCRIPT}}" toggle request-on` once to record the standing request (external button panels read this marker for their toggle state).
- Still working, or background tasks/subagents/workflows pending? Acknowledge briefly, continue the work, and remember this standing request. When EVERYTHING is verified complete (background shells included) and you are writing your final wrap-up response, run this as that response's final action:
  `node "{{SCRIPT}}" toggle on --this-turn`
  The PC then powers off 60 seconds after that response ends. Never arm early: the Stop hook fires when a response ends and is blind to still-running work, so arming before you are done shuts the PC down mid-task.
- Nothing running and nothing left to do? Then you ARE at the wrap-up: run the command above now, tell the user the PC will shut down 60 seconds after this response, and end your response.
- If the session continues past the arming for any reason (the flag is one-shot), re-arm at the new true completion point.

**off** — run `node "{{SCRIPT}}" toggle off` (this also aborts a countdown already in flight) and drop any standing arm-at-completion request from this conversation.

**status** — run `node "{{SCRIPT}}" toggle status` and also say whether an arm-at-completion request is standing in this conversation.

Relay the script's output to the user. Grace period is 60 seconds; `shutdown -a` aborts it.
