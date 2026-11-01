'use strict';
const fs = require('fs');
const path = require('path');

const DEFAULT_SETTINGS = {
  groqBaseUrl: 'https://api.groq.com/openai/v1',
  groqApiKeyEncrypted: '',
  modelMode: 'fast', // fast = no reasoning, deep = thinking
  visionModel: 'qwen/qwen3.8-27b',
  agentModel: 'qwen/qwen3.8-27b',
  sttModel: 'whisper-large-v3-turbo',
  ttsProvider: 'groq', // groq | windows
  ttsModel: 'canopylabs/orpheus-v1-english',
  ttsVoice: 'autumn',
  captions: true,
  pushToTalkShortcut: 'ctrl+alt',
  cursorEnabled: true,
  hasCompletedOnboarding: false,
  hasSubmittedEmail: false,
  email: '',
  launchAtLogin: true,
  coordinateSpace: 'normalized',
  useAccessibilityGrounding: true,
  hideFromCapture: true,
  playOnboardingMusic: true,
  micGranted: false,
  userName: '',
  agent: {
    allowDrive: true,
    driveApproval: 'ask', // ask | auto
    commandApproval: 'ask', // ask | never
    maxSteps: 60,
  },
  routines: [],
  memory: [],
  jobs: [],
  chat: [],
};

function isPlainObject(v) {
  return v && typeof v === 'object' && !Array.isArray(v);
}

function deepMerge(base, patch) {
  const out = Array.isArray(base) ? base.slice() : Object.assign({}, base);
  for (const key of Object.keys(patch || {})) {
    const v = patch[key];
    if (isPlainObject(v) && isPlainObject(out[key])) out[key] = deepMerge(out[key], v);
    else out[key] = v;
  }
  return out;
}

class SettingsStore {
  constructor(file, safeStorage, env = process.env) {
    this.file = file;
    this.safeStorage = safeStorage || null;
    this.env = env;
    this.data = deepMerge(DEFAULT_SETTINGS, {});
    this.listeners = new Set();
    this._load();
  }

  _load() {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      this.data = deepMerge(DEFAULT_SETTINGS, parsed);
    } catch (_) {
      this.data = deepMerge(DEFAULT_SETTINGS, {});
    }
  }

  _save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = this.file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmp, this.file);
  }

  onChange(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  _emit() {
    for (const fn of this.listeners) {
      try {
        fn(this.getPublic());
      } catch (_) {
        /* ignore */
      }
    }
  }

  get(key) {
    return this.data[key];
  }

  all() {
    return this.data;
  }

  set(patch) {
    this.data = deepMerge(this.data, patch);
    this._save();
    this._emit();
    return this.getPublic();
  }

  getApiKey() {
    if (this.env && this.env.GROQ_API_KEY) return this.env.GROQ_API_KEY.trim();
    const enc = this.data.groqApiKeyEncrypted;
    if (!enc) return '';
    try {
      if (enc.startsWith('plain:')) return Buffer.from(enc.slice(6), 'base64').toString('utf8');
      if (this.safeStorage && this.safeStorage.isEncryptionAvailable()) {
        return this.safeStorage.decryptString(Buffer.from(enc, 'base64'));
      }
    } catch (_) {
      /* fallthrough */
    }
    return '';
  }

  setApiKey(key) {
    const trimmed = String(key || '').trim();
    if (!trimmed) {
      this.data.groqApiKeyEncrypted = '';
    } else if (this.safeStorage && this.safeStorage.isEncryptionAvailable()) {
      this.data.groqApiKeyEncrypted = this.safeStorage.encryptString(trimmed).toString('base64');
    } else {
      this.data.groqApiKeyEncrypted = 'plain:' + Buffer.from(trimmed, 'utf8').toString('base64');
    }
    this._save();
    this._emit();
  }

  hasApiKey() {
    return !!this.getApiKey();
  }

  getPublic() {
    const copy = JSON.parse(JSON.stringify(this.data));
    delete copy.groqApiKeyEncrypted;
    delete copy.chat;
    copy.hasApiKey = this.hasApiKey();
    copy.apiKeyFromEnv = !!(this.env && this.env.GROQ_API_KEY);
    return copy;
  }

  reset() {
    this.data = deepMerge(DEFAULT_SETTINGS, {});
    this._save();
    this._emit();
  }
}

module.exports = { SettingsStore, DEFAULT_SETTINGS, deepMerge };
