import { apiBase, authHeaders } from './api.js';

export interface ChatSession {
  id: string;
  title: string;
  updated_at: number;
  model_hint?: string;
  messages?: number;
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  ts: number;
}

async function asJson<T>(res: Response): Promise<T | null> {
  try {
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

export async function listSessions(): Promise<ChatSession[]> {
  try {
    const res = await fetch(`${apiBase()}/api/chat/sessions`, { headers: authHeaders() });
    if (!res.ok) return [];
    const v = await asJson<unknown>(res);
    return Array.isArray(v) ? (v as ChatSession[]) : [];
  } catch {
    return [];
  }
}

export async function createSession(title?: string): Promise<ChatSession | null> {
  try {
    const res = await fetch(`${apiBase()}/api/chat/sessions`, {
      method: 'POST',
      headers: authHeaders({ 'content-type': 'application/json' }),
      body: JSON.stringify(title ? { title } : {}),
    });
    if (!res.ok) return null;
    return await asJson<ChatSession>(res);
  } catch {
    return null;
  }
}

export async function deleteSession(id: string): Promise<boolean> {
  try {
    const res = await fetch(`${apiBase()}/api/chat/sessions/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function fetchMessages(id: string): Promise<ChatMessage[]> {
  try {
    const res = await fetch(`${apiBase()}/api/chat/sessions/${encodeURIComponent(id)}/messages`, {
      headers: authHeaders(),
    });
    if (!res.ok) return [];
    const v = await asJson<unknown>(res);
    return Array.isArray(v) ? (v as ChatMessage[]) : [];
  } catch {
    return [];
  }
}

export type Pin = 'auto' | 'auto-fast' | 'auto-smart';

/** Stream an assistant reply via SSE; resolves with the full text. */
export async function sendChatStream(
  sessionId: string,
  content: string,
  pin: Pin,
  onDelta: (chunk: string) => void,
  signal?: AbortSignal,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const res = await fetch(`${apiBase()}/api/chat/sessions/${encodeURIComponent(sessionId)}/send`, {
      method: 'POST',
      headers: authHeaders({ 'content-type': 'application/json' }),
      body: JSON.stringify({ content, pin, stream: true }),
      signal,
    });
    if (!res.ok) {
      const body = await asJson<{ error?: { message?: string; code?: string } }>(res);
      return { ok: false, error: body?.error?.message ?? `HTTP ${res.status}` };
    }
    if (!res.body) return { ok: false, error: 'no response body' };
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    let text = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      for (;;) {
        const sep = buf.indexOf('\n\n');
        if (sep < 0) break;
        const frame = buf.slice(0, sep);
        buf = buf.slice(sep + 2);
        const line = frame.split('\n').find((l) => l.startsWith('data: '));
        if (!line) continue;
        const payload = line.slice(6);
        if (payload === '[DONE]') continue;
        try {
          const j = JSON.parse(payload) as {
            choices?: { delta?: { content?: string } }[];
            error?: { message?: string };
          };
          if (j.error?.message) return { ok: false, error: j.error.message };
          const delta = j.choices?.[0]?.delta?.content;
          if (delta) {
            text += delta;
            onDelta(delta);
          }
        } catch {
          /* ignore malformed frame */
        }
      }
    }
    return { ok: true };
  } catch (e) {
    if ((e as Error).name === 'AbortError') return { ok: false, error: 'aborted' };
    return { ok: false, error: String(e) };
  }
}
