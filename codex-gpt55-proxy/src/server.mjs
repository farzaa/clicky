import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.PORT || 8787);
const CODEX_AUTH_FILE = expandHome(process.env.CODEX_AUTH_FILE || '~/.codex/auth.json');
const CODEX_MODEL = process.env.CODEX_MODEL || 'gpt-5.5';
const CODEX_UPSTREAM_URL = process.env.CODEX_UPSTREAM_URL || 'https://chatgpt.com/backend-api/codex/responses';
const CLICKY_UPSTREAM_WORKER_URL = process.env.CLICKY_UPSTREAM_WORKER_URL || '';
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

async function handleForward(req, res, pathname) {
  if (!CLICKY_UPSTREAM_WORKER_URL) {
    return sendJson(res, 502, {
      error: `No CLICKY_UPSTREAM_WORKER_URL configured for ${pathname}`,
    });
  }

  const upstreamURL = new URL(pathname, CLICKY_UPSTREAM_WORKER_URL).toString();
  const body = await readRequestBody(req);
  const upstream = await fetch(upstreamURL, {
    method: req.method,
    headers: { 'content-type': req.headers['content-type'] || 'application/json' },
    body,
  });

  res.writeHead(upstream.status, {
    'content-type': upstream.headers.get('content-type') || 'application/octet-stream',
  });
  if (upstream.body) {
    for await (const chunk of upstream.body) res.write(chunk);
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
    if (url.pathname === '/tts' || url.pathname === '/transcribe-token') {
      return await handleForward(req, res, url.pathname);
    }
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
