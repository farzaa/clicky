'use strict';
/*
 * Minimal Groq client (OpenAI-compatible REST). No SDK, so it is easy to mock.
 */

const SPEECH_INPUT_CHARACTER_LIMIT = 200;

class GroqError extends Error {
  constructor(kind, message, status) {
    super(message);
    this.name = 'GroqError';
    this.kind = kind; // no_key|bad_key|rate_limited|terms_required|too_large|server|network|aborted|bad_request
    this.status = status || 0;
  }
}

function errorFromResponse(status, bodyText) {
  let message = bodyText || '';
  let code = '';
  try {
    const j = JSON.parse(bodyText);
    message = (j.error && j.error.message) || message;
    code = (j.error && j.error.code) || '';
  } catch (_) {
    /* not json */
  }
  if (status === 401) return new GroqError('bad_key', 'Groq rejected the API key. Check it in Clicky settings.', status);
  if (status === 429) return new GroqError('rate_limited', 'Groq rate limit reached. Try again in a moment.', status);
  if (status === 413) return new GroqError('too_large', 'The request was too large for Groq.', status);
  if (code === 'model_terms_required' || /terms acceptance/i.test(message)) {
    return new GroqError(
      'terms_required',
      'This Groq model needs terms acceptance. Accept them once at console.groq.com/playground, then try again.',
      status
    );
  }
  if (status >= 500) return new GroqError('server', 'Groq had a server problem (' + status + ').', status);
  return new GroqError('bad_request', message || 'Groq request failed (' + status + ').', status);
}

function buildMultipartBody(fields, file) {
  const boundary = '----clicky' + Math.random().toString(16).slice(2);
  const chunks = [];
  const push = (s) => chunks.push(Buffer.from(s, 'utf8'));
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null || v === '') continue;
    push(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`);
  }
  push(
    `--${boundary}\r\nContent-Disposition: form-data; name="${file.field}"; filename="${file.filename}"\r\nContent-Type: ${file.contentType}\r\n\r\n`
  );
  chunks.push(file.data);
  push(`\r\n--${boundary}--\r\n`);
  return { body: Buffer.concat(chunks), contentType: 'multipart/form-data; boundary=' + boundary };
}

function imagePart(jpegBuffer) {
  return { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,' + Buffer.from(jpegBuffer).toString('base64') } };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function readChatStream(response, onTextDelta) {
  const decoder = new TextDecoder();
  let buffer = '';
  let text = '';
  const toolCalls = [];
  let finishReason = null;
  const handleLine = (line) => {
    line = line.trim();
    if (!line.startsWith('data:')) return;
    const payload = line.slice(5).trim();
    if (!payload || payload === '[DONE]') return;
    let json;
    try {
      json = JSON.parse(payload);
    } catch (_) {
      return;
    }
    if (json.error) throw errorFromResponse(500, JSON.stringify(json));
    const choice = json.choices && json.choices[0];
    if (!choice) return;
    if (choice.finish_reason) finishReason = choice.finish_reason;
    const delta = choice.delta || {};
    if (delta.content) {
      text += delta.content;
      if (onTextDelta) onTextDelta(delta.content);
    }
    for (const tc of delta.tool_calls || []) {
      const i = tc.index || 0;
      if (!toolCalls[i]) toolCalls[i] = { id: '', type: 'function', function: { name: '', arguments: '' } };
      if (tc.id) toolCalls[i].id = tc.id;
      if (tc.function && tc.function.name) toolCalls[i].function.name += tc.function.name;
      if (tc.function && tc.function.arguments) toolCalls[i].function.arguments += tc.function.arguments;
    }
  };
  const body = response.body;
  if (body && typeof body.getReader === 'function') {
    const reader = body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let idx;
      while ((idx = buffer.indexOf('\n')) >= 0) {
        handleLine(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 1);
      }
    }
  } else {
    for await (const value of body) {
      buffer += decoder.decode(value, { stream: true });
      let idx;
      while ((idx = buffer.indexOf('\n')) >= 0) {
        handleLine(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 1);
      }
    }
  }
  if (buffer) handleLine(buffer);
  return { text, toolCalls: toolCalls.filter(Boolean), finishReason };
}

class GroqClient {
  constructor({ getApiKey, getBaseUrl, fetchImpl, log } = {}) {
    this.getApiKey = getApiKey || (() => '');
    this.getBaseUrl = getBaseUrl || (() => 'https://api.groq.com/openai/v1');
    this.fetch = fetchImpl || ((...a) => fetch(...a));
    this.log = log || { info() {}, warn() {}, error() {} };
  }

  async request(pathname, init = {}, attempt = 0) {
    const key = this.getApiKey();
    if (!key) throw new GroqError('no_key', 'Add your Groq API key in Clicky settings first.');
    const url = this.getBaseUrl().replace(/\/$/, '') + pathname;
    const headers = Object.assign({ Authorization: 'Bearer ' + key }, init.headers || {});
    let res;
    try {
      res = await this.fetch(url, Object.assign({}, init, { headers }));
    } catch (e) {
      if (init.signal && init.signal.aborted) throw new GroqError('aborted', 'Request cancelled.');
      if (attempt < 1) {
        await sleep(300);
        return this.request(pathname, init, attempt + 1);
      }
      throw new GroqError('network', 'Could not reach Groq. Check your internet connection.');
    }
    if (res.ok) return res;
    const text = await res.text().catch(() => '');
    if (res.status === 429 && attempt < 2) {
      const retryAfter = Number(res.headers && res.headers.get && res.headers.get('retry-after'));
      const wait = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 1200;
      if (wait <= 3000) {
        await sleep(wait);
        return this.request(pathname, init, attempt + 1);
      }
    }
    if (res.status >= 500 && attempt < 1) {
      await sleep(400);
      return this.request(pathname, init, attempt + 1);
    }
    throw errorFromResponse(res.status, text);
  }

  async validateKey() {
    const res = await this.request('/models', { method: 'GET' });
    const j = await res.json();
    return { ok: true, models: (j.data || []).map((m) => m.id) };
  }

  async chat(opts) {
    const {
      model,
      messages,
      tools,
      toolChoice,
      stream = true,
      onTextDelta,
      signal,
      maxTokens,
      temperature,
      topP,
      reasoningEffort,
      jsonMode,
    } = opts;
    const buildBody = (withReasoning) => {
      const b = { model, messages, stream };
      if (tools && tools.length) {
        b.tools = tools;
        b.tool_choice = toolChoice || 'auto';
      }
      if (maxTokens) b.max_completion_tokens = maxTokens;
      if (temperature !== undefined) b.temperature = temperature;
      if (topP !== undefined) b.top_p = topP;
      if (withReasoning && reasoningEffort) b.reasoning_effort = reasoningEffort;
      if (jsonMode) b.response_format = { type: 'json_object' };
      return b;
    };
    const send = (withReasoning) =>
      this.request('/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(buildBody(withReasoning)),
        signal,
      });
    let res;
    try {
      res = await send(true);
    } catch (e) {
      if (e instanceof GroqError && e.kind === 'bad_request' && reasoningEffort) {
        this.log.warn('Groq rejected reasoning params, retrying without them');
        res = await send(false);
      } else throw e;
    }
    if (!stream) {
      const j = await res.json();
      const msg = (j.choices && j.choices[0] && j.choices[0].message) || {};
      return {
        text: msg.content || '',
        toolCalls: msg.tool_calls || [],
        finishReason: j.choices && j.choices[0] && j.choices[0].finish_reason,
      };
    }
    try {
      return await readChatStream(res, onTextDelta);
    } catch (e) {
      if (signal && signal.aborted) throw new GroqError('aborted', 'Request cancelled.');
      if (e instanceof GroqError) throw e;
      throw new GroqError('network', 'The connection to Groq dropped mid-answer.');
    }
  }

  async transcribe({ wavBuffer, model, language, prompt, signal }) {
    const { body, contentType } = buildMultipartBody(
      { model: model || 'whisper-large-v3-turbo', language, prompt, response_format: 'json', temperature: 0 },
      { field: 'file', filename: 'speech.wav', contentType: 'audio/wav', data: wavBuffer }
    );
    const res = await this.request('/audio/transcriptions', {
      method: 'POST',
      headers: { 'Content-Type': contentType },
      body,
      signal,
    });
    const j = await res.json();
    return String(j.text || '').trim();
  }

  async synthesizeSpeech({ model, voice, text, signal }) {
    let input = String(text || '').trim();
    if (input.length > SPEECH_INPUT_CHARACTER_LIMIT) input = input.slice(0, SPEECH_INPUT_CHARACTER_LIMIT);
    const res = await this.request('/audio/speech', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: model || 'canopylabs/orpheus-v1-english',
        voice: voice || 'autumn',
        input,
        response_format: 'wav',
      }),
      signal,
    });
    return Buffer.from(await res.arrayBuffer());
  }
}

module.exports = {
  GroqClient,
  GroqError,
  errorFromResponse,
  buildMultipartBody,
  imagePart,
  readChatStream,
  SPEECH_INPUT_CHARACTER_LIMIT,
};
