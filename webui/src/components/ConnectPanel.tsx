import { useCallback, useEffect, useState } from 'react';
import { apiBase, authHeaders } from '../api.js';
import { DeployModal } from './DeployModal.js';

interface ConnectorFile {
  name: string;
  lang: string;
  code: string;
}
interface ConnectorHarness {
  id: string;
  name: string;
  note: string;
  files: ConnectorFile[];
}
interface ConnectorInfo {
  base: string;
  bases: { label: string; base: string }[];
  key_required: boolean;
  api_key?: string;
  models: string[];
  harnesses: ConnectorHarness[];
}

function download(name: string, code: string): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([code], { type: 'text/plain' }));
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
}

export function ConnectPanel(): React.JSX.Element {
  const [deployOpen, setDeployOpen] = useState(false);
  const [info, setInfo] = useState<ConnectorInfo | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const load = useCallback(async (): Promise<void> => {
    try {
      const res = await fetch(`${apiBase()}/api/connectors`, { headers: authHeaders() });
      if (!res.ok) {
        setErr(`daemon returned ${res.status}`);
        return;
      }
      setInfo((await res.json()) as ConnectorInfo);
      setErr(null);
    } catch (e) {
      setErr(String(e));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const copy = async (key: string, code: string): Promise<void> => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(key);
      setTimeout(() => setCopied((c) => (c === key ? null : c)), 1200);
    } catch {
      /* clipboard blocked */
    }
  };

  if (err) {
    return (
      <div className="connect-wrap">
        <div className="connect-err">
          Could not load connector configs: {err}
          <button className="btn btn-sm" onClick={() => void load()}>
            Retry
          </button>
        </div>
      </div>
    );
  }
  if (!info) return <div className="connect-wrap"><div className="chat-empty">Loading harness configs…</div></div>;

  return (
    <div className="connect-wrap">
      <header className="connect-head">
        <div>
          <div className="connect-title">Harness configs</div>
          <div className="connect-sub">
            generated live from this daemon&apos;s listen address · <code>{info.base}</code> ·{' '}
            {info.key_required ? 'API key required (shown below)' : 'auth disabled — any key works'} · models:{' '}
            {info.models.map((m) => (
              <code key={m}>{m}</code>
            ))}
          </div>
        </div>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn btn-sm" onClick={() => setDeployOpen(true)}>
            ↓ Deploy model
          </button>
          <button className="btn btn-sm" onClick={() => void load()}>
            ⟳ Refresh
          </button>
        </div>
      </header>
      <DeployModal open={deployOpen} onClose={() => setDeployOpen(false)} onDeployed={() => setDeployOpen(false)} />

      {info.api_key ? (
        <div className="connect-key">
          <span className="connect-key-label">API key</span>
          <code className="connect-key-value">{info.api_key}</code>
          <button className="btn btn-sm" onClick={() => void copy('key', info.api_key ?? '')}>
            {copied === 'key' ? '✓ Copied' : 'Copy'}
          </button>
        </div>
      ) : null}

      <div className="connect-grid">
        {info.harnesses.map((h) => (
          <section key={h.id} className="connect-card">
            <div className="connect-card-head">
              <span className="connect-card-name">{h.name}</span>
              <span className="connect-card-lang">{h.files.map((f) => f.name).join(', ')}</span>
            </div>
            <p className="connect-card-note">{h.note}</p>
            {h.files.map((f) => (
              <div key={f.name} className="connect-file">
                <pre className="connect-code">{f.code}</pre>
                <div className="connect-file-actions">
                  <button className="btn btn-sm" onClick={() => void copy(`${h.id}:${f.name}`, f.code)}>
                    {copied === `${h.id}:${f.name}` ? '✓ Copied' : 'Copy'}
                  </button>
                  <button className="btn btn-sm" onClick={() => download(f.name, f.code)}>
                    ⭳ Download
                  </button>
                </div>
              </div>
            ))}
          </section>
        ))}
      </div>
    </div>
  );
}
