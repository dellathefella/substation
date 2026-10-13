import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../api.js';
import type { DeployJob, HfFile, HfRepo } from '../api.js';

type Step = 'search' | 'files' | 'configure' | 'progress';

function fmtSize(b: number): string {
  if (b <= 0) return '?';
  const gb = b / 1e9;
  return gb >= 1 ? `${gb.toFixed(2)} GB` : `${Math.round(b / 1e6)} MB`;
}

export function DeployModal(props: { open: boolean; onClose: () => void; onDeployed: () => void }): React.JSX.Element | null {
  const { open } = props;
  const [step, setStep] = useState<Step>('search');
  const [q, setQ] = useState('');
  const [repos, setRepos] = useState<HfRepo[]>([]);
  const [repo, setRepo] = useState<HfRepo | null>(null);
  const [files, setFiles] = useState<HfFile[]>([]);
  const [file, setFile] = useState<string>('');
  const [mmproj, setMmproj] = useState<string>('');
  const [name, setName] = useState('');
  const [tier, setTier] = useState('fast');
  const [token, setToken] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [job, setJob] = useState<DeployJob | null>(null);
  const pollRef = useRef<number | null>(null);

  const reset = useCallback((): void => {
    setStep('search');
    setQ('');
    setRepos([]);
    setRepo(null);
    setFiles([]);
    setFile('');
    setMmproj('');
    setName('');
    setTier('fast');
    setError(null);
    setJob(null);
    setBusy(false);
  }, []);

  useEffect(() => {
    if (!open) {
      if (pollRef.current) window.clearInterval(pollRef.current);
      reset();
    }
    return () => {
      if (pollRef.current) window.clearInterval(pollRef.current);
    };
  }, [open, reset]);

  // token is kept across close on purpose only within a session; never persisted.
  useEffect(() => {
    if (step === 'search' && q.trim().length >= 3) {
      const t = window.setTimeout(async () => {
        const r = await api.hfSearch(q.trim(), token);
        setRepos(r);
      }, 400);
      return () => window.clearTimeout(t);
    }
    return undefined;
  }, [q, step, token]);

  const pickRepo = async (r: HfRepo): Promise<void> => {
    setRepo(r);
    setBusy(true);
    setError(null);
    const fs = await api.hfFiles(r.repo, token);
    setBusy(false);
    if (fs.length === 0) {
      setError(`No GGUF files (or access requires a token). ${r.gated || r.private ? 'This repo is gated — add your HF token and retry.' : ''}`);
      if (r.gated || r.private) setStep('search');
      return;
    }
    const mains = fs.filter((f) => !f.mmproj);
    const mms = fs.filter((f) => f.mmproj);
    setFiles(fs);
    setFile(mains[0]?.file ?? fs[0]?.file ?? '');
    setMmproj(mms[0]?.file ?? '');
    if (!name) setName(suggestName(mains[0]?.file ?? fs[0]?.file ?? 'model'));
    setStep('files');
  };

  const suggestName = (f: string): string => {
    const base = f.split('/').pop() ?? 'model';
    return base
      .replace(/\.gguf$/i, '')
      .toLowerCase()
      .replace(/[^a-z0-9._-]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 48) || 'model';
  };

  const mainFiles = files.filter((f) => !f.mmproj);
  const mmFiles = files.filter((f) => f.mmproj);
  const selSize = mainFiles.find((f) => f.file === file)?.size ?? 0;

  const start = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    const res = await api.deploy({ repo: repo?.repo, file, mmproj: mmproj || null, name, tier, token });
    setBusy(false);
    const j = (res.body ?? {}) as { id?: string; error?: string; detail?: string };
    if (!res.ok || !j.id) {
      const msg = j.error ?? `request failed (${res.status})`;
      setError(msg === 'needs_token' ? j.detail ?? 'This model needs a valid HF token.' : `${msg}${j.detail ? ` — ${j.detail}` : ''}`);
      if (j.error === 'needs_token') setStep('configure');
      return;
    }
    setStep('progress');
    pollRef.current = window.setInterval(async () => {
      const jobs = await api.deployments();
      const me = jobs.find((x) => x.id === j.id) ?? jobs[0] ?? null;
      setJob(me);
      if (me && (me.state === 'installed' || me.state === 'error' || me.state === 'canceled')) {
        if (pollRef.current) window.clearInterval(pollRef.current);
        if (me.state === 'installed') props.onDeployed();
      }
    }, 2000);
  };

  if (!open) return null;

  const pct = job && job.total > 0 ? Math.min(100, (job.bytes / job.total) * 100) : 0;

  return (
    <div className="modal-backdrop" onClick={props.onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h3>Deploy model</h3>
          <span className="dim">
            {{ search: '1 · find', files: '2 · quant', configure: '3 · configure', progress: '4 · download' }[step]}
          </span>
          <button className="btn ghost sm" onClick={props.onClose}>close</button>
        </div>

        {step === 'search' && (
          <div className="modal-body">
            <input className="input" placeholder="search hugging face (e.g. qwen2.5 vl)" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
            <input
              className="input"
              type="password"
              placeholder="HF token (required for gated models — kept in memory only)"
              value={token}
              onChange={(e) => setToken(e.target.value)}
            />
            <div className="hf-list">
              {repos.map((r) => (
                <button key={r.repo} className="hf-item" onClick={() => void pickRepo(r)}>
                  <span className="mono">{r.repo}</span>
                  <span className="dim">
                    {r.downloads.toLocaleString()} dl{r.gated ? ' · gated' : ''}{r.private ? ' · private' : ''}
                  </span>
                </button>
              ))}
              {repos.length === 0 && q.trim().length >= 3 ? <div className="dim">no GGUF repos found</div> : null}
            </div>
            {error ? <div className="hf-err">{error}</div> : null}
          </div>
        )}

        {step === 'files' && repo && (
          <div className="modal-body">
            <div className="dim mono">{repo.repo}</div>
            <div className="hf-list">
              {mainFiles.map((f) => (
                <button key={f.file} className={`hf-item${file === f.file ? ' on' : ''}`} onClick={() => { setFile(f.file); setName(suggestName(f.file)); }}>
                  <span className="mono">{f.file}</span>
                  <span className="dim">{fmtSize(f.size)}</span>
                </button>
              ))}
            </div>
            {mmFiles.length > 0 && (
              <div className="hf-mmrow">
                <span className="dim">vision projector</span>
                <select className="input" value={mmproj} onChange={(e) => setMmproj(e.target.value)}>
                  <option value="">none (text only)</option>
                  {mmFiles.map((f) => (
                    <option key={f.file} value={f.file}>{f.file} · {fmtSize(f.size)}</option>
                  ))}
                </select>
              </div>
            )}
            {error ? <div className="hf-err">{error}</div> : null}
            <div className="modal-foot">
              <button className="btn ghost" onClick={() => setStep('search')}>back</button>
              <button className="btn" disabled={!file} onClick={() => { setName((n) => n || suggestName(file)); setStep('configure'); }}>continue</button>
            </div>
          </div>
        )}

        {step === 'configure' && (
          <div className="modal-body">
            <label className="hf-field">
              <span>name</span>
              <input className="input mono" value={name} onChange={(e) => setName(e.target.value.toLowerCase().replace(/[^a-z0-9._-]/g, '-'))} />
            </label>
            <label className="hf-field">
              <span>tier</span>
              <select className="input" value={tier} onChange={(e) => setTier(e.target.value)}>
                <option value="fast">fast</option>
                <option value="balanced">balanced</option>
                <option value="smart">smart</option>
              </select>
            </label>
            <label className="hf-field">
              <span>HF token</span>
              <input className="input" type="password" placeholder={repo?.gated || repo?.private ? 'required (gated model)' : 'optional (faster + private repos)'} value={token} onChange={(e) => setToken(e.target.value)} />
            </label>
            <div className="dim">
              {file} · {fmtSize(selSize + (mmFiles.find((f) => f.file === mmproj)?.size ?? 0))}
              {mmproj ? ' · will register as vision' : ''} · → models/{name || '…'}.gguf → tier {tier}
            </div>
            {repo?.gated || repo?.private ? <div className="hf-err">gated model: download is refused until a valid HF token is supplied.</div> : null}
            {error ? <div className="hf-err">{error}</div> : null}
            <div className="modal-foot">
              <button className="btn ghost" onClick={() => setStep('files')}>back</button>
              <button className="btn" disabled={busy || !name || (repo != null && (repo.gated || repo.private) && token.length === 0)} onClick={() => void start()}>
                {busy ? 'starting…' : 'download & deploy'}
              </button>
            </div>
          </div>
        )}

        {step === 'progress' && (
          <div className="modal-body">
            {job == null ? (
              <div className="dim">starting…</div>
            ) : (
              <>
                <div className="hf-dl-name mono">{job.repo} → {job.file}</div>
                <div className="hf-bar"><div className="hf-bar-fill" style={{ width: `${pct}%` }} /></div>
                <div className="dim">
                  {job.state === 'error' ? `error: ${job.error}` :
                    job.state === 'installed' ? `installed → tier ${job.tier}${job.vision ? ' · vision' : ''}` :
                    job.state === 'canceled' ? 'canceled' :
                    `${(job.bytes / 1e6).toFixed(0)} / ${(job.total / 1e6).toFixed(0)} MB (${pct.toFixed(0)}%) · ${job.state}`}
                </div>
                {job.state === 'installed' && (
                  <div className="modal-foot"><button className="btn" onClick={props.onClose}>done</button></div>
                )}
                {(job.state === 'error' || job.state === 'canceled') && (
                  <div className="modal-foot">
                    <button className="btn ghost" onClick={() => setStep('configure')}>back</button>
                  </div>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
