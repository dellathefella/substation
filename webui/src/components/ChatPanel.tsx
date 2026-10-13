import { useCallback, useEffect, useRef, useState } from 'react';
import type { KeyboardEvent } from 'react';
import { useStore } from '../store.js';
import {
  createSession,
  deleteSession,
  fetchMessages,
  listSessions,
  sendChatStream,
  type ChatMessage,
  type ChatSession,
  type Pin,
} from '../chat.js';

const PINS: readonly Pin[] = ['auto', 'auto-fast', 'auto-smart'];

function fmtTs(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return '';
  const ms = ts > 1e12 ? ts : ts * 1000;
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

export function ChatPanel(): React.JSX.Element {
  const pushToast = useStore((s) => s.pushToast);
  const [sessions, setSessions] = useState<ChatSession[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [draft, setDraft] = useState('');
  const [pin, setPin] = useState<Pin>('auto');
  const [busy, setBusy] = useState(false);
  const [streaming, setStreaming] = useState('');
  const abortRef = useRef<AbortController | null>(null);
  const threadRef = useRef<HTMLDivElement | null>(null);

  const refreshSessions = useCallback(async (): Promise<ChatSession[]> => {
    const list = await listSessions();
    setSessions(list);
    return list;
  }, []);

  useEffect(() => {
    void refreshSessions().then((list) => {
      if (!active && list.length > 0) setActive(list[0]?.id ?? null);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!active) {
      setMessages([]);
      return;
    }
    setStreaming('');
    void fetchMessages(active).then(setMessages);
  }, [active]);

  useEffect(() => {
    threadRef.current?.scrollTo({ top: threadRef.current.scrollHeight });
  }, [messages, streaming]);

  const newChat = async (): Promise<void> => {
    const s = await createSession();
    if (!s) {
      pushToast('error', 'Could not create session');
      return;
    }
    await refreshSessions();
    setActive(s.id);
  };

  const remove = async (id: string): Promise<void> => {
    if (!window.confirm('Delete this conversation?')) return;
    await deleteSession(id);
    const list = await refreshSessions();
    if (active === id) setActive(list[0]?.id ?? null);
  };

  const send = async (): Promise<void> => {
    const content = draft.trim();
    if (!content || busy) return;
    let sid = active;
    if (!sid) {
      const s = await createSession();
      if (!s) {
        pushToast('error', 'Daemon unreachable', 'cannot create a chat session');
        return;
      }
      sid = s.id;
      setActive(sid);
      setMessages([]);
    }
    setDraft('');
    setBusy(true);
    setStreaming('');
    setMessages((m) => [...m, { role: 'user', content, ts: Date.now() / 1000 }]);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    const res = await sendChatStream(
      sid,
      content,
      pin,
      (delta) => setStreaming((s) => s + delta),
      ctrl.signal,
    );
    abortRef.current = null;
    setBusy(false);
    setStreaming('');
    if (!res.ok) {
      pushToast('error', 'Chat failed', res.error ?? 'unknown error');
    }
    const msgs = await fetchMessages(sid);
    setMessages(msgs);
    await refreshSessions();
  };

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>): void => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  };

  return (
    <div className="chat-wrap">
      <aside className="chat-sessions">
        <div className="chat-sessions-head">
          <span className="chat-title">Conversations</span>
          <button className="btn btn-primary btn-sm" onClick={() => void newChat()} disabled={busy}>
            + New
          </button>
        </div>
        {sessions.length === 0 ? <div className="chat-empty">No conversations yet.</div> : null}
        {sessions.map((s) => (
          <div
            key={s.id}
            className={`chat-session${active === s.id ? ' active' : ''}`}
            onClick={() => setActive(s.id)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => e.key === 'Enter' && setActive(s.id)}
          >
            <div className="chat-session-main">
              <span className="chat-session-title">{s.title || 'Untitled'}</span>
              <span className="chat-session-meta">
                {s.messages ?? 0} msg · {fmtTs(s.updated_at)}
              </span>
            </div>
            <button
              className="banner-x"
              aria-label="Delete conversation"
              onClick={(e) => {
                e.stopPropagation();
                void remove(s.id);
              }}
            >
              ✕
            </button>
          </div>
        ))}
      </aside>

      <section className="chat-thread-wrap">
        <div className="chat-thread" ref={threadRef}>
          {messages.length === 0 && !busy ? (
            <div className="chat-empty chat-empty-thread">
              Ask anything — Substation routes through the orchestrator (model stays transparent: you pick
              <code> auto</code>/<code> auto-fast</code>/<code> auto-smart</code>).
            </div>
          ) : null}
          {messages.map((m, i) => (
            <div key={i} className={`chat-msg chat-msg-${m.role}`}>
              <div className="chat-msg-role">{m.role === 'user' ? 'you' : 'substation'}</div>
              <div className="chat-bubble">{m.content}</div>
            </div>
          ))}
          {streaming || busy ? (
            <div className="chat-msg chat-msg-assistant">
              <div className="chat-msg-role">substation{busy && !streaming ? ' · thinking…' : ''}</div>
              <div className="chat-bubble chat-bubble-stream">
                {streaming}
                {busy ? <span className="chat-caret">▍</span> : null}
              </div>
            </div>
          ) : null}
        </div>

        <footer className="chat-composer">
          <select className="chat-pin" value={pin} onChange={(e) => setPin(e.target.value as Pin)} title="Route pin">
            {PINS.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
          <textarea
            className="chat-input"
            rows={2}
            placeholder="Message Substation… (Enter to send, Shift+Enter for newline)"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKey}
            disabled={busy}
          />
          {busy ? (
            <button
              className="btn"
              onClick={() => {
                abortRef.current?.abort();
              }}
            >
              Stop
            </button>
          ) : (
            <button className="btn btn-primary" onClick={() => void send()} disabled={!draft.trim()}>
              Send
            </button>
          )}
        </footer>
      </section>
    </div>
  );
}
