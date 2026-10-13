#!/usr/bin/env node
/*
 * Substation mock daemon — zero-dependency Node WS + REST replay on :8800.
 *
 * Implements the observability surface from docs/PROTOCOL.md:
 *   GET  /api/status /api/metrics /api/events?limit=200 /api/cache /api/config
 *        /api/discovery /api/models /api/nodes
 *   PUT  /api/config            (partial merge → broadcasts config.changed)
 *   POST /api/admin/pause|resume|reload|join-code
 *   POST /api/models/{name}/load|unload
 *   WS   /ws  → {type, ts, data} frames (request.received … cluster.warning)
 *
 * Scripted scenario: realistic request traffic (tiers, split+RPC requests,
 * cache hits), model loading lifecycle, cluster disabled→enabled flip,
 * cluster.warning RDMA banner, paused state window, config.changed echo.
 *
 * Run: node scripts/mock-ws.mjs [--port 8800] [--seed N]
 */
import { createServer } from 'node:http';
import { createHash, randomUUID } from 'node:crypto';

const args = process.argv.slice(2);
const portArg = args.indexOf('--port');
const PORT = portArg >= 0 ? Number(args[portArg + 1]) : 8800;

/* ------------------------------ helpers ------------------------------ */

const now = () => Date.now();
const rand = (a, b) => a + Math.random() * (b - a);
const randInt = (a, b) => Math.floor(rand(a, b + 1));
const pick = (arr) => arr[randInt(0, arr.length - 1)];
const chance = (p) => Math.random() < p;
const round = (v, d = 2) => Number(v.toFixed(d));

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

/* ------------------------------- state ------------------------------- */

const state = {
  bootedAt: now(),
  paused: false,
  config: {
    cluster: { enabled: false, heartbeat_ms: 2000 },
    default_ctx: 8192,
    session_stick_seconds: 300,
    max_concurrent_requests: 8,
    triage_timeout_ms: 250,
    triage_upgrade_confidence: 0.8,
    cache_enabled: true,
    cache_max_entries: 256,
    cache_max_bytes_mb: 512,
    idle_evict_seconds: 900,
    min_free_ram_gb: 8,
  },
  models: [
    { name: 'qwen2.5-0.5b', state: 'loaded', node: 'studio0', size_gb: 0.4, ctx: 4096 },
    { name: 'qwen2.5-1.5b', state: 'loaded', node: 'studio0', size_gb: 1.1, ctx: 8192 },
    { name: 'qwen2.5-7b', state: 'loaded', node: 'studio0', size_gb: 4.4, ctx: 8192 },
    { name: 'qwen2.5-32b', state: 'unloaded', node: 'studio0', size_gb: 19.8, ctx: 16384, split: true, rpc_peers: ['studio1:50052'] },
    { name: 'llama-3.1-70b', state: 'unloaded', node: 'studio0', size_gb: 41.2, ctx: 8192, split: true, rpc_peers: ['studio1:50052', 'studio2:50052'] },
  ],
  nodes: {
    studio0: { node: 'studio0', ram_used_gb: 96, ram_total_gb: 256, gpu_pct: 22, runners: [], rpc_up: true },
    studio1: { node: 'studio1', ram_used_gb: 71, ram_total_gb: 256, gpu_pct: 12, runners: [], rpc_up: true },
  },
  cache: {
    hit_ratio: 0.24,
    entries: 84,
    max_entries: 256,
    bytes: 118 * 1024 * 1024,
    max_bytes: 512 * 1024 * 1024,
    kv_slots: [
      { engine: 'qwen2.5-1.5b', used: 2, total: 4 },
      { engine: 'qwen2.5-7b', used: 3, total: 4 },
      { engine: 'qwen2.5-32b', used: 1, total: 2 },
    ],
  },
  discovery: [
    { node_id: 'studio1', name: 'studio1', ip: '10.99.1.2', agent_port: 8801, seen_ms_ago: 380, link: { kind: 'thunderbolt', rtt_ms: 0.42, mbps: 9600, rdma: false } },
    { node_id: 'studio2', name: 'mbp-jeff', ip: '192.168.7.121', agent_port: 8801, seen_ms_ago: 2200, link: { kind: 'wifi', rtt_ms: 38, mbps: 412, rdma: false } },
  ],
  events: [],
  active: new Map(),
  reqTimes: [],
  ttftSamples: [],
  totalSamples: [],
  counters: { requests: 0, triage: { fast: 0, balanced: 0, smart: 0 }, hits: 0, done: 0 },
};

const clients = new Set();

const TIER_MODEL = { fast: 'qwen2.5-1.5b', balanced: 'qwen2.5-7b', smart: 'qwen2.5-32b' };
const TIER_TPS = { fast: [55, 140], balanced: [26, 55], smart: [6.5, 14] };
const REASONS = {
  fast: ['triage fast: short/greeting signal (0.94)', 'session sticky (fast)', 'fast tier: low window pressure', 'heuristic fallback: heuristic length<80'],
  balanced: ['triage balanced: code-ish signals (0.86)', 'window pressure: ctx 6.2k/8k', 'session sticky (balanced)', 'balanced tier: repo Q&A shape'],
  smart: ['triage smart: multi-file plan (0.91)', 'smart tier: agentic tool-loop detected', 'smart tier: reasoning chain detected'],
};

function status() {
  let liveTps = 0;
  for (const s of state.active.values()) liveTps += s.tps;
  return {
    state: state.paused ? 'paused' : 'running',
    uptime_s: Math.floor((now() - state.bootedAt) / 1000),
    requests_active: state.active.size,
    requests_per_min: state.reqTimes.filter((t) => now() - t < 60_000).length,
    tokens_per_sec: round(liveTps, 1),
    models_loaded: state.models.filter((m) => m.state === 'loaded').length,
    models_total: state.models.length,
    cache_hit_ratio: round(state.cache.hit_ratio, 3),
    nodes: Object.values(state.nodes),
  };
}

/* ------------------------------ WS plumbing ------------------------------ */

function sendFrame(type, data) {
  const frame = { type, ts: now(), data };
  state.events.push(frame);
  if (state.events.length > 200) state.events.splice(0, state.events.length - 200);
  const payload = encodeText(JSON.stringify(frame));
  for (const c of clients) {
    try {
      c.write(payload);
    } catch {
      clients.delete(c);
    }
  }
}

function encodeText(str) {
  const payload = Buffer.from(str, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

/* minimal client→server frame reader: we only need close/ping handling */
function attachSocket(socket) {
  let buf = Buffer.alloc(0);
  socket.setNoDelay(true);
  clients.add(socket);
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < off + 2) return;
        len = buf.readUInt16BE(off);
        off += 2;
      } else if (len === 127) {
        if (buf.length < off + 8) return;
        len = Number(buf.readBigUInt64BE(off));
        off += 8;
      }
      let mask = null;
      if (masked) {
        if (buf.length < off + 4) return;
        mask = buf.subarray(off, off + 4);
        off += 4;
      }
      if (buf.length < off + len) return;
      const payload = Buffer.from(buf.subarray(off, off + len));
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      buf = buf.subarray(off + len);
      if (opcode === 0x8) {
        try {
          socket.end(Buffer.from([0x88, 0x00]));
        } catch { /* ignore */ }
        clients.delete(socket);
        return;
      }
      if (opcode === 0x9 && fin) {
        try {
          socket.write(Buffer.concat([Buffer.from([0x8a, payload.length]), payload]));
        } catch { /* ignore */ }
      }
    }
  });
  const drop = () => clients.delete(socket);
  socket.on('close', drop);
  socket.on('error', drop);
}

/* ------------------------------ traffic sim ------------------------------ */

function tierPick(virtual) {
  if (virtual === 'auto-fast') return 'fast';
  if (virtual === 'auto-smart') return 'smart';
  const r = Math.random();
  if (r < 0.52) return 'fast';
  if (r < 0.83) return 'balanced';
  return 'smart';
}

function spawnRequest() {
  if (state.paused) return;
  const id = randomUUID();
  const virtual = chance(0.62) ? 'auto' : chance(0.55) ? 'auto-fast' : 'auto-smart';
  state.counters.requests += 1;
  state.reqTimes.push(now());
  sendFrame('request.received', { id, virtual_model: virtual, bytes: randInt(180, 4200), session: `sess-${randomUUID().slice(0, 8)}` });

  const tier = tierPick(virtual);
  const model = TIER_MODEL[tier];
  const card = state.models.find((m) => m.name === model);
  const split = Boolean(card?.split) && card?.state === 'loaded';
  const method = chance(0.78) ? 'model' : 'heuristic';
  const confidence = round(rand(method === 'model' ? 0.66 : 0.5, method === 'model' ? 0.99 : 0.9), 2);
  const triageMs = randInt(method === 'model' ? 40 : 3, method === 'model' ? 240 : 12);

  const stream = { id, tier, tps: 0 };
  state.active.set(id, stream);

  setTimeout(() => {
    if (!state.active.has(id)) return;
    state.counters.triage[tier] += 1;
    sendFrame('triage.decision', { id, tier, confidence, method, ms: triageMs });
    setTimeout(() => {
      if (!state.active.has(id)) return;
      sendFrame('route.selected', {
        id,
        model: model,
        node: 'studio0',
        split,
        rpc_peers: split ? card?.rpc_peers ?? [] : [],
        reason: pick(REASONS[tier]),
      });
      const waiter = chance(0.28) ? pick(['loading', 'queued', 'cache']) : null;
      const waitMs = waiter === 'loading' ? randInt(900, 2600) : waiter === 'queued' ? randInt(40, 320) : randInt(1, 8);
      if (waiter) sendFrame('engine.wait', { id, ms: waitMs, reason: waiter });

      const isCacheHit = chance(0.26);
      const ttft = Math.round(waitMs + rand(80, tier === 'smart' ? 900 : 420));

      if (isCacheHit) {
        state.counters.hits += 1;
        state.cache.entries = Math.min(state.cache.max_entries, state.cache.entries + 1);
        setTimeout(() => {
          if (!state.active.delete(id)) return;
          sendFrame('cache.hit', { id, model });
          const totalMs = ttft + randInt(40, 160);
          state.totalSamples.push(totalMs);
          sendFrame('stream.done', { id, total_tokens: randInt(80, 900), ms: totalMs, cached: true });
          state.counters.done += 1;
        }, 30);
        return;
      }

      setTimeout(() => {
        if (!state.active.has(id)) return;
        state.ttftSamples.push(ttft);
        sendFrame('stream.first_token', { id, ttft_ms: ttft });
        const [lo, hi] = TIER_TPS[tier];
        let base = rand(lo, hi);
        let tokens = 0;
        const ticks = randInt(4, 9);
        let sent = 0;
        const timer = setInterval(() => {
          if (!state.active.has(id)) {
            clearInterval(timer);
            return;
          }
          sent += 1;
          base = Math.max(lo * 0.6, Math.min(hi, base + rand(-6, 6)));
          stream.tps = round(base, 1);
          const batchTokens = randInt(2, 6);
          tokens += batchTokens;
          sendFrame('stream.tick', { id, tokens: batchTokens, tok_per_s: round(base, 1) });
          if (sent >= ticks) {
            clearInterval(timer);
            stream.tps = 0;
            if (!state.active.delete(id)) return;
            const totalMs = ttft + ticks * 250 + randInt(10, 120);
            state.totalSamples.push(totalMs);
            sendFrame('stream.done', { id, total_tokens: tokens, ms: totalMs, cached: false });
            state.counters.done += 1;
            const hits = state.counters.hits;
            const done = state.counters.done;
            if (done > 0) state.cache.hit_ratio = state.cache.hit_ratio * 0.9 + (hits / done) * 0.1;
          }
        }, 250);
      }, 30);
    }, randInt(30, 140));
  }, randInt(45, 260));
}

/* --------------------------- cluster scenarios --------------------------- */

function flipCluster(on, note) {
  state.config.cluster.enabled = on;
  if (on) {
    for (const id of Object.keys(state.nodes)) state.nodes[id].rpc_up = true;
  }
  sendFrame('config.changed', { keys: ['cluster.enabled'] });
  sendFrame('status', status());
  if (note) console.log(`[mock] ${note}`);
}

function scenario() {
  const at = (sec, fn) => setTimeout(fn, sec * 1000);

  // t+1.5s — smart-tier model loads with RPC split
  at(1.5, () => {
    const card = state.models.find((m) => m.name === 'qwen2.5-32b');
    if (!card) return;
    card.state = 'loading';
    sendFrame('model.loading', { model: 'qwen2.5-32b', node: 'studio0', gb: 19.8, ms: 2600 });
    state.nodes.studio0.runners = [{ model: 'qwen2.5-1.5b', port: 8940, state: 'ok', tok_s: 92 }, { model: 'qwen2.5-7b', port: 8941, state: 'ok', tok_s: 38 }, { model: 'qwen2.5-32b', port: 8942, state: 'loading' }];
    state.nodes.studio1.runners = [{ model: 'qwen2.5-32b (rpc shard)', port: 50052, state: 'rpc' }];
  });
  at(3.2, () => {
    const card = state.models.find((m) => m.name === 'qwen2.5-32b');
    if (!card) return;
    card.state = 'loaded';
    sendFrame('model.loaded', { model: 'qwen2.5-32b', node: 'studio0', gb: 19.8, ms: 2640 });
    const r = state.nodes.studio0.runners.find((x) => x.model === 'qwen2.5-32b');
    if (r) r.state = 'ok';
  });

  // t+12s — cluster disabled → enabled (PUT /api/config equivalent broadcast)
  at(12, () => flipCluster(true, 'cluster.enabled false→true'));

  // t+14s — RDMA warning banner (amber)
  at(14, () =>
    sendFrame('cluster.warning', {
      node: 'studio1',
      level: 'warning',
      code: 'rdma_not_enabled',
      msg: 'RDMA not enabled — llama.cpp RPC over TCP. Expect degraded split-model throughput (measured 0.42ms / 9.6Gbps, RDMA-over-TB needs TB4/ILB2).',
    })),

  // t+20s — paused state window
  at(20, () => {
    state.paused = true;
    sendFrame('status', status());
    console.log('[mock] paused (t+20s)');
  });
  at(27, () => {
    state.paused = false;
    sendFrame('status', status());
    console.log('[mock] resumed (t+27s)');
  });

  // t+32s — config.changed echo (mirrors a settings-drawer save)
  at(32, () => {
    state.config.default_ctx = 16384;
    state.config.session_stick_seconds = 240;
    sendFrame('config.changed', { keys: ['default_ctx', 'session_stick_seconds'] });
  });

  // steady loops
  setInterval(() => {
    for (const id of Object.keys(state.nodes)) {
      const n = state.nodes[id];
      n.ram_used_gb = Math.max(40, Math.min(n.ram_total_gb - 20, n.ram_used_gb + rand(-2.2, 2.4)));
      n.gpu_pct = Math.max(2, Math.min(97, n.gpu_pct + rand(-7, 7)));
      sendFrame('node.health', {
        node: n.node,
        ram_used_gb: round(n.ram_used_gb, 1),
        ram_total_gb: n.ram_total_gb,
        gpu_pct: round(n.gpu_pct, 0),
        runners: n.runners,
        rpc_up: state.config.cluster.enabled ? n.rpc_up : false,
      });
      if (state.config.cluster.enabled && id === 'studio0') {
        sendFrame('rpc.sample', { node: 'studio0', rpc_ms_last: round(rand(0.6, 2.4), 2), tok_s: round(rand(8.5, 13.5), 1) });
      }
    }
    state.discovery.forEach((p) => {
      p.seen_ms_ago = Math.max(120, p.seen_ms_ago - 2000 + randInt(0, 900));
    });
  }, 2000);

  const spawn = () => {
    spawnRequest();
    if (chance(0.35)) setTimeout(spawnRequest, randInt(150, 450));
    setTimeout(spawn, randInt(420, 1100));
  };
  setTimeout(spawn, 700);

  setInterval(() => sendFrame('status', status()), 5000);

  console.log('[mock] scenario armed: model load 1.5s · cluster on 12s · rdma warn 14s · pause 20-27s · config echo 32s');
}

/* -------------------------------- REST -------------------------------- */

function deepMergeConfig(patch, prefix = '') {
  const changed = [];
  const walk = (obj, path) => {
    for (const [k, v] of Object.entries(obj)) {
      const key = path ? `${path}.${k}` : k;
      if (v !== null && typeof v === 'object' && !Array.isArray(v)) walk(v, key);
      else {
        changed.push(key);
        const parts = key.split('.');
        let target = state.config;
        for (const p of parts.slice(0, -1)) {
          target[p] = target[p] ?? {};
          target = target[p];
        }
        target[parts[parts.length - 1]] = v;
      }
    }
  };
  walk(patch, prefix);
  return changed;
}

function readBody(req) {
  return new Promise((resolve) => {
    let buf = '';
    req.on('data', (c) => {
      buf += c;
      if (buf.length > 262144) resolve(buf);
    });
    req.on('end', () => resolve(buf));
  });
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'content-type': 'application/json',
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
    'access-control-allow-headers': 'content-type,authorization',
  });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://x');
  const path = url.pathname;

  if (req.method === 'OPTIONS') return json(res, 204, {});

  if (req.method === 'GET') {
    if (path === '/api/status') return json(res, 200, status());
    if (path === '/api/metrics') {
      const ttft = [...state.ttftSamples].sort((a, b) => a - b);
      const total = [...state.totalSamples].sort((a, b) => a - b);
      return json(res, 200, {
        requests_total: state.counters.requests,
        cache_hit_ratio: round(state.cache.hit_ratio, 3),
        queue_depth: state.paused ? 0 : state.active.size,
        percentiles: {
          ttft_ms: { p50: percentile(ttft.slice(-200), 50), p95: percentile(ttft.slice(-200), 95), p99: percentile(ttft.slice(-200), 99) },
          total_ms: { p50: percentile(total.slice(-200), 50), p95: percentile(total.slice(-200), 95), p99: percentile(total.slice(-200), 99) },
        },
        triage: { ...state.counters.triage },
        memory: { ram_used_gb: round(state.nodes.studio0.ram_used_gb, 1), ram_total_gb: state.nodes.studio0.ram_total_gb },
      });
    }
    if (path === '/api/events') {
      const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit') ?? 200) || 200));
      return json(res, 200, state.events.slice(-limit).reverse());
    }
    if (path === '/api/cache') return json(res, 200, state.cache);
    if (path === '/api/config') return json(res, 200, state.config);
    if (path === '/api/discovery') return json(res, 200, state.discovery);
    if (path === '/api/models') return json(res, 200, { models: state.models });
    if (path === '/api/nodes') return json(res, 200, Object.values(state.nodes));
    if (path === '/')
      return res.writeHead(200, { 'content-type': 'text/plain' }).end('substation mock daemon — see scripts/mock-ws.mjs\n');
    return json(res, 404, { error: 'not found', path });
  }

  if (req.method === 'PUT' && path === '/api/config') {
    let patch;
    try {
      patch = JSON.parse((await readBody(req)) || '{}');
    } catch {
      return json(res, 400, { error: 'invalid json' });
    }
    const changed = deepMergeConfig(patch);
    sendFrame('config.changed', { keys: changed });
    return json(res, 200, { ok: true, changed: state.config });
  }

  if (req.method === 'POST') {
    if (path === '/api/admin/pause' || path === '/api/admin/resume') {
      state.paused = path.endsWith('pause');
      const s = status();
      sendFrame('status', s);
      return json(res, 200, s);
    }
    if (path === '/api/admin/reload') {
      sendFrame('config.changed', { keys: ['(reload)'] });
      return json(res, 200, { ok: true, reloaded: true });
    }
    if (path === '/api/admin/join-code') {
      const code = String(randInt(100000, 999999));
      return json(res, 200, { code, ttl_s: 600 });
    }
    const m = path.match(/^\/api\/models\/([^/]+)\/(load|unload)$/);
    if (m) {
      const name = decodeURIComponent(m[1]);
      const card = state.models.find((x) => x.name === name);
      if (!card) return json(res, 404, { error: `unknown model ${name}` });
      if (m[2] === 'load') {
        card.state = 'loading';
        sendFrame('model.loading', { model: name, node: card.node ?? 'studio0', gb: card.size_gb ?? 0, ms: 1500 });
        setTimeout(() => {
          card.state = 'loaded';
          sendFrame('model.loaded', { model: name, node: card.node ?? 'studio0', gb: card.size_gb ?? 0, ms: 1500 });
        }, 1500);
      } else {
        card.state = 'unloaded';
        sendFrame('model.unloaded', { model: name, node: card.node ?? 'studio0', gb: card.size_gb ?? 0, ms: 0 });
      }
      return json(res, 200, { ok: true, model: card });
    }
  }

  return json(res, 404, { error: 'not found', path });
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key || !socket) return socket.destroy();
  const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  attachSocket(socket);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[mock] substation mock daemon on http://127.0.0.1:${PORT} (WS ws://127.0.0.1:${PORT}/ws)`);
  scenario();
});

process.on('SIGINT', () => process.exit(0));
