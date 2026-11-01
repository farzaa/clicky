'use strict';
const { spawn } = require('child_process');

const isWindows = () => process.platform === 'win32';

function encode(script) {
  return Buffer.from(script, 'utf16le').toString('base64');
}

// Runs a PowerShell script; resolves {code, stdout, stderr}. Never rejects.
function runPowerShell(script, { timeoutMs = 20000, signal } = {}) {
  return new Promise((resolve) => {
    if (!isWindows()) return resolve({ code: -1, stdout: '', stderr: 'PowerShell is only available on Windows.' });
    const wrapped = '$ProgressPreference="SilentlyContinue";[Console]::OutputEncoding=[Text.Encoding]::UTF8;' + script;
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(wrapped)],
      { windowsHide: true }
    );
    let stdout = '';
    let stderr = '';
    let done = false;
    const finish = (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    };
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch (_) {
        /* ignore */
      }
      stderr += '\n(timed out)';
      finish(-2);
    }, timeoutMs);
    if (signal) signal.addEventListener('abort', () => { try { child.kill(); } catch (_) { /* ignore */ } finish(-3); });
    child.stdout.on('data', (d) => (stdout += d.toString('utf8')));
    child.stderr.on('data', (d) => (stderr += d.toString('utf8')));
    child.on('error', (e) => {
      stderr += String(e.message);
      finish(-1);
    });
    child.on('close', (code) => finish(code));
  });
}

// single-quote escape for embedding in a PowerShell string literal
function psQuote(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

module.exports = { runPowerShell, psQuote, encode, isWindows };
