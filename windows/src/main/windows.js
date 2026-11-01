'use strict';
/*
 * WindowManager: owns every BrowserWindow (tray panel, per-display overlays, notch HUD,
 * Home, 3D viewer, hidden audio host) and exposes the `ui` object that CompanionManager
 * and AgentRunner talk to.
 */
const path = require('path');
const os = require('os');
const { BrowserWindow, screen, Tray, Menu, nativeImage } = require('electron');

const RENDERER = path.join(__dirname, '..', 'renderer');
const PRELOAD = path.join(__dirname, '..', 'preload', 'preload.js');
const PANEL_WIDTH = 348;

function isWin11() {
  if (process.platform !== 'win32') return false;
  const build = Number(os.release().split('.')[2] || 0);
  return build >= 22000;
}

function webPrefs(extra) {
  return Object.assign(
    { preload: PRELOAD, contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false, spellcheck: false },
    extra || {}
  );
}

class WindowManager {
  constructor({ settings, log, assetsDir, e2e = false, getStatus, getJobs }) {
    this.settings = settings;
    this.log = log;
    this.assetsDir = assetsDir;
    this.e2e = e2e;
    this.getStatus = getStatus || (() => ({}));
    this.getJobs = getJobs || (() => []);
    this.panel = null;
    this.home = null;
    this.notch = null;
    this.model3d = null;
    this.audio = null;
    this.tray = null;
    this.overlays = new Map(); // displayId -> { win, ready }
    this.overlayInit = null;
    this.voiceState = 'idle';
    this.panelHeight = 520;
    this.lastCursor = { x: 0, y: 0 };
    this.notchPrompts = [];
    this.lastPanelShownAt = 0;
    this.handlers = {};
  }

  // -------------------------------------------------------------- generic
  send(win, channel, payload) {
    if (win && !win.isDestroyed() && !win.webContents.isDestroyed()) win.webContents.send(channel, payload);
  }

  broadcast(channel, payload, { overlays = true, others = true } = {}) {
    if (overlays) for (const o of this.overlays.values()) this.send(o.win, channel, payload);
    if (others) for (const w of [this.panel, this.home, this.notch, this.model3d]) this.send(w, channel, payload);
  }

  protect(win) {
    try {
      win.setContentProtection(!!this.settings.get('hideFromCapture') && !this.e2e);
    } catch (_) {
      /* not supported */
    }
  }

  reapplyProtection() {
    const all = [this.panel, this.home, this.notch, this.model3d, ...Array.from(this.overlays.values()).map((o) => o.win)];
    all.filter(Boolean).forEach((w) => !w.isDestroyed() && this.protect(w));
  }

  // -------------------------------------------------------------- tray
  createTray(onQuit) {
    const iconPath = path.join(this.assetsDir, 'tray.png');
    const img = nativeImage.createFromPath(iconPath);
    this.tray = new Tray(img.isEmpty() ? nativeImage.createEmpty() : img);
    this.tray.setToolTip('Clicky');
    this.tray.on('click', () => this.togglePanel());
    this.tray.on('right-click', () => {
      const menu = Menu.buildFromTemplate([
        { label: 'Open Clicky panel', click: () => this.showPanel() },
        { label: 'Open Clicky Home', click: () => this.openHome() },
        { type: 'separator' },
        { label: 'Quit Clicky', click: onQuit },
      ]);
      this.tray.popUpContextMenu(menu);
    });
  }

  // -------------------------------------------------------------- panel
  ensurePanel() {
    if (this.panel && !this.panel.isDestroyed()) return this.panel;
    this.panel = new BrowserWindow({
      width: PANEL_WIDTH, height: this.panelHeight, show: false, frame: false, transparent: true, resizable: false,
      movable: false, skipTaskbar: true, alwaysOnTop: true, hasShadow: false, fullscreenable: false,
      webPreferences: webPrefs(),
    });
    this.panel.setAlwaysOnTop(true, 'pop-up-menu');
    this.protect(this.panel);
    this.panel.loadFile(path.join(RENDERER, 'panel', 'panel.html'));
    this.panel.on('blur', () => {
      if (this.e2e) return;
      setTimeout(() => {
        if (this.panel && !this.panel.isDestroyed() && !this.panel.isFocused() && Date.now() - this.lastPanelShownAt > 400) this.panel.hide();
      }, 120);
    });
    this.panel.on('closed', () => { this.panel = null; });
    return this.panel;
  }

  positionPanel() {
    const win = this.ensurePanel();
    const tb = this.tray ? this.tray.getBounds() : { x: 0, y: 0, width: 0, height: 0 };
    const hasTray = tb.width > 0;
    const point = hasTray ? { x: tb.x + tb.width / 2, y: tb.y + tb.height / 2 } : screen.getCursorScreenPoint();
    const display = screen.getDisplayNearestPoint(point);
    const wa = display.workArea;
    const height = Math.min(this.panelHeight, wa.height - 16);
    let x = hasTray ? Math.round(tb.x + tb.width / 2 - PANEL_WIDTH / 2) : wa.x + wa.width - PANEL_WIDTH - 8;
    let y;
    if (hasTray) y = tb.y > wa.y + wa.height / 2 ? tb.y - height - 6 : tb.y + tb.height + 6;
    else y = wa.y + wa.height - height - 8;
    x = Math.max(wa.x + 8, Math.min(x, wa.x + wa.width - PANEL_WIDTH - 8));
    y = Math.max(wa.y + 8, Math.min(y, wa.y + wa.height - height - 8));
    win.setBounds({ x, y, width: PANEL_WIDTH, height });
  }

  showPanel() {
    const win = this.ensurePanel();
    this.lastPanelShownAt = Date.now();
    this.positionPanel();
    win.show();
    win.focus();
  }

  hidePanel() {
    if (this.panel && !this.panel.isDestroyed()) this.panel.hide();
  }

  togglePanel() {
    if (this.panel && !this.panel.isDestroyed() && this.panel.isVisible()) this.hidePanel();
    else this.showPanel();
  }

  resizePanel(h) {
    this.panelHeight = Math.max(120, Math.round(h));
    if (this.panel && !this.panel.isDestroyed() && this.panel.isVisible()) this.positionPanel();
  }

  // -------------------------------------------------------------- overlays
  hasOverlay() {
    return this.overlays.size > 0;
  }

  showOverlay({ firstAppearance = false } = {}) {
    this.hideOverlay(true);
    const s = this.settings.all();
    this.overlayInit = { firstAppearance };
    for (const d of screen.getAllDisplays()) this._createOverlay(d, firstAppearance, s);
    if (!this._displayListener) {
      this._displayListener = () => {
        if (!this.hasOverlay()) return;
        this.showOverlay({ firstAppearance: false });
      };
      screen.on('display-added', this._displayListener);
      screen.on('display-removed', this._displayListener);
    }
  }

  _overlaySettings() {
    const sc = require('./keys').SHORTCUT_OPTIONS[this.settings.get('pushToTalkShortcut')] || require('./keys').SHORTCUT_OPTIONS['ctrl+alt'];
    return {
      captions: this.settings.get('captions'),
      onboardingPrompt: `press ${sc.keyCapsuleLabels.join(' + ').toLowerCase().replace('ctrl', 'control')} and introduce yourself`,
    };
  }

  _createOverlay(display, firstAppearance) {
    const b = display.bounds;
    const win = new BrowserWindow({
      x: b.x, y: b.y, width: b.width, height: b.height, show: false, frame: false, transparent: true, resizable: false,
      movable: false, focusable: false, skipTaskbar: true, alwaysOnTop: true, hasShadow: false, fullscreenable: false,
      thickFrame: false, webPreferences: webPrefs(),
    });
    win.setAlwaysOnTop(true, 'screen-saver');
    win.setIgnoreMouseEvents(true);
    this.protect(win);
    const entry = { win, ready: false, display };
    this.overlays.set(display.id, entry);
    win.setBounds(b);
    win.loadFile(path.join(RENDERER, 'overlay', 'overlay.html'));
    entry.initialize = () => {
      entry.ready = true;
      this.send(win, 'overlay:init', {
        bounds: b,
        settings: this._overlaySettings(),
        firstAppearance,
        cursor: screen.getCursorScreenPoint(),
        voiceState: this.voiceState,
      });
      win.showInactive();
    };
    win.on('closed', () => { if (this.overlays.get(display.id) === entry) this.overlays.delete(display.id); });
  }

  overlayReady(webContents) {
    for (const o of this.overlays.values()) if (o.win.webContents === webContents && !o.ready) o.initialize();
  }

  hideOverlay() {
    for (const o of this.overlays.values()) {
      try { if (!o.win.isDestroyed()) o.win.destroy(); } catch (_) { /* ignore */ }
    }
    this.overlays.clear();
  }

  fadeOutOverlay() {
    this.broadcast('overlay:fade-out', {}, { others: false });
    const wins = Array.from(this.overlays.values());
    setTimeout(() => {
      // only hide if nothing re-created them in the meantime
      if (wins.every((o) => this.overlays.get(o.display.id) === o)) this.hideOverlay();
    }, 450);
  }

  sendCursor(point) {
    if (point.x === this.lastCursor.x && point.y === this.lastCursor.y) return;
    this.lastCursor = point;
    for (const o of this.overlays.values()) this.send(o.win, 'cursor', point);
  }

  // -------------------------------------------------------------- audio host
  ensureAudio() {
    if (this.audio && !this.audio.isDestroyed()) return this.audio;
    this.audio = new BrowserWindow({ show: false, width: 200, height: 100, webPreferences: webPrefs({ autoplayPolicy: 'no-user-gesture-required' }) });
    this.audio.loadFile(path.join(RENDERER, 'audio', 'audio.html'));
    this.audio.on('closed', () => { this.audio = null; });
    return this.audio;
  }

  // -------------------------------------------------------------- notch HUD
  ensureNotch() {
    if (this.notch && !this.notch.isDestroyed()) return this.notch;
    const d = screen.getPrimaryDisplay();
    const w = 440;
    this.notch = new BrowserWindow({
      x: Math.round(d.bounds.x + d.bounds.width / 2 - w / 2), y: d.bounds.y + 10, width: w, height: 90, show: false, frame: false,
      transparent: true, resizable: false, movable: false, focusable: false, skipTaskbar: true, alwaysOnTop: true,
      hasShadow: false, thickFrame: false, webPreferences: webPrefs(),
    });
    this.notch.setAlwaysOnTop(true, 'screen-saver');
    this.protect(this.notch);
    this.notch.loadFile(path.join(RENDERER, 'notch', 'notch.html'));
    this.notch.on('closed', () => { this.notch = null; });
    return this.notch;
  }

  resizeNotch(height, visible, focusable) {
    const n = this.ensureNotch();
    if (focusable !== undefined) { try { n.setFocusable(!!focusable); } catch (_) { /* ignore */ } }
    const d = screen.getPrimaryDisplay();
    const w = 440;
    n.setBounds({ x: Math.round(d.bounds.x + d.bounds.width / 2 - w / 2), y: d.bounds.y + 10, width: w, height: Math.max(40, Math.round(height)) });
    if (visible) { if (!n.isVisible()) n.showInactive(); } else if (n.isVisible()) n.hide();
  }

  // -------------------------------------------------------------- home
  openHome(section) {
    if (this.home && !this.home.isDestroyed()) {
      if (this.home.isMinimized()) this.home.restore();
      this.home.show();
      this.home.focus();
      if (section) this.send(this.home, 'home:section', section);
      return;
    }
    const win11 = isWin11();
    this.home = new BrowserWindow({
      width: 1040, height: 700, minWidth: 820, minHeight: 540, show: false, frame: false, title: 'Clicky',
      backgroundColor: win11 ? '#00000000' : '#101211', backgroundMaterial: win11 ? 'acrylic' : undefined,
      roundedCorners: true, webPreferences: webPrefs(),
    });
    this.protect(this.home);
    this.home.loadFile(path.join(RENDERER, 'home', 'home.html'));
    this.home.once('ready-to-show', () => this.home.show());
    this.home.on('closed', () => { this.home = null; });
  }

  // -------------------------------------------------------------- 3D
  openModel3D() {
    if (this.model3d && !this.model3d.isDestroyed()) {
      this.model3d.show();
      return this.model3d;
    }
    const d = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const w = 560, h = 520;
    this.model3d = new BrowserWindow({
      x: Math.round(d.workArea.x + d.workArea.width - w - 24), y: Math.round(d.workArea.y + 60), width: w, height: h, frame: false,
      transparent: true, resizable: true, skipTaskbar: false, alwaysOnTop: true, hasShadow: false, show: false, webPreferences: webPrefs(),
    });
    this.protect(this.model3d);
    this.model3d.loadFile(path.join(RENDERER, 'model3d', 'model3d.html'));
    this.model3d.once('ready-to-show', () => this.model3d.show());
    this.model3d.on('closed', () => { this.model3d = null; });
    return this.model3d;
  }

  // -------------------------------------------------------------- the `ui` bridge
  buildUi(ctx) {
    const self = this;
    return {
      hasOverlay: () => self.hasOverlay(),
      setVoiceState(state) {
        self.voiceState = state;
        self.broadcast('voice-state', state);
      },
      status(snapshot) {
        self.send(self.panel, 'status', snapshot);
        self.send(self.home, 'status', snapshot);
      },
      notify(message, kind = 'info') {
        self.broadcast('notify', { message, kind }, { overlays: false, others: false });
        self.send(self.panel, 'notify', { message, kind });
        self.send(self.home, 'notify', { message, kind });
      },
      caption(text) {
        self.broadcast('overlay:caption', { text }, { others: false });
      },
      showOverlay: (opts) => self.showOverlay(opts),
      hideOverlay: () => self.hideOverlay(),
      fadeOutOverlay: () => self.fadeOutOverlay(),
      dismissPanel: () => self.hidePanel(),
      openPanel: () => self.showPanel(),
      openHome: (s) => self.openHome(s),
      startOnboardingOverlay: ({ replay }) => ctx.startOnboarding(replay),
      clearPointing() {
        self.broadcast('overlay:clear', {}, { others: false });
        ctx.companion.pointingActive = false;
      },
      dismissOnboardingPrompt: () => self.broadcast('overlay:prompt-dismiss', {}, { others: false }),
      pointAt(target, label, bounds, text) {
        ctx.companion.pointingActive = true;
        self.broadcast('overlay:point', { target, label, text }, { others: false });
        // safety: never leave the flag stuck if the overlay vanished
        clearTimeout(self._pointTimer);
        self._pointTimer = setTimeout(() => { ctx.companion.pointingActive = false; }, 20000);
      },
      drawShapes(shapes) {
        self.broadcast('overlay:draw', shapes, { others: false });
      },
      async showCards(cards) {
        const resolved = await Promise.all(cards.map(async (c) => Object.assign({}, c, { photoUrl: c.photoQuery ? await ctx.resolvePhoto(c.photoQuery) : null })));
        self.broadcast('overlay:cards', resolved, { others: false });
      },
      showModel3D: (topic) => ctx.showModel3D(topic),
      userSaid: (text) => ctx.chatAppend({ role: 'user', text }),
      assistantSaid: (text) => ctx.chatAppend({ role: 'assistant', text }),
      // agent callbacks
      jobUpdate(job) {
        self.broadcast('job-update', job, { overlays: false });
        self.send(self.panel, 'status', ctx.companion.snapshot());
        const live = ctx.agent.listJobs().filter((j) => j.status === 'running' || j.status === 'waiting');
        self._syncNotch(live);
      },
      jobPrompt(p) {
        self.notchPrompts = self.notchPrompts.filter((x) => x.jobId !== p.jobId).concat([p]);
        self._syncNotch(ctx.agent.listJobs().filter((j) => j.status === 'running' || j.status === 'waiting'));
        self.send(self.home, 'job-prompt', p);
        ctx.speakShort(p.kind === 'question' ? p.text : 'i need your okay before i do this. check the top of your screen.');
      },
      driveState(active, name) {
        self.broadcast('drive-state', { active, name }, { others: false });
      },
      say: (text) => ctx.companion.say(text),
    };
  }

  _syncNotch(liveJobs) {
    this.notchPrompts = this.notchPrompts.filter((p) => liveJobs.some((j) => j.id === p.jobId && j.status === 'waiting'));
    const exists = this.notch && !this.notch.isDestroyed();
    if (!liveJobs.length && !exists) return;
    const n = this.ensureNotch();
    const payload = { jobs: liveJobs, prompts: this.notchPrompts };
    if (n.webContents.isLoading()) n.webContents.once('did-finish-load', () => this.send(n, 'notch:state', payload));
    else this.send(n, 'notch:state', payload);
    if (!liveJobs.length) this.resizeNotch(40, false);
  }
}

module.exports = { WindowManager, PANEL_WIDTH, isWin11 };
