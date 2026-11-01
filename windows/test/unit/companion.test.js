'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { CompanionManager } = require('../../src/main/companion');
const { SettingsStore } = require('../../src/main/settings');
const { SpeechQueue } = require('../../src/main/tts');

function harness({ chatText, chunks }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clicky-c-'));
  const settings = new SettingsStore(path.join(dir, 's.json'), null, {});
  settings.setApiKey('k');
  settings.set({ hasCompletedOnboarding: true });
  const events = [];
  const played = [];
  const speech = new SpeechQueue({
    synthesize: async (t) => Buffer.from(t),
    playWav: async (b) => { played.push(b.toString()); },
  });
  const ui = {
    hasOverlay: () => true,
    setVoiceState: (s) => events.push(['state', s]),
    status() {}, notify: (m, k) => events.push(['notify', k, m]), caption() {},
    showOverlay() {}, hideOverlay() {}, fadeOutOverlay() {}, dismissPanel() {}, openPanel() {},
    clearPointing() {}, dismissOnboardingPrompt() {},
    pointAt: (t, label, b, text) => events.push(['point', t, label]),
    drawShapes: (s) => events.push(['draw', s.length]),
    showCards: (c) => events.push(['cards', c.length]),
    showModel3D: (t) => events.push(['model', t]),
  };
  const capture = {
    captureAllScreens: async () => [{
      jpeg: Buffer.from('x'), label: 'screen 1', isCursorScreen: true,
      bounds: { x: 0, y: 0, width: 2000, height: 1000 }, screenshotWidth: 1280, screenshotHeight: 640,
    }],
  };
  const requests = [];
  const groq = {
    transcribe: async () => 'how do i save',
    chat: async (o) => {
      requests.push(o);
      for (const c of chunks) o.onTextDelta(c);
      return { text: chatText, toolCalls: [] };
    },
  };
  const audio = { start: async () => {}, stop: async () => ({ wav: Buffer.from('w'), durationMs: 900 }), cancel() {} };
  const agent = { listJobs: () => [], run: async (j) => { events.push(['agent', j.task, j.mode, j.desktop]); return { status: 'done', summary: 'ok' }; }, stopAll() {} };
  const c = new CompanionManager({ settings, groq, capture, audio, speech, agent, ui, screenApi: {} });
  c.refreshPermissions({ microphone: true, screen: true, input: true });
  c.start();
  return { c, events, played, requests, settings };
}

test('full push-to-talk turn: speaks sentences, points, draws, history', async () => {
  const text = 'press control s to save your file, it works in every app. look at the file menu too. [POINT:500,250:file menu] [DRAW:circle:500,250,40:here]';
  const h = harness({ chatText: text, chunks: [text.slice(0, 40), text.slice(40, 90), text.slice(90)] });
  h.c.handleShortcutEvent({ type: 'pressed' });
  assert.equal(h.c.voiceState, 'listening');
  h.c.handleShortcutEvent({ type: 'released' });
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(h.c.voiceState, 'idle');
  const states = h.events.filter((e) => e[0] === 'state').map((e) => e[1]);
  assert.deepEqual(states, ['listening', 'processing', 'responding', 'idle']);
  assert.ok(h.played.join(' ').includes('press control s'));
  assert.ok(!h.played.join(' ').includes('POINT'));
  const point = h.events.find((e) => e[0] === 'point');
  assert.deepEqual(point[1], { x: 1000, y: 250 });
  assert.equal(point[2], 'file menu');
  assert.ok(h.events.find((e) => e[0] === 'draw'));
  assert.equal(h.c.history.length, 1);
  // second turn includes history
  h.c.handleShortcutEvent({ type: 'pressed' });
  h.c.handleShortcutEvent({ type: 'released' });
  await new Promise((r) => setTimeout(r, 200));
  const msgs = h.requests[1].messages;
  assert.equal(msgs[1].content, 'how do i save');
  assert.equal(h.requests[0].reasoningEffort, 'none');
});

test('DRIVE tag starts the agent after speech', async () => {
  const text = 'okay, i will open youtube for you now. [DRIVE:open youtube and search lofi]';
  const h = harness({ chatText: text, chunks: [text] });
  await h.c.sendText('open youtube');
  await new Promise((r) => setTimeout(r, 100));
  const a = h.events.find((e) => e[0] === 'agent');
  assert.ok(a, 'agent should run');
  assert.equal(a[2], 'drive');
  assert.equal(a[3], true);
});

test('history is capped at 10 exchanges', async () => {
  const h = harness({ chatText: 'fine. [POINT:none]', chunks: ['fine. [POINT:none]'] });
  for (let i = 0; i < 13; i++) await h.c.sendText('q' + i);
  assert.equal(h.c.history.length, 10);
  assert.equal(h.c.history[0].user, 'q3');
});

test('missing permissions block push to talk', () => {
  const h = harness({ chatText: 'x', chunks: [] });
  h.c.refreshPermissions({ microphone: false });
  h.c.handleShortcutEvent({ type: 'pressed' });
  assert.equal(h.c.voiceState, 'idle');
  assert.ok(h.events.find((e) => e[0] === 'notify'));
});

test('memory and routines tags persist', async () => {
  const text = 'got it. [REMEMBER:name is sam] [ROUTINE:daily@09:00|open my inbox]';
  const h = harness({ chatText: text, chunks: [text] });
  await h.c.sendText('hi');
  assert.deepEqual(h.settings.get('memory'), ['name is sam']);
  assert.equal(h.settings.get('routines')[0].task, 'open my inbox');
});

test('status snapshot is structured-clone safe (IPC)', () => {
  const { CompanionManager } = require('../../src/main/companion');
  const settings = { get: (k) => ({ pushToTalkShortcut: 'ctrl+alt', cursorEnabled: true }[k]), all: () => ({}), hasApiKey: () => true, onChange() {} };
  const c = new CompanionManager({ settings, ui: { hasOverlay: () => false, setVoiceState() {}, status() {} }, speech: {}, audio: {}, agent: { listJobs: () => [] } });
  assert.doesNotThrow(() => structuredClone(c.snapshot()));
});
