// Automated tests for the shutdown-on-done engine — the highest-consequence component
// (it can power off the PC). Run: node --test tests/   (needs Node 18+; uses node:test).
// Every test uses a throwaway USERPROFILE so the real ~/.claude is never touched, and the
// Stop-hook fire path always runs under SHUTDOWN_ON_DONE_DRYRUN=1 so nothing shuts down.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync, readFileSync, readdirSync, utimesSync, chmodSync } from 'node:fs';
import { tmpdir, uptime as osUptime } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const ENGINE = join(dirname(fileURLToPath(import.meta.url)), '..', 'engine', 'shutdown-on-done.mjs');
let HOME;                         // per-run throwaway USERPROFILE
const flagDir = () => join(HOME, '.claude', 'shutdown-on-done');

before(() => { HOME = mkdtempSync(join(tmpdir(), 'cb-engine-')); });
after(() => { try { rmSync(HOME, { recursive: true, force: true }); } catch {} });
beforeEach(() => { rmSync(flagDir(), { recursive: true, force: true }); mkdirSync(flagDir(), { recursive: true }); });

// run in toggle mode (args) with a session id
function toggle(args, session = 't') {
  const r = spawnSync('node', [ENGINE, ...args.split(' ')],
    { env: { ...process.env, USERPROFILE: HOME, HOME, CLAUDE_CODE_SESSION_ID: session }, encoding: 'utf8' });
  return { out: (r.stdout || '').trim(), err: (r.stderr || '').trim(), code: r.status };
}
// run in Stop-hook mode: feed JSON on stdin; always dry-run so no real shutdown
function stop(payload, { dryrun = true, rawInput = null } = {}) {
  const input = rawInput ?? JSON.stringify(payload);
  const env = { ...process.env, USERPROFILE: HOME, HOME };
  if (dryrun) env.SHUTDOWN_ON_DONE_DRYRUN = '1';
  const r = spawnSync('node', [ENGINE], { env, input, encoding: 'utf8' });
  return { out: (r.stdout || '').trim(), code: r.status };
}

// Arm a chat THE WAY A USER CAN: request-on (the consent marker), then on. Tests used to
// hand-write `<id>.json` with no `<id>.request` beside it, which is not a state the engine can
// legitimately produce - and asserting a countdown or a FIRE from it is asserting exactly the
// defect: that the fire path trusts a flag written earlier instead of re-verifying live consent.
// The arm flag is now bound to the request that authorised it, so a hand-written flag has no
// valid token and could not carry these tests anyway.
function arm(id, { thisTurn = true } = {}) {
  const r1 = toggle('toggle request-on', id);
  assert.equal(r1.code, 0, `request-on failed for ${id}: ${r1.err}`);
  const r2 = toggle(`toggle on${thisTurn ? ' --this-turn' : ''}`, id);
  assert.match(r2.out, /^Armed/m, `arm failed for ${id}: ${r2.out} ${r2.err}`);
}

test('toggle status: nothing armed', () => {
  const { out } = toggle('toggle status');
  assert.match(out, /Not armed for this chat/);
  assert.match(out, /Standing request: none/);
  assert.match(out, /Machine-wide switch: off/);
});

test('unknown toggle verb fails loudly (never silently reports status)', () => {
  // `toggle of` (a typo for off) must not silently succeed as a status report.
  const r = toggle('toggle of', 'sTypo');
  assert.equal(r.code, 1, 'exits non-zero on an unknown verb');
  assert.match(r.err, /Unknown toggle verb/);
  assert.doesNotMatch(r.out, /Not armed|Armed for this chat/);
});

test('request-on creates the .request marker (panel toggle state)', () => {
  toggle('toggle request-on', 'sReq');
  assert.ok(existsSync(join(flagDir(), 'sReq.request')), '.request marker should exist');
  assert.match(toggle('toggle status', 'sReq').out, /Standing request: ACTIVE/);
});

test('toggle on --this-turn arms the current turn (skip 0)', () => {
  toggle('toggle request-on', 'sArm');       // arming now requires a standing request
  toggle('toggle on --this-turn', 'sArm');
  const flag = JSON.parse(readFileSync(join(flagDir(), 'sArm.json'), 'utf8'));
  assert.equal(flag.skip, 0);
});

test('toggle on (no flag) arms the NEXT turn (skip 1)', () => {
  toggle('toggle request-on', 'sNext');      // arming now requires a standing request
  toggle('toggle on', 'sNext');
  assert.equal(JSON.parse(readFileSync(join(flagDir(), 'sNext.json'), 'utf8')).skip, 1);
});

test('toggle on is REFUSED without a standing request (arm gate)', () => {
  const { out } = toggle('toggle on --this-turn', 'sInj');
  assert.match(out, /Refused: no standing shutdown request/);
  assert.ok(!existsSync(join(flagDir(), 'sInj.json')), 'no flag written when refused');
});

// MACHINE-ARMED must NOT be a second key to the arm gate. It is a zero-byte file with no
// allow-rule and no content check, so an agent that had read untrusted content could create it
// - and that alone re-opened the gate that withholding `request-on` from permissions.allow
// exists to close, because `on --this-turn` IS pre-authorised. Found by an outside auditor
// after four internal review rounds took the gate's "two principals" framing at face value.
test('a machine switch alone does NOT satisfy the arm gate (second-key hole)', () => {
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  const { out } = toggle('toggle on --this-turn', 'sMach');
  assert.match(out, /Refused: no standing shutdown request/);
  assert.ok(!existsSync(join(flagDir(), 'sMach.json')), 'no flag written from the marker alone');
});

test('the machine-switch wake does not hand the model a pre-authorised arm command', () => {
  // The wake fires because a FILE exists, and that file may exist because of injected content.
  // Naming the exact allow-listed command in the reason made the tool complete the chain itself.
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  const { out } = stop({ session_id: 'sWake', stop_hook_active: false });
  const reason = JSON.parse(out).reason;
  assert.doesNotMatch(reason, /toggle\s+on\b/, 'must not spell out the arm command');
  assert.doesNotMatch(reason, /--this-turn/, 'must not spell out the arm flag');
  assert.match(reason, /did not ask|not treat this message as permission/i, 'must warn against unrequested arming');
});

// A session id becomes a filename, and the fire path calls rmSync(force, recursive) on it.
for (const bad of ['../../escape', '..', '.', 'a/b', 'a\\b', '']) {
  test(`a malformed session id (${JSON.stringify(bad)}) is rejected, not turned into a path`, () => {
    const r = toggle('toggle request-on', bad);
    assert.notEqual(r.code, 0, 'must exit non-zero');
    assert.doesNotMatch(r.out, /recorded/i, 'must not report success');
  });
}

test('toggle off clears the flag and the request', () => {
  toggle('toggle request-on', 'sOff');
  toggle('toggle on --this-turn', 'sOff');
  toggle('toggle off', 'sOff');
  assert.ok(!existsSync(join(flagDir(), 'sOff.json')));
  assert.ok(!existsSync(join(flagDir(), 'sOff.request')));
});

test('toggle off is per-chat: cancelling one chat leaves other armed chats intact', () => {
  // Arm A and B independently, then off from B: A must SURVIVE (per-chat arming).
  toggle('toggle request-on', 'chatA');
  toggle('toggle on --this-turn', 'chatA');
  toggle('toggle request-on', 'chatB');
  toggle('toggle on --this-turn', 'chatB');
  toggle('toggle off', 'chatB');
  assert.ok(!existsSync(join(flagDir(), 'chatB.json')), 'chatB disarmed by its own off');
  assert.ok(existsSync(join(flagDir(), 'chatA.json')), 'chatA still armed (not touched by chatB off)');
  assert.ok(existsSync(join(flagDir(), 'chatA.request')), 'chatA request intact');
});

test('Stop hook: skip counter decrements without firing', () => {
  arm('sSkip', { thisTurn: false });          // skip 1, WITH the standing request that authorised it
  const { out } = stop({ session_id: 'sSkip' });
  assert.match(out, /Shutdown-on-done armed:/, "must say ARMED - /armed/i also matches \"disarmed\"");
  assert.doesNotMatch(out, /shutting down|would start/i);
  assert.equal(JSON.parse(readFileSync(join(flagDir(), 'sSkip.json'), 'utf8')).skip, 0);
});

test('Stop hook: armed (skip 0) fires and consumes the flag (dry-run)', () => {
  arm('sFire');
  const { out } = stop({ session_id: 'sFire' });
  assert.match(out, /\[dry-run\].*shutdown/i);
  assert.ok(!existsSync(join(flagDir(), 'sFire.json')), 'flag consumed');
  assert.ok(!existsSync(join(flagDir(), 'sFire.request')), 'request consumed');
});

test('Stop hook: no flag and no machine switch does nothing', () => {
  const { out } = stop({ session_id: 'sIdle' });
  assert.equal(out, '');
});

test('Stop hook: a leading UTF-8 BOM on the payload still parses (F8 fix)', () => {
  arm('sBom');
  const { out } = stop(null, { rawInput: '﻿' + JSON.stringify({ session_id: 'sBom' }) });
  assert.match(out, /\[dry-run\].*shutdown/i);
});

test('MACHINE-ARMED fresh: still wakes the model to judge completion', () => {
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  const { out } = stop({ session_id: 'sMachine', stop_hook_active: false });
  const obj = JSON.parse(out);
  assert.equal(obj.decision, 'block');
  assert.match(obj.reason, /switch is ON/, 'the wake still describes the state');
  // It used to name the engine path so the command would match the allow-rules. That is now
  // the opposite of what we want: see the no-pre-authorised-command test above.
});

test('MACHINE-ARMED stale (>12h): ignored, cleared, no wake', () => {
  const f = join(flagDir(), 'MACHINE-ARMED');
  writeFileSync(f, '');
  const old = Date.now() / 1000 - 13 * 3600;
  utimesSync(f, old, old);
  const { out } = stop({ session_id: 'sStale', stop_hook_active: false });
  assert.equal(out, '', 'no wake for a stale switch');
  assert.ok(!existsSync(f), 'stale switch is cleared');
});

test('MACHINE-ARMED with stop_hook_active is suppressed (no re-trigger loop)', () => {
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  const { out } = stop({ session_id: 'sLoop', stop_hook_active: true });
  assert.equal(out, '');
});

// ---------------------------------------------------------------------------
// Band 1 safety fixes. Every case below was verified to FAIL against the code as
// it shipped in v1.7.1 - a regression test that only passes on the fix proves
// nothing about the bug it claims to guard.
// ---------------------------------------------------------------------------

// ENG-01: `skip: 0` is the fire sentinel, so defaulting a corrupt flag to it meant every
// malformed flag powered the PC off - with no attacker involved, just an interrupted write.
for (const [name, body] of [
  ['truncated write', '{"ski'],
  ['empty file', ''],
  ['garbage', 'not json at all'],
  ['no skip key', '{}'],
  ['negative skip', '{"skip":-1}'],
  ['string skip', '{"skip":"abc"}'],
  ['fractional skip', '{"skip":1.5}'],
  ['JSON null', 'null'],
  ['JSON array', '[]'],
  ['object skip', '{"skip":{"a":1}}'],
]) {
  test(`corrupt flag (${name}) disarms WITHOUT shutting down`, () => {
    const id = `sCorrupt-${name.replace(/\W/g, '')}`;
    writeFileSync(join(flagDir(), `${id}.json`), body);
    writeFileSync(join(flagDir(), `${id}.request`), 'x');
    const { out, code } = stop({ session_id: id });
    assert.doesNotMatch(out, /would start PC shutdown/, 'must NOT fire on unreadable state');
    assert.match(out, /unreadable/i, 'must tell the user it disarmed rather than fail silently');
    assert.equal(code, 0);
    assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'bad flag is consumed so it cannot repeat');
  });
}

// ENG-02: any hook returning decision:"block" re-enters the Stop hook within the SAME
// user-visible turn - including this engine's own MACHINE-ARMED wake. Counting invocations
// instead of turns decremented twice and fired one response early.
test('a re-entered Stop hook does not burn the grace turn', () => {
  const id = 'sReenter';
  arm(id, { thisTurn: false });
  const first = stop({ session_id: id });
  assert.match(first.out, /Shutdown-on-done armed:/, "must say ARMED - /armed/i also matches \"disarmed\"");
  const second = stop({ session_id: id, stop_hook_active: true });
  assert.doesNotMatch(second.out, /would start PC shutdown/, 'must not fire on re-entry');
  assert.equal(JSON.parse(readFileSync(join(flagDir(), `${id}.json`), 'utf8')).skip, 0,
    'the counter must not decrement twice for one turn');
});

// ENG-04: `--off` was filtered out as a "flag" BEFORE the verb check, so it reached the
// status branch: exit 0, no stderr, machine still armed, user believes they disarmed.
for (const bad of ['--off', '--status', '--on', '--disable']) {
  test(`\`toggle ${bad}\` fails loudly and leaves the arm untouched`, () => {
    const id = `sFlag${bad.replace(/\W/g, '')}`;
    toggle('toggle request-on', id);
    toggle('toggle on --this-turn', id);
    const r = toggle(`toggle ${bad}`, id);
    assert.equal(r.code, 1, 'must exit non-zero');
    assert.match(r.err, /Unknown option/);
    assert.doesNotMatch(r.out, /Armed for this chat|Not armed/, 'must not masquerade as a status report');
    assert.ok(existsSync(join(flagDir(), `${id}.json`)), 'a rejected command must not half-disarm');
  });
}

test('an unexpected extra argument is rejected rather than silently armed', () => {
  toggle('toggle request-on', 'sExtra');
  const r = toggle('toggle on --this-turn junk', 'sExtra');
  assert.equal(r.code, 1);
  assert.match(r.err, /Unexpected extra argument/);
  assert.ok(!existsSync(join(flagDir(), 'sExtra.json')), 'nothing armed on a rejected command');
});

// ENG-06: the panel's power button watches *.request via stateGlob, so clearing only the
// marker made the button go dark while the chat stayed armed - the UI asserting "not armed"
// about a machine that was.
test('request-off also drops the arm it authorised (button state cannot lie)', () => {
  const id = 'sReqOff';
  toggle('toggle request-on', id);
  toggle('toggle on --this-turn', id);
  toggle('toggle request-off', id);
  assert.ok(!existsSync(join(flagDir(), `${id}.request`)), 'marker cleared');
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'arm cleared too');
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/, 'a withdrawn request must not still fire');
});

// The MACHINE-ARMED round trip. Round 1 "fixed" double-counting with a blanket
// `if (input.stop_hook_active) process.exit(0)`, which killed this feature outright - the wake
// IS a decision:"block", so the invocation that would fire always carries stop_hook_active -
// and left the flag armed to detonate at an arbitrary later turn. Every other test passed with
// the feature dead, so this end-to-end path is what actually guards against its resurrection.
test('machine-switch round trip: wake, arm WITH a standing request, and FIRE on the same turn', () => {
  // The supported physical-switch flow now requires the external trigger to write BOTH the
  // marker and a request - the marker alone is no longer a key (see the second-key test
  // above). Everything downstream of the arm must still work, which is what this covers:
  // round 1 "fixed" double-counting in a way that killed firing on the re-entry entirely.
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  toggle('toggle request-on', 'sTrip');
  const wake = stop({ session_id: 'sTrip', stop_hook_active: false });
  assert.match(wake.out, /"decision":"block"/, 'turn end wakes the model to judge completion');
  toggle('toggle on --this-turn', 'sTrip');      // the model judges "done" and arms
  const fired = stop({ session_id: 'sTrip', stop_hook_active: true });   // re-entry caused BY the block
  assert.match(fired.out, /would start PC shutdown/, 'the promised turn must actually fire');
  assert.ok(!existsSync(join(flagDir(), 'sTrip.json')), 'flag consumed, not left to detonate later');
});

test('an armed chat does not detonate in a LATER unrelated turn', () => {
  const id = 'sLater';
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  stop({ session_id: id, stop_hook_active: false });
  // The arm must really happen, or "does not fire in a later turn" passes for the empty reason
  // that nothing was ever armed. arm() asserts the arm landed.
  arm(id);
  const fired = stop({ session_id: id, stop_hook_active: true });          // fires here
  assert.match(fired.out, /would start PC shutdown/, 'the armed turn fires (else the test below is vacuous)');
  const later = stop({ session_id: id, stop_hook_active: false });
  assert.doesNotMatch(later.out, /would start PC shutdown/, 'must not fire again in a later turn');
});

// TEST-02: these behaviours were all correct but unguarded - reverting any of them left the
// suite fully green.
test('request-off also clears the machine switch (else the wake re-arms next turn)', () => {
  const id = 'sReqOffMachine';
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  toggle('toggle request-on', id);
  toggle('toggle on --this-turn', id);
  toggle('toggle request-off', id);
  assert.ok(!existsSync(join(flagDir(), 'MACHINE-ARMED')), 'machine switch cleared too');
  const woke = stop({ session_id: id, stop_hook_active: false });
  assert.equal(woke.out, '', 'a withdrawn request must not be re-armed by a lingering wake');
});

test('a flag with no verb is rejected rather than reported as status', () => {
  const r = toggle('toggle --this-turn', 'sNoVerb');
  assert.equal(r.code, 1, 'exits non-zero');
  assert.match(r.err, /needs a verb/);
  assert.doesNotMatch(r.out, /Armed for this chat|Not armed/, 'must not read as an arm confirmation');
});

// ---------------------------------------------------------------------------
// ENG-07: a flag write that fails ENTIRELY (both the atomic rename and the direct-write
// fallback) used to be swallowed - writeFlagAtomic logged and returned, and the caller went on
// to print "Armed" / "Standing shutdown request recorded". The user then believes the machine
// will power off when the work finishes, and it will not; or believes state exists that does
// not. The message must match what is actually on disk.
//
// Failure injection: a DIRECTORY at the target path makes rename fail EPERM and the direct
// write fail EISDIR; a READ-ONLY file makes both fail EPERM while still being readable. Both
// verified on this platform. No mock is involved - the real fs error paths run.
// ---------------------------------------------------------------------------
test('toggle on fails LOUDLY when the arm flag cannot be written (never says Armed)', () => {
  const id = 'sArmWriteFail';
  toggle('toggle request-on', id);
  mkdirSync(join(flagDir(), `${id}.json`), { recursive: true });   // every write to this path now fails
  const r = toggle('toggle on --this-turn', id);
  assert.notEqual(r.code, 0, 'must exit non-zero when nothing was written');
  assert.doesNotMatch(r.out, /^Armed/m, 'must not claim the chat is armed');
  assert.match(r.err, /NOT armed/, 'must say plainly that nothing was armed');
  assert.doesNotMatch(r.err, /may STILL/, 'the request is withdrawn, so no arm on disk can fire');
  // ...and the disk must agree: a later turn-end must not fire off a half-written arm.
  const fired = stop({ session_id: id });
  assert.doesNotMatch(fired.out, /would start PC shutdown/, 'a failed arm must not fire later');
});

test('toggle request-on fails LOUDLY when the marker cannot be written (never says recorded)', () => {
  const id = 'sReqWriteFail';
  mkdirSync(join(flagDir(), `${id}.request`), { recursive: true });
  const r = toggle('toggle request-on', id);
  assert.notEqual(r.code, 0, 'must exit non-zero');
  assert.doesNotMatch(r.out, /recorded/i, 'must not report a standing request that does not exist');
  assert.match(r.err, /NOT recorded/);
  // The request marker is the ONLY arm key, so a failed one must not open the gate either.
  const armed = toggle('toggle on --this-turn', id);
  assert.doesNotMatch(armed.out, /^Armed/m, 'a request that was never recorded cannot authorise an arm');
});

test('Stop hook: an unwritable countdown DISARMS rather than promising a shutdown', () => {
  const id = 'sSkipWriteFail';
  const f = join(flagDir(), `${id}.json`);
  arm(id, { thisTurn: false });
  chmodSync(f, 0o444);          // readable (so skip parses) but unwritable
  const r = stop({ session_id: id });
  assert.equal(r.code, 0, 'the hook must not crash the turn');
  assert.doesNotMatch(r.out, /Shutdown-on-done armed:/,
    'must not promise a countdown whose decrement never reached the disk');
  assert.match(r.out, /DISARMED/, 'must tell the user it disarmed instead');
  // The undecremented flag must never relocate the power-off to some later turn.
  try { chmodSync(f, 0o666); } catch {}
  const later = stop({ session_id: id, stop_hook_active: false });
  assert.doesNotMatch(later.out, /would start PC shutdown/, 'must not detonate in a later turn');
});

// ---------------------------------------------------------------------------
// SEC-03: the two-sided consent gate existed only at the arming COMMAND. `toggle on` required a
// standing `<id>.request`, but the Stop hook checked only that `<id>.json` existed and the fire
// path never looked at the request again. `request-off` deletes the request FIRST and the arm
// flag SECOND, so a locked/failed second delete left a valid `skip: 0` flag with the consent
// marker already gone - and the next turn end powered the machine off.
//
// These cases were verified to FAIL before the fix: with the old engine each of them fired.
// ---------------------------------------------------------------------------
test('an arm whose standing request has vanished does NOT fire (consent withdrawn)', () => {
  const id = 'sReqGone';
  arm(id);                                                   // armed for THIS turn, skip 0
  rmSync(join(flagDir(), `${id}.request`), { force: true }); // the request-off half that succeeded
  const { out, code } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/, 'must NOT power off after consent is gone');
  assert.match(out, /NOT shut down/i, 'must say plainly that it did not shut down');
  assert.equal(code, 0);
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'the orphaned arm is consumed, not left to retry');
});

test('the exact reported sequence: request-off clears the request but the arm flag survives', () => {
  const id = 'sHalfWithdrawn';
  arm(id);
  // Reproduce the failure of `request-off` at engine:257 - the request delete lands, the arm-flag
  // delete does not (a Windows lock on the file). Reconstructing the flag with the SAME bytes is
  // exactly what "the delete failed" means on disk.
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  toggle('toggle request-off', id);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/,
    'a withdrawn request must stop the shutdown even when its arm flag survives the withdrawal');
});

test('an arm does NOT ride a LATER, differently-authorised request (token, not mere existence)', () => {
  // Existence alone is not enough: withdraw, then make a NEW standing request for the same chat
  // and never arm it. An existence check sees "a request" and fires an arm the user did not
  // authorise in this consent episode. The token identifies WHICH request granted the arm.
  const id = 'sReArmed';
  arm(id);
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  toggle('toggle request-off', id);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);   // stale arm survives, as above
  toggle('toggle request-on', id);                            // a NEW request, not armed
  assert.ok(existsSync(join(flagDir(), `${id}.request`)), 'a standing request does exist again');
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/, 'the new request must not authorise the old arm');
  // Only the stale ARM is dropped. Deleting the request the user has just made would withdraw
  // consent they gave and darken the panel's power button (it mirrors *.request) - the UI lying
  // in the other direction, which is the defect class this whole area exists to close.
  assert.ok(existsSync(join(flagDir(), `${id}.request`)), 'the live standing request survives');
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'the stale arm does not');
});

test('the countdown path re-verifies the request too, not only the fire path', () => {
  // skip: 1 is one turn away from a power-off. If consent is withdrawn during the grace turn the
  // engine must disarm THEN, rather than promise a countdown it will honour with no live request.
  const id = 'sGraceGone';
  arm(id, { thisTurn: false });
  rmSync(join(flagDir(), `${id}.request`), { force: true });
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /Shutdown-on-done armed:/, 'must not promise a countdown without live consent');
  assert.match(out, /NOT shut down/i);
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'disarmed rather than left counting down');
});

test('a hand-written arm flag cannot fire: the flag alone is not a key', () => {
  // The shape the old tests asserted a FIRE from. Any principal that can drop a file into
  // FLAG_DIR could write this; only a request it was bound to makes it act.
  const id = 'sForged';
  writeFileSync(join(flagDir(), `${id}.json`), JSON.stringify({ skip: 0 }));
  writeFileSync(join(flagDir(), `${id}.request`), 'x');   // even WITH a request beside it
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/, 'an unbound flag must never fire');
});

test('the consent token SURVIVES the countdown decrement (the fix must not kill the feature)', () => {
  // Fail-closed re-verification plus a decrement that dropped `req` would disarm every chat at
  // its grace turn - the feature dead, and every other test still green. This is the round trip.
  const id = 'sTokenTrip';
  arm(id, { thisTurn: false });
  const first = stop({ session_id: id });
  assert.match(first.out, /Shutdown-on-done armed:/, 'grace turn still counts down');
  const second = stop({ session_id: id });
  assert.match(second.out, /would start PC shutdown/, 'the promised turn still fires');
  assert.ok(!existsSync(join(flagDir(), `${id}.request`)), 'request consumed by the fire');
});

// QA-07: machineArmedFresh() is what makes the 12h expiry real, but only the Stop path was
// covered - a forgotten week-old switch could still satisfy the anti-injection arm gate.
test('a STALE machine switch does not satisfy the arm gate', () => {
  const f = join(flagDir(), 'MACHINE-ARMED');
  writeFileSync(f, '');
  const old = Date.now() / 1000 - 13 * 3600;
  utimesSync(f, old, old);
  const { out } = toggle('toggle on --this-turn', 'sStaleArm');
  assert.match(out, /Refused: no standing shutdown request/);
  assert.ok(!existsSync(join(flagDir(), 'sStaleArm.json')), 'no flag written when refused');
});

// ---------------------------------------------------------------------------
// ARM AGE (reported by @RasmusKD). The consent token proves an arm belongs to the request on disk
// NOW; it says nothing about WHEN. The fire path deletes the request, so a request still standing
// is one that never fired - and yesterday's arm passed the token check intact. A "next turn" arm
// not consumed until the user replied a day later powered the PC off then, in a session they
// believed was live. An arm is now stamped with the wall clock (armedAt) AND the machine's uptime
// (armedUp) and bounded to 12h like the machine switch.
//
// age() rewrites ONLY the two stamps on an arm the engine itself wrote, keeping its consent token,
// so each case below isolates the age check from the token check. Both stamps are set relative to
// "now" on this machine, as the engine reads them.
// ---------------------------------------------------------------------------
const HOUR = 3600 * 1000;
const upNow = () => Math.round(osUptime() * 1000);
function age(id, { wall, up = wall }) {   // how long ago, per clock, the arm was made (ms)
  const f = join(flagDir(), `${id}.json`);
  const o = JSON.parse(readFileSync(f, 'utf8'));
  o.armedAt = Date.now() - wall;
  o.armedUp = upNow() - up;
  writeFileSync(f, JSON.stringify(o));
}
function setStamps(id, fields) {           // write arbitrary stamp values (fail-closed cases)
  const f = join(flagDir(), `${id}.json`);
  const o = JSON.parse(readFileSync(f, 'utf8'));
  for (const [k, v] of Object.entries(fields)) { if (v === undefined) delete o[k]; else o[k] = v; }
  writeFileSync(f, JSON.stringify(o));
}
const readFlag = (id) => JSON.parse(readFileSync(join(flagDir(), `${id}.json`), 'utf8'));

test('toggle on stamps the arm with the wall clock AND the uptime it was armed at', () => {
  const t0 = Date.now();
  const u0 = upNow();
  arm('sStamp');
  const { armedAt, armedUp } = readFlag('sStamp');
  assert.ok(armedAt >= t0 && armedAt <= Date.now(), `armedAt ${armedAt} is the arm time`);
  assert.ok(armedUp >= u0 - 1000 && armedUp <= upNow() + 1000, `armedUp ${armedUp} is the uptime at arming`);
});

test('an arm older than 12h does NOT fire, and clears both markers', () => {
  const id = 'sAgedFire';
  arm(id);                                   // skip 0, live request, valid token
  age(id, { wall: 13 * HOUR });
  const { out, code } = stop({ session_id: id });
  assert.equal(code, 0);
  assert.doesNotMatch(out, /would start PC shutdown/, 'a day-old arm must not power the PC off');
  assert.match(out, /more than 12h old/, 'must tell the user why');
  assert.match(out, /NOT shut down/);
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'the stale arm is consumed');
  // The request goes too: left standing, the agent could renew the arm with the pre-authorised
  // `toggle on` and re-arm yesterday's consent without the user being asked again.
  assert.ok(!existsSync(join(flagDir(), `${id}.request`)), 'the stale standing request is cleared');
  const again = toggle('toggle on --this-turn', id);
  assert.match(again.out, /Refused: no standing shutdown request/, 're-arming needs a fresh request-on');
});

test('a stale NEXT-turn arm is cleared, not decremented toward firing (the reported case)', () => {
  const id = 'sAgedNext';
  arm(id, { thisTurn: false });              // skip 1
  age(id, { wall: 25 * HOUR });              // the user replied a day later
  const first = stop({ session_id: id });
  assert.doesNotMatch(first.out, /Shutdown-on-done armed:/, 'must not promise a countdown');
  assert.match(first.out, /more than 12h old/);
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'cleared, not decremented to skip 0');
  const second = stop({ session_id: id });
  assert.doesNotMatch(second.out, /would start PC shutdown/, 'and nothing fires on the turn after');
});

test('an arm just under 12h old still fires (the bound must not kill the feature)', () => {
  const id = 'sElevenHours';
  arm(id);
  age(id, { wall: 11 * HOUR });
  const { out } = stop({ session_id: id });
  assert.match(out, /would start PC shutdown/);
});

// The reviewer's sequence: an arm survives (the app closed before its Stop hook ran), the chat is
// resumed the next day, and the skill tells the agent to check `toggle status` and re-arm while
// the request is ACTIVE. Arming over the old flag would stamp yesterday's request as fresh and
// fire at the end of THIS response - so status and `toggle on` must expire it too.
test('a stale arm is expired by toggle status, so the skill cannot see an ACTIVE request', () => {
  const id = 'sAgedStatus';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const st = toggle('toggle status', id);
  assert.match(st.out, /Not armed for this chat \(its arm was more than 12h old/);
  assert.match(st.out, /Standing request: none\./, 'the skill keys re-arming on ACTIVE');
  const re = toggle('toggle on --this-turn', id);
  assert.match(re.out, /Refused: no standing shutdown request/);
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/);
});

test('a stale arm cannot be renewed by arming over it (toggle on expires it first)', () => {
  const id = 'sAgedRenew';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const re = toggle('toggle on --this-turn', id);
  assert.match(re.out, /Refused: no standing shutdown request for this chat \(its previous arm was more than 12h old/);
  assert.ok(!existsSync(join(flagDir(), `${id}.request`)), 'its request went with it');
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/, 'and the turn end does not fire');
});

test('a FRESH arm is still re-armable and status still reports it (the checks are age-only)', () => {
  const id = 'sFreshRenew';
  arm(id, { thisTurn: false });
  age(id, { wall: 2 * HOUR });
  assert.match(toggle('toggle status', id).out, /^Armed for this chat\. Standing request: ACTIVE\./);
  assert.match(toggle('toggle on --this-turn', id).out, /^Armed/);
  assert.match(stop({ session_id: id }).out, /would start PC shutdown/);
});

// The wall clock alone can lie. Set back two hours after arming, a 13h-old arm reads 11h old.
test('a clock set BACK after arming cannot make an old arm look young', () => {
  const id = 'sClockBack';
  arm(id);
  age(id, { wall: 11 * HOUR, up: 13 * HOUR });
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/);
  assert.match(out, /clock was changed/);
});

test('within the clock tolerance the OLDER of the two ages still counts', () => {
  const id = 'sClockOlder';
  arm(id);
  age(id, { wall: 12 * HOUR - 60 * 1000, up: 12 * HOUR + 60 * 1000 });   // 2 min apart
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/);
  assert.match(out, /more than 12h old/);
});

test('an arm whose stored uptime exceeds the current uptime (a restart) fails closed', () => {
  const id = 'sRebooted';
  arm(id);
  age(id, { wall: 1 * HOUR, up: -1 * HOUR });   // uptime is now LOWER than when it was armed
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/);
  assert.match(out, /before the PC last restarted/);
});

test('ordinary clock correction (a minute either way) still fires', () => {
  for (const [id, wall] of [['sSkewAhead', -60 * 1000], ['sSkewBehind', 2 * HOUR + 60 * 1000]]) {
    arm(id);
    age(id, { wall, up: wall < 0 ? 0 : 2 * HOUR });
    assert.match(stop({ session_id: id }).out, /would start PC shutdown/, id);
  }
});

for (const [name, fields] of [
  ['no stamps (an arm written by an older build)', { armedAt: undefined, armedUp: undefined }],
  ['no uptime stamp', { armedUp: undefined }],
  ['a string armedAt', { armedAt: String(Date.now()) }],
  ['a null armedUp', { armedUp: null }],
  ['an armedAt an hour in the future', { armedAt: Date.now() + HOUR }],
]) {
  test(`an arm with ${name} fails CLOSED: cleared, not fired`, () => {
    const id = `sUndated-${name.replace(/\W/g, '').slice(0, 40)}`;
    arm(id);
    setStamps(id, fields);
    const { out, code } = stop({ session_id: id });
    assert.equal(code, 0);
    assert.doesNotMatch(out, /would start PC shutdown/, 'an arm that cannot be aged must not fire');
    assert.match(out, /NOT shut down/);
    assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'and it does not linger to fire later');
  });
}

test('the countdown decrement keeps the ORIGINAL arm stamps (age is not reset)', () => {
  // Refreshing a stamp at the decrement would make a skip-1 arm that then sits for a day look
  // brand new on the turn it fires - the exact path the bound exists to catch.
  const id = 'sKeepStamp';
  arm(id, { thisTurn: false });
  age(id, { wall: 2 * HOUR });
  const before = readFlag(id);
  const { out } = stop({ session_id: id });
  assert.match(out, /Shutdown-on-done armed:/);
  const after = readFlag(id);
  assert.equal(after.skip, 0, 'decremented');
  assert.equal(after.armedAt, before.armedAt, 'armedAt carried through unchanged');
  assert.equal(after.armedUp, before.armedUp, 'armedUp carried through unchanged');
});

test('the age check also runs on a same-turn re-entry (no window for a stale arm to survive)', () => {
  const id = 'sAgedReentry';
  arm(id, { thisTurn: false });
  stop({ session_id: id });                  // decrement: skip 0, consumedInTurn
  age(id, { wall: 13 * HOUR });
  const { out } = stop({ session_id: id, stop_hook_active: true });
  assert.match(out, /more than 12h old/);
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'cleared on the re-entry, not left armed');
});

test('a stale arm under a NEWER request drops the arm but never the newer request', () => {
  // The token check must run before the age check: expiring deletes the request, which is only
  // safe once the request is proven to be the one that authorised this arm.
  const id = 'sAgedOldToken';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  toggle('toggle request-off', id);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);   // the arm survives the withdrawal
  toggle('toggle request-on', id);                            // the user asks again, not armed yet
  const { out } = stop({ session_id: id });
  assert.doesNotMatch(out, /would start PC shutdown/);
  assert.ok(existsSync(join(flagDir(), `${id}.request`)), 'the newer standing request survives');
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'the stale arm does not');
});

test('toggle status drops a stale arm under a NEWER request but reports that request ACTIVE', () => {
  // The newer request is consent the user gave AFTER the aged arm: it is not voided with it.
  const id = 'sAgedOldTokenCmd';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  toggle('toggle request-off', id);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);
  toggle('toggle request-on', id);
  assert.match(toggle('toggle status', id).out, /Standing request: ACTIVE\./, 'the newer request is reported');
  assert.ok(existsSync(join(flagDir(), `${id}.request`)), 'and not deleted by status');
  assert.ok(!existsSync(join(flagDir(), `${id}.json`)), 'the aged arm is gone');
});

test('toggle on under a NEWER request replaces a stale arm with a fresh one bound to it', () => {
  const id = 'sAgedOldTokenArm';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  const oldReq = readFlag(id).req;
  toggle('toggle request-off', id);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);
  toggle('toggle request-on', id);                            // fresh consent, approved by the user
  const t0 = Date.now();
  assert.match(toggle('toggle on --this-turn', id).out, /^Armed/, 'the newer request may be armed under');
  const f = readFlag(id);
  assert.notEqual(f.req, oldReq, 'bound to the newer request');
  assert.ok(f.armedAt >= t0, 'freshly stamped');
  assert.match(stop({ session_id: id }).out, /would start PC shutdown/);
});

// WITHDRAWN CONSENT IS REVOKED BY TOKEN, NOT ONLY BY DELETING FILES. Windows refuses to delete a
// file another process holds open without delete sharing (antivirus, an indexer, a backup agent),
// and a request that survives its delete looks live again once the lock clears - status said
// ACTIVE and `toggle on` re-armed it. Every withdrawal now records the void token in
// <session>.revoked first. The locks here are held by a real second process, so no hook inside the
// engine is needed.
function holdOpen(path, share) {             // share: 'Read' (readable, not deletable) or 'None'
  const ps = spawn('powershell.exe', ['-NoProfile', '-Command',
    "$f = [IO.File]::Open($env:CB_HOLD, 'Open', 'Read', $env:CB_SHARE); [Console]::Out.WriteLine('held'); " +
    '[Console]::Out.Flush(); [void][Console]::In.ReadLine(); $f.Close()'],
    { env: { ...process.env, CB_HOLD: path, CB_SHARE: share }, stdio: ['pipe', 'pipe', 'inherit'] });
  const held = new Promise((res, rej) => {
    ps.stdout.on('data', (d) => { if (String(d).includes('held')) res(); });
    ps.on('exit', (c) => rej(new Error(`holder exited ${c} before holding the file`)));
  });
  const release = () => new Promise((res) => { ps.on('exit', res); ps.stdin.end(); });
  return { held, release };
}
const onWindows = { skip: process.platform !== 'win32' && 'Windows file locking' };
const exists = (id, ext) => existsSync(join(flagDir(), `${id}.${ext}`));

for (const share of ['Read', 'None']) {
  test(`a stale arm whose request is LOCKED (share ${share}): never ACTIVE, never renewed, never fired`, onWindows, async () => {
    const id = `sAgedLocked${share}`;
    arm(id);
    age(id, { wall: 13 * HOUR });
    const lock = holdOpen(join(flagDir(), `${id}.request`), share);
    try {
      await lock.held;
      const st = toggle('toggle status', id);
      assert.doesNotMatch(st.out, /Standing request: ACTIVE/, 'a void request is never reported ACTIVE');
      assert.match(st.out, /Standing request: EXPIRED/);
      assert.ok(exists(id, 'request'), 'the lock really did keep the request on disk');
      const re = toggle('toggle on --this-turn', id);
      assert.doesNotMatch(re.out, /^Armed/m, 'toggle on must not re-arm a void request');
      assert.ok(!exists(id, 'json'), 'no fresh arm was written');
      assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/);
    } finally {
      await lock.release();
    }
    // Lock gone: the void request is still void, and is cleared at the next look.
    assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m, 'still void once readable');
    assert.match(toggle('toggle status', id).out, /Standing request: none\./);
    assert.ok(!exists(id, 'request'), 'the revoked request is removed once it can be');
  });
}

test('a clock put right again cannot revive an arm that was settled (revocation, not just deletion)', () => {
  // An arm can fail the age check only transiently (a clock jump, a quick restart). If its files
  // had survived the cleanup and the clock were then put right, it would look in date again. Its
  // token is revoked, so it cannot fire. Simulated by restoring both files after the settle - what
  // a failed delete leaves - with stamps that are perfectly in date.
  const id = 'sRevived';
  arm(id);
  const flagBytes = readFileSync(join(flagDir(), `${id}.json`));
  const reqBytes = readFileSync(join(flagDir(), `${id}.request`));
  age(id, { wall: 1 * HOUR - 10 * 60 * 1000, up: 1 * HOUR });   // wall clock 10 min out
  assert.match(stop({ session_id: id }).out, /clock was changed/);
  writeFileSync(join(flagDir(), `${id}.json`), flagBytes);       // the arm "survived"
  writeFileSync(join(flagDir(), `${id}.request`), reqBytes);     // and so did its request
  assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/, 'a settled arm stays dead');
  assert.doesNotMatch(toggle('toggle status', id).out, /Standing request: ACTIVE/);
  assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m);
  // Asking again is the way back: request-on is a new nonce, not on the revoked list.
  assert.equal(toggle('toggle request-on', id).code, 0);
  assert.match(toggle('toggle on --this-turn', id).out, /^Armed/m);
  assert.match(stop({ session_id: id }).out, /would start PC shutdown/);
});

for (const verb of ['toggle off', 'toggle request-off']) {
  test(`${verb} with the request LOCKED (share Read) still voids it, and still disarms`, onWindows, async () => {
    const id = `sLockedOff-${verb.split(' ')[1]}`;
    arm(id);
    const lock = holdOpen(join(flagDir(), `${id}.request`), 'Read');
    let r;
    try {
      await lock.held;
      r = toggle(verb, id);
      assert.ok(!exists(id, 'json'), 'the arm is gone');
      assert.match(toggle('toggle status', id).out, /Standing request: EXPIRED/, 'never ACTIVE');
    } finally {
      await lock.release();
    }
    assert.equal(r.code, 0, `revoked by token, so the withdrawal is complete: ${r.err}`);
    assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m, 'the withdrawn request cannot be re-armed');
    assert.match(toggle('toggle status', id).out, /Standing request: none\./);
  });

  test(`${verb} with the request LOCKED (share None) says it is NOT fully cleared`, onWindows, async () => {
    const id = `sLockedOffNone-${verb.split(' ')[1]}`;
    arm(id);
    const lock = holdOpen(join(flagDir(), `${id}.request`), 'None');
    let r;
    try {
      await lock.held;
      r = toggle(verb, id);
    } finally {
      await lock.release();
    }
    // Its token cannot be read, so it cannot be proven void: the disarm must not look successful.
    assert.notEqual(r.code, 0);
    assert.match(r.err, /NOT fully cleared/);
    // The arm was revoked by its own token, which is this request's: once readable it is void.
    assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m);
    assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/);
  });
}

test('an unreadable arm flag with its request LOCKED still voids the request', onWindows, async () => {
  const id = 'sCorruptLocked';
  assert.equal(toggle('toggle request-on', id).code, 0);
  writeFileSync(join(flagDir(), `${id}.json`), '{"ski');     // a truncated arm
  const lock = holdOpen(join(flagDir(), `${id}.request`), 'Read');
  try {
    await lock.held;
    const { out } = stop({ session_id: id });
    assert.match(out, /unreadable/);
    assert.ok(!exists(id, 'json'), 'the bad flag is consumed');
  } finally {
    await lock.release();
  }
  assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m, 'the request it sat on is void');
});


test('when consent cannot be voided at all, the aged arm is KEPT and every path refuses', onWindows, async () => {
  // The directory refuses new files (a deny ACE for this user) and the request is locked: no
  // revocation marker can be created and the request cannot be removed. The arm must then stay on
  // disk so the hook, status and toggle on keep finding it and keep refusing, rather than vanish
  // and leave a request with nothing beside it to say it is void.
  const id = 'sNothingWritable';
  arm(id);
  age(id, { wall: 13 * HOUR });
  const who = `${process.env.USERDOMAIN ? `${process.env.USERDOMAIN}\\` : ''}${process.env.USERNAME}`;
  const deny = spawnSync('icacls', [flagDir(), '/deny', `${who}:(WD,AD)`], { encoding: 'utf8' });
  assert.equal(deny.status, 0, `could not set up the deny ACE: ${deny.stdout} ${deny.stderr}`);
  const lock = holdOpen(join(flagDir(), `${id}.request`), 'Read');
  try {
    await lock.held;
    assert.throws(() => writeFileSync(join(flagDir(), 'probe.txt'), 'x'), 'the directory really refuses new files');
    const { out } = stop({ session_id: id });
    assert.doesNotMatch(out, /would start PC shutdown/);
    assert.match(out, /could not be changed/);
    assert.ok(exists(id, 'json'), 'the aged arm is kept');
    assert.doesNotMatch(toggle('toggle status', id).out, /Standing request: ACTIVE/);
    assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m);
    assert.ok(exists(id, 'json'), 'and still kept after status and toggle on');
  } finally {
    await lock.release();
    spawnSync('icacls', [flagDir(), '/remove:d', who], { encoding: 'utf8' });
  }
});

// ---------------------------------------------------------------------------
// Round-4 review cases.
// ---------------------------------------------------------------------------

test('the fire path consumes a LOCKED arm by revocation, so it cannot fire again later', onWindows, async () => {
  // The old consume threw on a locked arm before deleting anything: no fire now, and the surviving
  // skip-0 arm fired at the next, unrelated turn end - a power-off moved to a moment nobody chose.
  const id = 'sFireLocked';
  arm(id);
  const lock = holdOpen(join(flagDir(), `${id}.json`), 'Read');
  try {
    await lock.held;
    assert.match(stop({ session_id: id }).out, /would start PC shutdown/, 'consumed by revocation, so it fires now');
  } finally {
    await lock.release();
  }
  assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/, 'and the surviving file never fires again');
  assert.doesNotMatch(toggle('toggle status', id).out, /Standing request: ACTIVE/);
});

test('an unusable arm that names an OLDER request leaves a newer request alone', () => {
  const id = 'sBadArmNewerReq';
  assert.equal(toggle('toggle request-on', id).code, 0);       // newer consent
  writeFileSync(join(flagDir(), `${id}.json`), JSON.stringify({ skip: 'bad', req: 'b'.repeat(32) }));
  assert.match(stop({ session_id: id }).out, /unreadable/);
  assert.ok(!exists(id, 'json'), 'the bad arm is consumed');
  assert.match(toggle('toggle on --this-turn', id).out, /^Armed/m, 'the newer request still authorises an arm');
});


test('toggle off whose `shutdown -a` fails does NOT say disarmed', () => {
  // A countdown may be running. SystemRoot points the engine's shutdown.exe at a missing file.
  const id = 'sAbortFails';
  arm(id);
  // Windows env names are case-insensitive but a spread object is not: drop every spelling first.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^systemroot$/i.test(k)));
  const r = spawnSync('node', [ENGINE, 'toggle', 'off'], {
    env: { ...env, USERPROFILE: HOME, HOME, CLAUDE_CODE_SESSION_ID: id, SystemRoot: join(HOME, 'no-such-windows') },
    encoding: 'utf8',
  });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /shutdown -a. failed/);
  assert.doesNotMatch(r.stdout, /Disarmed/);
  assert.ok(!exists(id, 'json'), 'the chat itself is still disarmed');
});

test('status does not call an arm with an unusable countdown "Armed"', () => {
  const id = 'sStatusBadSkip';
  arm(id);
  const o = readFlag(id);
  o.skip = 'bad';
  writeFileSync(join(flagDir(), `${id}.json`), JSON.stringify(o));
  assert.match(toggle('toggle status', id).out, /^Not armed for this chat \(a leftover arm/);
});

test('status reports a stale machine switch as off, the way the hook reads it', () => {
  const f = join(flagDir(), 'MACHINE-ARMED');
  writeFileSync(f, '');
  const old = Date.now() / 1000 - 13 * 3600;
  utimesSync(f, old, old);
  assert.match(toggle('toggle status', 'sStatusStaleMachine').out, /Machine-wide switch: off\./);
});

test('an arm whose request is gone/unreadable AND which cannot be deleted is revoked, so it never fires later', onWindows, async () => {
  // The token-mismatch path used to delete the arm, best effort, and say "disarmed". With the
  // request locked against reading and the arm locked against deletion, both survived; once the
  // locks cleared they matched again and fired at some later, unrelated turn end.
  const id = 'sMismatchLocked';
  arm(id);
  const reqLock = holdOpen(join(flagDir(), `${id}.request`), 'None');
  const armLock = holdOpen(join(flagDir(), `${id}.json`), 'Read');
  try {
    await reqLock.held;
    await armLock.held;
    const { out } = stop({ session_id: id });
    assert.doesNotMatch(out, /would start PC shutdown/);
    assert.match(out, /now disarmed/, 'disarmed is said only once it is proven (revoked)');
  } finally {
    await armLock.release();
    await reqLock.release();
  }
  assert.ok(exists(id, 'json') && exists(id, 'request'), 'both files survived the locks');
  assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/, 'and still never fire');
  assert.doesNotMatch(toggle('toggle on --this-turn', id).out, /^Armed/m, 'nor can the request be re-armed');
});

test('request-on clears only THIS chat\'s revocation markers', () => {
  const a = 'sClr';
  const b = 'sClr.b';                                          // an id that starts with the first
  for (const id of [a, b]) { arm(id); toggle('toggle off', id); }
  const markers = (id) => readdirSync(flagDir()).filter((n) => new RegExp(`^${id.replace(/\./g, '\\.')}\\.[0-9a-f]{32}\\.revoked$`).test(n));
  assert.ok(markers(a).length > 0 && markers(b).length > 0, 'both chats have revocation markers');
  assert.equal(toggle('toggle request-on', a).code, 0);
  assert.equal(markers(a).length, 0, 'the obsolete markers of this chat are cleared');
  assert.ok(markers(b).length > 0, 'the other chat keeps its markers');
});

test('a hand-written arm token never becomes part of a path', () => {
  // `req` comes from a file. Revocation names a marker after a token, so only real tokens may.
  const id = 'sEvilToken';
  assert.equal(toggle('toggle request-on', id).code, 0);
  writeFileSync(join(flagDir(), `${id}.json`), JSON.stringify({ skip: 0, req: '../../evil', armedAt: Date.now(), armedUp: upNow() }));
  assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/);
  assert.ok(!readdirSync(HOME).some((n) => n.includes('evil')), 'nothing written outside the flag directory');
  assert.ok(!readdirSync(flagDir()).some((n) => n.includes('evil')), 'nor inside it');
});

// ---------------------------------------------------------------------------
// Round-6 review: a write that failed must not leave an older arm or request live behind a
// "disarmed" / "NOT armed" / "NOT recorded" message. Both files are held by second processes
// (share Read: readable, so consent verifies; neither rewritable nor deletable).
// ---------------------------------------------------------------------------
async function withBothLocked(id, fn) {
  const a = holdOpen(join(flagDir(), `${id}.json`), 'Read');
  const b = holdOpen(join(flagDir(), `${id}.request`), 'Read');
  try { await a.held; await b.held; return fn(); } finally { await a.release(); await b.release(); }
}
const neverFires = (id) => {
  for (let i = 0; i < 3; i++) {
    assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/, `turn end ${i + 1} after the locks cleared`);
  }
};

test('a countdown whose decrement cannot be written is DISARMED for real', onWindows, async () => {
  const id = 'sCountdownLocked';
  arm(id, { thisTurn: false });                                // skip 1
  const out = await withBothLocked(id, () => stop({ session_id: id }).out);
  assert.match(out, /DISARMED/);
  neverFires(id);                                              // the intact skip-1 arm used to fire here
});

test('toggle on that cannot replace a locked older arm says NOT armed - and it is true', onWindows, async () => {
  const id = 'sRearmLocked';
  arm(id, { thisTurn: false });                                // an older, live arm
  const r = await withBothLocked(id, () => toggle('toggle on --this-turn', id));
  assert.notEqual(r.code, 0);
  assert.match(r.err, /NOT armed/);
  assert.doesNotMatch(r.err, /may STILL/, 'withdrawn by revocation, so it is proven safe');
  neverFires(id);                                              // the older arm used to survive and fire
});

test('request-on that cannot replace a locked request says NOT recorded - and nothing stands', onWindows, async () => {
  const id = 'sRerequestLocked';
  arm(id);                                                     // previous request + a this-turn arm
  const r = await withBothLocked(id, () => toggle('toggle request-on', id));
  assert.notEqual(r.code, 0);
  assert.match(r.err, /NOT recorded/);
  assert.doesNotMatch(r.err, /may STILL/);
  neverFires(id);                                              // the previous request + arm used to fire
  assert.doesNotMatch(toggle('toggle status', id).out, /Standing request: ACTIVE/);
});

test('toggle off with the ARM locked unreadable still disarms: the void request leaves it nothing to fire under', onWindows, async () => {
  // The arm can be neither read (so its token is unknown) nor removed. Its request is revoked and
  // removed, and an arm fires only under the request on disk - so it is safe, and saying so is true.
  const id = 'sOffArmUnreadable';
  arm(id);
  const lock = holdOpen(join(flagDir(), `${id}.json`), 'None');
  let r;
  try {
    await lock.held;
    r = toggle('toggle off', id);
  } finally {
    await lock.release();
  }
  assert.equal(r.code, 0, `the disarm is proven, so it is reported as done: ${r.err}`);
  assert.ok(exists(id, 'json'), 'the arm file did survive the lock');
  assert.doesNotMatch(stop({ session_id: id }).out, /would start PC shutdown/);
});
