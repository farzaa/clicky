'use strict';
/*
 * Sentence-chunk speech queue.
 *
 *  - synthesize(text) -> Promise<Buffer wav>   (Groq Orpheus)
 *  - playWav(buffer, signal) -> Promise        (hidden audio window)
 *  - speakFallback(text, signal) -> Promise    (Windows SAPI via PowerShell)
 *
 * Chunks are synthesized ahead of time (prefetch) but always played in order.
 */
const { runPowerShell, psQuote } = require('./powershell');
const { splitForSpeech } = require('./tags');
const { SPEECH_INPUT_CHARACTER_LIMIT } = require('./groq');

class SpeechQueue {
  constructor({ synthesize, playWav, speakFallback, onStart, onIdle, log } = {}) {
    this.synthesize = synthesize;
    this.playWav = playWav;
    this.speakFallback = speakFallback || (() => Promise.resolve());
    this.onStart = onStart || (() => {});
    this.onIdle = onIdle || (() => {});
    this.log = log || { info() {}, warn() {}, error() {} };
    this.items = [];
    this.generation = 0;
    this.running = false;
    this.closed = false; // true after finish(): no more text expected
    this.startedFlag = false;
    this.abort = new AbortController();
    this.lastError = null;
    this.idleWaiters = [];
  }

  get isSpeaking() {
    return this.running || this.items.length > 0;
  }

  enqueue(text) {
    const pieces = splitForSpeech(text, SPEECH_INPUT_CHARACTER_LIMIT - 5);
    for (const piece of pieces) {
      if (!piece.trim()) continue;
      const signal = this.abort.signal;
      const item = { text: piece, wav: null };
      item.wav = this.synthesize(piece, signal).catch((e) => {
        if (signal.aborted) return null;
        this.lastError = e;
        this.log.warn('TTS synth failed, using fallback:', e && e.message);
        return null;
      });
      this.items.push(item);
    }
    this._run();
  }

  // call when the whole answer has been enqueued
  finish() {
    this.closed = true;
    if (!this.running && !this.items.length) this._idle();
  }

  async _run() {
    if (this.running) return;
    this.running = true;
    const gen = this.generation;
    while (this.items.length && gen === this.generation) {
      const item = this.items[0];
      const wav = await item.wav;
      if (gen !== this.generation) break;
      if (!this.startedFlag) {
        this.startedFlag = true;
        this.onStart();
        if (this.onStartHandler) this.onStartHandler();
      }
      try {
        if (wav) await this.playWav(wav, this.abort.signal);
        else await this.speakFallback(item.text, this.abort.signal);
      } catch (e) {
        if (gen !== this.generation) break;
        this.log.warn('playback failed:', e && e.message);
      }
      if (gen !== this.generation) break;
      this.items.shift();
    }
    if (gen === this.generation) {
      this.running = false;
      if (this.closed) this._idle();
    }
  }

  // Speak a short message immediately with the built-in voice (error messages).
  speakFallbackNow(text) {
    return Promise.resolve(this.speakFallback(text, undefined)).catch(() => {});
  }

  _idle() {
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    this.onIdle();
    waiters.forEach((w) => w());
  }

  whenIdle() {
    if (!this.isSpeaking && (this.closed || !this.startedFlag)) return Promise.resolve();
    return new Promise((r) => this.idleWaiters.push(r));
  }

  stop() {
    this.generation++;
    this.abort.abort();
    this.abort = new AbortController();
    this.items = [];
    this.running = false;
    this.startedFlag = false;
    this.closed = false;
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    waiters.forEach((w) => w());
  }
}

// Windows built-in voice. Used when there is no Groq key, no network, or provider = windows.
function speakWithSapi(text, signal) {
  const script =
    'Add-Type -AssemblyName System.Speech;$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;$s.Rate=1;$s.Speak(' +
    psQuote(text) +
    ')';
  return runPowerShell(script, { timeoutMs: 60000, signal }).then(() => undefined);
}

module.exports = { SpeechQueue, speakWithSapi };
