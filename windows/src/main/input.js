'use strict';
/*
 * Human-like mouse/keyboard driving with safety aborts.
 *
 * screenApi = { dipToScreenPoint({x,y}) -> physical {x,y} }   (Electron's screen module)
 */
const { parseKeySequence } = require('./win32');

class InputAbortedError extends Error {
  constructor(reason) {
    super('Input driving stopped: ' + (reason || 'aborted'));
    this.name = 'InputAbortedError';
    this.reason = reason || 'aborted';
  }
}

const MOUSE_GRAB_THRESHOLD_PX = 14;
const TYPE_BATCH = 6;
const INJECT_SUPPRESS_MS = 120;

class InputController {
  constructor({ win32, screenApi, sleepImpl, now } = {}) {
    this.win32 = win32;
    this.screenApi = screenApi || { dipToScreenPoint: (p) => p };
    this.sleep = sleepImpl || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.now = now || (() => Date.now());
    this.driving = false;
    this.abortReason = null;
    this.lastPlaced = null;
    this.injectUntil = 0;
  }

  beginDriving() {
    this.driving = true;
    this.abortReason = null;
    this.lastPlaced = this.win32.getCursorPosition();
  }

  endDriving() {
    this.driving = false;
  }

  abort(reason) {
    if (this.driving && !this.abortReason) this.abortReason = reason || 'aborted';
  }

  get isAborted() {
    return !!this.abortReason;
  }

  throwIfAborted() {
    if (this.abortReason) throw new InputAbortedError(this.abortReason);
    if (this.driving && this.lastPlaced) {
      const cur = this.win32.getCursorPosition();
      if (Math.hypot(cur.x - this.lastPlaced.x, cur.y - this.lastPlaced.y) > MOUSE_GRAB_THRESHOLD_PX) {
        this.abortReason = 'mouse moved by user';
        throw new InputAbortedError(this.abortReason);
      }
    }
  }

  isInjecting() {
    return this.now() < this.injectUntil;
  }

  markInjecting() {
    this.injectUntil = this.now() + INJECT_SUPPRESS_MS;
  }

  _place(p) {
    this.win32.setCursorPosition(p.x, p.y);
    this.lastPlaced = { x: Math.round(p.x), y: Math.round(p.y) };
  }

  // target is in global DIP coordinates
  async moveTo(target) {
    this.throwIfAborted();
    const end = this.screenApi.dipToScreenPoint(target);
    const start = this.win32.getCursorPosition();
    const dist = Math.hypot(end.x - start.x, end.y - start.y);
    const duration = Math.min(650, Math.max(160, dist * 0.45));
    const steps = Math.max(4, Math.round(duration / 14));
    const lift = Math.min(dist * 0.12, 60);
    const cx = (start.x + end.x) / 2;
    const cy = (start.y + end.y) / 2 - lift;
    for (let i = 1; i <= steps; i++) {
      this.throwIfAborted();
      const t0 = i / steps;
      const t = t0 * t0 * (3 - 2 * t0);
      const omt = 1 - t;
      this._place({
        x: omt * omt * start.x + 2 * omt * t * cx + t * t * end.x,
        y: omt * omt * start.y + 2 * omt * t * cy + t * t * end.y,
      });
      await this.sleep(duration / steps);
    }
    this._place(end);
  }

  async click(target, { button = 'left', count = 1 } = {}) {
    await this.moveTo(target);
    this.markInjecting();
    for (let i = 0; i < count; i++) {
      this.throwIfAborted();
      this.win32.mouseButton(button, true);
      await this.sleep(35);
      this.win32.mouseButton(button, false);
      if (i < count - 1) await this.sleep(70);
    }
    await this.sleep(60);
  }

  async drag(from, to) {
    await this.moveTo(from);
    this.markInjecting();
    this.win32.mouseButton('left', true);
    await this.sleep(80);
    try {
      await this.moveTo(to);
    } finally {
      this.win32.mouseButton('left', false);
    }
    await this.sleep(60);
  }

  async scroll(notches, horizontal = false) {
    this.throwIfAborted();
    const steps = Math.max(1, Math.abs(Math.round(notches)));
    const dir = notches < 0 ? -1 : 1;
    for (let i = 0; i < steps; i++) {
      this.throwIfAborted();
      this.win32.wheel(dir, horizontal);
      await this.sleep(45);
    }
  }

  async typeText(text) {
    const chars = Array.from(String(text));
    for (let i = 0; i < chars.length; i += TYPE_BATCH) {
      this.throwIfAborted();
      this.markInjecting();
      this.win32.typeText(chars.slice(i, i + TYPE_BATCH).join(''));
      await this.sleep(28);
    }
  }

  async pressKeys(spec) {
    const combos = parseKeySequence(spec);
    for (const combo of combos) {
      this.throwIfAborted();
      this.markInjecting();
      this.win32.pressCombo(combo.map(nameOfVk).join('+'));
      await this.sleep(90);
    }
  }
}

const { VK } = require('./win32');
const VK_NAME = {};
for (const [name, vk] of Object.entries(VK)) if (VK_NAME[vk] === undefined) VK_NAME[vk] = name;
// prefer canonical names for modifiers
Object.assign(VK_NAME, { 0x10: 'shift', 0x11: 'ctrl', 0x12: 'alt', 0x5b: 'win', 0x0d: 'enter', 0x1b: 'escape', 0x2e: 'delete' });
function nameOfVk(vk) {
  return VK_NAME[vk];
}

module.exports = { InputController, InputAbortedError, MOUSE_GRAB_THRESHOLD_PX };
