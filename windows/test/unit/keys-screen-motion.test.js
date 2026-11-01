'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { ShortcutDetector } = require('../../src/main/keys');
const S = require('../../src/main/screen-math');
const M = require('../../src/shared/motion');
const { NO_KEYS } = require('../../src/main/win32');

const snap = (o) => Object.assign({}, NO_KEYS, o);

test('ctrl+alt pressed and released', () => {
  const d = new ShortcutDetector('ctrl+alt');
  assert.deepEqual(d.update(snap({ ctrl: true }), 0), []);
  assert.deepEqual(d.update(snap({ ctrl: true, alt: true }), 20).map((e) => e.type), ['pressed']);
  assert.deepEqual(d.update(snap({ ctrl: true, alt: true }), 40), []);
  assert.deepEqual(d.update(snap({ ctrl: true }), 60).map((e) => e.type), ['released']);
});

test('ctrl+alt does not fire when another key is held first (ctrl+alt+del style)', () => {
  const d = new ShortcutDetector('ctrl+alt');
  assert.deepEqual(d.update(snap({ ctrl: true, alt: true, otherKey: true }), 0), []);
});

test('escape edge', () => {
  const d = new ShortcutDetector('ctrl+alt');
  assert.deepEqual(d.update(snap({ escape: true }), 0).map((e) => e.type), ['escape']);
  assert.deepEqual(d.update(snap({ escape: true }), 10), []);
});

test('double ctrl tap', () => {
  const d = new ShortcutDetector('ctrl+alt');
  let ev = [];
  ev.push(...d.update(snap({ ctrl: true }), 0));
  ev.push(...d.update(snap({}), 80));
  ev.push(...d.update(snap({ ctrl: true }), 200));
  ev.push(...d.update(snap({}), 260));
  assert.deepEqual(ev.map((e) => e.type), ['double-ctrl']);
});

test('shortcut options with space', () => {
  const d = new ShortcutDetector('ctrl+alt+space');
  assert.deepEqual(d.update(snap({ ctrl: true, alt: true, space: true }), 0).map((e) => e.type), ['pressed']);
});

test('screenshot sizing max 1280', () => {
  assert.deepEqual(S.screenshotSizeForDisplay(2560, 1440), { width: 1280, height: 720 });
  assert.deepEqual(S.screenshotSizeForDisplay(1000, 500), { width: 1000, height: 500 });
});

test('normalized mapping across multi-monitor offsets', () => {
  const cap = { bounds: { x: 1920, y: 0, width: 1920, height: 1080 }, screenshotWidth: 1280, screenshotHeight: 720 };
  assert.deepEqual(S.mapModelPointToGlobal({ x: 500, y: 500 }, cap, 'normalized'), { x: 2880, y: 540 });
  assert.deepEqual(S.mapModelPointToGlobal({ x: 640, y: 360 }, cap, 'pixels'), { x: 2880, y: 540 });
  assert.deepEqual(S.mapModelPointToGlobal({ x: 5000, y: -3 }, cap, 'normalized'), { x: 3840, y: 0 });
});

test('pickTargetCapture and labels', () => {
  const caps = [{ isCursorScreen: false }, { isCursorScreen: true }];
  assert.equal(S.pickTargetCapture(caps, 1), caps[0]);
  assert.equal(S.pickTargetCapture(caps, null), caps[1]);
  assert.equal(S.pickTargetCapture(caps, 9), caps[1]);
  assert.match(S.buildScreenLabel(1, 2, true, 1280, 720), /screen 2 of 2 — cursor is on this screen \(primary focus\)/);
});

test('physicalRectToModelSpace honors dpi', () => {
  const cap = { bounds: { x: 0, y: 0, width: 1000, height: 500 }, screenshotWidth: 1000, screenshotHeight: 500 };
  assert.deepEqual(S.physicalRectToModelSpace({ x: 300, y: 150, width: 150, height: 75 }, cap, 1.5, 'pixels'), { x: 200, y: 100, width: 100, height: 50 });
});

test('flight duration and frame endpoints', () => {
  assert.equal(M.flightDurationSeconds(100), 0.6);
  assert.equal(M.flightDurationSeconds(8000), 1.4);
  const a = { x: 0, y: 0 }, b = { x: 800, y: 0 };
  assert.deepEqual([M.flightFrame(a, b, 0).x, M.flightFrame(a, b, 0).y], [0, 0]);
  const end = M.flightFrame(a, b, 1);
  assert.ok(Math.abs(end.x - 800) < 1e-9 && Math.abs(end.y) < 1e-9);
  assert.ok(Math.abs(M.flightFrame(a, b, 0.5).scale - 1.3) < 1e-9);
  assert.equal(M.arcControlPoint(a, b).y, -80);
});

test('clampNavigationTarget', () => {
  assert.deepEqual(M.clampNavigationTarget({ x: 0, y: 0 }, { x: 0, y: 0, width: 1000, height: 800 }), { x: 20, y: 20 });
  assert.deepEqual(M.clampNavigationTarget({ x: 100, y: 100 }, { x: 0, y: 0, width: 1000, height: 800 }), { x: 108, y: 112 });
});

test('spring converges and audio level math', () => {
  const sp = M.createSpring(0.2, 0.6, { x: 0, y: 0 });
  for (let i = 0; i < 120; i++) M.stepSpring(sp, { x: 100, y: 50 }, 1 / 60);
  assert.ok(Math.abs(sp.x - 100) < 0.5 && Math.abs(sp.y - 50) < 0.5);
  assert.equal(M.boostedAudioLevel(1), 1);
  assert.ok(M.smoothAudioLevel(0, 1) > 0.7);
  const idle = M.waveformBarHeights(0, 0);
  assert.ok(idle.every((h) => h >= 3 && h <= 4.5), 'idle bars stay between 3 and 4.5');
  assert.ok(Math.abs(idle[0] - 3.75) < 1e-9, 'first bar at t=0 is 3 + 0.75');
  const loud = M.waveformBarHeights(1, 0);
  assert.ok(loud[2] > loud[1] && loud[1] > loud[0]);
});
