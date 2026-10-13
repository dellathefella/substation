import { wsUrl } from './api.js';
import { useStore } from './store.js';
import type { WsFrame } from './types.js';
import { isWsFrame } from './types.js';

/*
 * WS client with rAF-batched store updates and exponential reconnect.
 * Frames are queued on arrival and applied to the zustand store once per
 * animation frame (rAF) to keep render cost flat under high frame rates.
 */

let socket: WebSocket | null = null;
let disposed = false;
let attempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let pending: WsFrame[] = [];
let flushQueued = false;

function flush(): void {
  flushQueued = false;
  if (pending.length === 0) return;
  const batch = pending;
  pending = [];
  useStore.getState().applyFrames(batch);
}

function scheduleFlush(): void {
  if (flushQueued) return;
  flushQueued = true;
  const run = (): void => flush();
  if (typeof requestAnimationFrame === 'function') {
    requestAnimationFrame(run);
  } else {
    setTimeout(run, 16);
  }
}

function setStatus(status: 'connecting' | 'connected' | 'offline'): void {
  useStore.getState().setWs(wsUrl(), status);
}

function connect(): void {
  if (disposed) return;
  let url = '';
  try {
    url = wsUrl();
  } catch {
    setStatus('offline');
    return;
  }
  setStatus(attempt === 0 ? 'connecting' : useStore.getState().ws === 'connected' ? 'connecting' : 'offline');

  let ws: WebSocket;
  try {
    ws = new WebSocket(url);
  } catch {
    scheduleReconnect();
    return;
  }
  socket = ws;
  ws.onopen = (): void => {
    attempt = 0;
    setStatus('connected');
  };
  ws.onmessage = (ev: MessageEvent): void => {
    const raw = typeof ev.data === 'string' ? ev.data : '';
    if (raw.length === 0) return;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (isWsFrame(parsed)) {
        pending.push(parsed);
        scheduleFlush();
      }
    } catch {
      /* ignore malformed frames */
    }
  };
  ws.onclose = (): void => {
    if (socket === ws) socket = null;
    if (!disposed) {
      setStatus('offline');
      scheduleReconnect();
    }
  };
  ws.onerror = (): void => {
    try {
      ws.close();
    } catch {
      /* noop */
    }
  };
}

function scheduleReconnect(): void {
  if (disposed || reconnectTimer !== null) return;
  const delay = Math.min(8000, 500 * 2 ** Math.min(attempt, 4));
  attempt += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

export function connectDashboard(): () => void {
  disposed = false;
  connect();
  return () => {
    disposed = true;
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    const ws = socket;
    socket = null;
    if (ws) {
      ws.onclose = null;
      ws.onmessage = null;
      ws.onopen = null;
      ws.onerror = null;
      try {
        ws.close();
      } catch {
        /* noop */
      }
    }
  };
}
