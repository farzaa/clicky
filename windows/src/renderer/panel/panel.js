'use strict';
/* Tray panel: port of CompanionPanelView.swift (+ Groq key / agent extras). */
(function () {
  const app = document.getElementById('app');
  const api = window.clicky;
  let status = null;
  let settings = null;
  let keyDraft = '';
  let keyState = ''; // '', 'checking', 'ok', 'bad:<msg>'
  let emailDraft = '';
  let toast = null;

  const ICON = {
    mic: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
    eye: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    key: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M16 7l3 3"/></svg>',
    hand: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M8 13V5a2 2 0 0 1 4 0v6M12 11V3a2 2 0 0 1 4 0v8M16 11V6a2 2 0 0 1 4 0v8a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-3l-3-5a2 2 0 0 1 3-2l2 2"/></svg>',
    power: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0"/></svg>',
    play: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M10 8.5l5 3.5-5 3.5z"/></svg>',
    chat: '<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H9l-5 4V5a1 1 0 0 1 1-1z"/></svg>',
    home: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 11l9-8 9 8M5 10v10h14V10"/></svg>',
  };

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function statusDot() {
    if (!status) return '';
    if (!status.overlayVisible) return '';
    if (status.voiceState === 'idle') return 'green';
    return 'blue';
  }

  function permRow({ icon, name, sub, granted, action, label }) {
    return `<div class="row"><div class="lbl"><span class="ic ${granted ? '' : 'warn'}">${icon}</span><div><div class="name">${name}</div>${sub ? `<div class="sub">${sub}</div>` : ''}</div></div>${
      granted
        ? '<div class="granted"><i></i>Granted</div>'
        : `<button class="grant" data-act="${action}">${label || 'Grant'}</button>`
    }</div>`;
  }

  function copySection() {
    const onboarded = settings.hasCompletedOnboarding;
    const all = status.allPermissionsGranted;
    const sc = status.shortcut;
    if (onboarded && all) {
      return `<div class="copy-line">Hold ${sc.keyCapsuleLabels.map((k) => `<span class="kbd">${k}</span>`).join('+')} to talk.</div>`;
    }
    if (all && !settings.hasSubmittedEmail) {
      return `<div class="copy-line">Drop your email to get started.</div><div class="copy-body" style="margin-top:4px">If I keep building this, I'll keep you in the loop.</div>`;
    }
    if (all) return `<div class="copy-line">You're all set. Hit Start to meet Clicky.</div>`;
    if (onboarded) {
      return `<div class="copy-title">Permissions needed</div><div class="copy-body">Some permissions were revoked. Grant everything below to keep using Clicky.</div>`;
    }
    return `<div class="copy-title">Hi, I'm Farza. This is Clicky.</div>
      <div class="copy-body">A side project I made for fun to help me learn stuff as I use my computer. This is the Windows version, powered by Groq.</div>
      <div class="copy-warn">Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.</div>`;
  }

  function keySection() {
    const has = settings.hasApiKey;
    if (has && !keyDraft && keyState !== 'bad') {
      return `<div class="row"><div class="lbl"><span class="ic">${ICON.key}</span><div><div class="name">Groq API key</div><div class="sub">${settings.apiKeyFromEnv ? 'From GROQ_API_KEY' : 'Stored encrypted on this PC'}</div></div></div>
        <button class="btn btn-text" data-act="change-key">Change</button></div>`;
    }
    return `<div style="padding:6px 0">
      <div class="name" style="margin-bottom:6px;display:flex;gap:8px;align-items:center"><span class="ic warn">${ICON.key}</span>Groq API key</div>
      <div class="keybox"><input id="key" class="field" type="password" placeholder="gsk_..." value="${esc(keyDraft)}" spellcheck="false" autocomplete="off">
      <button class="btn btn-primary" style="padding:6px 14px;animation:none" data-act="save-key">${keyState === 'checking' ? '...' : 'Save'}</button></div>
      <div class="sub" style="margin-top:6px">Get a free key at <button class="mini-link" data-act="open-groq">console.groq.com/keys</button></div>
      ${keyState.startsWith('bad:') ? `<div class="err">${esc(keyState.slice(4))}</div>` : ''}
    </div>`;
  }

  function permsSection() {
    const p = status.permissions;
    return `<div class="sec"><div class="perm-title">PERMISSIONS</div>
      ${keySection()}
      ${permRow({ icon: ICON.hand, name: 'Input Control', sub: 'Windows needs no grant. Only used when you ask me to do things', granted: true })}
      ${permRow({ icon: ICON.eye, name: 'Screen Recording', sub: 'Only takes a screenshot when you use the hotkey', granted: p.screen })}
      ${permRow({ icon: ICON.mic, name: 'Microphone', sub: p.microphone ? '' : 'Click Grant, then allow in the Windows prompt', granted: p.microphone, action: 'grant-mic' })}
    </div>`;
  }

  function modelPicker() {
    const fast = settings.modelMode !== 'deep';
    return `<div class="sec"><div class="row" style="padding:4px 0"><div class="name">Model</div>
      <div class="segmented"><button data-act="mode-fast" class="${fast ? 'sel' : ''}">Fast</button><button data-act="mode-deep" class="${fast ? '' : 'sel'}">Deep</button></div></div>
      <div class="row" style="padding:4px 0"><div class="name">Show Clicky</div><div class="switch ${settings.cursorEnabled ? 'on' : ''}" data-act="toggle-cursor"></div></div>
      <div class="row" style="padding:4px 0"><div class="name">Voice</div><div class="segmented"><button data-act="tts-groq" class="${settings.ttsProvider === 'groq' ? 'sel' : ''}">Groq</button><button data-act="tts-windows" class="${settings.ttsProvider === 'windows' ? 'sel' : ''}">Windows</button></div></div>
    </div>`;
  }

  function startArea() {
    if (!settings.hasSubmittedEmail) {
      return `<div class="sec"><div style="display:grid;gap:8px"><input id="email" class="field" type="email" placeholder="Enter your email" value="${esc(emailDraft)}">
        <button class="btn btn-primary" data-act="submit-email" ${emailDraft.trim() ? '' : 'disabled'}>Submit</button></div></div>`;
    }
    return `<div class="sec"><button class="btn btn-primary full" data-act="start">Start</button></div>`;
  }

  function jobsSection() {
    const jobs = (status.jobs || []).filter((j) => j.status === 'running' || j.status === 'waiting');
    if (!jobs.length) return '';
    return `<div class="sec"><div class="jobs">${jobs.map((j) => `<div class="job"><div><b>${esc(j.name)}</b><div class="muted">${esc(j.note || '')}</div></div><button class="btn btn-destructive" style="padding:4px 10px" data-act="stop-job" data-id="${j.id}">Stop</button></div>`).join('')}</div></div>`;
  }

  function render() {
    if (!status || !settings) return;
    const onboarded = settings.hasCompletedOnboarding;
    const all = status.allPermissionsGranted;
    const dot = statusDot();
    const html = [];
    html.push(`<div class="hdr"><div class="l"><div class="dot ${dot}"></div>Clicky</div><div class="r"><span class="status">${status.statusText}</span><button class="xbtn" data-act="close">&#x2715;</button></div></div><div class="divider"></div>`);
    html.push(`<div class="sec" style="padding-top:16px">${copySection()}</div>`);
    if (onboarded && all) html.push(`<div class="spacer12"></div>${modelPicker()}`);
    if (!all) html.push(`<div class="spacer16"></div>${permsSection()}`);
    if (!onboarded && all) html.push(`<div class="spacer16"></div>${startArea()}`);
    if (onboarded && all) {
      html.push(`<div class="spacer12"></div>${jobsSection()}`);
      html.push(`<div class="spacer16"></div><div class="sec"><button class="btn-secondary btn full" data-act="open-home" style="display:flex;gap:8px;align-items:center;justify-content:center">${ICON.home} Open Clicky Home</button></div>`);
      html.push(`<div class="spacer12"></div><div class="sec"><button class="dm" data-act="dm"><span style="display:contents">${ICON.chat}</span><div><b>Got feedback? DM me</b><span>Bugs, ideas, anything &mdash; I read every message.</span></div></button></div>`);
    }
    if (status.lastError) html.push(`<div class="sec"><div class="err">${esc(status.lastError)}</div></div>`);
    html.push(`<div class="spacer12"></div><div class="divider"></div><div class="foot"><button class="btn btn-text" data-act="quit">${ICON.power} Quit Clicky</button>${onboarded ? `<button class="btn btn-text" data-act="replay">${ICON.play} Watch Onboarding Again</button>` : ''}</div>`);
    const focused = document.activeElement && document.activeElement.id;
    const sel = focused && document.activeElement.selectionStart;
    app.innerHTML = html.join('');
    if (focused) {
      const el = document.getElementById(focused);
      if (el) { el.focus(); try { el.setSelectionRange(sel, sel); } catch (_) {} }
    }
    api.invoke('notch:resize', { panelHeight: app.offsetHeight + 34 });
  }

  const actions = {
    close: () => api.invoke('panel:action', { type: 'close' }),
    quit: () => api.invoke('panel:action', { type: 'quit' }),
    replay: () => api.invoke('panel:action', { type: 'replay' }),
    start: () => api.invoke('panel:action', { type: 'start' }),
    dm: () => api.invoke('panel:action', { type: 'open-url', url: 'https://x.com/farzatv' }),
    'open-groq': () => api.invoke('panel:action', { type: 'open-url', url: 'https://console.groq.com/keys' }),
    'open-home': () => api.invoke('panel:action', { type: 'home' }),
    'grant-mic': () => api.invoke('permissions:request', { name: 'microphone' }),
    'mode-fast': () => api.invoke('settings:set', { modelMode: 'fast' }),
    'mode-deep': () => api.invoke('settings:set', { modelMode: 'deep' }),
    'tts-groq': () => api.invoke('settings:set', { ttsProvider: 'groq' }),
    'tts-windows': () => api.invoke('settings:set', { ttsProvider: 'windows' }),
    'toggle-cursor': () => api.invoke('panel:action', { type: 'cursor', enabled: !settings.cursorEnabled }),
    'change-key': () => { keyDraft = ' '; keyDraft = ''; keyState = 'edit'; settings.hasApiKey = false; render(); const k = document.getElementById('key'); if (k) k.focus(); },
    'submit-email': () => { if (emailDraft.trim()) api.invoke('panel:action', { type: 'email', email: emailDraft.trim() }); },
    'stop-job': (el) => api.invoke('job:stop', { id: el.dataset.id }),
    'save-key': async () => {
      const key = (document.getElementById('key') || {}).value || '';
      if (!key.trim()) return;
      keyState = 'checking';
      render();
      const r = await api.invoke('settings:setApiKey', { key: key.trim() });
      if (r && r.ok) { keyState = ''; keyDraft = ''; } else { keyState = 'bad:' + ((r && r.error) || 'That key did not work.'); keyDraft = key; }
      render();
    },
  };

  app.addEventListener('click', (e) => {
    const el = e.target.closest('[data-act]');
    if (el && actions[el.dataset.act]) actions[el.dataset.act](el);
  });
  app.addEventListener('input', (e) => {
    if (e.target.id === 'key') keyDraft = e.target.value;
    if (e.target.id === 'email') {
      emailDraft = e.target.value;
      const b = app.querySelector('[data-act="submit-email"]');
      if (b) b.disabled = !emailDraft.trim();
    }
  });
  app.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      if (e.target.id === 'key') actions['save-key']();
      if (e.target.id === 'email') actions['submit-email']();
    }
    if (e.key === 'Escape') actions.close();
  });

  api.on('status', (s) => { status = s; render(); });
  api.on('settings', (s) => { settings = s; render(); });
  api.on('notify', (n) => {
    const t = document.createElement('div');
    t.className = 'toast ' + (n.kind === 'error' ? 'error' : '');
    t.textContent = n.message;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 4000);
  });
  Promise.all([api.invoke('status:get'), api.invoke('settings:get')]).then(([s, st]) => { status = s; settings = st; render(); });
})();
