'use strict';
const fs = require('fs');
const path = require('path');

let logFile = null;
const MAX_BYTES = 1024 * 1024;

function init(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true });
    logFile = path.join(dir, 'clicky.log');
    try {
      if (fs.statSync(logFile).size > MAX_BYTES) fs.renameSync(logFile, logFile + '.old');
    } catch (_) {
      /* no previous log */
    }
  } catch (_) {
    logFile = null;
  }
}

function write(level, args) {
  const line =
    new Date().toISOString() +
    ' [' +
    level +
    '] ' +
    args.map((a) => (a instanceof Error ? a.stack || a.message : typeof a === 'string' ? a : safeJson(a))).join(' ');
  if (level === 'error') console.error(line);
  else console.log(line);
  if (logFile) {
    try {
      fs.appendFileSync(logFile, line + '\n');
    } catch (_) {
      /* ignore */
    }
  }
}

function safeJson(v) {
  try {
    return JSON.stringify(v);
  } catch (_) {
    return String(v);
  }
}

module.exports = {
  init,
  info: (...a) => write('info', a),
  warn: (...a) => write('warn', a),
  error: (...a) => write('error', a),
  get file() {
    return logFile;
  },
};
