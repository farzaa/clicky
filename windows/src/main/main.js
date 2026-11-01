'use strict';
/*
 * Clicky for Windows: main process entry.
 *
 * Wires every module together: settings, Groq client, capture, speech, audio bridge,
 * input driving, agent, companion state machine, windows (tray panel, overlays, notch,
 * Home, 3D viewer), IPC handlers, shortcut polling, onboarding, routines.
 */
const path = require('path');
const { pathToFileURL } = require('url');
const { app, BrowserWindow, ipcMain, screen, shell, clipboard, desktopCapturer, safeStorage, session, systemPreferences } = require('electron');

const log = require('./log');
const { SettingsStore } = require('./settings');
const { GroqClient } = require('./groq');
const { createCapture } = require('./capture');
const { SpeechQueue, speakWithSapi } = require('./tts');
const { InputController } = require('./input');
const { createSystemTools } = require('./system-tools');
const uia = require('./uia');
const { AgentRunner } = require('./agent');
const { CompanionManager } = require('./companion');
const { RoutineScheduler } = require('./routines');
const { ShortcutDetector } = require('./keys');
const { parseRoutineSchedule } = require('./tags');
const { buildModel3DPrompt } = require('./prompts');
const { WindowManager } = require('./windows');
const motion = require('../shared/motion');

const argv = process.argv.slice(2);
const FLAG_E2E = argv.includes('--e2e');
const FLAG_HIDDEN = argv.includes('--hidden');
const E2E_SCRIPT = (argv.find((a) => a.startsWith('--e2e-script=')) || '').slice('--e2e-script='.length);
const ASSETS = path.join(__dirname, '..', '..', 'assets');

if (process.env.CLICKY_USER_DATA) app.setPath('userData', process.env.CLICKY_USER_DATA);
app.setName('Clicky');
if (process.platform === 'win32') app.setAppUserModelId('com.moonycoder.clicky');

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  boot();
}

function boot() {
  process.on('uncaughtException', (e) => log.error('uncaughtException', e));
  process.on('unhandledRejection', (e) => log.error('unhandledRejection', e));

  app.on('window-all-closed', () => { /* tray app: keep running */ });
  app.on('web-contents-created', (_e, wc) => {
    wc.setWindowOpenHandler(() => ({ action: 'deny' }));
    wc.on('will-navigate', (ev) => ev.preventDefault());
  });

  app.whenReady().then(start).catch((e) => {
    log.error('fatal start error', e);
    app.quit();
  });
}

// A do-nothing Win32 layer for non-Windows development and tests.
function stubWin32() {
  const noop = () => {};
  return {
    stub: true,
    readKeySnapshot: () => ({ ctrl: false, alt: false, shift: false, win: false, space: false, escape: false, otherKey: false }),
    getCursorPosition: () => screen.getCursorScreenPoint(),
    setCursorPosition: noop,
    isMouseButtonDown: () => false,
    sendInputs: noop,
    pressCombo: noop,
    typeText: noop,
    mouseButton: noop,
    wheel: noop,
    getForegroundWindow: () => 0,
    focusWindow: () => false,
  };
}

function loadWin32() {
  if (process.platform !== 'win32' || FLAG_E2E) return stubWin32();
  try {
    return require('./win32').loadRealWin32();
  } catch (e) {
    log.error('Could not load the Win32 layer (koffi). Push-to-talk and PC driving are disabled.', e);
    return stubWin32();
  }
}

function start() {
  const userData = app.getPath('userData');
  log.init(path.join(userData, 'logs'));
  log.info('Clicky starting', { version: app.getVersion(), electron: process.versions.electron, e2e: FLAG_E2E });

  const settings = new SettingsStore(path.join(userData, 'settings.json'), safeStorage);
  if (process.env.CLICKY_E2E_MIC) settings.set({ micGranted: true });
  const baseUrl = () => process.env.CLICKY_GROQ_BASE_URL || settings.get('groqBaseUrl');
  const groq = new GroqClient({ getApiKey: () => settings.getApiKey(), getBaseUrl: baseUrl, log });
  const capture = createCapture({ screen, desktopCapturer });
  const win32 = loadWin32();
  const isWin = process.platform === 'win32';

  const screenApi = {
    dipToScreenPoint: (p) => (isWin && screen.dipToScreenPoint ? screen.dipToScreenPoint(p) : p),
    screenToDipPoint: (p) => (isWin && screen.screenToDipPoint ? screen.screenToDipPoint(p) : p),
  };
  const input = new InputController({ win32, screenApi });
  const tools = createSystemTools({ shell, clipboard, documentsDir: app.getPath('documents') });

  // ------------------------------------------------------------ shared context
  const ctx = {
    settings, groq, capture, win32, input, tools, log, screenApi,
    companion: null, agent: null, wm: null, speech: null, routines: null, detector: null,
    chat: Array.isArray(settings.get('chat')) ? settings.get('chat').slice(-120) : [],
    modelPayload: null,
    onboarding: null,
  };

  const wm = new WindowManager({
    settings, log, assetsDir: ASSETS, e2e: FLAG_E2E,
    getStatus: () => ctx.companion && ctx.companion.snapshot(),
    getJobs: () => (ctx.agent ? ctx.agent.listJobs() : []),
  });
  ctx.wm = wm;

  // ------------------------------------------------------------ chat log (Home window)
  let chatSaveTimer = null;
  ctx.chatAppend = (m) => {
    const msg = { role: m.role, text: String(m.text || '').slice(0, 4000), at: Date.now() };
    if (!msg.text) return;
    ctx.chat.push(msg);
    if (ctx.chat.length > 120) ctx.chat.shift();
    wm.send(wm.home, 'chat-msg', msg);
    clearTimeout(chatSaveTimer);
    chatSaveTimer = setTimeout(() => {
      try {
        settings.data.chat = ctx.chat;
        settings._save();
      } catch (_) { /* ignore */ }
    }, 1500);
  };

  // ------------------------------------------------------------ audio bridge (hidden window)
  const audioState = { ready: false, readyWaiters: [], recordWaiter: null, probing: null, playWaiters: new Map(), playId: 0, micOkSeen: false };
  const audioWin = () => wm.ensureAudio();
  const whenAudioReady = () => (audioState.ready ? Promise.resolve() : new Promise((r) => audioState.readyWaiters.push(r)));
  audioWin();

  const audio = {
    async start() {
      await whenAudioReady();
      wm.send(audioWin(), 'audio:start', {});
    },
    stop() {
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          audioState.recordWaiter = null;
          resolve(null);
        }, 6000);
        audioState.recordWaiter = (rec) => { clearTimeout(timer); resolve(rec); };
        wm.send(audioWin(), 'audio:stop', {});
      });
    },
    cancel() {
      wm.send(audioWin(), 'audio:cancel', {});
      if (audioState.recordWaiter) { audioState.recordWaiter(null); audioState.recordWaiter = null; }
    },
  };

  function playWav(wav, signal) {
    return new Promise((resolve) => {
      const id = ++audioState.playId;
      let finished = false;
      const finish = () => {
        if (finished) return;
        finished = true;
        clearTimeout(guard);
        audioState.playWaiters.delete(id);
        resolve();
      };
      const guard = setTimeout(finish, 90000);
      audioState.playWaiters.set(id, finish);
      if (signal) {
        if (signal.aborted) return finish();
        signal.addEventListener('abort', () => { wm.send(audioWin(), 'audio:stop-playback', {}); finish(); }, { once: true });
      }
      whenAudioReady().then(() => wm.send(audioWin(), 'audio:play', { id, data: wav }));
      return undefined;
    });
  }

  // ------------------------------------------------------------ speech
  const speech = new SpeechQueue({
    synthesize: async (text, signal) => {
      const s = settings.all();
      if (s.ttsProvider !== 'groq' || !settings.hasApiKey()) return null;
      return groq.synthesizeSpeech({ model: s.ttsModel, voice: s.ttsVoice, text, signal });
    },
    playWav,
    speakFallback: (text, signal) => (isWin ? speakWithSapi(text, signal) : Promise.resolve()),
    log,
  });
  ctx.speech = speech;

  // ------------------------------------------------------------ onboarding (music + welcome + video)
  ctx.startOnboarding = (replay) => {
    clearTimeout(ctx.onboarding && ctx.onboarding.fadeTimer);
    const state = { replay, fadeTimer: null };
    ctx.onboarding = state;
    settings.set({ cursorEnabled: true });
    wm.showOverlay({ firstAppearance: true });
    ctx.companion.onboardingVideoActive = true;
    if (settings.get('playOnboardingMusic')) {
      whenAudioReady().then(() => {
        wm.send(audioWin(), 'audio:music', { action: 'start', src: pathToFileURL(path.join(ASSETS, 'ff.mp3')).href });
        state.fadeTimer = setTimeout(() => wm.send(audioWin(), 'audio:music', { action: 'fade' }), 90000);
      });
    }
  };

  function onboardingEvent(type) {
    const comp = ctx.companion;
    switch (type) {
      case 'welcome-done':
        wm.broadcast('overlay:onboarding', { action: 'video-start' }, { others: false });
        break;
      case 'demo':
        comp.performOnboardingDemo();
        break;
      case 'video-ended':
        comp.onboardingVideoActive = false;
        break;
      default:
    }
  }

  // ------------------------------------------------------------ photos for info cards
  const photoCache = new Map();
  ctx.resolvePhoto = async (query) => {
    const q = String(query || '').trim();
    if (!q) return null;
    if (photoCache.has(q)) return photoCache.get(q);
    let url = null;
    try {
      const api = 'https://en.wikipedia.org/w/api.php?action=query&format=json&generator=search&gsrlimit=1&prop=pageimages&piprop=thumbnail&pithumbsize=640&gsrsearch=' + encodeURIComponent(q);
      const res = await fetch(api, { signal: AbortSignal.timeout(4500), headers: { 'User-Agent': 'ClickyWindows/1.0' } });
      const j = await res.json();
      const pages = j && j.query && j.query.pages ? Object.values(j.query.pages) : [];
      const hit = pages.find((p) => p.thumbnail && p.thumbnail.source);
      url = hit ? hit.thumbnail.source : null;
    } catch (_) {
      url = null;
    }
    photoCache.set(q, url);
    return url;
  };

  // ------------------------------------------------------------ 3D models
  function pushModel(payload) {
    ctx.modelPayload = payload;
    const w = wm.model3d;
    if (!w || w.isDestroyed()) return;
    if (w.webContents.isLoading()) w.webContents.once('did-finish-load', () => wm.send(w, 'model3d:show', ctx.modelPayload));
    else wm.send(w, 'model3d:show', payload);
  }

  function parseModelJson(text) {
    const cleaned = String(text || '').replace(/```(?:json)?/gi, '').trim();
    const start = cleaned.indexOf('{');
    const end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) throw new Error('The model did not return a 3D model.');
    const model = JSON.parse(cleaned.slice(start, end + 1));
    if (!model || !Array.isArray(model.parts) || !model.parts.length) throw new Error('The 3D model had no parts.');
    return model;
  }

  ctx.showModel3D = async (topic) => {
    wm.openModel3D();
    pushModel({ state: 'loading', topic });
    try {
      const s = settings.all();
      const res = await groq.chat({
        model: s.agentModel,
        messages: [
          { role: 'system', content: buildModel3DPrompt(topic) },
          { role: 'user', content: 'build the model of: ' + topic },
        ],
        stream: false,
        jsonMode: true,
        reasoningEffort: 'none',
        maxTokens: 5000,
        temperature: 0.4,
      });
      pushModel({ model: parseModelJson(res.text) });
    } catch (e) {
      log.warn('3D model failed', e && e.message);
      pushModel({ state: 'error', message: 'Could not build that model. ' + ((e && e.message) || '') });
    }
  };

  ctx.speakShort = (t) => ctx.companion && ctx.companion.say(t);

  // ------------------------------------------------------------ agent + companion
  const ui = wm.buildUi(ctx);
  ctx.ui = ui;
  const agent = new AgentRunner({ groq, settings, capture, input, tools, uia, screenApi, ui, log, win32 });
  ctx.agent = agent;
  const companion = new CompanionManager({ settings, groq, capture, audio, speech, agent, ui, log, screenApi });
  ctx.companion = companion;

  // ------------------------------------------------------------ permissions
  function micGranted() {
    if (settings.get('micGranted')) return true;
    try {
      if (systemPreferences.getMediaAccessStatus) return systemPreferences.getMediaAccessStatus('microphone') === 'granted' && isWin;
    } catch (_) { /* ignore */ }
    return false;
  }

  function refreshPermissions() {
    companion.refreshPermissions({ microphone: micGranted(), screen: true, input: true, groqKey: settings.hasApiKey() });
  }

  async function requestMic() {
    if (micGranted()) return refreshPermissions();
    try {
      if (isWin && systemPreferences.getMediaAccessStatus('microphone') === 'denied') {
        shell.openExternal('ms-settings:privacy-microphone');
        ui.notify('Turn on microphone access for desktop apps, then press Grant again.', 'warn');
        return undefined;
      }
    } catch (_) { /* ignore */ }
    // Probe: open the mic for a moment. Success means Windows let us in.
    await whenAudioReady();
    audioState.micOkSeen = false;
    const ok = await new Promise((resolve) => {
      audioState.probing = resolve;
      wm.send(audioWin(), 'audio:start', {});
      setTimeout(() => resolve(audioState.micOkSeen), 4000);
    });
    audioState.probing = null;
    wm.send(audioWin(), 'audio:cancel', {});
    if (ok) settings.set({ micGranted: true });
    else {
      ui.notify('Clicky could not open the microphone. Check Windows Settings > Privacy > Microphone.', 'error');
      if (isWin) shell.openExternal('ms-settings:privacy-microphone');
    }
    return refreshPermissions();
  }

  session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
    const url = (wc && wc.getURL && wc.getURL()) || '';
    cb(url.startsWith('file://') && (permission === 'media' || permission === 'audioCapture'));
  });
  session.defaultSession.setPermissionCheckHandler((wc, permission) => permission === 'media' || permission === 'audioCapture');

  // ------------------------------------------------------------ settings side effects
  const detector = new ShortcutDetector(settings.get('pushToTalkShortcut'));
  ctx.detector = detector;

  function applyLoginItem() {
    if (!app.isPackaged || !isWin) return;
    try {
      app.setLoginItemSettings({ openAtLogin: !!settings.get('launchAtLogin'), args: ['--hidden'] });
    } catch (e) {
      log.warn('login item failed', e && e.message);
    }
  }

  let lastProtect = settings.get('hideFromCapture');
  settings.onChange((pub) => {
    wm.broadcast('settings', pub, { overlays: false });
    wm.broadcast('settings', wm._overlaySettings(), { others: false });
    detector.setOption(pub.pushToTalkShortcut);
    applyLoginItem();
    if (pub.hideFromCapture !== lastProtect) {
      lastProtect = pub.hideFromCapture;
      wm.reapplyProtection();
    }
    companion._publishStatus();
  });

  // ------------------------------------------------------------ IPC
  const handle = (channel, fn) => ipcMain.handle(channel, async (event, payload) => {
    try {
      return await fn(payload || {}, event);
    } catch (e) {
      log.error('ipc ' + channel + ' failed', e);
      return { ok: false, error: (e && e.message) || String(e) };
    }
  });

  handle('settings:get', () => settings.getPublic());
  handle('settings:set', (patch) => settings.set(patch));
  handle('settings:setApiKey', async ({ key }) => {
    const trimmed = String(key || '').trim();
    if (!trimmed) {
      settings.setApiKey('');
      refreshPermissions();
      return { ok: true };
    }
    const probe = new GroqClient({ getApiKey: () => trimmed, getBaseUrl: baseUrl, log });
    try {
      await probe.validateKey();
    } catch (e) {
      return { ok: false, error: e.kind === 'bad_key' ? 'Groq did not accept that key.' : e.message };
    }
    settings.setApiKey(trimmed);
    refreshPermissions();
    return { ok: true };
  });
  handle('settings:validateKey', async () => {
    try {
      const r = await groq.validateKey();
      return { ok: true, models: r.models.length };
    } catch (e) {
      return { ok: false, error: e.message };
    }
  });
  handle('settings:resetAll', () => {
    agent.stopAll('reset');
    settings.reset();
    ctx.chat = [];
    refreshPermissions();
    return { ok: true };
  });
  handle('status:get', () => companion.snapshot());
  handle('app:info', () => ({ version: app.getVersion(), electron: process.versions.electron, platform: process.platform }));

  handle('panel:action', (p) => {
    switch (p.type) {
      case 'close': wm.hidePanel(); break;
      case 'quit': quit(); break;
      case 'replay': companion.replayOnboarding(); break;
      case 'start': companion.triggerOnboarding(); break;
      case 'home': wm.hidePanel(); wm.openHome(); break;
      case 'cursor': companion.setCursorEnabled(!!p.enabled); break;
      case 'email': companion.submitEmail(p.email); break;
      case 'open-url':
        if (/^https:\/\//i.test(String(p.url || ''))) shell.openExternal(p.url);
        break;
      default:
    }
    return { ok: true };
  });
  handle('permissions:request', async ({ name }) => {
    if (name === 'microphone') await requestMic();
    return { ok: true };
  });

  handle('chat:send', ({ text }) => {
    const t = String(text || '').trim();
    if (!t) return { ok: false };
    ctx.chatAppend({ role: 'user', text: t });
    companion.sendText(t);
    return { ok: true };
  });
  handle('chat:history', () => ctx.chat);
  handle('chat:clear', () => { ctx.chat = []; return { ok: true }; });

  handle('job:respond', ({ id, approved, answer }) => { agent.respond(id, { approved: !!approved, answer: String(answer || '') }); return { ok: true }; });
  handle('job:stop', ({ id }) => ({ ok: agent.stop(id) }));
  handle('job:run', ({ task, desktop }) => {
    const t = String(task || '').trim();
    if (!t) return { ok: false };
    companion.runJob(t, { mode: desktop ? 'drive' : 'background', desktop: !!desktop }).then((r) => ui.notify(r.summary, r.status === 'failed' ? 'error' : 'info'));
    return { ok: true };
  });
  handle('job:list', () => agent.listJobs());

  handle('routine:delete', ({ id }) => settings.set({ routines: settings.get('routines').filter((r) => r.id !== id) }) && { ok: true });
  handle('routine:toggle', ({ id }) => settings.set({ routines: settings.get('routines').map((r) => (r.id === id ? Object.assign({}, r, { enabled: r.enabled === false }) : r)) }) && { ok: true });
  handle('routine:add', ({ task, time, days }) => {
    const scheduleText = `${(days && days.length ? days : ['*']).join(',')}@${time}`;
    const schedule = parseRoutineSchedule(scheduleText);
    if (!schedule || !String(task || '').trim()) return { ok: false, error: 'Invalid routine.' };
    const routine = { id: 'r' + Date.now().toString(36), schedule, scheduleText, task: String(task).trim(), enabled: true };
    settings.set({ routines: settings.get('routines').concat([routine]) });
    return { ok: true };
  });
  handle('memory:delete', ({ index }) => {
    const mem = settings.get('memory').slice();
    mem.splice(Number(index), 1);
    settings.set({ memory: mem });
    return { ok: true };
  });

  handle('overlay:ready', (_p, event) => { wm.overlayReady(event.sender); return { ok: true }; });
  handle('overlay:event', (p) => {
    if (p.type === 'pointing-done') {
      companion.pointingActive = false;
      wm.broadcast('overlay:pointing-state', { active: false }, { others: false });
    } else onboardingEvent(p.type);
    return { ok: true };
  });

  handle('model3d:ready', () => {
    if (ctx.modelPayload) wm.send(wm.model3d, 'model3d:show', ctx.modelPayload);
    return { ok: true };
  });
  handle('model3d:ask', ({ title, part, info }) => {
    const q = `about the 3d model of ${title}: what is the ${part}? ${info || ''}`.trim();
    ctx.chatAppend({ role: 'user', text: q });
    companion.sendText(q);
    return { ok: true };
  });

  handle('notch:resize', (p) => {
    if (p.panelHeight) wm.resizePanel(p.panelHeight);
    else wm.resizeNotch(p.height || 40, p.visible !== false, p.focusable);
    return { ok: true };
  });

  let level = 0;
  handle('audio:levels', ({ rms }) => {
    if (audioState.probing && rms > 0) audioState.micOkSeen = true;
    if (audioState.probing && rms === 0) audioState.micOkSeen = audioState.micOkSeen || false;
    level = motion.smoothAudioLevel(Number(rms) || 0, level);
    wm.broadcast('audio-level', level, { others: false });
    if (audioState.probing && audioState.micOkSeen) audioState.probing(true);
    return { ok: true };
  });
  handle('audio:ready', () => {
    audioState.ready = true;
    audioState.readyWaiters.splice(0).forEach((r) => r());
    return { ok: true };
  });
  handle('audio:recorded', ({ wav, durationMs }) => {
    const waiter = audioState.recordWaiter;
    audioState.recordWaiter = null;
    if (waiter) waiter(wav ? { wav: Buffer.from(wav), durationMs } : null);
    return { ok: true };
  });
  handle('audio:ended', ({ id }) => {
    const w = audioState.playWaiters.get(id);
    if (w) w();
    return { ok: true };
  });
  handle('audio:error', ({ message, name }) => {
    log.warn('audio host error', name, message);
    if (audioState.probing) { audioState.probing(false); return { ok: true }; }
    companion.recording = false;
    companion.setPermission('microphone', false);
    if (name === 'NotAllowedError' || name === 'SecurityError') settings.set({ micGranted: false });
    companion._fail(new Error('I could not open the microphone. Check Windows microphone privacy settings.'));
    return { ok: true };
  });

  handle('voice:test', () => { companion.say('hey, this is how i sound. hold the shortcut and talk to me anytime.'); return { ok: true }; });
  handle('window:control', ({ action }, event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return { ok: false };
    if (action === 'minimize') win.minimize();
    else if (action === 'maximize') (win.isMaximized() ? win.unmaximize() : win.maximize());
    else if (action === 'close') win.close();
    return { ok: true };
  });

  // ------------------------------------------------------------ tray
  try {
    wm.createTray(() => quit());
  } catch (e) {
    log.warn('tray failed', e && e.message);
  }

  // ------------------------------------------------------------ loops
  const timers = [];
  // push-to-talk: poll the keyboard (no hooks, nothing is recorded or stored)
  timers.push(setInterval(() => {
    if (input.isInjecting() || win32.stub) return;
    try {
      const events = detector.update(win32.readKeySnapshot(), Date.now());
      for (const e of events) companion.handleShortcutEvent(e);
    } catch (e) {
      log.warn('key poll failed', e && e.message);
    }
  }, 16));
  // overlay cursor follower
  timers.push(setInterval(() => {
    if (wm.hasOverlay()) wm.sendCursor(screen.getCursorScreenPoint());
  }, 16));
  // permissions
  timers.push(setInterval(refreshPermissions, 1500));

  const routines = new RoutineScheduler({
    getRoutines: () => settings.get('routines'),
    onDue: (r) => {
      ui.notify('Running routine: ' + r.task, 'info');
      companion.runJob(r.task, { name: 'Routine: ' + r.task.slice(0, 36), mode: 'background', desktop: false })
        .then((res) => ui.notify(res.summary, res.status === 'failed' ? 'error' : 'info'));
    },
  });
  routines.start();
  ctx.routines = routines;

  // ------------------------------------------------------------ startup
  companion.start();
  refreshPermissions();
  applyLoginItem();

  app.on('second-instance', () => wm.showPanel());

  const needsSetup = !settings.get('hasCompletedOnboarding') || !companion.allPermissionsGranted();
  if (!FLAG_E2E && (!FLAG_HIDDEN || !settings.get('hasCompletedOnboarding')) && needsSetup) {
    setTimeout(() => wm.showPanel(), 600);
  }

  function quit() {
    try {
      companion.stop();
      agent.stopAll('quit');
      routines.stop();
      timers.forEach(clearInterval);
      settings.data.chat = ctx.chat;
      settings._save();
      wm.hideOverlay();
    } catch (_) { /* ignore */ }
    app.exit(0);
  }
  ctx.quit = quit;

  app.on('before-quit', () => timers.forEach(clearInterval));

  if (FLAG_E2E && E2E_SCRIPT) {
    // The e2e scenario runs inside the main process and drives the whole app.
    Promise.resolve()
      .then(() => require(path.resolve(E2E_SCRIPT))(Object.assign(ctx, { app, screen, BrowserWindow })))
      .catch((e) => {
        console.error('E2E FAILED', e);
        app.exit(1);
      });
  }
}
