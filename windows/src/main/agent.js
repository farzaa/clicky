'use strict';
/*
 * Agent loop: Groq tool-calling that can see the screen and drive the PC.
 *
 * Groq has no native "computer use" API, so grounding is done here:
 *   - the model sees a labeled screenshot and answers in a 0..1000 grid
 *   - optional Windows UI Automation gives exact, named click targets
 *   - every desktop action goes through InputController (abortable by Escape /
 *     mouse movement / stop button) and the first one needs the user's approval.
 */
const { buildAgentSystemPrompt, AGENT_TOOL_NAMES } = require('./prompts');
const { imagePart } = require('./groq');
const { InputAbortedError } = require('./input');
const { mapModelPointToGlobal, globalToModelPoint, mapDrawToGlobal } = require('./screen-math');
const { findElement, describeElements } = require('./uia');

const MAX_IMAGES_IN_CONTEXT = 2; // Groq allows 3 per request; keep one spare

function fn(name, description, properties = {}, required = []) {
  return { type: 'function', function: { name, description, parameters: { type: 'object', properties, required } } };
}
const num = (d) => ({ type: 'number', description: d });
const str = (d) => ({ type: 'string', description: d });

function buildToolDefinitions({ desktopAllowed, powershellAllowed }) {
  const screenArg = { screen: num('screen number from the last screenshot, default is the cursor screen') };
  const xy = { x: num('x in the 0..1000 grid'), y: num('y in the 0..1000 grid'), ...screenArg };
  const tools = [];
  if (desktopAllowed) {
    tools.push(
      fn('screenshot', 'Look at the screen now. Always do this before acting and after actions that change the screen.', screenArg),
      fn('click', 'Left click at a point.', xy, ['x', 'y']),
      fn('double_click', 'Double click at a point.', xy, ['x', 'y']),
      fn('right_click', 'Right click at a point.', xy, ['x', 'y']),
      fn('move_mouse', 'Move the mouse to a point without clicking.', xy, ['x', 'y']),
      fn('drag', 'Drag from one point to another.', {
        x: num('start x'), y: num('start y'), to_x: num('end x'), to_y: num('end y'), ...screenArg,
      }, ['x', 'y', 'to_x', 'to_y']),
      fn('scroll', 'Scroll the mouse wheel at the current position. Positive = up, negative = down. Units are notches (3 is a small page).', {
        amount: num('notches, negative scrolls down'),
      }, ['amount']),
      fn('type_text', 'Type text into the focused control.', { text: str('text to type') }, ['text']),
      fn('press_keys', 'Press keys or shortcuts, for example "ctrl+l", "enter", "win", "alt+tab", "ctrl+shift+t". Several combos separated by comma are pressed in order.', {
        keys: str('key combos'),
      }, ['keys']),
      fn('click_element', 'Click a named control in the foreground window (exact, via UI Automation). Prefer this when a visible label exists.', {
        name: str('visible name of the control'),
      }, ['name']),
      fn('focus_window', 'Bring a window to the front by (part of) its title.', { title: str('window title or app name') }, ['title']),
      fn('list_windows', 'List open windows.'),
      fn('wait', 'Wait for something to load.', { seconds: num('1 to 10') }, ['seconds'])
    );
  }
  tools.push(
    fn('open_url', 'Open a web page in the default browser.', { url: str('http or https url') }, ['url']),
    fn('open_app', 'Launch an installed application by name (for example notepad, calc, chrome).', { name: str('app name') }, ['name']),
    fn('web_search', 'Search the web and get result titles, links and snippets.', { query: str('search query') }, ['query']),
    fn('fetch_page', 'Fetch a web page as plain text.', { url: str('http or https url') }, ['url']),
    fn('read_clipboard', 'Read the clipboard text.'),
    fn('write_clipboard', 'Put text on the clipboard.', { text: str('text') }, ['text']),
    fn('save_file', 'Save a text file into the Clicky folder in Documents.', { name: str('file name'), content: str('file content') }, ['name', 'content']),
    fn('list_files', 'List files in a folder (default: the Clicky folder).', { dir: str('folder path') }),
    fn('read_file', 'Read a text file inside the user folder.', { path: str('file path') }, ['path']),
    fn('point_at', 'Fly the blue cursor to a point on screen and show a short label, to show the user something.', {
      ...xy, label: str('1-3 word label'),
    }, ['x', 'y']),
    fn('draw', 'Draw on the screen with the glowing marker: circle, rect, arrow, line, underline, highlight, path, text, step.', {
      kind: str('circle|rect|arrow|line|underline|highlight|path|text|step'),
      numbers: str('comma separated numbers in the 0..1000 grid, like the DRAW tag'),
      label: str('optional label'),
      ...screenArg,
    }, ['kind', 'numbers']),
    fn('say', 'Say one short sentence out loud to the user (progress note).', { text: str('lowercase casual sentence') }, ['text']),
    fn('ask_user', 'Ask the user a question or for permission and wait for the answer. Use before anything risky.', { question: str('the question') }, ['question']),
    fn('remember', 'Remember a fact about the user for later.', { fact: str('short fact') }, ['fact']),
    fn('finish', 'Finish the job with a short spoken summary.', { summary: str('one or two lowercase sentences') }, ['summary'])
  );
  if (powershellAllowed) {
    tools.push(fn('run_powershell', 'Run a PowerShell command. The user must approve each command. Use only when nothing else works.', { script: str('powershell script') }, ['script']));
  }
  return tools;
}

function safeParse(json) {
  try {
    return JSON.parse(json || '{}');
  } catch (_) {
    return {};
  }
}

class AgentRunner {
  constructor(deps) {
    this.d = deps; // { groq, settings, capture, input, tools, uia, screenApi, ui, log }
    this.running = new Map();
  }

  listJobs() {
    return Array.from(this.running.values()).map((j) => this._publicJob(j));
  }

  _publicJob(j) {
    return { id: j.id, name: j.name, task: j.task, mode: j.mode, status: j.status, step: j.step, note: j.note, startedAt: j.startedAt, log: j.log.slice(-30) };
  }

  _update(job, patch) {
    Object.assign(job, patch);
    this.d.ui.jobUpdate(this._publicJob(job));
  }

  stopAll(reason = 'stopped by user') {
    for (const job of this.running.values()) this.stop(job.id, reason);
  }

  stop(id, reason = 'stopped by user') {
    const job = this.running.get(id);
    if (!job) return false;
    job.controller.abort();
    this.d.input.abort(reason);
    if (job.pending) {
      job.pending.resolve({ approved: false, answer: '' });
      job.pending = null;
    }
    return true;
  }

  // The job (if any) currently waiting for the user's answer.
  pendingJob() {
    for (const j of this.running.values()) if (j.pending) return j;
    return null;
  }

  // Resolve a pending approval / question from the UI.
  respond(id, payload) {
    const job = this.running.get(id);
    if (job && job.pending) {
      job.pending.resolve(payload);
      job.pending = null;
    }
  }

  _ask(job, kind, text) {
    return new Promise((resolve) => {
      job.pending = { resolve };
      this._update(job, { status: 'waiting', note: text, prompt: { kind, text } });
      this.d.ui.jobPrompt({ jobId: job.id, kind, text, name: job.name });
    }).then((r) => {
      this._update(job, { status: 'running', prompt: null });
      return r;
    });
  }

  async run({ name, task, mode = 'drive', desktop = true }) {
    const settings = this.d.settings.all();
    const job = {
      id: 'job-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5),
      name: name || task.slice(0, 40),
      task,
      mode,
      desktop: desktop && settings.agent.allowDrive,
      status: 'running',
      step: 0,
      note: 'starting',
      startedAt: Date.now(),
      log: [],
      controller: new AbortController(),
      pending: null,
      approvedDesktop: settings.agent.driveApproval === 'auto',
      captures: [],
      elements: [],
    };
    this.running.set(job.id, job);
    this._update(job, {});
    let summary = '';
    try {
      summary = await this._loop(job);
      this._update(job, { status: 'done', note: summary });
    } catch (e) {
      if (e instanceof InputAbortedError || job.controller.signal.aborted || (e && e.kind === 'aborted')) {
        this._update(job, { status: 'stopped', note: (e && e.reason) || 'stopped' });
        summary = 'okay, i stopped.';
      } else {
        this.d.log.error('agent failed', e);
        this._update(job, { status: 'failed', note: e.message || String(e) });
        summary = 'i got stuck: ' + (e.message || 'something went wrong');
      }
    } finally {
      if (this.d.input.driving) this.d.input.endDriving();
      this.d.ui.driveState(false);
      setTimeout(() => this.running.delete(job.id), 15000);
    }
    return { jobId: job.id, status: job.status, summary };
  }

  async _loop(job) {
    const { groq, settings: store } = this.d;
    const settings = store.all();
    const maxSteps = settings.agent.maxSteps || 60;
    const powershellAllowed = settings.agent.commandApproval !== 'never';
    const defs = buildToolDefinitions({ desktopAllowed: job.desktop, powershellAllowed });
    const messages = [
      {
        role: 'system',
        content: buildAgentSystemPrompt({
          jobName: job.name,
          jobMode: job.mode,
          coordinateSpace: settings.coordinateSpace,
          memoryFacts: settings.memory,
          desktopAllowed: job.desktop,
          userName: settings.userName,
        }),
      },
      { role: 'user', content: 'task: ' + job.task },
    ];
    let finished = null;
    for (let step = 1; step <= maxSteps && finished === null; step++) {
      this._throwIfStopped(job);
      this._update(job, { step, note: 'thinking' });
      const res = await groq.chat({
        model: settings.agentModel,
        messages,
        tools: defs,
        toolChoice: 'auto',
        stream: false,
        signal: job.controller.signal,
        reasoningEffort: settings.modelMode === 'deep' ? undefined : 'none',
        temperature: 0.3,
        maxTokens: 1500,
      });
      const calls = res.toolCalls || [];
      messages.push({ role: 'assistant', content: res.text || null, tool_calls: calls.length ? calls : undefined });
      if (!calls.length) {
        // The model answered in text without a tool call: treat as the final summary.
        finished = (res.text || 'done.').replace(/<think>[\s\S]*?<\/think>/g, '').trim() || 'done.';
        break;
      }
      const pendingImages = [];
      for (const call of calls) {
        this._throwIfStopped(job);
        const name = call.function.name;
        const args = safeParse(call.function.arguments);
        this._update(job, { note: this._describe(name, args) });
        job.log.push(this._describe(name, args));
        let result;
        try {
          result = await this._exec(job, name, args, pendingImages);
        } catch (e) {
          if (e instanceof InputAbortedError || job.controller.signal.aborted) throw e;
          result = { ok: false, error: e.message || String(e) };
        }
        if (name === 'finish') finished = String(args.summary || 'done.');
        messages.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify(result).slice(0, 6000) });
      }
      for (const img of pendingImages) {
        messages.push({
          role: 'user',
          content: [{ type: 'text', text: img.text }, imagePart(img.jpeg)],
        });
      }
      this._trimImages(messages);
    }
    if (finished === null) finished = 'i hit my step limit before finishing.';
    this.d.ui.say(finished);
    return finished;
  }

  _throwIfStopped(job) {
    if (job.controller.signal.aborted) throw new InputAbortedError('stopped');
    this.d.input.throwIfAborted();
  }

  _trimImages(messages) {
    let seen = 0;
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m.role === 'user' && Array.isArray(m.content)) {
        seen++;
        if (seen > MAX_IMAGES_IN_CONTEXT) messages[i] = { role: 'user', content: '(older screenshot removed to save space)' };
      }
    }
  }

  _describe(name, a) {
    switch (name) {
      case 'click': case 'double_click': case 'right_click': case 'move_mouse': return `${name.replace('_', ' ')} at ${a.x},${a.y}`;
      case 'type_text': return `typing "${String(a.text || '').slice(0, 30)}"`;
      case 'press_keys': return `pressing ${a.keys}`;
      case 'click_element': return `clicking "${a.name}"`;
      case 'open_url': return `opening ${a.url}`;
      case 'open_app': return `opening ${a.name}`;
      case 'web_search': return `searching "${a.query}"`;
      case 'fetch_page': return `reading ${a.url}`;
      case 'say': return 'talking';
      case 'ask_user': return 'asking you';
      case 'screenshot': return 'looking at the screen';
      case 'finish': return 'finishing';
      default: return name.replace('_', ' ');
    }
  }

  async _ensureDesktopApproval(job) {
    if (job.approvedDesktop) return true;
    const r = await this._ask(job, 'approve-desktop', `Let Clicky take over your mouse and keyboard to: ${job.task}? Press Esc or move the mouse any time to stop.`);
    job.approvedDesktop = !!r.approved;
    return job.approvedDesktop;
  }

  _captureFor(job, screenNumber) {
    const caps = job.captures;
    if (!caps.length) return null;
    if (screenNumber && caps[screenNumber - 1]) return caps[screenNumber - 1];
    return caps.find((c) => c.isCursorScreen) || caps[0];
  }

  _toGlobal(job, a) {
    const cap = this._captureFor(job, a.screen);
    if (!cap) throw new Error('Take a screenshot first.');
    return mapModelPointToGlobal({ x: Number(a.x), y: Number(a.y) }, cap, this.d.settings.get('coordinateSpace'));
  }

  async _takeScreenshot(job, a, pendingImages) {
    const captures = await this.d.capture.captureAllScreens();
    job.captures = captures;
    const space = this.d.settings.get('coordinateSpace');
    const cap = this._captureFor(job, a && a.screen);
    let text = `${cap.label}. coordinate space: ${space === 'normalized' ? '0..1000 grid on this image' : 'image pixels'}.`;
    let elements = [];
    if (this.d.settings.get('useAccessibilityGrounding') && this.d.uia) {
      try {
        const info = await this.d.uia.listForegroundElements();
        elements = info.elements;
        job.elements = elements;
        const mapped = (e) => {
          const tl = this.d.screenApi.screenToDipPoint({ x: e.x, y: e.y });
          const br = this.d.screenApi.screenToDipPoint({ x: e.x + e.w, y: e.y + e.h });
          const a1 = globalToModelPoint(tl, cap, space);
          const a2 = globalToModelPoint(br, cap, space);
          return { x: a1.x, y: a1.y, width: a2.x - a1.x, height: a2.y - a1.y };
        };
        if (elements.length) text += `\nforeground window: "${info.title}". named controls (name at center x,y):\n` + describeElements(elements, mapped);
      } catch (_) {
        /* grounding is optional */
      }
    }
    pendingImages.push({ jpeg: cap.jpeg, text });
    return { ok: true, note: 'screenshot attached in the next message', screens: captures.length, controls: elements.length };
  }

  async _exec(job, name, a, pendingImages) {
    const { input, tools, ui } = this.d;
    const desktopTools = AGENT_TOOL_NAMES.desktop;
    if (desktopTools.includes(name)) {
      if (!job.desktop) return { ok: false, error: 'Desktop control is turned off for this job.' };
      if (name !== 'screenshot' && name !== 'list_windows' && name !== 'wait') {
        if (!(await this._ensureDesktopApproval(job))) throw new InputAbortedError('you declined computer control');
      }
      if (!input.driving && name !== 'screenshot') {
        input.beginDriving();
        ui.driveState(true, job.name);
      }
    }
    switch (name) {
      case 'screenshot':
        return this._takeScreenshot(job, a, pendingImages);
      case 'click':
        await input.click(this._toGlobal(job, a));
        return { ok: true };
      case 'double_click':
        await input.click(this._toGlobal(job, a), { count: 2 });
        return { ok: true };
      case 'right_click':
        await input.click(this._toGlobal(job, a), { button: 'right' });
        return { ok: true };
      case 'move_mouse':
        await input.moveTo(this._toGlobal(job, a));
        return { ok: true };
      case 'drag': {
        const from = this._toGlobal(job, a);
        const to = this._toGlobal(job, { x: a.to_x, y: a.to_y, screen: a.screen });
        await input.drag(from, to);
        return { ok: true };
      }
      case 'scroll':
        await input.scroll(Number(a.amount) || 0);
        return { ok: true };
      case 'type_text':
        await input.typeText(String(a.text || ''));
        return { ok: true };
      case 'press_keys':
        await input.pressKeys(String(a.keys || ''));
        return { ok: true };
      case 'click_element': {
        let els = job.elements;
        if (!els.length && this.d.uia) els = (await this.d.uia.listForegroundElements()).elements;
        const el = findElement(els, a.name);
        if (!el) return { ok: false, error: 'No control with that name. Take a screenshot and use coordinates instead.' };
        const dip = this.d.screenApi.screenToDipPoint({ x: el.x + el.w / 2, y: el.y + el.h / 2 });
        await input.click(dip);
        return { ok: true, clicked: el.name };
      }
      case 'focus_window': {
        const r = await tools.listWindows();
        const q = String(a.title || '').toLowerCase();
        const w = r.windows.find((x) => (x.title + ' ' + x.app).toLowerCase().includes(q));
        if (!w) return { ok: false, error: 'No window matches.' };
        const ok = this.d.win32.focusWindow(w.id);
        await new Promise((r2) => setTimeout(r2, 300));
        return { ok, focused: w.title };
      }
      case 'list_windows':
        return tools.listWindows();
      case 'wait':
        await new Promise((r) => setTimeout(r, Math.min(10, Math.max(0.5, Number(a.seconds) || 1)) * 1000));
        return { ok: true };
      case 'open_url':
        return tools.openUrl(String(a.url));
      case 'open_app':
        return tools.openApp(String(a.name));
      case 'web_search':
        return tools.webSearch(String(a.query));
      case 'fetch_page':
        return tools.fetchPage(String(a.url));
      case 'read_clipboard':
        return tools.readClipboard();
      case 'write_clipboard':
        return tools.writeClipboard(a.text);
      case 'save_file':
        return tools.saveFile(a.name, a.content);
      case 'list_files':
        return tools.listFiles(a.dir);
      case 'read_file':
        return tools.readFile(a.path);
      case 'point_at': {
        if (!job.captures.length) job.captures = await this.d.capture.captureAllScreens();
        const g = this._toGlobal(job, a);
        ui.pointAt(g, a.label || '');
        return { ok: true };
      }
      case 'draw': {
        const nums = String(a.numbers || '').split(',').map(Number).filter(Number.isFinite);
        if (!job.captures.length) job.captures = await this.d.capture.captureAllScreens();
        const shape = mapDrawToGlobal({ kind: String(a.kind), nums, label: a.label || null, screen: a.screen || null }, job.captures, this.d.settings.get('coordinateSpace'));
        if (!shape) return { ok: false, error: 'Could not draw that shape.' };
        ui.drawShapes([shape]);
        return { ok: true };
      }
      case 'say':
        ui.say(String(a.text || ''));
        return { ok: true };
      case 'ask_user': {
        const r = await this._ask(job, 'question', String(a.question || ''));
        return { ok: true, answer: r.answer || (r.approved ? 'yes' : 'no') };
      }
      case 'remember': {
        const memory = this.d.settings.get('memory').slice();
        memory.push(String(a.fact));
        this.d.settings.set({ memory: memory.slice(-40) });
        return { ok: true };
      }
      case 'finish':
        return { ok: true };
      case 'run_powershell': {
        const r = await this._ask(job, 'approve-command', 'Run this PowerShell command?\n\n' + String(a.script).slice(0, 600));
        if (!r.approved) return { ok: false, error: 'The user declined this command.' };
        return tools.runPowerShell(a.script);
      }
      default:
        return { ok: false, error: 'Unknown tool ' + name };
    }
  }
}

module.exports = { AgentRunner, buildToolDefinitions };
