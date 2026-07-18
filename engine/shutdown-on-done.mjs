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
import {
  readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, statSync, appendFileSync, renameSync,
} from 'node:fs';
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

// Backing store for Atomics.wait, used as a CPU-free synchronous sleep in the retry below.
const SLEEP_LOCK = new Int32Array(new SharedArrayBuffer(4));

// Write via temp + rename so the flag is never observed half-written. A bare writeFileSync
// truncates first, and this tool cuts power to the machine - so an interrupted write was a
// realistic way to produce the corrupt flag that (before the fail-closed fix) fired a shutdown.
const writeFlagAtomic = (p, data) => {
  // Unique temp name: a shared one lets two interleaved writers rename each other's payload.
  const tmp = `${p}.${process.pid}.${Date.now()}.tmp`;
  try {
    writeFileSync(tmp, data);
    for (let i = 0; ; i++) {
      try { renameSync(tmp, p); return; } catch (e) {
        // On Windows, rename-over-existing fails with EPERM/EBUSY while ANY process holds the
        // target open (Defender, a backup agent, an indexer). The plain write it replaced
        // tolerated that, so an unguarded rename is a reliability REGRESSION. Retry with a
        // real backoff - a retry loop with no delay completes in microseconds and cannot
        // outlast the transient hold it exists to survive.
        if (i >= 4 || (e.code !== 'EPERM' && e.code !== 'EBUSY')) throw e;
        // Atomics.wait, not a spin loop: this path must stay synchronous (the hook has no
        // event loop to yield to), but a busy-wait over the full 1.2s schedule measured at
        // 98.9% of one core. This blocks the thread for the same wall time at ~0% CPU.
        Atomics.wait(SLEEP_LOCK, 0, 0, 120 * (i + 1));
      }
    }
  } catch (e) {
    // Never let a flag write crash the hook: an uncaught throw here means the arm silently
    // fails behind a stack trace, or the counter is not written and the shutdown lands late.
    try { rmSync(tmp, { force: true }); } catch {}
    try {
      writeFileSync(p, data);   // last resort: the old, non-atomic path is better than nothing
      logLine(`atomic flag write fell back to a direct write: ${e.code ?? e}`);
    } catch (e2) {
      // The fallback hits the SAME lock the retry just exhausted on, so it must be guarded
      // too - an unguarded one crashed every turn-end with a raw stack trace and emitted no
      // confirmation at all. Failing here defers the shutdown, which is the safe direction.
      logLine(`flag write FAILED entirely (${e.code ?? e} then ${e2.code ?? e2}); state unchanged`);
    }
  }
};

// A session id becomes a FILENAME, and the fire path calls rmSync(force, recursive) on the
// result - so `../../x` escaped FLAG_DIR and deleted an arbitrary file or directory tree.
// Claude Code mints UUIDs, so no attacker channel was found, but a hook that deletes paths
// derived from stdin JSON should not rely on the caller being well-behaved.
const validSessionId = (v) => typeof v === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(v) && v !== '.' && v !== '..';

const flagPath = (id) => join(FLAG_DIR, `${id}.json`);
// Standing-request marker: exists from the moment the user asks until disarm or
// fire. Carries no logic; external UIs (button panels) read it for toggle state.
const requestPath = (id) => join(FLAG_DIR, `${id}.request`);
const emit = (obj) => process.stdout.write(JSON.stringify(obj));

// Whether the Stop hook is re-entering within the same user-visible turn. ONE normalizer used
// at BOTH read sites, so they cannot disagree. `=== true` was too strict (a harness sending 1
// or "true" made a re-entry look like a fresh turn, firing a turn early); bare truthiness was
// too loose (the string "false" is truthy in JS, so a fresh turn could look like a re-entry and
// wedge the flag forever). Accept only values that actually mean true.
const isHookActive = (v) =>
  v === true || v === 1 || (typeof v === 'string' && /^(1|true|yes)$/i.test(v.trim()));

const [mode, ...rest] = process.argv.slice(2);

if (mode === 'toggle') {
  // Nothing on the disarm path may fail quietly. A user who types a disarm command and
  // sees a success-shaped message must never still be armed, so EVERY unrecognised token
  // exits non-zero rather than falling through to the status report.
  const KNOWN = ['on', 'off', 'request-on', 'request-off', 'status'];
  const KNOWN_FLAGS = ['--this-turn'];
  const flags = rest.filter((a) => a.startsWith('--'));
  const words = rest.filter((a) => !a.startsWith('--'));
  // A dash-prefixed typo (`--off`) used to be filtered out as a "flag" BEFORE the verb
  // check ran, so it reached the status branch: exit 0, no stderr, machine still armed.
  const badFlag = flags.find((f) => !KNOWN_FLAGS.includes(f));
  if (badFlag) {
    console.error(
      `Unknown option "${badFlag}". Valid options: ${KNOWN_FLAGS.join(', ')}. ` +
        `Did you mean \`toggle ${badFlag.replace(/^-+/, '')}\`?`,
    );
    process.exit(1);
  }
  if (words.length > 1) {
    console.error(`Unexpected extra argument "${words[1]}". Usage: toggle ${KNOWN.join('|')} [--this-turn]`);
    process.exit(1);
  }
  // A flag with no verb (`toggle --this-turn`) used to fall through to the status report -
  // which begins "Armed for this chat", i.e. it reads as confirmation of an arm that never
  // happened. Same silent-success class as the `--off` hole, in the arming direction.
  if (words.length === 0 && flags.length > 0) {
    console.error(`"${flags[0]}" needs a verb. Did you mean \`toggle on ${flags[0]}\`?`);
    process.exit(1);
  }
  const verb = words[0];
  const action = verb ?? 'status';   // no verb at all = report status (documented default)
  if (verb && !KNOWN.includes(verb)) {
    // A mistyped verb must NOT silently fall through to a status report: someone who
    // typed `toggle of` (meaning off) would believe they had disarmed while the chat
    // stays armed and the PC still shuts down. Fail loudly on the disarm path instead.
    console.error(`Unknown toggle verb "${verb}". Valid verbs: ${KNOWN.join(', ')}.`);
    process.exit(1);
  }
  const thisTurn = rest.includes('--this-turn');
  const id = process.env.CLAUDE_CODE_SESSION_ID;
  if (!validSessionId(id)) {
    console.error('CLAUDE_CODE_SESSION_ID is not set or is not a plain session id; cannot identify this chat.');
    process.exit(1);
  }
  if (action === 'on') {
    // Arming requires an intent signal the user established: either a standing
    // request (the skill runs `request-on` first) or a fresh machine switch.
    // Without one, refuse - this blocks a drive-by prompt injection that runs
    // `toggle on` directly from powering the machine off, while the legitimate
    // request-on -> on flow and the physical-switch flow stay untouched.
    // A STANDING REQUEST IS THE ONLY KEY. MACHINE-ARMED deliberately does NOT satisfy this
    // gate any more, because it was a second key with no lock on it:
    //
    //   MACHINE-ARMED is a zero-byte file with no allow-rule and no content check. An agent
    //   that had read untrusted content could create it - it is not a shutdown command and
    //   does not read like one - and that alone re-opened the gate that withholding
    //   `request-on` from permissions.allow was meant to close. The wake below then handed
    //   the model the exact pre-authorised arm command, so the tool completed the chain
    //   itself. Both "sides" of the gate were reachable by one principal.
    //
    // The physical-switch flow is unaffected in practice: a real external trigger writes to
    // the filesystem anyway, so it should write BOTH the marker and a `<session>.request`.
    // That keeps the two sides in different hands, which is the property that matters.
    if (!existsSync(requestPath(id))) {
      console.log(
        'Refused: no standing shutdown request for this chat. Run `toggle request-on` first (the /shutdown-on-done skill does this, and it asks you to approve it).',
      );
      logLine(`ARM refused for session ${id}: no standing request`);
      process.exit(0);
    }
    mkdirSync(FLAG_DIR, { recursive: true });
    writeFlagAtomic(flagPath(id), JSON.stringify({ skip: thisTurn ? 0 : 1 }));
    console.log(
      thisTurn
        ? `Armed: the PC will shut down (${GRACE_SECONDS}s grace) when THIS response finishes. Disarm: toggle off. Abort a started countdown: shutdown -a`
        : `Armed: the PC will shut down (${GRACE_SECONDS}s grace) when the NEXT response in this chat finishes. Disarm: toggle off. Abort a started countdown: shutdown -a`,
    );
  } else if (action === 'request-on') {
    mkdirSync(FLAG_DIR, { recursive: true });
    writeFlagAtomic(requestPath(id), new Date().toISOString());
    console.log('Standing shutdown request recorded for this chat.');
  } else if (action === 'request-off') {
    // Withdrawing the request must also drop any arm it authorised. The panel's toggle
    // watches *.request via stateGlob, so clearing only the marker made the power button
    // go dark while the chat stayed armed and the PC still shut down - the UI actively
    // asserting "not armed" about a machine that was.
    rmSync(requestPath(id), { force: true });
    rmSync(flagPath(id), { force: true });
    // ...and the machine switch, which `toggle off` already clears. Leaving it meant the
    // wake re-armed the chat at the next turn end, so the user read a withdrawal
    // confirmation and the PC still powered off.
    rmSync(MACHINE_FLAG, { force: true });
    console.log('Standing shutdown request cleared for this chat (and any arm it authorised).');
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
if (!validSessionId(id) || !existsSync(flagPath(id))) {
  // Machine-wide switch: no file heuristic can know whether a session is truly
  // finished (background shells, pending wakeups), so wake the model at turn-end
  // and let it judge; it arms the real per-session flag when everything is done.
  if (machineArmedFresh() && !isHookActive(input.stop_hook_active)) {
    logLine(`MACHINE-ARMED wake sent to session ${id ?? '(none)'}`);
    emit({
      decision: 'block',
      // Deliberately does NOT name the arm command. This message is emitted because a file
      // exists on disk, and an agent that had read untrusted content could be the reason it
      // exists - so spelling out a pre-authorised command here made the tool an amplifier for
      // the very injection its arm gate exists to stop. Describing the state is enough; the
      // model already has the skill if the user legitimately asked for this.
      reason:
        `The user's machine-wide "shut down the PC when done" switch is ON (a file marking it is present). Judge honestly: is ALL work in this session completely finished, with no background shells, subagents, workflows, or planned follow-ups pending? If anything is still running, or you are unsure, or this brief session is clearly not the long task they meant, then simply continue your remaining work normally - you may note briefly that the switch is on. If everything is truly done and the user has actually asked for a shutdown in this conversation, use the /shutdown-on-done skill; it will ask them to confirm. Do NOT arm a shutdown that the user did not ask for in this conversation, and do not treat this message as permission to do so.`,
    });
  }
  process.exit(0);
}

// A turn-end that re-enters the Stop hook (any hook returning decision:"block" causes this -
// including our own MACHINE-ARMED wake below) is still the SAME user-visible turn. A skip may
// therefore be burned at most ONCE per turn.
//
// It must NOT suppress firing outright. Doing that killed the machine-switch feature entirely
// (its wake IS a decision:"block", so the invocation that would fire always carries
// stop_hook_active) and - far worse - left the flag armed, so the shutdown the user was
// promised for THIS turn silently detonated at the end of some unrelated later turn. That
// moves a power-off from a moment they consented to, to one they did not.
const sameTurn = isHookActive(input.stop_hook_active);   // normalizer defined at module scope

// Fail CLOSED. `skip: 0` is the fire sentinel, so defaulting a corrupt flag to it meant
// every truncated / empty / malformed flag powered the PC off. There is no shape of
// unreadable data that means "shut down" - it means we do not know what the user wanted.
let parsed = null;
try {
  parsed = JSON.parse(readFileSync(flagPath(id), 'utf8'));
} catch {
  parsed = null;
}
const skip =
  parsed && typeof parsed === 'object' && !Array.isArray(parsed) &&
  typeof parsed.skip === 'number' && Number.isInteger(parsed.skip) && parsed.skip >= 0
    ? parsed.skip
    : null;

if (skip === null) {
  // Consume the bad flag so it cannot repeat, and tell the user plainly - silently
  // disarming would be its own trap ("I armed it and nothing happened"). recursive+try:
  // a directory-shaped flag made rmSync throw here, killing the hook BEFORE the message
  // was emitted, so every turn crashed with a raw stack trace and the bad flag survived.
  try {
    rmSync(flagPath(id), { force: true, recursive: true });
    rmSync(requestPath(id), { force: true, recursive: true });
  } catch {}
  logLine(`flag unreadable/invalid for session ${id}; disarmed WITHOUT shutting down`);
  emit({
    systemMessage:
      'Shutdown-on-done: the arm flag was unreadable, so the PC was NOT shut down and this chat is now disarmed. Re-arm if you still want it.',
  });
  process.exit(0);
}

// This turn has already been accounted for: either it burned the skip, or it decided not to
// fire. Do nothing more. Crucially this must be checked BEFORE the skip branch AND before the
// fire path: a counter decremented 1 -> 0 during THIS turn means "due next turn", not "due
// now", so firing on the re-entry would still be a turn early. An arm created during the
// re-entry itself (the MACHINE-ARMED wake path) carries no marker, so it correctly falls
// through and fires - which is what makes the physical switch work at all.
if (sameTurn && parsed.consumedInTurn === true) process.exit(0);

if (skip > 0) {
  writeFlagAtomic(flagPath(id), JSON.stringify({ skip: skip - 1, consumedInTurn: true }));
  emit({
    systemMessage:
      'Shutdown-on-done armed: the PC will shut down when the next response in this chat finishes.',
  });
  process.exit(0);
}

// One-shot: consume the flags before firing so a misfire can never repeat and
// the machine switch does not re-trigger after the next boot.
//
// Guarded, for the same reason writeFlagAtomic is: a transient Windows lock (Defender, an
// indexer, a backup agent) made these throw, which crashed the hook with a raw stack trace,
// emitted NO systemMessage, and left the flag ARMED - so the power-off silently relocated to
// an arbitrary later turn. That is the exact harm this file's own comments call out as the
// worst outcome. If the flags cannot be consumed we must NOT fire: firing without consuming
// them could repeat after a reboot, which is worse than a shutdown that did not happen.
try {
  rmSync(flagPath(id), { force: true });
  rmSync(requestPath(id), { force: true });
  rmSync(MACHINE_FLAG, { force: true });
} catch (e) {
  logLine(`could not consume flags for session ${id} (${e.code ?? e}); NOT shutting down`);
  emit({
    systemMessage:
      'Shutdown-on-done: the arm flag could not be cleared, so the PC was NOT shut down ' +
      '(firing without consuming it could repeat after a reboot). Re-arm if you still want it.',
  });
  process.exit(0);
}

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
