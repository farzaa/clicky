'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const w = require('../../src/main/win32');
const { InputController, InputAbortedError } = require('../../src/main/input');

function fakeLib(state = {}) {
  const lib = {
    keys: new Set(),
    sent: [],
    pos: { x: 0, y: 0 },
    getAsyncKeyState: (vk) => (lib.keys.has(vk) ? 0x8000 : 0),
    sendInput: (i) => { lib.sent.push(...i); return i.length; },
    setCursorPos: (x, y) => { lib.pos = { x, y }; },
    getCursorPos: () => lib.pos,
    getForegroundWindow: () => 1,
    setForegroundWindow: () => true,
    getWindowText: () => '',
  };
  return Object.assign(lib, state);
}

test('parseKeyCombo maps names', () => {
  assert.deepEqual(w.parseKeyCombo('ctrl+shift+t'), [0x11, 0x10, 0x54]);
  assert.deepEqual(w.parseKeyCombo('F5'), [0x74]);
  assert.throws(() => w.parseKeyCombo('ctrl+banana'));
});

test('parseKeySequence splits combos', () => {
  const seq = w.parseKeySequence('ctrl+l, enter');
  assert.equal(seq.length, 2);
  assert.deepEqual(seq[1], [0x0d]);
});

test('buildComboInputs presses and releases in order', () => {
  const inputs = w.buildComboInputs([0x11, 0x43]);
  assert.deepEqual(inputs.map((i) => [i.vk, !!(i.flags & 2)]), [[0x11, false], [0x43, false], [0x43, true], [0x11, true]]);
});

test('buildTextInputs uses unicode and handles newline', () => {
  const inputs = w.buildTextInputs('hi\n');
  assert.equal(inputs.length, 6);
  assert.equal(inputs[0].scan, 'h'.charCodeAt(0));
  assert.equal(inputs[4].vk, 0x0d);
});

test('snapshot: ctrl+left alt counts, AltGr does not', () => {
  const lib = fakeLib();
  const win = w.createWin32(lib);
  lib.keys = new Set([w.VK.lctrl, w.VK.lalt]);
  let s = win.readKeySnapshot();
  assert.ok(s.ctrl && s.alt && !s.otherKey);
  lib.keys = new Set([w.VK.lctrl, w.VK.ralt]);
  s = win.readKeySnapshot();
  assert.ok(!s.ctrl && !s.alt);
  lib.keys = new Set([w.VK.lctrl, w.VK.lalt, 0x41]);
  assert.ok(win.readKeySnapshot().otherKey);
});

test('wheel and mouse button inputs', () => {
  const lib = fakeLib();
  const win = w.createWin32(lib);
  win.wheel(-2);
  win.mouseButton('right', true);
  assert.equal(lib.sent[0].flags, w.MOUSEEVENTF.WHEEL);
  assert.equal(lib.sent[0].data, -240);
  assert.equal(lib.sent[1].flags, w.MOUSEEVENTF.RIGHTDOWN);
});

function controller(lib, screenApi) {
  return new InputController({ win32: w.createWin32(lib), screenApi, sleepImpl: async () => {} });
}

test('moveTo converts DIP to physical and lands exactly', async () => {
  const lib = fakeLib();
  const c = controller(lib, { dipToScreenPoint: (p) => ({ x: p.x * 1.5, y: p.y * 1.5 }) });
  c.beginDriving();
  await c.moveTo({ x: 100, y: 200 });
  assert.deepEqual(lib.pos, { x: 150, y: 300 });
});

test('click sends down/up and marks injecting', async () => {
  const lib = fakeLib();
  const c = controller(lib);
  c.beginDriving();
  await c.click({ x: 10, y: 10 });
  assert.equal(lib.sent.filter((i) => i.type === 'mouse').length, 2);
  assert.ok(c.isInjecting());
});

test('user grabbing the mouse aborts', async () => {
  const lib = fakeLib();
  const c = controller(lib);
  c.beginDriving();
  lib.pos = { x: 500, y: 500 };
  await assert.rejects(c.moveTo({ x: 1, y: 1 }), InputAbortedError);
});

test('abort during typing stops further batches', async () => {
  const lib = fakeLib();
  const c = new InputController({
    win32: w.createWin32(lib),
    sleepImpl: async () => { c.abort('escape'); },
  });
  c.beginDriving();
  await assert.rejects(c.typeText('a'.repeat(30)), InputAbortedError);
  assert.ok(lib.sent.length <= 12);
});

test('typing is batched by 6 chars', async () => {
  const lib = fakeLib();
  const c = controller(lib);
  c.beginDriving();
  await c.typeText('abcdefghijkl');
  assert.equal(lib.sent.length, 24);
});

test('pressKeys sends sequences', async () => {
  const lib = fakeLib();
  const c = controller(lib);
  c.beginDriving();
  await c.pressKeys('ctrl+l, enter');
  assert.equal(lib.sent.length, 4 + 2);
});
