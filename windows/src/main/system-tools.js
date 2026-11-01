'use strict';
/*
 * Non-mouse tools the agent can use: open urls/apps, search, fetch pages,
 * clipboard, files, windows, and (approved) PowerShell.
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const { runPowerShell, psQuote } = require('./powershell');

function isSafeHttpUrl(u) {
  try {
    const url = new URL(u);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch (_) {
    return false;
  }
}

function htmlToText(html, max = 6000) {
  return String(html)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max);
}

function parseDuckDuckGo(html, limit = 6) {
  const out = [];
  const re = /<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?(?:class="result__snippet"[^>]*>([\s\S]*?)<\/a>)?/g;
  let m;
  while ((m = re.exec(html)) && out.length < limit) {
    let href = m[1];
    const u = /uddg=([^&]+)/.exec(href);
    if (u) href = decodeURIComponent(u[1]);
    out.push({ url: href, title: htmlToText(m[2], 140), snippet: htmlToText(m[3] || '', 240) });
  }
  return out;
}

function safeAppName(name) {
  return /^[\w .\-+()]{1,60}$/.test(name);
}

function createSystemTools({ shell, clipboard, fetchImpl = (...a) => fetch(...a), documentsDir, run = runPowerShell, platform = process.platform }) {
  const workDir = path.join(documentsDir || path.join(os.homedir(), 'Documents'), 'Clicky');
  const homeDir = os.homedir();

  function insideAllowedRoot(p) {
    const resolved = path.resolve(p);
    return resolved.startsWith(path.resolve(homeDir)) && !/[\\/]\.(ssh|aws|gnupg)([\\/]|$)/i.test(resolved);
  }

  return {
    workDir,
    async openUrl(url) {
      if (!isSafeHttpUrl(url)) return { ok: false, error: 'Only http and https links can be opened.' };
      await shell.openExternal(url);
      return { ok: true, opened: url };
    },
    async openApp(name) {
      if (!safeAppName(name)) return { ok: false, error: 'That app name looks unsafe.' };
      if (platform !== 'win32') return { ok: false, error: 'Opening apps is only supported on Windows.' };
      const script = `try { Start-Process ${psQuote(name)} -ErrorAction Stop; 'ok' } catch { 'ERR: ' + $_.Exception.Message }`;
      const r = await run(script, { timeoutMs: 10000 });
      if (/^ERR/.test(r.stdout)) {
        // fall back to the Start menu search: win key, type, enter is handled by the agent
        return { ok: false, error: r.stdout.slice(5) };
      }
      return { ok: true, opened: name };
    },
    async webSearch(query) {
      const res = await fetchImpl('https://html.duckduckgo.com/html/?q=' + encodeURIComponent(query), {
        headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Clicky' },
      });
      const html = await res.text();
      const results = parseDuckDuckGo(html);
      return { ok: true, results };
    },
    async fetchPage(url) {
      if (!isSafeHttpUrl(url)) return { ok: false, error: 'Only http and https pages can be read.' };
      const res = await fetchImpl(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Clicky' } });
      const text = await res.text();
      return { ok: true, status: res.status, text: htmlToText(text) };
    },
    readClipboard() {
      return { ok: true, text: clipboard.readText().slice(0, 4000) };
    },
    writeClipboard(text) {
      clipboard.writeText(String(text));
      return { ok: true };
    },
    saveFile(name, content) {
      const safe = String(name).replace(/[\\/:*?"<>|]/g, '_').slice(0, 120) || 'note.txt';
      fs.mkdirSync(workDir, { recursive: true });
      const full = path.join(workDir, safe);
      fs.writeFileSync(full, String(content), 'utf8');
      return { ok: true, path: full };
    },
    listFiles(dir) {
      const target = dir ? path.resolve(dir) : workDir;
      if (!insideAllowedRoot(target)) return { ok: false, error: 'That folder is outside your user folder.' };
      try {
        const entries = fs.readdirSync(target, { withFileTypes: true }).slice(0, 100);
        return { ok: true, dir: target, entries: entries.map((e) => (e.isDirectory() ? e.name + '/' : e.name)) };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },
    readFile(file) {
      const target = path.resolve(file);
      if (!insideAllowedRoot(target)) return { ok: false, error: 'That file is outside your user folder.' };
      try {
        const stat = fs.statSync(target);
        if (stat.size > 2 * 1024 * 1024) return { ok: false, error: 'File is too large to read.' };
        return { ok: true, text: fs.readFileSync(target, 'utf8').slice(0, 8000) };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    },
    async listWindows() {
      if (platform !== 'win32') return { ok: true, windows: [] };
      const r = await run(
        "Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object -First 40 Id,ProcessName,MainWindowTitle,@{n='Handle';e={[int64]$_.MainWindowHandle}} | ConvertTo-Json -Compress",
        { timeoutMs: 8000 }
      );
      try {
        let j = JSON.parse(r.stdout || '[]');
        if (!Array.isArray(j)) j = [j];
        return {
          ok: true,
          windows: j.map((w) => ({ id: w.Handle, app: w.ProcessName, title: w.MainWindowTitle })),
        };
      } catch (_) {
        return { ok: true, windows: [] };
      }
    },
    async runPowerShell(script) {
      const r = await run(String(script), { timeoutMs: 30000 });
      return { ok: r.code === 0, code: r.code, stdout: r.stdout.slice(0, 4000), stderr: r.stderr.slice(0, 1500) };
    },
  };
}

module.exports = { createSystemTools, isSafeHttpUrl, htmlToText, parseDuckDuckGo, safeAppName };
