import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { ProxyAgent } from 'undici';
import os from 'node:os';
import path from 'node:path';

loadDotEnv(path.join(process.cwd(), '.env'));

const PORT = Number(process.env.PORT || 8877);
const CODEX_AUTH_FILE = expandHome(process.env.CODEX_AUTH_FILE || '~/.codex/auth.json');
const CODEX_MODEL = process.env.CODEX_MODEL || 'gpt-5.5';
const CODEX_UPSTREAM_URL = process.env.CODEX_UPSTREAM_URL || 'https://chatgpt.com/backend-api/codex/responses';
const DEEPGRAM_API_KEY=process.env.DEEPGRAM_API_KEY || '';
const DEEPGRAM_STT_MODEL = process.env.DEEPGRAM_STT_MODEL || 'nova-3';
const DEEPGRAM_TTS_MODEL = process.env.DEEPGRAM_TTS_MODEL || 'aura-2-thalia-en';
const DEEPGRAM_TTS_ENCODING = process.env.DEEPGRAM_TTS_ENCODING || 'mp3';
const AGENT_VAULT_ADDR = process.env.AGENT_VAULT_ADDR || '';
const AGENT_VAULT_TOKEN = process.env.AGENT_VAULT_TOKEN || process.env.AGENT_VAULT_SESSION_TOKEN || '';
const AGENT_VAULT_VAULT = process.env.AGENT_VAULT_VAULT || 'default';
const AGENT_VAULT_PROXY = process.env.AGENT_VAULT_PROXY || '';
const AGENT_VAULT_CA_FILE = process.env.AGENT_VAULT_CA_FILE || '';
const CODEX_BIN = process.env.CODEX_BIN || firstExisting([
  path.join(os.homedir(), '.local/bin/codex'),
  '/Applications/Codex.app/Contents/Resources/codex',
  'codex',
]);

function expandHome(value) {
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return value;
}

function firstExisting(candidates) {
  return candidates.find((candidate) => candidate === 'codex' || existsSync(candidate)) || 'codex';
}

function deepgramFetchOptions(extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (DEEPGRAM_API_KEY) {
    headers.authorization = `Token ${DEEPGRAM_API_KEY}`;
    return { headers };
  }

  if (!AGENT_VAULT_TOKEN) {
    throw new Error('Missing DEEPGRAM_API_KEY or AGENT_VAULT_TOKEN');
  }

  if (AGENT_VAULT_VAULT) {
    headers['X-Vault'] = AGENT_VAULT_VAULT;
  }

  const dispatcher = agentVaultDispatcher();
  if (!dispatcher) {
    throw new Error('Agent Vault is configured but missing a valid HTTPS proxy URL or readable AGENT_VAULT_CA_FILE');
  }
  return { headers, dispatcher };
}

function agentVaultDispatcher() {
  if (!AGENT_VAULT_TOKEN) return undefined;
  const proxyURL = agentVaultProxyURL();
  if (!proxyURL) return undefined;
  const proxyCA = agentVaultProxyCA();
  if (!proxyCA) return undefined;

  const token = Buffer.from(`${AGENT_VAULT_TOKEN}:`).toString('base64');
  return new ProxyAgent({
    uri: proxyURL,
    token: `Basic ${token}`,
    proxyTls: { ca: proxyCA },
    requestTls: { ca: proxyCA },
  });
}

function agentVaultProxyURL() {
  const configuredProxyURL = AGENT_VAULT_PROXY || '';
  if (configuredProxyURL) {
    try {
      const proxyURL = new URL(configuredProxyURL);
      return proxyURL.protocol === 'https:' ? proxyURL.toString() : '';
    } catch {
      return '';
    }
  }

  if (!AGENT_VAULT_ADDR) return '';
  try {
    const vaultURL = new URL(AGENT_VAULT_ADDR);
    return `https://${vaultURL.hostname}:14322`;
  } catch {
    return '';
  }
}

function agentVaultProxyCA() {
  if (!AGENT_VAULT_CA_FILE) return undefined;
  try {
    return readFileSync(expandHome(AGENT_VAULT_CA_FILE));
  } catch (error) {
    console.error(`[Agent Vault] unable to read AGENT_VAULT_CA_FILE: ${error.message}`);
    return undefined;
  }
}

function loadDotEnv(filePath) {
  if (!existsSync(filePath)) return;
  const raw = readFileSync(filePath, 'utf8');
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const equals = trimmed.indexOf('=');
    if (equals === -1) continue;
    const key = trimmed.slice(0, equals).trim();
    if (!key || process.env[key] !== undefined) continue;
    let value = trimmed.slice(equals + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

async function readCodexTokens() {
  const raw = await readFile(CODEX_AUTH_FILE, 'utf8');
  const auth = JSON.parse(raw);
  if (auth.auth_mode !== 'chatgpt' || !auth.tokens?.access_token) {
    throw new Error(`${CODEX_AUTH_FILE} does not contain ChatGPT OAuth Codex tokens. Run: codex login`);
  }
  return auth.tokens;
}

async function refreshCodexTokens() {
  await new Promise((resolve, reject) => {
    const child = spawn(CODEX_BIN, ['debug', 'models'], {
      stdio: ['ignore', 'ignore', 'pipe'],
      env: process.env,
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`codex debug models exited ${code}: ${stderr}`));
    });
  });
  return readCodexTokens();
}

function anthropicContentToResponsesInputContent(content) {
  if (typeof content === 'string') {
    return [{ type: 'input_text', text: content }];
  }

  const output = [];
  for (const block of Array.isArray(content) ? content : []) {
    if (block?.type === 'text' && typeof block.text === 'string') {
      output.push({ type: 'input_text', text: block.text });
      continue;
    }

    if (block?.type === 'image' && block.source?.type === 'base64') {
      const mediaType = block.source.media_type || 'image/jpeg';
      output.push({
        type: 'input_image',
        image_url: `data:${mediaType};base64,${block.source.data}`,
      });
    }
  }
  return output;
}

function anthropicMessagesToResponsesInput(messages = []) {
  return messages.map((message) => {
    const role = message.role === 'assistant' ? 'assistant' : 'user';
    if (role === 'assistant') {
      const text = typeof message.content === 'string'
        ? message.content
        : (Array.isArray(message.content) ? message.content.map((b) => b?.text || '').join('\n') : '');
      return { role, content: [{ type: 'output_text', text }] };
    }
    return { role, content: anthropicContentToResponsesInputContent(message.content) };
  });
}

function buildResponsesPayload(anthropicBody) {
  return {
    model: process.env.CODEX_MODEL || CODEX_MODEL,
    instructions: anthropicBody.system || 'You are Clicky, a concise screen-aware assistant.',
    input: anthropicMessagesToResponsesInput(anthropicBody.messages),
    stream: true,
    store: false,
    reasoning: { effort: process.env.CODEX_REASONING_EFFORT || 'low' },
    text: { verbosity: process.env.CODEX_TEXT_VERBOSITY || 'medium' },
  };
}

function sseAnthropicDelta(text) {
  return `event: content_block_delta\ndata: ${JSON.stringify({
    type: 'content_block_delta',
    index: 0,
    delta: { type: 'text_delta', text },
  })}\n\n`;
}

async function handleChat(req, res) {
  const rawBody = await readRequestBody(req);
  let anthropicBody;
  try {
    anthropicBody = JSON.parse(rawBody || '{}');
  } catch {
    return sendJson(res, 400, { error: 'Invalid JSON body' });
  }

  const responsesPayload = buildResponsesPayload(anthropicBody);
  let tokens = await readCodexTokens();
  let upstream = await callCodexResponses(responsesPayload, tokens);
  if (upstream.status === 401) {
    tokens = await refreshCodexTokens();
    upstream = await callCodexResponses(responsesPayload, tokens);
  }

  if (!upstream.ok || !upstream.body) {
    const text = await upstream.text();
    console.error(`[/chat] Codex GPT-5.5 upstream error ${upstream.status}: ${text}`);
    res.writeHead(upstream.status, { 'content-type': 'application/json' });
    res.end(text || JSON.stringify({ error: `Codex upstream error ${upstream.status}` }));
    return;
  }

  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });

  const decoder = new TextDecoder();
  let buffer = '';

  for await (const chunk of upstream.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let eventEnd;
    while ((eventEnd = buffer.indexOf('\n\n')) !== -1) {
      const eventBlock = buffer.slice(0, eventEnd);
      buffer = buffer.slice(eventEnd + 2);
      for (const line of eventBlock.split('\n')) {
        if (!line.startsWith('data: ')) continue;
        const data = line.slice(6);
        if (data === '[DONE]') continue;
        try {
          const event = JSON.parse(data);
          if (event.type === 'response.output_text.delta' && event.delta) {
            res.write(sseAnthropicDelta(event.delta));
          }
        } catch {
          // Ignore malformed upstream event lines.
        }
      }
    }
  }

  res.write('data: [DONE]\n\n');
  res.end();
}

async function callCodexResponses(payload, tokens) {
  const headers = {
    authorization: `Bearer ${tokens.access_token}`,
    'content-type': 'application/json',
  };
  if (tokens.account_id) {
    headers['chatgpt-account-id'] = tokens.account_id;
  }
  return fetch(CODEX_UPSTREAM_URL, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
  });
}

async function handleTranscribe(req, res) {
  if (!DEEPGRAM_API_KEY && !AGENT_VAULT_TOKEN) {
    return sendJson(res, 500, { error: 'Missing DEEPGRAM_API_KEY or AGENT_VAULT_TOKEN' });
  }

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const audioBody = Buffer.concat(chunks);
  if (!audioBody.length) {
    return sendJson(res, 400, { error: 'Missing audio body' });
  }

  const upstreamURL = new URL('https://api.deepgram.com/v1/listen');
  upstreamURL.searchParams.set('model', DEEPGRAM_STT_MODEL);
  upstreamURL.searchParams.set('smart_format', 'true');
  upstreamURL.searchParams.set('punctuate', 'true');
  upstreamURL.searchParams.set('language', 'en');

  const upstream = await fetch(upstreamURL, {
    method: 'POST',
    ...deepgramFetchOptions({
      'content-type': req.headers['content-type'] || 'audio/wav',
      accept: 'application/json',
    }),
    body: audioBody,
  });

  await pipeUpstreamResponse(res, upstream, 'application/json', 'Deepgram transcription');
}

async function handleTTS(req, res) {
  if (!DEEPGRAM_API_KEY && !AGENT_VAULT_TOKEN) {
    return sendJson(res, 500, { error: 'Missing DEEPGRAM_API_KEY or AGENT_VAULT_TOKEN' });
  }

  const rawBody = await readRequestBody(req);
  let text = '';
  try {
    const parsed = JSON.parse(rawBody || '{}');
    text = typeof parsed.text === 'string' ? parsed.text : '';
  } catch {
    return sendJson(res, 400, { error: 'Invalid JSON body' });
  }
  if (!text.trim()) {
    return sendJson(res, 400, { error: 'Missing text' });
  }

  const upstreamURL = new URL('https://api.deepgram.com/v1/speak');
  upstreamURL.searchParams.set('model', DEEPGRAM_TTS_MODEL);
  upstreamURL.searchParams.set('encoding', DEEPGRAM_TTS_ENCODING);

  const upstream = await fetch(upstreamURL, {
    method: 'POST',
    ...deepgramFetchOptions({
      'content-type': 'application/json',
      accept: 'audio/mpeg',
    }),
    body: JSON.stringify({ text }),
  });

  await pipeUpstreamResponse(res, upstream, 'audio/mpeg', 'Deepgram TTS');
}

async function pipeUpstreamResponse(res, upstream, fallbackContentType, label) {
  const contentType = upstream.headers.get('content-type') || fallbackContentType;
  res.writeHead(upstream.status, { 'content-type': contentType });
  if (upstream.body) {
    for await (const chunk of upstream.body) res.write(chunk);
  } else if (!upstream.ok) {
    const text = await upstream.text();
    console.error(`[${label}] upstream error ${upstream.status}: ${text}`);
    res.write(text);
  }
  res.end();
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function sendJson(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(value));
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
    if (req.method === 'GET' && url.pathname === '/health') {
      return sendJson(res, 200, { ok: true, model: CODEX_MODEL });
    }
    if (req.method !== 'POST') {
      res.writeHead(405, { 'content-type': 'text/plain' });
      res.end('Method not allowed');
      return;
    }
    if (url.pathname === '/chat') return await handleChat(req, res);
    if (url.pathname === '/tts') return await handleTTS(req, res);
    if (url.pathname === '/transcribe') return await handleTranscribe(req, res);
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('Not found');
  } catch (error) {
    console.error(`[server] ${error?.stack || error}`);
    sendJson(res, 500, { error: String(error?.message || error) });
  }
});

if (process.argv.includes('--smoke')) {
  const tokens = await readCodexTokens();
  console.log(JSON.stringify({ ok: true, hasAccessToken: Boolean(tokens.access_token), accountId: Boolean(tokens.account_id), model: CODEX_MODEL }));
} else {
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`Clicky Codex GPT-5.5 proxy listening on http://127.0.0.1:${PORT}`);
  });
}
