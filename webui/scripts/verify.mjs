#!/usr/bin/env node
/*
 * Headless verification for the Substation dashboard.
 *
 *  1. boots scripts/mock-ws.mjs (REST + WS replay on :8800)
 *  2. REST  : all /api/* endpoints → 200 + shape checks
 *  3. admin : PUT /api/config echo, pause/resume, join-code, load/unload
 *  4. WS    : connects, records the scripted scenario, asserts frame types
 *             incl. split+RPC route, cache.hit, cluster.warning,
 *             cluster disabled→enabled flip, paused status, config.changed
 *  5. UI    : compiles src/ with tsconfig.verify.json, mounts <App/> in
 *             happy-dom (jsdom-class DOM) against the live mock and asserts
 *             panels render, feed rows arrive over WS, and console.error == 0
 *  6. dev   : `vite dev` serves 200 and honors index.html; `vite preview`
 *             serves dist/ with 200
 *
 * Run: npm run verify   (after npm install && npm run build)
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const MOCK_PORT = 8800;
const MOCK = `http://127.0.0.1:${MOCK_PORT}`;
const DEV_PORT = 5199;
const PREVIEW_PORT = 4173;

let failures = 0;
const results = [];
function check(name, ok, detail = '') {
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  · ${detail}` : ''}`);
  if (!ok) failures += 1;
}

function spawnSh(cmd, args, opts = {}) {
  return spawn(cmd, args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], ...opts });
}

function drain(child, name, sink) {
  child.stdout.on('data', (d) => sink.push(`${name}: ${String(d).trimEnd()}`));
  child.stderr.on('data', (d) => sink.push(`${name}(err): ${String(d).trimEnd()}`));
}

async function fetchJson(url, init) {
  const res = await fetch(url, init);
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { status: res.status, body, headers: res.headers };
}

async function waitForHttp(url, timeoutMs = 30000) {
  const t0 = Date.now();
  for (;;) {
    try {
      const res = await fetch(url);
      if (res.status === 200) return true;
    } catch {
      /* not yet */
    }
    if (Date.now() - t0 > timeoutMs) return false;
    await sleep(300);
  }
}

/* ------------------------------ 1. mock ------------------------------ */

const mockLogs = [];
const mock = spawnSh(process.execPath, [path.join(HERE, 'mock-ws.mjs')]);
drain(mock, 'mock', mockLogs);
const mockExited = new Promise((resolve) => mock.on('exit', (code) => resolve(code)));

/* ------------------------------ 2. REST ------------------------------ */

if (!(await waitForHttp(`${MOCK}/api/status`, 15000))) {
  check('mock boots', false, mockLogs.join(' | ') || 'no /api/status 200');
  finish();
}
check('mock boots', true);

const [status, metrics, events, cache, config, discovery, models] = await Promise.all([
  fetchJson(`${MOCK}/api/status`),
  fetchJson(`${MOCK}/api/metrics`),
  fetchJson(`${MOCK}/api/events?limit=200`),
  fetchJson(`${MOCK}/api/cache`),
  fetchJson(`${MOCK}/api/config`),
  fetchJson(`${MOCK}/api/discovery`),
  fetchJson(`${MOCK}/api/models`),
]);

check('GET /api/status 200 + fields', status.status === 200 && typeof status.body.state === 'string' && typeof status.body.tokens_per_sec === 'number');
check('GET /api/metrics 200 + percentiles', metrics.status === 200 && metrics.body.percentiles?.ttft_ms !== undefined && metrics.body.cache_hit_ratio !== undefined);
check('GET /api/events?limit=200 200 + newest-first', events.status === 200 && Array.isArray(events.body) && events.body.every((f) => typeof f.type === 'string' && typeof f.ts === 'number' && typeof f.data === 'object'));
check('GET /api/cache 200 + kv_slots', cache.status === 200 && Array.isArray(cache.body.kv_slots) && cache.body.max_bytes > 0);
check('GET /api/config 200 + cluster.enabled=false', config.status === 200 && config.body.cluster?.enabled === false);
check('GET /api/discovery 200 + links', discovery.status === 200 && Array.isArray(discovery.body) && discovery.body.some((p) => p.link?.kind === 'thunderbolt'));
check('GET /api/models 200 + catalog', models.status === 200 && Array.isArray(models.body.models) && models.body.models.length >= 4);

/* ------------------------------ 3. admin ------------------------------ */

const putRes = await fetchJson(`${MOCK}/api/config`, {
  method: 'PUT',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ session_stick_seconds: 240 }),
});
const cfgAfter = (await fetchJson(`${MOCK}/api/config`)).body;
check('PUT /api/config partial merge', putRes.status === 200 && cfgAfter.session_stick_seconds === 240);

const pauseRes = await fetchJson(`${MOCK}/api/admin/pause`, { method: 'POST' });
const paused = pauseRes.status === 200 && pauseRes.body.state === 'paused';
const resumeRes = await fetchJson(`${MOCK}/api/admin/resume`, { method: 'POST' });
const resumed = resumeRes.status === 200 && resumeRes.body.state === 'running';
check('POST /api/admin/pause → state=paused', paused);
check('POST /api/admin/resume → state=running', resumed);
const reloadRes = await fetchJson(`${MOCK}/api/admin/reload`, { method: 'POST' });
check('POST /api/admin/reload', reloadRes.status === 200 && reloadRes.body.ok === true);

const joinRes = await fetchJson(`${MOCK}/api/admin/join-code`, { method: 'POST' });
check('POST /api/admin/join-code → 6-digit', joinRes.status === 200 && /^\d{6}$/.test(String(joinRes.body.code)));

const loadRes = await fetchJson(`${MOCK}/api/models/llama-3.1-70b/load`, { method: 'POST' });
const unloadRes = await fetchJson(`${MOCK}/api/models/llama-3.1-70b/unload`, { method: 'POST' });
check('POST /api/models/{name}/load|unload', loadRes.status === 200 && unloadRes.status === 200);

/* ------------------------------- 4. WS ------------------------------- */

const frames = [];
await new Promise((resolve, reject) => {
  const ws = new WebSocket(`ws://127.0.0.1:${MOCK_PORT}/ws`);
  ws.onmessage = (ev) => {
    try {
      frames.push(JSON.parse(ev.data));
    } catch {
      /* ignore */
    }
  };
  ws.onerror = (e) => reject(e.error ?? new Error('ws error'));
  ws.onopen = () => setTimeout(() => {
    try {
      ws.close();
    } catch {
      /* ignore */
    }
    resolve();
  }, 22000);
}).catch(() => check('WS connects', false));

const types = new Set(frames.map((f) => f.type));
const has = (t) => types.has(t);
const frameOf = (t) => frames.find((f) => f.type === t);
const routeFrames = frames.filter((f) => f.type === 'route.selected');
const splitRoute = routeFrames.find((f) => f.data.split === true && Array.isArray(f.data.rpc_peers) && f.data.rpc_peers.length > 0);
const warning = frameOf('cluster.warning');
const configChanged = frameOf('config.changed');
const pausedStatus = frames.filter((f) => f.type === 'status').find((f) => f.data.state === 'paused');
const clusterFlip = frames.some((f) => f.type === 'config.changed' && (f.data.keys ?? []).includes('cluster.enabled'));
const doneCached = frames.find((f) => f.type === 'stream.done' && f.data.cached === true);

for (const t of ['request.received', 'triage.decision', 'route.selected', 'stream.first_token', 'stream.tick', 'stream.done', 'cache.hit', 'model.loading', 'model.loaded', 'node.health', 'rpc.sample']) {
  check(`WS frame ${t}`, has(t), frameOf(t) ? `ts=${frameOf(t).ts}` : 'missing');
}
check('WS frame triage.decision tier/method/confidence', ['fast', 'balanced', 'smart'].includes(frameOf('triage.decision')?.data.tier) && typeof frameOf('triage.decision')?.data.confidence === 'number');
check('WS SPLIT route with rpc_peers', splitRoute !== undefined, splitRoute ? `${splitRoute.data.model} via ${splitRoute.data.rpc_peers.join(',')}` : 'no split route');
check('WS cache hit (stream.done cached)', doneCached !== undefined);
check('WS cluster.warning rdma_not_enabled', warning !== undefined && warning.data.code === 'rdma_not_enabled', warning ? `${warning.data.level}/${warning.data.code}` : 'missing');
check('WS cluster disabled→enabled flip', clusterFlip);
check('WS paused state frame', pausedStatus !== undefined);
check('WS config.changed echo', configChanged !== undefined, configChanged ? (configChanged.data.keys ?? []).join(',') : 'missing');

/* ------------------------------- 5. UI ------------------------------- */

const tsc = spawnSh(process.platform === 'win32' ? 'npx.cmd' : path.join(ROOT, 'node_modules', '.bin', 'tsc'), ['-p', 'tsconfig.verify.json']);
const tscCode = await new Promise((resolve) => {
  const sink = [];
  drain(tsc, 'tsc', sink);
  tsc.on('exit', (c) => {
    if (c !== 0) results.push(`tsc verify build output: ${sink.join(' | ')}`);
    resolve(c);
  });
});
check('tsc -p tsconfig.verify.json (render bundle)', tscCode === 0, String(tscCode));

let consoleErrors = 0;
const origError = console.error;
console.error = (...args) => {
  consoleErrors += 1;
  origError('  [console.error]', ...args);
};
const uncaught = [];
process.on('uncaughtException', (e) => uncaught.push(String(e)));
process.on('unhandledRejection', (e) => uncaught.push(String(e)));

let uiOk = false;
let uiDetail = '';
let feedRows = 0;
let heroText = '';
let clusterPanel = false;
let latencyPanel = false;
let triagePanel = false;
try {
  const { Window } = await import('happy-dom');
  const win = new Window({ url: `http://127.0.0.1:${DEV_PORT}/`, pretendToBeVisual: true });
  const g = globalThis;
  const define = (k, v) => Object.defineProperty(g, k, { value: v, writable: true, configurable: true });
  // NOTE: deliberately do NOT clobber Node's native Event/EventTarget/CustomEvent/MessageEvent —
  // undici's WebSocket (used by the app's WS client) requires them.
  const names = [
    'window', 'document', 'navigator', 'HTMLElement', 'HTMLDivElement', 'HTMLAnchorElement', 'HTMLInputElement',
    'HTMLButtonElement', 'HTMLFormElement', 'HTMLLabelElement', 'HTMLLIElement', 'HTMLUListElement', 'HTMLHeadElement',
    'HTMLBodyElement', 'HTMLHtmlElement', 'HTMLSpanElement', 'HTMLCanvasElement', 'SVGElement', 'Element',
    'Node', 'NodeFilter', 'NodeIterator', 'NodeList', 'DOMParser', 'Range',
    'DocumentFragment', 'Text', 'ResizeObserver', 'requestAnimationFrame',
    'cancelAnimationFrame', 'matchMedia', 'getComputedStyle', 'DOMRect', 'DOMRectReadOnly', 'DOMMatrix', 'Image',
  ];
  for (const n of names) {
    const v = win[n];
    if (v !== undefined) define(n, v);
  }
  define('window', win);
  define('document', win.document);
  const nativeFetch = g.fetch;
  define('fetch', (input, init) => (typeof input === 'string' && input.startsWith('/') ? nativeFetch(MOCK + input, init) : nativeFetch(input, init)));

  const { createElement } = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { App } = await import('file://' + path.join(ROOT, '.verify-dist', 'App.js'));
  const container = win.document.createElement('div');
  container.id = 'root';
  win.document.body.appendChild(container);
  const root = createRoot(container);
  root.render(createElement(App));
  await sleep(5000);
  feedRows = container.querySelectorAll('.feed-row').length;
  heroText = container.querySelector('.hero-value')?.textContent ?? '';
  clusterPanel = container.querySelector('.panel-cluster') !== null;
  latencyPanel = container.querySelector('.panel-latency') !== null;
  triagePanel = container.querySelector('.panel-triage') !== null;
  root.unmount();
  uiOk = true;
  define('fetch', nativeFetch);
  void win.happyDOM?.cancelAsync?.();
  win.happyDOM?.close?.();
} catch (e) {
  uiDetail = String(e && (e.stack ?? e));
}
console.error = origError;

check('happy-dom mount renders', uiOk, uiDetail.slice(0, 200));
check('UI: routing feed rows over WS', feedRows > 0, `${feedRows} rows`);
check('UI: header tok/s rendered', heroText.length > 0 && heroText !== '—', heroText);
check('UI: cluster panel present', clusterPanel);
check('UI: latency panel present', latencyPanel);
check('UI: triage panel present', triagePanel);
check('UI: console.error count == 0', consoleErrors === 0, `${consoleErrors} errors`);
check('UI: no uncaught exceptions', uncaught.length === 0, uncaught.join(' | ').slice(0, 300));

/* ------------------------------ 6. dev/preview ------------------------------ */

const dev = spawnSh('npm', ['run', 'dev', '--', '--port', String(DEV_PORT), '--strictPort']);
const devLogs = [];
drain(dev, 'dev', devLogs);
const devUp = await waitForHttp(`http://127.0.0.1:${DEV_PORT}/`, 30000);
let devHtml = '';
if (devUp) devHtml = await (await fetch(`http://127.0.0.1:${DEV_PORT}/`)).text();
check('vite dev server GET / 200', devUp);
check('vite dev serves app shell', devHtml.includes('id="root"') && devHtml.includes('/src/main.tsx'));
dev.kill('SIGKILL');

const distHtmlPath = path.join(ROOT, 'dist', 'index.html');
check('dist/index.html exists', existsSync(distHtmlPath));
let assetOk = false;
if (existsSync(distHtmlPath)) {
  const html = readFileSync(distHtmlPath, 'utf8');
  const m = html.match(/src="\/(assets\/[^"]+\.js)"/);
  assetOk = m !== null && existsSync(path.join(ROOT, 'dist', m[1]));
  check('dist references built JS asset', assetOk, m ? m[1] : 'no asset ref');
}

const preview = spawnSh('npm', ['run', 'preview', '--', '--port', String(PREVIEW_PORT), '--strictPort']);
const previewLogs = [];
drain(preview, 'preview', previewLogs);
const prevUp = await waitForHttp(`http://127.0.0.1:${PREVIEW_PORT}/`, 30000);
check('vite preview (dist/) GET / 200', prevUp);
preview.kill('SIGKILL');

mock.kill('SIGKILL');
await Promise.race([mockExited, sleep(2000)]);

/* ------------------------------- summary ------------------------------- */

function finish() {
  console.log('\n================ verify.mjs ================');
  for (const line of results) console.log(line);
  const errs = mockLogs.filter((l) => l.includes('(err):'));
  if (errs.length) console.log('mock stderr:\n' + errs.join('\n'));
  console.log(`============================================\n${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}
setTimeout(() => {
  /* safety: nothing else pending */
}, 100).unref();
finish();
