'use strict';
/* Runs inside Electron's main process (see run-e2e.js). Drives the app and screenshots every window. */
const fs = require('fs');
const path = require('path');

module.exports = async function scenario(ctx) {
  const out = process.env.CLICKY_E2E_OUT;
  const { wm, companion, settings, app } = ctx;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const results = [];
  const check = (name, ok, extra) => {
    results.push({ name, ok: !!ok, extra });
    console.log((ok ? 'PASS ' : 'FAIL ') + name + (extra ? ' - ' + extra : ''));
  };
  async function shot(win, name) {
    if (!win || win.isDestroyed()) return check('screenshot ' + name, false, 'window missing');
    const img = await win.webContents.capturePage();
    fs.writeFileSync(path.join(out, name + '.png'), img.toPNG());
    const size = img.getSize();
    return check('screenshot ' + name, size.width > 50, size.width + 'x' + size.height);
  }
  const js = (win, code) => win.webContents.executeJavaScript(code);

  await sleep(1200);

  // ---- tray panel
  settings.set({ hasSubmittedEmail: true });
  companion.refreshPermissions({ microphone: true, screen: true, input: true, groqKey: settings.hasApiKey() });
  wm.showPanel();
  await sleep(1500);
  await shot(wm.panel, '01-panel-onboarding-ready');
  check('panel shows Start button', await js(wm.panel, "!!document.querySelector('[data-act=start]')"));

  // ---- panel after onboarding
  settings.set({ hasCompletedOnboarding: true });
  await sleep(700);
  await shot(wm.panel, '02-panel-ready');
  check('panel shows model picker', await js(wm.panel, "!!document.querySelector('[data-act=mode-fast]')"));

  // ---- overlay + response with pointing, drawing, card
  wm.hidePanel();
  settings.set({ cursorEnabled: true });
  wm.showOverlay({ firstAppearance: false });
  await sleep(2000);
  check('overlay window created', wm.overlays.size >= 1, 'count ' + wm.overlays.size);

  ctx.settings.set({ ttsProvider: 'groq' });
  const p = companion.sendText('how do i save this file');
  await sleep(1800);
  const overlay = Array.from(wm.overlays.values())[0].win;
  await shot(overlay, '03-overlay-processing');
  await p;
  await sleep(2600);
  await shot(overlay, '04-overlay-pointing');
  await sleep(2500);
  await shot(overlay, '05-overlay-after');
  check('conversation history stored', companion.history.length >= 1, 'len ' + companion.history.length);

  // ---- home window
  wm.openHome();
  await sleep(2000);
  await shot(wm.home, '06-home-chat');
  for (const sec of ['agent', 'routines', 'memory', 'visuals', 'settings']) {
    wm.send(wm.home, 'home:section', sec);
    await sleep(500);
    await shot(wm.home, '07-home-' + sec);
  }
  check('home chat has messages', ctx.chat.length >= 1, 'chat ' + ctx.chat.length);

  // ---- notch with approval prompt
  const jobs = [{ id: 'j1', name: 'Open Notepad and write a list', task: 'x', mode: 'drive', status: 'waiting', note: 'Waiting for you', log: [], startedAt: Date.now() },
    { id: 'j2', name: 'Summarize today\'s tech news', task: 'y', mode: 'background', status: 'running', note: 'searching the web', log: [], startedAt: Date.now() }];
  wm.notchPrompts = [{ jobId: 'j1', kind: 'approve-desktop', text: 'Let Clicky take over your mouse and keyboard to: open Notepad and write a list? Press Esc or move the mouse any time to stop.', name: jobs[0].name }];
  wm.ensureNotch();
  await sleep(1200);
  wm.send(wm.notch, 'notch:state', { jobs, prompts: wm.notchPrompts });
  await sleep(1200);
  await shot(wm.notch, '08-notch');
  wm.send(wm.notch, 'notch:state', { jobs: [], prompts: [] });
  await sleep(300);

  // ---- drive banner on overlay
  wm.broadcast('drive-state', { active: true, name: 'Open Notepad' }, { others: false });
  await sleep(900);
  await shot(overlay, '09-overlay-driving');
  wm.broadcast('drive-state', { active: false }, { others: false });

  // ---- 3D
  await ctx.showModel3D('a plant cell');
  let built = false;
  for (let i = 0; i < 30 && !built; i++) {
    await sleep(500);
    built = await js(wm.model3d, "document.getElementById('loading').classList.contains('hide')");
  }
  await sleep(2500);
  await shot(wm.model3d, '10-model3d');
  const title = await js(wm.model3d, "document.getElementById('title').textContent");
  check('3D model built and loading overlay hidden', built && /Plant cell/i.test(title), title);

  // ---- onboarding overlay (welcome bubble)
  wm.hideOverlay();
  settings.set({ playOnboardingMusic: false });
  ctx.startOnboarding(false);
  await sleep(4500);
  const ov2 = Array.from(wm.overlays.values())[0].win;
  await shot(ov2, '11-overlay-welcome');

  const failed = results.filter((r) => !r.ok);
  fs.writeFileSync(path.join(out, 'results.json'), JSON.stringify(results, null, 2));
  console.log(`E2E done: ${results.length - failed.length}/${results.length} passed`);
  app.exit(failed.length ? 2 : 0);
};
