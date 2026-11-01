'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { GroqClient, GroqError, buildMultipartBody } = require('../../src/main/groq');
const { SettingsStore } = require('../../src/main/settings');
const P = require('../../src/main/prompts');

function sseResponse(lines) {
  const enc = new TextEncoder();
  const stream = new ReadableStream({
    start(c) { for (const l of lines) c.enqueue(enc.encode(l)); c.close(); },
  });
  return new Response(stream, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}
const chunk = (o) => 'data: ' + JSON.stringify({ choices: [{ delta: o }] }) + '\n\n';

test('chat streams text deltas and tool calls', async () => {
  const calls = [];
  const client = new GroqClient({
    getApiKey: () => 'k',
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return sseResponse([
        chunk({ content: 'hel' }), chunk({ content: 'lo' }),
        chunk({ tool_calls: [{ index: 0, id: 'c1', function: { name: 'click', arguments: '{"x"' } }] }),
        chunk({ tool_calls: [{ index: 0, function: { arguments: ':1}' } }] }),
        'data: [DONE]\n\n',
      ]);
    },
  });
  const deltas = [];
  const r = await client.chat({ model: 'm', messages: [], onTextDelta: (d) => deltas.push(d), reasoningEffort: 'none' });
  assert.equal(r.text, 'hello');
  assert.deepEqual(deltas, ['hel', 'lo']);
  assert.equal(r.toolCalls[0].function.name, 'click');
  assert.equal(r.toolCalls[0].function.arguments, '{"x":1}');
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.reasoning_effort, 'none');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer k');
});

test('chat retries without reasoning params when rejected', async () => {
  let n = 0;
  const client = new GroqClient({
    getApiKey: () => 'k',
    fetchImpl: async (url, init) => {
      n++;
      if (JSON.parse(init.body).reasoning_effort) return new Response('{"error":{"message":"bad param"}}', { status: 400 });
      return sseResponse([chunk({ content: 'ok' }), 'data: [DONE]\n\n']);
    },
  });
  const r = await client.chat({ model: 'm', messages: [], reasoningEffort: 'none' });
  assert.equal(r.text, 'ok');
  assert.equal(n, 2);
});

test('errors are classified', async () => {
  const mk = (status, body) => new GroqClient({ getApiKey: () => 'k', fetchImpl: async () => new Response(body, { status, headers: { 'retry-after': '99' } }) });
  await assert.rejects(mk(401, '{}').chat({ model: 'm', messages: [], stream: false }), (e) => e.kind === 'bad_key');
  await assert.rejects(mk(429, '{}').chat({ model: 'm', messages: [], stream: false }), (e) => e.kind === 'rate_limited');
  await assert.rejects(mk(400, '{"error":{"code":"model_terms_required","message":"x"}}').chat({ model: 'm', messages: [], stream: false }), (e) => e.kind === 'terms_required');
  await assert.rejects(new GroqClient({ getApiKey: () => '' }).chat({ model: 'm', messages: [] }), (e) => e instanceof GroqError && e.kind === 'no_key');
});

test('transcribe sends multipart wav and tts truncates to 200 chars', async () => {
  let seen;
  const client = new GroqClient({
    getApiKey: () => 'k',
    fetchImpl: async (url, init) => {
      seen = { url, init };
      if (url.endsWith('/audio/transcriptions')) return new Response('{"text":" hi there "}');
      return new Response(new Uint8Array([1, 2, 3]));
    },
  });
  assert.equal(await client.transcribe({ wavBuffer: Buffer.from('RIFF') }), 'hi there');
  assert.match(seen.init.headers['Content-Type'], /multipart\/form-data; boundary=/);
  assert.ok(Buffer.from(seen.init.body).toString().includes('whisper-large-v3-turbo'));
  const wav = await client.synthesizeSpeech({ text: 'a'.repeat(500) });
  assert.equal(wav.length, 3);
  assert.equal(JSON.parse(seen.init.body).input.length, 200);
});

test('multipart builder', () => {
  const { body } = buildMultipartBody({ a: '1' }, { field: 'file', filename: 'x.wav', contentType: 'audio/wav', data: Buffer.from('DATA') });
  assert.ok(body.toString().includes('name="a"'));
  assert.ok(body.toString().includes('DATA'));
});

test('settings: persist, merge, key never leaks, env override', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clicky-'));
  const file = path.join(dir, 's.json');
  const fake = { isEncryptionAvailable: () => true, encryptString: (s) => Buffer.from('enc:' + s), decryptString: (b) => b.toString().slice(4) };
  const s = new SettingsStore(file, fake, {});
  s.setApiKey('gsk_secret');
  s.set({ agent: { maxSteps: 12 } });
  assert.equal(s.getApiKey(), 'gsk_secret');
  assert.ok(!fs.readFileSync(file, 'utf8').includes('gsk_secret'));
  const pub = s.getPublic();
  assert.equal(pub.groqApiKeyEncrypted, undefined);
  assert.equal(pub.hasApiKey, true);
  assert.equal(pub.agent.maxSteps, 12);
  assert.equal(pub.agent.allowDrive, true);
  const s2 = new SettingsStore(file, fake, { GROQ_API_KEY: 'envkey' });
  assert.equal(s2.getApiKey(), 'envkey');
  assert.equal(s2.get('agent').maxSteps, 12);
});

test('prompts contain the key pieces', () => {
  const p = P.buildTalkSystemPrompt({ memoryFacts: ['likes tea'], shortcutText: 'control+alt' });
  assert.match(p, /\[POINT:x,y:label\]/);
  assert.match(p, /1000 by 1000 grid/);
  assert.match(p, /likes tea/);
  assert.match(p, /\[DRIVE:/);
  assert.ok(!/\[DRIVE:/.test(P.buildTalkSystemPrompt({ allowDrive: false })));
  assert.match(P.buildTalkSystemPrompt({ coordinateSpace: 'pixels' }), /pixel dimensions/);
  assert.match(P.buildModel3DPrompt('engine'), /engine/);
  assert.match(P.buildAgentSystemPrompt({ jobName: 'x' }), /click_element/);
});
