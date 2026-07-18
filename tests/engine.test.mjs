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
  assert.match(out, /armed/i);
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
