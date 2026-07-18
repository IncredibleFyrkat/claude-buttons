#!/usr/bin/env node
// Shutdown-on-done: per-chat toggle that powers the PC off when the armed chat
// finishes responding. Portable version (no hardcoded user paths).
//
// Two modes:
//   toggle on [--this-turn] | off | status
//     Run by Claude via the Bash tool; identifies the chat via CLAUDE_CODE_SESSION_ID.
//     Default arming skips the toggle turn itself, so the shutdown fires when the
//     NEXT response finishes. --this-turn arms for the current turn (use when the
//     work and the arm request arrive in the same message).
//   (no args)
//     Stop-hook mode: reads the hook JSON from stdin and, if this session is armed,
//     starts a 60s-grace shutdown (abort with `shutdown -a`).
//
// Set SHUTDOWN_ON_DONE_DRYRUN=1 to test the Stop path without touching the PC.
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, statSync, appendFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Forward-slash form so a command built from it matches the installer's allow-rules
// (which use forward slashes); Node/Windows accept either in a path.
const SELF = fileURLToPath(import.meta.url).replace(/\\/g, '/');
const FLAG_DIR = join(homedir(), '.claude', 'shutdown-on-done');
// Machine-wide switch: create/delete a MACHINE-ARMED file in FLAG_DIR from any
// external trigger (e.g. a physical/custom button) to use completion-judged mode.
const MACHINE_FLAG = join(FLAG_DIR, 'MACHINE-ARMED');
const GRACE_SECONDS = 60;
// Resolve shutdown.exe absolutely: Claude runs Stop hooks with CWD = the project
// dir, and Node/Windows resolves a bare command name from CWD before PATH, so a
// cloned repo shipping its own shutdown.exe could otherwise run at turn-end or on
// `toggle off`. Absolute path from %SystemRoot% closes that repo-to-machine gap.
const SHUTDOWN_EXE = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'shutdown.exe');
// A forgotten machine-wide switch must not power off some unrelated session days
// later. Ignore (and clear) MACHINE-ARMED once it is older than this.
const MACHINE_MAX_AGE_MS = 12 * 60 * 60 * 1000; // 12 hours
const LOG_FILE = join(FLAG_DIR, 'shutdown-on-done.log');
const logLine = (msg) => {
  try { appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`); } catch {}
};
// True only if MACHINE-ARMED exists AND is fresh; a stale switch is cleared.
const machineArmedFresh = () => {
  if (!existsSync(MACHINE_FLAG)) return false;
  try {
    if (Date.now() - statSync(MACHINE_FLAG).mtimeMs > MACHINE_MAX_AGE_MS) {
      rmSync(MACHINE_FLAG, { force: true });
      logLine('MACHINE-ARMED ignored and cleared (stale, older than 12h)');
      return false;
    }
  } catch { return false; }
  return true;
};

const flagPath = (id) => join(FLAG_DIR, `${id}.json`);
// Standing-request marker: exists from the moment the user asks until disarm or
// fire. Carries no logic; external UIs (button panels) read it for toggle state.
const requestPath = (id) => join(FLAG_DIR, `${id}.request`);
const emit = (obj) => process.stdout.write(JSON.stringify(obj));

const [mode, ...rest] = process.argv.slice(2);

if (mode === 'toggle') {
  const action = rest.find((a) => !a.startsWith('--')) ?? 'status';
  const thisTurn = rest.includes('--this-turn');
  const id = process.env.CLAUDE_CODE_SESSION_ID;
  if (!id) {
    console.error('CLAUDE_CODE_SESSION_ID is not set; cannot identify this chat.');
    process.exit(1);
  }
  if (action === 'on') {
    // Arming requires an intent signal the user established: either a standing
    // request (the skill runs `request-on` first) or a fresh machine switch.
    // Without one, refuse - this blocks a drive-by prompt injection that runs
    // `toggle on` directly from powering the machine off, while the legitimate
    // request-on -> on flow and the physical-switch flow stay untouched.
    if (!existsSync(requestPath(id)) && !machineArmedFresh()) {
      console.log(
        'Refused: no standing shutdown request for this chat. Run `toggle request-on` first (the /shutdown-on-done skill does this).',
      );
      logLine(`ARM refused for session ${id}: no standing request or machine switch`);
      process.exit(0);
    }
    mkdirSync(FLAG_DIR, { recursive: true });
    writeFileSync(flagPath(id), JSON.stringify({ skip: thisTurn ? 0 : 1 }));
    console.log(
      thisTurn
        ? `Armed: the PC will shut down (${GRACE_SECONDS}s grace) when THIS response finishes. Disarm: toggle off. Abort a started countdown: shutdown -a`
        : `Armed: the PC will shut down (${GRACE_SECONDS}s grace) when the NEXT response in this chat finishes. Disarm: toggle off. Abort a started countdown: shutdown -a`,
    );
  } else if (action === 'request-on') {
    mkdirSync(FLAG_DIR, { recursive: true });
    writeFileSync(requestPath(id), new Date().toISOString());
    console.log('Standing shutdown request recorded for this chat.');
  } else if (action === 'request-off') {
    rmSync(requestPath(id), { force: true });
    console.log('Standing shutdown request cleared for this chat.');
  } else if (action === 'off') {
    // Per-chat disarm: cancel THIS chat only. Arming is per-chat, so cancelling
    // must be too - disarming one chat must never silently disarm another the user
    // still wants armed. The global power button stays lit while any OTHER chat is
    // armed (its *.request glob still matches), which honestly signals "still armed
    // elsewhere" rather than going dark on a shutdown that is actually still coming.
    rmSync(flagPath(id), { force: true });
    rmSync(requestPath(id), { force: true });
    rmSync(MACHINE_FLAG, { force: true });
    const abort = spawnSync(SHUTDOWN_EXE, ['-a'], { stdio: 'pipe' });
    console.log(
      abort.status === 0
        ? 'Disarmed this chat (+ machine switch), and aborted a shutdown countdown that was already in flight.'
        : 'Disarmed this chat (+ machine switch): this chat will no longer shut down the PC.',
    );
  } else {
    const chat = existsSync(flagPath(id)) ? 'Armed for this chat.' : 'Not armed for this chat.';
    const req = existsSync(requestPath(id)) ? 'Standing request: ACTIVE.' : 'Standing request: none.';
    const machine = existsSync(MACHINE_FLAG) ? 'Machine-wide switch: ARMED.' : 'Machine-wide switch: off.';
    console.log(`${chat} ${req} ${machine}`);
  }
  process.exit(0);
}

// Stop-hook mode.
let input = {};
try {
  // Strip a leading UTF-8 BOM if some upstream added one, else JSON.parse throws
  // and the hook silently disarms the turn (QA F8).
  input = JSON.parse(readFileSync(0, 'utf8').replace(/^﻿/, ''));
} catch {
  process.exit(0);
}
const id = input.session_id;
if (!id || !existsSync(flagPath(id))) {
  // Machine-wide switch: no file heuristic can know whether a session is truly
  // finished (background shells, pending wakeups), so wake the model at turn-end
  // and let it judge; it arms the real per-session flag when everything is done.
  if (machineArmedFresh() && !input.stop_hook_active) {
    logLine(`MACHINE-ARMED wake sent to session ${id ?? '(none)'}`);
    emit({
      decision: 'block',
      reason:
        `The user's machine-wide "shut down the PC when done" switch is ON (they flipped a physical toggle, expecting the PC to power off once their long-running Claude work completes). Judge honestly: is ALL work in this session completely finished, with no background shells, subagents, workflows, or planned follow-ups pending? If anything is still running, or you are unsure, or this brief session is clearly not the long task they meant: continue your remaining work normally and ignore this (you may note briefly that the shutdown switch is on). If everything is truly done: run via Bash: node "${SELF}" toggle on --this-turn  then tell the user the PC will power off 60 seconds after this response, and stop.`,
    });
  }
  process.exit(0);
}

let flag = { skip: 0 };
try {
  flag = JSON.parse(readFileSync(flagPath(id), 'utf8'));
} catch {
  // Unreadable flag: treat as armed with no skip.
}

if ((flag.skip ?? 0) > 0) {
  writeFileSync(flagPath(id), JSON.stringify({ skip: flag.skip - 1 }));
  emit({
    systemMessage:
      'Shutdown-on-done armed: the PC will shut down when the next response in this chat finishes.',
  });
  process.exit(0);
}

// One-shot: consume the flags before firing so a misfire can never repeat and
// the machine switch does not re-trigger after the next boot.
rmSync(flagPath(id), { force: true });
rmSync(requestPath(id), { force: true });
rmSync(MACHINE_FLAG, { force: true });

if (process.env.SHUTDOWN_ON_DONE_DRYRUN === '1') {
  emit({ systemMessage: '[dry-run] Chat done; would start PC shutdown now.' });
  process.exit(0);
}

// -f force-closes apps that would otherwise block the shutdown; without it a
// single hung app leaves the PC on all night, which defeats the feature.
const res = spawnSync(
  SHUTDOWN_EXE,
  ['-s', '-f', '-t', String(GRACE_SECONDS), '-c', `Claude chat finished. Shutting down in ${GRACE_SECONDS}s; run "shutdown -a" to abort.`],
  { stdio: 'pipe' },
);
if (res.status === 0) {
  logLine(`SHUTDOWN started (${GRACE_SECONDS}s grace) for session ${id}`);
  emit({ systemMessage: `Chat done: PC shutting down in ${GRACE_SECONDS} seconds. Abort with: shutdown -a` });
} else {
  const err = (res.stderr ?? '').toString().trim() || (res.error ? String(res.error) : 'unknown error');
  logLine(`SHUTDOWN failed for session ${id}: ${err}`);
  emit({ systemMessage: `Shutdown-on-done: failed to start shutdown (${err}).` });
}
