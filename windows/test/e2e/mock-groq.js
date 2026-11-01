'use strict';
/* Tiny Groq look-alike for end-to-end tests (no network, no key needed). */
const http = require('http');

function wavBuffer(ms = 400, rate = 16000) {
  const n = Math.floor((rate * ms) / 1000);
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVE', 8); buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22); buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) buf.writeInt16LE(Math.round(Math.sin(i / 20) * 1200), 44 + i * 2);
  return buf;
}

const MODEL = {
  title: 'Plant cell',
  parts: [
    { name: 'Cell wall', info: 'A rigid outer layer that gives the cell its shape.', shape: 'box', position: [0, 0, 0], size: [3.2, 2.2, 2.2], rotation: [0, 0, 0], color: '#34d399' },
    { name: 'Nucleus', info: 'Holds the DNA and controls the cell.', shape: 'sphere', position: [0.4, 0.2, 0], size: [0.7, 0.7, 0.7], rotation: [0, 0, 0], color: '#6366f1' },
    { name: 'Chloroplast', info: 'Makes sugar from sunlight.', shape: 'capsule', position: [-1.0, 0.5, 0.4], size: [0.22, 0.5, 0.22], rotation: [0, 0, 70], color: '#22c55e' },
    { name: 'Vacuole', info: 'Stores water and keeps the cell firm.', shape: 'sphere', position: [-0.6, -0.5, 0], size: [0.6, 0.6, 0.6], rotation: [0, 0, 0], color: '#60a5fa' },
    { name: 'Mitochondrion', info: 'Releases energy for the cell.', shape: 'capsule', position: [1.0, -0.6, 0.3], size: [0.16, 0.4, 0.16], rotation: [0, 0, 40], color: '#f97316' },
  ],
};

function start({ reply } = {}) {
  const calls = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const url = req.url.replace(/^\/openai\/v1/, '').replace(/^\/v1/, '');
      const raw = Buffer.concat(chunks);
      let body = {};
      try { body = JSON.parse(raw.toString()); } catch (_) { /* multipart */ }
      calls.push({ url, model: body.model, stream: body.stream, json: !!body.response_format });
      if (url === '/models') {
        res.setHeader('Content-Type', 'application/json');
        return res.end(JSON.stringify({ data: [{ id: 'qwen/qwen3.8-27b' }] }));
      }
      if (url === '/audio/transcriptions') {
        res.setHeader('Content-Type', 'application/json');
        return res.end(JSON.stringify({ text: 'how do i save this file' }));
      }
      if (url === '/audio/speech') {
        res.setHeader('Content-Type', 'audio/wav');
        return res.end(wavBuffer());
      }
      if (url === '/chat/completions') {
        if (body.response_format) {
          res.setHeader('Content-Type', 'application/json');
          return res.end(JSON.stringify({ choices: [{ message: { content: JSON.stringify(MODEL) }, finish_reason: 'stop' }] }));
        }
        const text = typeof reply === 'function' ? reply(body) : reply || 'press control and s to save. [POINT:500,500:file menu:screen1]';
        if (!body.stream) {
          res.setHeader('Content-Type', 'application/json');
          return res.end(JSON.stringify({ choices: [{ message: { content: text }, finish_reason: 'stop' }] }));
        }
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });
        const words = text.split(/(?<= )/);
        let i = 0;
        const iv = setInterval(() => {
          if (i >= words.length) {
            res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
            res.write('data: [DONE]\n\n');
            clearInterval(iv);
            return res.end();
          }
          res.write('data: ' + JSON.stringify({ choices: [{ delta: { content: words[i++] } }] }) + '\n\n');
          return undefined;
        }, 15);
        return undefined;
      }
      res.statusCode = 404;
      return res.end('{}');
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, calls })));
}

module.exports = { start, MODEL, wavBuffer };
