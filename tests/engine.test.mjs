// Automated tests for the shutdown-on-done engine — the highest-consequence component
// (it can power off the PC). Run: node --test tests/   (needs Node 18+; uses node:test).
// Every test uses a throwaway USERPROFILE so the real ~/.claude is never touched, and the
// Stop-hook fire path always runs under SHUTDOWN_ON_DONE_DRYRUN=1 so nothing shuts down.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync, readFileSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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

test('toggle on is allowed when a fresh machine switch is set (arm gate)', () => {
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  toggle('toggle on --this-turn', 'sMach');
  assert.equal(JSON.parse(readFileSync(join(flagDir(), 'sMach.json'), 'utf8')).skip, 0);
});

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
  writeFileSync(join(flagDir(), 'sSkip.json'), JSON.stringify({ skip: 1 }));
  const { out } = stop({ session_id: 'sSkip' });
  assert.match(out, /Shutdown-on-done armed:/, "must say ARMED - /armed/i also matches \"disarmed\"");
  assert.doesNotMatch(out, /shutting down|would start/i);
  assert.equal(JSON.parse(readFileSync(join(flagDir(), 'sSkip.json'), 'utf8')).skip, 0);
});

test('Stop hook: armed (skip 0) fires and consumes the flag (dry-run)', () => {
  writeFileSync(join(flagDir(), 'sFire.json'), JSON.stringify({ skip: 0 }));
  writeFileSync(join(flagDir(), 'sFire.request'), 'x');
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
  writeFileSync(join(flagDir(), 'sBom.json'), JSON.stringify({ skip: 0 }));
  const { out } = stop(null, { rawInput: '﻿' + JSON.stringify({ session_id: 'sBom' }) });
  assert.match(out, /\[dry-run\].*shutdown/i);
});

test('MACHINE-ARMED fresh: wakes the model with a forward-slash script path', () => {
  writeFileSync(join(flagDir(), 'MACHINE-ARMED'), '');
  const { out } = stop({ session_id: 'sMachine', stop_hook_active: false });
  const obj = JSON.parse(out);
  assert.equal(obj.decision, 'block');
  const m = obj.reason.match(/node "([^"]+)"/);
  assert.ok(m, 'reason names the engine');
  assert.ok(!m[1].includes('\\'), 'path must be forward-slash to match the allow-rules');
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
  writeFileSync(join(flagDir(), `${id}.json`), JSON.stringify({ skip: 1 }));
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
