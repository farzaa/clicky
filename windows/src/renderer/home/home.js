'use strict';
/* Clicky Home: chat, agent jobs, routines, memory, settings. */
(function () {
  const api = window.clicky;
  const nav = document.getElementById('nav');
  const main = document.getElementById('main');
  let section = 'chat';
  let settings = null;
  let status = null;
  let chat = [];
  const jobs = new Map();
  let draft = '';
  let keyDraft = '';
  let keyMsg = '';
  const routineDraft = { days: [1, 2, 3, 4, 5], time: '09:00', task: '' };
  let appInfo = {};

  const I = (d) => `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  const SECTIONS = [
    { id: 'chat', label: 'Chat', icon: I('<path d="M4 5h16v11H9l-5 4z"/>') },
    { id: 'agent', label: 'Agent jobs', icon: I('<circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4M5 5l3 3M16 16l3 3M19 5l-3 3M8 16l-3 3"/>') },
    { id: 'routines', label: 'Routines', icon: I('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>') },
    { id: 'memory', label: 'Memory', icon: I('<path d="M9 4a3 3 0 0 0-3 3v1a3 3 0 0 0-2 3 3 3 0 0 0 2 3v1a3 3 0 0 0 3 3h1V4zM15 4a3 3 0 0 1 3 3v1a3 3 0 0 1 2 3 3 3 0 0 1-2 3v1a3 3 0 0 1-3 3h-1V4z"/>') },
    { id: 'visuals', label: 'Visuals and 3D', icon: I('<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"/>') },
    { id: 'settings', label: 'Settings', icon: I('<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.2L14 3h-4l-.4 2.6a7 7 0 0 0-2 1.2l-2.3-.9-2 3.4 2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.2L10 21h4l.4-2.6a7 7 0 0 0 2-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z"/>') },
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }
  const DAYS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];
  const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
  const shortcutText = () => (status && status.shortcut ? status.shortcut.displayText : 'Ctrl+Alt');

  function renderNav() {
    const live = Array.from(jobs.values()).filter((j) => j.status === 'running' || j.status === 'waiting').length;
    nav.innerHTML =
      SECTIONS.map((s) => `<button data-sec="${s.id}" class="${s.id === section ? 'sel' : ''}">${s.icon}<span>${s.label}</span>${s.id === 'agent' && live ? `<span class="badge">${live}</span>` : ''}</button>`).join('') +
      '<div class="grow"></div>' +
      `<div class="muted" style="font-size:11px;padding:8px 12px;line-height:1.5">${status ? `<span class="dot ${status.voiceState === 'idle' ? 'green' : 'blue'}" style="display:inline-block;margin-right:6px"></span>${esc(status.statusText)}` : ''}<br>Hold ${esc(shortcutText())} to talk</div>`;
  }

  // ------------------------------------------------------------ chat
  function chatView() {
    const msgs = chat.length
      ? chat.map((m) => `<div class="msg ${m.role}">${esc(m.text)}</div>`).join('')
      : `<div class="empty"><div class="big">Ask Clicky anything</div>Type here, or hold ${esc(shortcutText())} anywhere to talk. Clicky looks at your screen, points at things, draws on it, and can drive your computer when you ask it to.</div>`;
    const chips = ['How do I make a new folder?', 'Open YouTube and search for lo-fi music', 'Explain what is on my screen', 'Show me a 3D model of a plant cell'];
    return `<div class="page chat" style="padding:0"><div class="msgs" id="msgs">${msgs}</div>
      ${chat.length ? '' : `<div class="chips">${chips.map((c) => `<button class="chip" data-chip="${esc(c)}">${esc(c)}</button>`).join('')}</div>`}
      <div class="composer"><textarea id="draft" class="field" placeholder="Message Clicky..." rows="1">${esc(draft)}</textarea>
      <button class="btn btn-primary" style="animation:none" data-act="send">Send</button></div></div>`;
  }

  function scrollChat() {
    const m = document.getElementById('msgs');
    if (m) m.scrollTop = m.scrollHeight;
  }

  // ------------------------------------------------------------ jobs
  function jobsView() {
    const list = Array.from(jobs.values()).sort((a, b) => b.startedAt - a.startedAt);
    const body = list.length
      ? list.map((j) => `<div class="card"><div class="job"><div style="flex:1;min-width:0"><div style="display:flex;gap:10px;align-items:center"><b>${esc(j.name)}</b><span class="jstatus ${j.status}">${j.status}</span></div>
          <div class="muted" style="margin-top:4px">${esc(j.note || '')}</div>
          ${j.log && j.log.length ? `<div class="joblog">${esc(j.log.join('\n'))}</div>` : ''}</div>
          ${j.status === 'running' || j.status === 'waiting' ? `<button class="btn btn-destructive" data-act="stop-job" data-id="${j.id}">Stop</button>` : ''}</div></div>`).join('')
      : '<div class="card muted">No jobs yet. Ask Clicky to "open my downloads folder and tell me what is big" or to "do X for me" and it will show up here.</div>';
    const s = settings.agent;
    return `<div class="page"><h1>Agent jobs</h1><p class="lead">Clicky can work in the background (web search, files, summaries) or take over the mouse and keyboard when you approve it. Press Esc or move the mouse to stop at any time.</p>
      ${body}
      <div class="card"><h3>Run a task</h3><div class="kv"><input id="jobtask" class="field" placeholder="e.g. open Notepad and write a shopping list"><button class="btn btn-secondary" data-act="run-bg">Background</button><button class="btn btn-primary" style="animation:none" data-act="run-drive" ${s.allowDrive ? '' : 'disabled'}>Drive my PC</button></div></div></div>`;
  }

  // ------------------------------------------------------------ routines
  function routinesView() {
    const rs = settings.routines || [];
    const list = rs.length
      ? rs.map((r) => `<div class="card"><div class="row" style="padding:0"><div><div class="t">${esc(r.task)}</div><div class="d">${esc(r.scheduleText || '')}</div></div>
          <div style="display:flex;gap:12px;align-items:center"><div class="switch ${r.enabled === false ? '' : 'on'}" data-act="toggle-routine" data-id="${r.id}"></div><button class="btn btn-tertiary" data-act="del-routine" data-id="${r.id}">Delete</button></div></div></div>`).join('')
      : '<div class="card muted">No routines. Say something like "every weekday at 9 give me the top tech headlines" and Clicky will save it here.</div>';
    return `<div class="page"><h1>Routines</h1><p class="lead">Recurring tasks run in the background while Clicky is open in the tray. They never take over your mouse unless you set that up with approval.</p>${list}
      <div class="card"><h3>New routine</h3><div class="days" style="margin-bottom:10px">${DAYS.map((d, i) => `<button data-day="${i}" class="${routineDraft.days.includes(i) ? 'on' : ''}">${d}</button>`).join('')}</div>
      <div class="kv"><input id="rtime" class="field" style="width:100px;flex:none" type="time" value="${routineDraft.time}"><input id="rtask" class="field" placeholder="What should Clicky do?" value="${esc(routineDraft.task)}"><button class="btn btn-primary" style="animation:none" data-act="add-routine">Add</button></div></div></div>`;
  }

  // ------------------------------------------------------------ memory
  function memoryView() {
    const mem = settings.memory || [];
    return `<div class="page"><h1>Memory</h1><p class="lead">Short facts Clicky remembers about you so answers feel personal. Stored only on this PC and sent to Groq as context with your questions.</p>
      <div class="card">${mem.length ? mem.map((m, i) => `<span class="pill">${esc(m)}<button data-act="del-mem" data-i="${i}" aria-label="Forget">&#x2715;</button></span>`).join('') : '<span class="muted">Nothing yet. Tell Clicky "remember that I use VS Code".</span>'}</div>
      <div class="card"><h3>Add a memory</h3><div class="kv"><input id="memnew" class="field" placeholder="e.g. I prefer dark mode"><button class="btn btn-secondary" data-act="add-mem">Remember</button></div></div></div>`;
  }

  // ------------------------------------------------------------ visuals
  function visualsView() {
    const demos = [
      ['Plant cell', 'a plant cell with its organelles'], ['Solar system', 'the solar system'], ['DNA helix', 'a DNA double helix'],
      ['Engine', 'a four-stroke engine piston and crankshaft'], ['Atom', 'a carbon atom with electron shells'], ['Pyramid', 'the great pyramid of giza'],
    ];
    return `<div class="page"><h1>Visuals and 3D</h1><p class="lead">When it helps, Clicky draws arrows, circles and step numbers right on your screen, shows info cards with photos, and builds interactive 3D models you can rotate and click to ask about.</p>
      <div class="card"><h3>Try a 3D model</h3>${demos.map(([t, q]) => `<div class="tile" data-model="${esc(q)}"><b>${t}</b><span>${esc(q)}</span></div>`).join('')}
      <div class="kv" style="margin-top:8px"><input id="modeltopic" class="field" placeholder="Anything: a bicycle, the heart, a castle..."><button class="btn btn-primary" style="animation:none" data-act="make-model">Generate</button></div></div>
      <div class="card"><h3>Ask by voice</h3><div class="secondary" style="line-height:1.6">"Draw an arrow to the save button", "circle what is wrong in this code", "show me how a heart pumps blood in 3D", "give me a card about the Eiffel tower".</div></div></div>`;
  }

  // ------------------------------------------------------------ settings
  function sel(id, value, options) {
    return `<select class="field" id="${id}">${options.map(([v, l]) => `<option value="${v}" ${v === value ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  }
  function tog(act, on) {
    return `<div class="switch ${on ? 'on' : ''}" data-act="${act}"></div>`;
  }
  function settingsView() {
    const s = settings;
    const keySrc = s.apiKeyFromEnv ? 'From GROQ_API_KEY environment variable' : s.hasApiKey ? 'Stored encrypted with Windows DPAPI' : 'Not set';
    return `<div class="page"><h1>Settings</h1><p class="lead">Everything here is stored locally in your user profile.</p>
      <div class="card"><h3>Groq</h3>
        <div class="row"><div><div class="t">API key</div><div class="d">${keySrc}. Get one free at console.groq.com/keys</div></div></div>
        <div class="kv" style="margin:4px 0 6px"><input id="keyin" type="password" class="field" placeholder="${s.hasApiKey ? 'Paste a new key to replace it' : 'gsk_...'}" value="${esc(keyDraft)}"><button class="btn btn-primary" style="animation:none;padding:7px 16px" data-act="save-key">Save</button>${s.hasApiKey && !s.apiKeyFromEnv ? '<button class="btn btn-tertiary" data-act="clear-key">Remove</button>' : ''}</div>
        ${keyMsg ? `<div style="font-size:12px;color:${keyMsg.startsWith('ok') ? 'var(--success)' : '#ff9a9d'}">${esc(keyMsg.replace(/^ok:|^err:/, ''))}</div>` : ''}
        <div class="row"><div><div class="t">Model mode</div><div class="d">Fast answers instantly. Deep thinks first and is better for hard questions.</div></div><div class="segmented"><button data-act="mode-fast" class="${s.modelMode !== 'deep' ? 'sel' : ''}">Fast</button><button data-act="mode-deep" class="${s.modelMode === 'deep' ? 'sel' : ''}">Deep</button></div></div>
        <div class="row"><div><div class="t">Chat and vision model</div></div><input class="field" style="width:240px" id="visionModel" value="${esc(s.visionModel)}"></div></div>
      <div class="card"><h3>Voice</h3>
        <div class="row"><div><div class="t">Speech engine</div><div class="d">Groq Orpheus sounds natural but is English only. Windows voices work offline.</div></div><div class="segmented"><button data-act="tts-groq" class="${s.ttsProvider === 'groq' ? 'sel' : ''}">Groq</button><button data-act="tts-windows" class="${s.ttsProvider === 'windows' ? 'sel' : ''}">Windows</button></div></div>
        <div class="row"><div class="t">Groq voice</div>${sel('ttsVoice', s.ttsVoice, ['autumn', 'diana', 'hannah', 'austin', 'daniel', 'troy'].map((v) => [v, v]))}</div>
        <div class="row"><div class="t">Test voice</div><button class="btn btn-secondary" data-act="test-voice">Speak a sample</button></div>
        <div class="row"><div><div class="t">Push-to-talk shortcut</div></div>${sel('shortcut', s.pushToTalkShortcut, [['ctrl+alt', 'Control + Alt'], ['shift+ctrl', 'Shift + Control'], ['ctrl+space', 'Control + Space'], ['alt+space', 'Alt + Space'], ['double-ctrl', 'Double-tap Control']])}</div>
        <div class="row"><div class="t">Show captions</div>${tog('toggle-captions', s.captions)}</div></div>
      <div class="card"><h3>Agent</h3>
        <div class="row"><div><div class="t">Allow Clicky to drive my PC</div><div class="d">Mouse and keyboard control, only after you approve each job.</div></div>${tog('toggle-drive', s.agent.allowDrive)}</div>
        <div class="row"><div><div class="t">Approve each drive job</div><div class="d">Turn off only if you fully trust what you ask for.</div></div>${tog('toggle-approval', s.agent.driveApproval !== 'auto')}</div>
        <div class="row"><div><div class="t">Allow PowerShell commands</div><div class="d">Each command still needs your approval.</div></div>${tog('toggle-ps', s.agent.commandApproval !== 'never')}</div>
        <div class="row"><div><div class="t">Read UI elements for accuracy</div><div class="d">Uses Windows UI Automation to get exact button positions. Names of on-screen controls go to Groq.</div></div>${tog('toggle-uia', s.useAccessibilityGrounding)}</div>
        <div class="row"><div><div class="t">Pointing coordinate space</div><div class="d">Normalized 0-1000 grid is usually more accurate than pixels.</div></div><div class="segmented"><button data-act="coord-normalized" class="${s.coordinateSpace !== 'pixels' ? 'sel' : ''}">Grid</button><button data-act="coord-pixels" class="${s.coordinateSpace === 'pixels' ? 'sel' : ''}">Pixels</button></div></div></div>
      <div class="card"><h3>System</h3>
        <div class="row"><div class="t">Start Clicky when I sign in</div>${tog('toggle-login', s.launchAtLogin)}</div>
        <div class="row"><div><div class="t">Hide Clicky from screenshots and screen sharing</div><div class="d">Windows excludes Clicky windows from capture.</div></div>${tog('toggle-hide', s.hideFromCapture)}</div>
        <div class="row"><div class="t">Play onboarding music</div>${tog('toggle-music', s.playOnboardingMusic)}</div>
        <div class="row"><div><div class="t">Reset all settings and data</div><div class="d">Removes your key, memory and routines.</div></div><button class="btn btn-destructive" data-act="reset">Reset</button></div></div>
      <div class="muted" style="font-size:11.5px;margin-top:6px">Clicky for Windows ${esc(appInfo.version || '')} &middot; Electron ${esc(appInfo.electron || '')}</div></div>`;
  }

  // ------------------------------------------------------------ render
  function render() {
    if (!settings) return;
    renderNav();
    const keepFocus = document.activeElement && document.activeElement.id;
    const keepSel = keepFocus && document.activeElement.selectionStart;
    const views = { chat: chatView, agent: jobsView, routines: routinesView, memory: memoryView, visuals: visualsView, settings: settingsView };
    const oldPage = main.querySelector('.page');
    const scroll = oldPage ? oldPage.scrollTop : 0;
    main.innerHTML = views[section]();
    const page = main.querySelector('.page');
    if (page && section !== 'chat') page.scrollTop = scroll;
    if (section === 'chat') scrollChat();
    if (keepFocus) {
      const el = document.getElementById(keepFocus);
      if (el) { el.focus(); try { el.setSelectionRange(keepSel, keepSel); } catch (_) { /* ignore */ } }
    }
  }

  function setSection(id) {
    section = id;
    render();
  }

  async function setSetting(patch) {
    settings = await api.invoke('settings:set', patch);
    render();
  }

  async function sendChat() {
    const text = draft.trim();
    if (!text) return;
    draft = '';
    render();
    await api.invoke('chat:send', { text });
  }

  const val = (id) => (document.getElementById(id) || {}).value || '';

  const actions = {
    send: sendChat,
    'stop-job': (el) => api.invoke('job:stop', { id: el.dataset.id }),
    'run-bg': () => { const t = val('jobtask').trim(); if (t) api.invoke('job:run', { task: t, desktop: false }); },
    'run-drive': () => { const t = val('jobtask').trim(); if (t) api.invoke('job:run', { task: t, desktop: true }); },
    'toggle-routine': (el) => api.invoke('routine:toggle', { id: el.dataset.id }),
    'del-routine': (el) => api.invoke('routine:delete', { id: el.dataset.id }),
    'add-routine': () => {
      const task = val('rtask').trim();
      const time = val('rtime') || routineDraft.time;
      if (!task || !routineDraft.days.length) return;
      api.invoke('routine:add', { task, time, days: routineDraft.days.map((d) => DAY_KEYS[d]) });
      routineDraft.task = '';
    },
    'del-mem': (el) => api.invoke('memory:delete', { index: Number(el.dataset.i) }),
    'add-mem': () => { const t = val('memnew').trim(); if (t) setSetting({ memory: settings.memory.concat([t]).slice(-40) }); },
    'make-model': () => { const t = val('modeltopic').trim(); if (t) api.invoke('chat:send', { text: `show me a 3D model of ${t}` }); },
    'save-key': async () => {
      const key = val('keyin').trim();
      if (!key) return;
      keyMsg = '';
      keyDraft = key;
      render();
      const r = await api.invoke('settings:setApiKey', { key });
      keyMsg = r && r.ok ? 'ok:Key verified and saved.' : 'err:' + ((r && r.error) || 'That key did not work.');
      if (r && r.ok) keyDraft = '';
      render();
    },
    'clear-key': async () => { await api.invoke('settings:setApiKey', { key: '' }); keyMsg = 'ok:Key removed.'; render(); },
    'mode-fast': () => setSetting({ modelMode: 'fast' }),
    'mode-deep': () => setSetting({ modelMode: 'deep' }),
    'tts-groq': () => setSetting({ ttsProvider: 'groq' }),
    'tts-windows': () => setSetting({ ttsProvider: 'windows' }),
    'test-voice': () => api.invoke('voice:test'),
    'toggle-captions': () => setSetting({ captions: !settings.captions }),
    'toggle-drive': () => setSetting({ agent: { allowDrive: !settings.agent.allowDrive } }),
    'toggle-approval': () => setSetting({ agent: { driveApproval: settings.agent.driveApproval === 'auto' ? 'ask' : 'auto' } }),
    'toggle-ps': () => setSetting({ agent: { commandApproval: settings.agent.commandApproval === 'never' ? 'ask' : 'never' } }),
    'toggle-uia': () => setSetting({ useAccessibilityGrounding: !settings.useAccessibilityGrounding }),
    'coord-normalized': () => setSetting({ coordinateSpace: 'normalized' }),
    'coord-pixels': () => setSetting({ coordinateSpace: 'pixels' }),
    'toggle-login': () => setSetting({ launchAtLogin: !settings.launchAtLogin }),
    'toggle-hide': () => setSetting({ hideFromCapture: !settings.hideFromCapture }),
    'toggle-music': () => setSetting({ playOnboardingMusic: !settings.playOnboardingMusic }),
    reset: async () => { if (window.confirm('Remove your Groq key, memory, routines and all settings?')) await api.invoke('settings:resetAll'); },
  };

  document.addEventListener('click', (e) => {
    const win = e.target.closest('[data-win]');
    if (win) return api.invoke('window:control', { action: win.dataset.win });
    const secBtn = e.target.closest('[data-sec]');
    if (secBtn) return setSection(secBtn.dataset.sec);
    const chip = e.target.closest('[data-chip]');
    if (chip) { api.invoke('chat:send', { text: chip.dataset.chip }); return undefined; }
    const tile = e.target.closest('[data-model]');
    if (tile) return api.invoke('chat:send', { text: 'show me a 3D model of ' + tile.dataset.model });
    const day = e.target.closest('[data-day]');
    if (day) {
      const d = Number(day.dataset.day);
      routineDraft.days = routineDraft.days.includes(d) ? routineDraft.days.filter((x) => x !== d) : routineDraft.days.concat([d]);
      return render();
    }
    const el = e.target.closest('[data-act]');
    if (el && actions[el.dataset.act]) actions[el.dataset.act](el);
    return undefined;
  });
  document.addEventListener('input', (e) => {
    if (e.target.id === 'draft') {
      draft = e.target.value;
      e.target.style.height = '44px';
      e.target.style.height = Math.min(120, e.target.scrollHeight) + 'px';
    }
    if (e.target.id === 'keyin') keyDraft = e.target.value;
    if (e.target.id === 'rtask') routineDraft.task = e.target.value;
    if (e.target.id === 'rtime') routineDraft.time = e.target.value;
  });
  document.addEventListener('change', (e) => {
    if (e.target.id === 'ttsVoice') setSetting({ ttsVoice: e.target.value });
    if (e.target.id === 'shortcut') setSetting({ pushToTalkShortcut: e.target.value });
    if (e.target.id === 'visionModel' && e.target.value.trim()) setSetting({ visionModel: e.target.value.trim(), agentModel: e.target.value.trim() });
  });
  document.addEventListener('keydown', (e) => {
    if (e.target.id === 'draft' && e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
    if (e.key === 'Enter' && e.target.id === 'keyin') actions['save-key']();
  });

  api.on('settings', (s) => { settings = s; render(); });
  api.on('status', (s) => { status = s; (s.jobs || []).forEach((j) => jobs.set(j.id, j)); if (section === 'chat') renderNav(); else render(); });
  api.on('job-update', (j) => { jobs.set(j.id, j); renderNav(); if (section === 'agent') render(); });
  api.on('chat-msg', (m) => { chat.push(m); if (chat.length > 200) chat.shift(); if (section === 'chat') render(); });
  api.on('home:section', (id) => { if (SECTIONS.some((s) => s.id === id)) setSection(id); });
  api.on('notify', (n) => {
    const t = document.createElement('div');
    t.className = 'toast ' + (n.kind === 'error' ? 'error' : '');
    t.textContent = n.message;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 4200);
  });

  Promise.all([api.invoke('settings:get'), api.invoke('status:get'), api.invoke('chat:history'), api.invoke('app:info'), api.invoke('job:list')]).then(([st, s, h, info, js]) => {
    settings = st; status = s; chat = h || []; appInfo = info || {};
    (js || []).forEach((j) => jobs.set(j.id, j));
    render();
  });
})();
