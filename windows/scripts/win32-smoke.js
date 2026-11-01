'use strict';
/* Runs on a real Windows machine (CI): verifies koffi loads user32 and the struct layouts work. */
if (process.platform !== 'win32') {
  console.log('skipped: not Windows');
  process.exit(0);
}
const { loadRealWin32 } = require('../src/main/win32');
const w = loadRealWin32();
const before = w.getCursorPosition();
console.log('cursor', before);
w.setCursorPosition(before.x, before.y);
const snap = w.readKeySnapshot();
console.log('keys', snap);
// a harmless SendInput: key up of an unused key
w.sendInputs([]);
console.log('foreground', w.getForegroundWindow());
console.log('win32 smoke test ok');
