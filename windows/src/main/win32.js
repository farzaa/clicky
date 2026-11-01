'use strict';
/*
 * Thin Win32 layer (user32 through koffi). Everything is written against an
 * injectable `lib` object so it can be unit tested with a fake off Windows.
 *
 * lib = {
 *   getAsyncKeyState(vk) -> int,
 *   sendInput(inputs[]) -> count,
 *   setCursorPos(x, y), getCursorPos() -> {x,y},
 *   getForegroundWindow() -> number, setForegroundWindow(hwnd) -> bool,
 *   getWindowText(hwnd) -> string
 * }
 */

const VK = {
  backspace: 0x08, tab: 0x09, enter: 0x0d, return: 0x0d, shift: 0x10, ctrl: 0x11, control: 0x11, alt: 0x12,
  menu: 0x12, pause: 0x13, capslock: 0x14, escape: 0x1b, esc: 0x1b, space: 0x20, pageup: 0x21, pagedown: 0x22,
  end: 0x23, home: 0x24, left: 0x25, up: 0x26, right: 0x27, down: 0x28, printscreen: 0x2c, insert: 0x2d,
  delete: 0x2e, del: 0x2e, win: 0x5b, windows: 0x5b, super: 0x5b, meta: 0x5b, cmd: 0x5b,
  lshift: 0xa0, rshift: 0xa1, lctrl: 0xa2, rctrl: 0xa3, lalt: 0xa4, ralt: 0xa5, lwin: 0x5b, rwin: 0x5c,
  numlock: 0x90, scrolllock: 0x91,
  ';': 0xba, '=': 0xbb, ',': 0xbc, '-': 0xbd, '.': 0xbe, '/': 0xbf, '`': 0xc0, '[': 0xdb, '\\': 0xdc, ']': 0xdd, "'": 0xde,
  plus: 0xbb, minus: 0xbd,
};
for (let i = 0; i < 26; i++) VK[String.fromCharCode(97 + i)] = 0x41 + i;
for (let i = 0; i < 10; i++) VK[String(i)] = 0x30 + i;
for (let i = 1; i <= 24; i++) VK['f' + i] = 0x6f + i;

const EXTENDED_KEYS = new Set([0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2d, 0x2e, 0x5b, 0x5c, 0xa3, 0xa5]);
const MODIFIER_VKS = new Set([0x10, 0x11, 0x12, 0x5b, 0x5c, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5]);

const KEYEVENTF = { EXTENDEDKEY: 0x1, KEYUP: 0x2, UNICODE: 0x4, SCANCODE: 0x8 };
const MOUSEEVENTF = {
  MOVE: 0x1, LEFTDOWN: 0x2, LEFTUP: 0x4, RIGHTDOWN: 0x8, RIGHTUP: 0x10, MIDDLEDOWN: 0x20, MIDDLEUP: 0x40,
  WHEEL: 0x800, HWHEEL: 0x1000,
};

const NO_KEYS = { ctrl: false, alt: false, shift: false, win: false, space: false, escape: false, otherKey: false };

// "ctrl+shift+t" -> [vk, vk, vk]; throws on unknown key names
function parseKeyCombo(combo) {
  const parts = String(combo || '')
    .toLowerCase()
    .split('+')
    .map((p) => p.trim())
    .filter(Boolean);
  if (!parts.length) throw new Error('empty key combo');
  return parts.map((p) => {
    if (VK[p] === undefined) throw new Error('unknown key: ' + p);
    return VK[p];
  });
}

// "ctrl+l, then enter" / "ctrl+l enter" -> [[vk..], [vk..]]
function parseKeySequence(text) {
  return String(text || '')
    .split(/\s*(?:,|\bthen\b|\s)\s*/i)
    .filter(Boolean)
    .map(parseKeyCombo);
}

function keyInput(vk, up) {
  let flags = 0;
  if (up) flags |= KEYEVENTF.KEYUP;
  if (EXTENDED_KEYS.has(vk)) flags |= KEYEVENTF.EXTENDEDKEY;
  return { type: 'key', vk, scan: 0, flags };
}
function unicodeInput(codeUnit, up) {
  return { type: 'key', vk: 0, scan: codeUnit, flags: KEYEVENTF.UNICODE | (up ? KEYEVENTF.KEYUP : 0) };
}
function mouseInput(flags, data = 0, dx = 0, dy = 0) {
  return { type: 'mouse', dx, dy, data, flags };
}

// Hold modifiers, tap the last key, release in reverse.
function buildComboInputs(vks) {
  const out = [];
  const mods = vks.slice(0, -1);
  const key = vks[vks.length - 1];
  if (!mods.length && MODIFIER_VKS.has(key)) {
    out.push(keyInput(key, false), keyInput(key, true));
    return out;
  }
  mods.forEach((m) => out.push(keyInput(m, false)));
  out.push(keyInput(key, false), keyInput(key, true));
  mods
    .slice()
    .reverse()
    .forEach((m) => out.push(keyInput(m, true)));
  return out;
}

function buildTextInputs(text) {
  const out = [];
  for (const ch of String(text)) {
    if (ch === '\r') continue;
    if (ch === '\n') {
      out.push(keyInput(VK.enter, false), keyInput(VK.enter, true));
      continue;
    }
    if (ch === '\t') {
      out.push(keyInput(VK.tab, false), keyInput(VK.tab, true));
      continue;
    }
    for (let i = 0; i < ch.length; i++) {
      const cu = ch.charCodeAt(i);
      out.push(unicodeInput(cu, false), unicodeInput(cu, true));
    }
  }
  return out;
}

function createWin32(lib) {
  const down = (vk) => (lib.getAsyncKeyState(vk) & 0x8000) !== 0;
  return {
    lib,
    // AltGr is reported as LCtrl + RAlt: only the LEFT alt counts as "alt".
    readKeySnapshot() {
      const lctrl = down(VK.lctrl);
      const rctrl = down(VK.rctrl);
      const lalt = down(VK.lalt);
      const ralt = down(VK.ralt);
      const altGr = ralt && lctrl;
      const snap = {
        ctrl: (lctrl && !altGr) || rctrl,
        alt: lalt,
        shift: down(VK.lshift) || down(VK.rshift),
        win: down(VK.lwin) || down(VK.rwin),
        space: down(VK.space),
        escape: down(VK.escape),
        otherKey: false,
      };
      for (let vk = 0x30; vk <= 0x5a; vk++) {
        if (down(vk)) {
          snap.otherKey = true;
          break;
        }
      }
      return snap;
    },
    isMouseButtonDown() {
      return down(0x01) || down(0x02);
    },
    setCursorPosition(x, y) {
      lib.setCursorPos(Math.round(x), Math.round(y));
    },
    getCursorPosition() {
      return lib.getCursorPos();
    },
    sendInputs(inputs) {
      if (inputs.length) lib.sendInput(inputs);
    },
    pressCombo(combo) {
      this.sendInputs(buildComboInputs(parseKeyCombo(combo)));
    },
    typeText(text) {
      this.sendInputs(buildTextInputs(text));
    },
    mouseButton(button, isDown) {
      const map = {
        left: [MOUSEEVENTF.LEFTDOWN, MOUSEEVENTF.LEFTUP],
        right: [MOUSEEVENTF.RIGHTDOWN, MOUSEEVENTF.RIGHTUP],
        middle: [MOUSEEVENTF.MIDDLEDOWN, MOUSEEVENTF.MIDDLEUP],
      };
      const pair = map[button] || map.left;
      this.sendInputs([mouseInput(isDown ? pair[0] : pair[1])]);
    },
    // positive notches scroll up (away from the user)
    wheel(notches, horizontal) {
      this.sendInputs([mouseInput(horizontal ? MOUSEEVENTF.HWHEEL : MOUSEEVENTF.WHEEL, Math.round(notches * 120))]);
    },
    getForegroundWindow() {
      return lib.getForegroundWindow();
    },
    focusWindow(hwnd) {
      // Windows only lets the foreground process steal focus; a tap on Alt unlocks it.
      this.sendInputs([keyInput(VK.alt, false), keyInput(VK.alt, true)]);
      return lib.setForegroundWindow(hwnd);
    },
  };
}

// ---- real binding via koffi (Windows only; no-op elsewhere) ----
function loadRealLib() {
  if (process.platform !== 'win32') {
    return {
      getAsyncKeyState: () => 0,
      sendInput: () => 0,
      setCursorPos: () => {},
      getCursorPos: () => ({ x: 0, y: 0 }),
      getForegroundWindow: () => 0,
      setForegroundWindow: () => false,
      getWindowText: () => '',
    };
  }
  const koffi = require('koffi');
  const user32 = koffi.load('user32.dll');
  const POINT = koffi.struct('POINT', { x: 'int32', y: 'int32' });
  const KEYBDINPUT = koffi.struct('KEYBDINPUT', {
    wVk: 'uint16', wScan: 'uint16', dwFlags: 'uint32', time: 'uint32', dwExtraInfo: 'uintptr',
  });
  const MOUSEINPUT = koffi.struct('MOUSEINPUT', {
    dx: 'int32', dy: 'int32', mouseData: 'uint32', dwFlags: 'uint32', time: 'uint32', dwExtraInfo: 'uintptr',
  });
  const INPUT_UNION = koffi.union('INPUT_UNION', { mi: MOUSEINPUT, ki: KEYBDINPUT });
  const INPUT = koffi.struct('INPUT', { type: 'uint32', u: INPUT_UNION });
  const GetAsyncKeyState = user32.func('int16 __stdcall GetAsyncKeyState(int vKey)');
  const SendInput = user32.func('uint32 __stdcall SendInput(uint32 cInputs, INPUT *pInputs, int cbSize)');
  const SetCursorPos = user32.func('int __stdcall SetCursorPos(int X, int Y)');
  const GetCursorPos = user32.func('int __stdcall GetCursorPos(_Out_ POINT *lpPoint)');
  const GetForegroundWindow = user32.func('void * __stdcall GetForegroundWindow()');
  const SetForegroundWindow = user32.func('int __stdcall SetForegroundWindow(void *hWnd)');
  const GetWindowTextW = user32.func('int __stdcall GetWindowTextW(void *hWnd, _Out_ uint16_t *lpString, int nMaxCount)');
  const inputSize = koffi.sizeof(INPUT);
  return {
    getAsyncKeyState: (vk) => GetAsyncKeyState(vk),
    sendInput(inputs) {
      const arr = inputs.map((i) =>
        i.type === 'key'
          ? { type: 1, u: { ki: { wVk: i.vk, wScan: i.scan, dwFlags: i.flags, time: 0, dwExtraInfo: 0 } } }
          : { type: 0, u: { mi: { dx: i.dx, dy: i.dy, mouseData: i.data >>> 0, dwFlags: i.flags, time: 0, dwExtraInfo: 0 } } }
      );
      return SendInput(arr.length, arr, inputSize);
    },
    setCursorPos: (x, y) => SetCursorPos(x, y),
    getCursorPos() {
      const p = {};
      GetCursorPos(p);
      return { x: p.x, y: p.y };
    },
    getForegroundWindow: () => {
      const h = GetForegroundWindow();
      return h ? Number(koffi.address(h)) : 0;
    },
    setForegroundWindow: (hwnd) => !!SetForegroundWindow(koffi.as(BigInt(hwnd), 'void *')),
    getWindowText(hwnd) {
      const buf = new Uint16Array(512);
      const n = GetWindowTextW(koffi.as(BigInt(hwnd), 'void *'), buf, 512);
      return Buffer.from(buf.buffer, 0, n * 2).toString('utf16le');
    },
  };
}

function loadRealWin32() {
  return createWin32(loadRealLib());
}

module.exports = {
  VK,
  KEYEVENTF,
  MOUSEEVENTF,
  NO_KEYS,
  parseKeyCombo,
  parseKeySequence,
  buildComboInputs,
  buildTextInputs,
  keyInput,
  unicodeInput,
  mouseInput,
  createWin32,
  loadRealLib,
  loadRealWin32,
};
