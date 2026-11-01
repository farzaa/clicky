'use strict';
/*
 * Tag protocol between the model and the app.
 *
 *   [POINT:x,y:label:screenN]  [POINT:none]
 *   [DRAW:kind:n,n,n:label:screenN]   kinds: circle rect arrow line underline highlight path text step
 *   [CARD:title|body|photo query]
 *   [MODEL3D:topic]   [DRIVE:task]   [AGENT:task]
 *   [ROUTINE:tue,thu@17:00|task]      [REMEMBER:fact]
 */

const TAG_NAMES = ['POINT', 'DRAW', 'CARD', 'MODEL3D', 'DRIVE', 'ROUTINE', 'AGENT', 'REMEMBER'];
const TAG_RE = new RegExp('\\[(' + TAG_NAMES.join('|') + '):([^\\]]*)\\]', 'g');
const DRAW_KINDS = ['circle', 'rect', 'arrow', 'line', 'underline', 'highlight', 'path', 'text', 'step'];
const DAY_NAMES = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

function stripThinking(text) {
  return String(text || '')
    .replace(/<think>[\s\S]*?<\/think>/gi, '')
    .replace(/^[\s\S]*?<\/think>/i, (m) => (m.toLowerCase().includes('<think>') ? '' : m))
    .trim();
}

function parseNumbers(s) {
  return String(s || '')
    .split(',')
    .map((n) => Number(n.trim()))
    .filter((n) => Number.isFinite(n));
}

function parseScreenSuffix(parts) {
  let screen = null;
  if (parts.length) {
    const m = /^screen(\d+)$/i.exec(parts[parts.length - 1].trim());
    if (m) {
      screen = Number(m[1]);
      parts.pop();
    }
  }
  return screen;
}

function parsePoint(body) {
  if (/^\s*none\s*$/i.test(body)) return { none: true };
  const parts = body.split(':');
  const screen = parseScreenSuffix(parts);
  const nums = parseNumbers(parts[0]);
  if (nums.length < 2) return null;
  const label = parts.slice(1).join(':').trim();
  return { x: nums[0], y: nums[1], label: label || null, screen };
}

function parseDraw(body) {
  const parts = body.split(':');
  const kind = (parts.shift() || '').trim().toLowerCase();
  if (!DRAW_KINDS.includes(kind)) return null;
  const screen = parseScreenSuffix(parts);
  const nums = parseNumbers(parts.shift());
  const label = parts.join(':').trim();
  const need = { circle: 2, rect: 4, arrow: 4, line: 4, underline: 4, highlight: 4, path: 4, text: 2, step: 2 }[kind];
  if (nums.length < need) return null;
  return { kind, nums, label: label || null, screen };
}

function parseCard(body) {
  const [title, text, photo] = body.split('|').map((s) => s.trim());
  if (!title) return null;
  return { title, body: text || '', photoQuery: photo || null };
}

function parseRoutineSchedule(spec) {
  const m = /^\s*([a-z,\s*]+?)\s*@\s*(\d{1,2}):(\d{2})\s*$/i.exec(spec || '');
  if (!m) return null;
  const hour = Number(m[2]);
  const minute = Number(m[3]);
  if (hour > 23 || minute > 59) return null;
  let days;
  const dayText = m[1].toLowerCase().trim();
  if (dayText === '*' || dayText === 'daily' || dayText === 'every day' || dayText === 'everyday') {
    days = [0, 1, 2, 3, 4, 5, 6];
  } else if (dayText === 'weekdays') {
    days = [1, 2, 3, 4, 5];
  } else if (dayText === 'weekends') {
    days = [0, 6];
  } else {
    days = dayText
      .split(/[,\s]+/)
      .map((d) => DAY_NAMES.indexOf(d.slice(0, 3)))
      .filter((d) => d >= 0);
  }
  if (!days.length) return null;
  return { days: Array.from(new Set(days)).sort(), hour, minute };
}

function parseRoutine(body) {
  const idx = body.indexOf('|');
  if (idx < 0) return null;
  const schedule = parseRoutineSchedule(body.slice(0, idx));
  const task = body.slice(idx + 1).trim();
  if (!schedule || !task) return null;
  return { schedule, task, scheduleText: body.slice(0, idx).trim() };
}

function parseResponseTags(text) {
  const result = {
    spokenText: '',
    coordinate: null,
    elementLabel: null,
    screenNumber: null,
    draws: [],
    cards: [],
    modelTopic: null,
    driveTask: null,
    agentTask: null,
    memories: [],
    routines: [],
  };
  const source = stripThinking(text);
  source.replace(TAG_RE, (_m, name, body) => {
    switch (name) {
      case 'POINT': {
        const p = parsePoint(body);
        if (p && !p.none && !result.coordinate) {
          result.coordinate = { x: p.x, y: p.y };
          result.elementLabel = p.label;
          result.screenNumber = p.screen;
        }
        break;
      }
      case 'DRAW': {
        const d = parseDraw(body);
        if (d) result.draws.push(d);
        break;
      }
      case 'CARD': {
        const c = parseCard(body);
        if (c) result.cards.push(c);
        break;
      }
      case 'MODEL3D':
        if (body.trim()) result.modelTopic = body.trim();
        break;
      case 'DRIVE':
        if (body.trim()) result.driveTask = body.trim();
        break;
      case 'AGENT':
        if (body.trim()) result.agentTask = body.trim();
        break;
      case 'REMEMBER':
        if (body.trim()) result.memories.push(body.trim());
        break;
      case 'ROUTINE': {
        const r = parseRoutine(body);
        if (r) result.routines.push(r);
        break;
      }
      default:
    }
    return '';
  });
  result.spokenText = source
    .replace(TAG_RE, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return result;
}

// True when `s` (which starts with "[") could still turn into a known "[TAG:" opener.
function couldBeTagStart(s) {
  if (!s.startsWith('[')) return false;
  const rest = s.slice(1);
  return TAG_NAMES.some((n) => (n + ':').startsWith(rest) || rest.startsWith(n + ':'));
}

function findPossibleTagStart(s) {
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '[' && couldBeTagStart(s.slice(i))) return i;
  }
  return -1;
}

// Removes <think>...</think> from a streamed text, even when tags are split across deltas.
class ThinkFilter {
  constructor() {
    this.buffer = '';
    this.inThink = false;
  }
  push(delta) {
    this.buffer += delta;
    let out = '';
    for (;;) {
      if (this.inThink) {
        const end = this.buffer.indexOf('</think>');
        if (end < 0) {
          // keep a possible partial closer
          this.buffer = this.buffer.slice(Math.max(0, this.buffer.length - 8));
          return out;
        }
        this.buffer = this.buffer.slice(end + 8);
        this.inThink = false;
      } else {
        const start = this.buffer.indexOf('<think>');
        if (start >= 0) {
          out += this.buffer.slice(0, start);
          this.buffer = this.buffer.slice(start + 7);
          this.inThink = true;
          continue;
        }
        const lt = this.buffer.lastIndexOf('<');
        if (lt >= 0 && '<think>'.startsWith(this.buffer.slice(lt))) {
          out += this.buffer.slice(0, lt);
          this.buffer = this.buffer.slice(lt);
        } else {
          out += this.buffer;
          this.buffer = '';
        }
        return out;
      }
    }
  }
  flush() {
    const rest = this.inThink ? '' : this.buffer;
    this.buffer = '';
    return rest;
  }
}

const FIRST_CHUNK_MIN = 18;
const LATER_CHUNK_MIN = 48;
const MAX_CHUNK = 190;

function splitForSpeech(text, max = MAX_CHUNK) {
  const out = [];
  let rest = String(text || '').replace(/\s+/g, ' ').trim();
  while (rest.length > max) {
    let cut = -1;
    const window = rest.slice(0, max);
    const m = [...window.matchAll(/[.!?…][)"'\]]?\s/g)];
    if (m.length) cut = m[m.length - 1].index + m[m.length - 1][0].length;
    if (cut < max * 0.4) cut = window.lastIndexOf(', ') + 2;
    if (cut < max * 0.3) cut = window.lastIndexOf(' ') + 1;
    if (cut <= 0) cut = max;
    out.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).trim();
  }
  if (rest) out.push(rest);
  return out;
}

/*
 * Turns streamed model deltas into speakable sentence chunks, so TTS can start
 * before the full answer arrives. Tag text is never emitted.
 */
class SpokenSentenceStream {
  constructor() {
    this.raw = '';
    this.speak = '';
    this.emitted = 0;
    this.held = '';
    this.thinkFilter = new ThinkFilter();
  }

  push(delta) {
    const visible = this.thinkFilter.push(delta);
    this.raw += visible;
    this.held += visible;
    this._drainHeld();
    return this._cut(false);
  }

  finish() {
    this.held += this.thinkFilter.flush();
    this._drainHeld(true);
    return this._cut(true);
  }

  _drainHeld(final) {
    for (;;) {
      const s = this.held;
      let idx = s.indexOf('[');
      // look for a '[' that is (or may become) a tag opener
      let tagStart = -1;
      while (idx >= 0) {
        if (couldBeTagStart(s.slice(idx))) {
          tagStart = idx;
          break;
        }
        idx = s.indexOf('[', idx + 1);
      }
      if (tagStart < 0) {
        this.speak += s;
        this.held = '';
        return;
      }
      this.speak += s.slice(0, tagStart);
      const tail = s.slice(tagStart);
      const isFull = TAG_NAMES.some((n) => tail.startsWith('[' + n + ':'));
      if (isFull) {
        const close = tail.indexOf(']');
        if (close < 0) {
          this.held = tail; // wait for closing bracket
          if (final) this.held = '';
          return;
        }
        this.held = tail.slice(close + 1); // drop the tag, continue
        continue;
      }
      this.held = tail; // partial opener, wait for more
      if (final) this.held = '';
      return;
    }
  }

  _cut(final) {
    const chunks = [];
    for (;;) {
      const buf = this.speak;
      const min = this.emitted === 0 ? FIRST_CHUNK_MIN : LATER_CHUNK_MIN;
      let cut = -1;
      const re = /[.!?…]["')\]]*\s|\n/g;
      let m;
      while ((m = re.exec(buf))) {
        const end = m.index + m[0].length;
        if (m.index + 1 >= min) {
          cut = end;
          break;
        }
      }
      if (cut < 0 && buf.length > MAX_CHUNK) {
        const parts = splitForSpeech(buf.slice(0, MAX_CHUNK + 40), MAX_CHUNK);
        cut = parts[0].length;
        const idx = buf.indexOf(parts[0]);
        cut = idx + parts[0].length;
      }
      if (cut < 0) break;
      const chunk = buf.slice(0, cut).replace(/\s+/g, ' ').trim();
      this.speak = buf.slice(cut);
      if (chunk) {
        chunks.push(chunk);
        this.emitted++;
      }
    }
    if (final) {
      const rest = this.speak.replace(/\s+/g, ' ').trim();
      this.speak = '';
      if (rest) {
        for (const piece of splitForSpeech(rest)) {
          chunks.push(piece);
          this.emitted++;
        }
      }
    }
    return chunks;
  }
}

module.exports = {
  TAG_NAMES,
  DRAW_KINDS,
  stripThinking,
  parseResponseTags,
  parseRoutineSchedule,
  couldBeTagStart,
  findPossibleTagStart,
  ThinkFilter,
  SpokenSentenceStream,
  splitForSpeech,
};
