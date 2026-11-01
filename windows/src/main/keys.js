'use strict';
/*
 * Push-to-talk shortcut detection from polled key snapshots.
 * snapshot: { ctrl, alt, shift, win, space, escape, otherKey }
 */

const SHORTCUT_OPTIONS = {
  'ctrl+alt': {
    id: 'ctrl+alt',
    displayText: 'Control+Alt',
    keyCapsuleLabels: ['Ctrl', 'Alt'],
    test: (s) => s.ctrl && s.alt && !s.shift && !s.win && !s.space,
  },
  'shift+ctrl': {
    id: 'shift+ctrl',
    displayText: 'Shift+Control',
    keyCapsuleLabels: ['Shift', 'Ctrl'],
    test: (s) => s.ctrl && s.shift && !s.alt && !s.win && !s.space,
  },
  'ctrl+win': {
    id: 'ctrl+win',
    displayText: 'Control+Win',
    keyCapsuleLabels: ['Ctrl', 'Win'],
    test: (s) => s.ctrl && s.win && !s.alt && !s.shift && !s.space,
  },
  'ctrl+alt+space': {
    id: 'ctrl+alt+space',
    displayText: 'Control+Alt+Space',
    keyCapsuleLabels: ['Ctrl', 'Alt', 'Space'],
    test: (s) => s.ctrl && s.alt && s.space && !s.shift && !s.win,
  },
  'shift+ctrl+space': {
    id: 'shift+ctrl+space',
    displayText: 'Shift+Control+Space',
    keyCapsuleLabels: ['Shift', 'Ctrl', 'Space'],
    test: (s) => s.ctrl && s.shift && s.space && !s.alt && !s.win,
  },
};

const DOUBLE_TAP_WINDOW_MS = 380;

class ShortcutDetector {
  constructor(optionId) {
    this.setOption(optionId);
    this.active = false;
    this.prevEscape = false;
    this.prevCtrl = false;
    this.ctrlDownAt = 0;
    this.ctrlDirty = false;
    this.lastCtrlTapAt = -Infinity;
  }

  setOption(optionId) {
    this.option = SHORTCUT_OPTIONS[optionId] || SHORTCUT_OPTIONS['ctrl+alt'];
  }

  update(snap, nowMs) {
    const events = [];
    const comboDown = this.option.test(snap) && (this.active || !snap.otherKey);

    if (comboDown && !this.active) {
      this.active = true;
      events.push({ type: 'pressed' });
    } else if (!comboDown && this.active) {
      this.active = false;
      events.push({ type: 'released' });
    }

    if (snap.escape && !this.prevEscape) events.push({ type: 'escape' });
    this.prevEscape = !!snap.escape;

    // double tap of Control alone
    const ctrlAlone = snap.ctrl && !snap.alt && !snap.shift && !snap.win && !snap.otherKey && !snap.space;
    if (snap.ctrl && !this.prevCtrl) {
      this.ctrlDownAt = nowMs;
      this.ctrlDirty = false;
    }
    if (snap.ctrl && !ctrlAlone) this.ctrlDirty = true;
    if (!snap.ctrl && this.prevCtrl) {
      const wasTap = !this.ctrlDirty && nowMs - this.ctrlDownAt < 250 && !this.active;
      if (wasTap) {
        if (nowMs - this.lastCtrlTapAt <= DOUBLE_TAP_WINDOW_MS) {
          events.push({ type: 'double-ctrl' });
          this.lastCtrlTapAt = -Infinity;
        } else {
          this.lastCtrlTapAt = nowMs;
        }
      }
    }
    this.prevCtrl = !!snap.ctrl;
    return events;
  }
}

module.exports = { ShortcutDetector, SHORTCUT_OPTIONS };
