'use strict';
/*
 * Hidden audio host: records the microphone (16 kHz mono WAV), reports live levels,
 * plays TTS wavs, and plays the onboarding music with fades.
 */
(function () {
  const TARGET_RATE = 16000;
  let ctx = null;
  let stream = null;
  let source = null;
  let processor = null;
  let chunks = [];
  let inputRate = 48000;
  let recording = false;
  let startedAt = 0;
  let levelTimer = null;
  let lastRms = 0;

  function downsample(buffer, from, to) {
    if (from === to) return buffer;
    const ratio = from / to;
    const length = Math.floor(buffer.length / ratio);
    const out = new Float32Array(length);
    for (let i = 0; i < length; i++) {
      const start = Math.floor(i * ratio);
      const end = Math.min(buffer.length, Math.floor((i + 1) * ratio));
      let sum = 0;
      for (let j = start; j < end; j++) sum += buffer[j];
      out[i] = sum / Math.max(1, end - start);
    }
    return out;
  }

  function encodeWav(samples, rate) {
    const buf = new ArrayBuffer(44 + samples.length * 2);
    const v = new DataView(buf);
    const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    w(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); w(8, 'WAVE'); w(12, 'fmt ');
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    w(36, 'data'); v.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return buf;
  }

  async function startRecording() {
    if (recording) return;
    recording = true;
    chunks = [];
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
      if (!recording) { stopTracks(); return; }
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      inputRate = ctx.sampleRate;
      source = ctx.createMediaStreamSource(stream);
      processor = ctx.createScriptProcessor(2048, 1, 1);
      processor.onaudioprocess = (e) => {
        if (!recording) return;
        const data = e.inputBuffer.getChannelData(0);
        chunks.push(new Float32Array(data));
        let sum = 0;
        for (let i = 0; i < data.length; i++) sum += data[i] * data[i];
        lastRms = Math.sqrt(sum / data.length);
      };
      const mute = ctx.createGain();
      mute.gain.value = 0;
      source.connect(processor);
      processor.connect(mute);
      mute.connect(ctx.destination);
      startedAt = performance.now();
      levelTimer = setInterval(() => window.clicky.invoke('audio:levels', { rms: lastRms }), 33);
    } catch (e) {
      recording = false;
      window.clicky.invoke('audio:error', { message: String((e && e.message) || e), name: e && e.name });
    }
  }

  function stopTracks() {
    clearInterval(levelTimer);
    levelTimer = null;
    try { if (processor) processor.disconnect(); } catch (_) {}
    try { if (source) source.disconnect(); } catch (_) {}
    try { if (stream) stream.getTracks().forEach((t) => t.stop()); } catch (_) {}
    try { if (ctx) ctx.close(); } catch (_) {}
    processor = source = stream = ctx = null;
  }

  async function stopRecording(cancel) {
    const wasRecording = recording;
    recording = false;
    const durationMs = performance.now() - startedAt;
    stopTracks();
    window.clicky.invoke('audio:levels', { rms: 0 });
    if (cancel || !wasRecording) return;
    let total = 0;
    chunks.forEach((c) => (total += c.length));
    const merged = new Float32Array(total);
    let off = 0;
    chunks.forEach((c) => { merged.set(c, off); off += c.length; });
    chunks = [];
    if (!total) {
      window.clicky.invoke('audio:recorded', { wav: null, durationMs: 0 });
      return;
    }
    const wav = encodeWav(downsample(merged, inputRate, TARGET_RATE), TARGET_RATE);
    window.clicky.invoke('audio:recorded', { wav, durationMs });
  }

  // ---- playback ----
  let current = null;
  function play({ id, data }) {
    stopPlayback();
    const blob = new Blob([data], { type: 'audio/wav' });
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    current = { id, audio, url };
    const done = (ok) => {
      if (!current || current.id !== id) return;
      URL.revokeObjectURL(url);
      current = null;
      window.clicky.invoke('audio:ended', { id, ok });
    };
    audio.onended = () => done(true);
    audio.onerror = () => done(false);
    audio.play().catch(() => done(false));
  }
  function stopPlayback() {
    if (!current) return;
    const c = current;
    current = null;
    try { c.audio.pause(); } catch (_) {}
    URL.revokeObjectURL(c.url);
    window.clicky.invoke('audio:ended', { id: c.id, ok: false });
  }

  // ---- onboarding music: volume 0.3, fade out over 3 s in 30 steps ----
  let music = null;
  let fadeTimer = null;
  function musicCommand({ action, src }) {
    clearInterval(fadeTimer);
    if (action === 'start') {
      if (music) { music.pause(); music = null; }
      music = new Audio(src);
      music.volume = 0.3;
      music.play().catch(() => {});
    } else if (action === 'stop') {
      if (music) { music.pause(); music = null; }
    } else if (action === 'fade' && music) {
      const m = music;
      const dec = m.volume / 30;
      let left = 30;
      fadeTimer = setInterval(() => {
        left--;
        m.volume = Math.max(0, m.volume - dec);
        if (left <= 0) { clearInterval(fadeTimer); m.pause(); if (music === m) music = null; }
      }, 100);
    }
  }

  window.clicky.on('audio:start', startRecording);
  window.clicky.on('audio:stop', () => stopRecording(false));
  window.clicky.on('audio:cancel', () => stopRecording(true));
  window.clicky.on('audio:play', play);
  window.clicky.on('audio:stop-playback', stopPlayback);
  window.clicky.on('audio:music', musicCommand);
  window.clicky.invoke('audio:ready');
})();
