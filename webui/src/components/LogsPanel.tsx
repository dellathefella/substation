import { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import { useStore } from '../store.js';
import type { LogFile } from '../types.js';
import { Empty, Pill } from './ui.js';

function fmtBytes(n: number): string {
  if (n > 1_048_576) return `${(n / 1_048_576).toFixed(1)} MB`;
  if (n > 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${n} B`;
}

export function LogsPanel(): React.JSX.Element {
  const nodes = useStore((s) => s.nodes);
  const [files, setFiles] = useState<LogFile[]>([]);
  const [node, setNode] = useState('local');
  const [sel, setSel] = useState('');
  const [lines, setLines] = useState<string[]>([]);
  const [tail, setTail] = useState(300);
  const [auto, setAuto] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const preRef = useRef<HTMLPreElement>(null);

  const nodeIds = Object.keys(nodes).sort();

  useEffect(() => {
    let stop = false;
    const tick = async (): Promise<void> => {
      const res = node === 'local' ? await api.logs() : await api.nodeLogList(node);
      if (stop || !res.ok) return;
      const body = res.body as { logs?: LogFile[] } | null;
      const list = body?.logs ?? [];
      setFiles(list);
      setSel((cur) => (cur && list.some((f) => f.name === cur) ? cur : list[0]?.name ?? ''));
    };
    void tick();
    const t = setInterval(() => void tick(), 5000);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [node]);

  const current = files;

  useEffect(() => {
    if (!sel) return;
    let stop = false;
    const tick = async (): Promise<void> => {
      const res = node === 'local' ? await api.logFile(sel, tail) : await api.nodeLogs(node, sel, tail);
      if (stop) return;
      if (res.ok) {
        const body = res.body as { text?: string[] } | null;
        setLines(body?.text ?? []);
        setErr(null);
      } else {
        const body = res.body as { error?: { message?: string } } | null;
        setErr(body?.error?.message ?? `HTTP ${res.status}`);
        setLines([]);
      }
    };
    void tick();
    if (!auto) return () => { stop = true; };
    const t = setInterval(() => void tick(), 3000);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [sel, tail, auto, node]);

  useEffect(() => {
    const el = preRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lines]);

  return (
    <div className="logs-wrap">
      <div className="logs-bar">
        <select value={node} onChange={(e) => { setNode(e.target.value); setSel(''); setLines([]); setErr(null); }}>
          <option value="local">this Mac</option>
          {nodeIds.map((n) => (
            <option key={n} value={n}>{n}</option>
          ))}
        </select>
        <select value={sel} onChange={(e) => setSel(e.target.value)}>
          {current.length === 0 ? <option value="">(no engine logs)</option> : null}
          {current.map((f) => (
            <option key={f.name} value={f.name}>
              {f.name}{f.bytes ? ` · ${fmtBytes(f.bytes)}` : ''}
            </option>
          ))}
        </select>
        <select value={tail} onChange={(e) => setTail(Number(e.target.value))} title="tail lines">
          {[100, 300, 1000, 3000].map((n) => (
            <option key={n} value={n}>tail {n}</option>
          ))}
        </select>
        <label className="logs-auto">
          <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} /> auto-refresh
        </label>
        <Pill tone={auto ? 'ok' : 'muted'}>{auto ? 'live · 3s' : 'paused'}</Pill>
      </div>
      {err ? <div className="logs-err">{err}</div> : null}
      {sel ? (
        <pre className="log-view" ref={preRef}>{lines.join('\n')}</pre>
      ) : (
        <Empty text={node === 'local' ? 'no engine logs yet — load a model or wait for triage' : `no runners on ${node}`} />
      )}
    </div>
  );
}
