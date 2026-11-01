'use strict';
/*
 * Headless end-to-end run: starts the mock Groq server, launches the real Electron app under
 * Xvfb with a scenario script, and collects screenshots in test/e2e/out.
 */
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const mock = require('./mock-groq');

(async () => {
  const root = path.join(__dirname, '..', '..');
  const out = path.join(__dirname, 'out');
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'clicky-e2e-'));
  const reply = 'sure thing, open the file menu at the top left and hit save. [DRAW:circle:300,250,60:save here] [DRAW:arrow:600,600,330,270:start here] [DRAW:step:300,250:1] [CARD:Saving files|Press ctrl and s in almost any app to save quickly.|floppy disk] [POINT:300,250:file menu:screen1]';
const { server, port, calls } = await mock.start({ reply });
  const electron = require(path.join(root, 'node_modules', 'electron'));
  const env = Object.assign({}, process.env, {
    CLICKY_GROQ_BASE_URL: `http://127.0.0.1:${port}`,
    CLICKY_USER_DATA: userData,
    CLICKY_E2E_OUT: out,
    CLICKY_E2E_MIC: '1',
    GROQ_API_KEY: 'gsk_e2e_test_key',
  });
  const args = ['--no-sandbox', '--disable-gpu-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', root, '--e2e', '--e2e-script=' + path.join(__dirname, 'scenario.js')];
  const useXvfb = !process.env.DISPLAY && process.platform === 'linux';
  const cmd = useXvfb ? 'xvfb-run' : electron;
  const full = useXvfb ? ['-a', '-s', '-screen 0 1920x1080x24', electron, ...args] : args;
  const child = spawn(cmd, full, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', (d) => { log += d; process.stdout.write(d); });
  child.stderr.on('data', (d) => { log += d; });
  const timer = setTimeout(() => { console.error('E2E timeout'); child.kill('SIGKILL'); }, 150000);
  child.on('exit', (code) => {
    clearTimeout(timer);
    server.close();
    fs.writeFileSync(path.join(out, 'log.txt'), log);
    fs.writeFileSync(path.join(out, 'groq-calls.json'), JSON.stringify(calls, null, 2));
    console.log('e2e exit code', code, '| groq calls:', calls.length);
    process.exit(code || 0);
  });
})();
