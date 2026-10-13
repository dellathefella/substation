import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import { api, authToken, setAuthToken } from '../api.js';
import { useStore } from '../store.js';
import type { ConfigPatch, RuntimeConfig } from '../types.js';

interface Field {
  path: string;
  label: string;
  type: 'number' | 'bool';
  step?: number;
  min?: number;
  hint?: string;
}

const SECTIONS: { title: string; fields: readonly Field[] }[] = [
  {
    title: 'Orchestrator',
    fields: [
      { path: 'orchestrator.enabled', label: 'Auto-router enabled (off = single-model mode)', type: 'bool' },
      { path: 'orchestrator.triage_timeout_ms', label: 'Triage timeout', type: 'number', hint: 'ms' },
      { path: 'orchestrator.triage_upgrade_confidence', label: 'Upgrade confidence', type: 'number', step: 0.05, hint: '0..1' },
      { path: 'orchestrator.idle_load_only', label: 'Start with triage only (lazy-load tiers)', type: 'bool' },
      { path: 'orchestrator.cache_enabled', label: 'Prompt cache enabled', type: 'bool' },
      { path: 'orchestrator.cache_max_entries', label: 'Cache max entries', type: 'number' },
    ],
  },
  {
    title: 'Engines',
    fields: [
      { path: 'engines.default_ctx', label: 'Default context window', type: 'number', step: 1024, hint: 'tokens' },
      { path: 'engines.idle_evict_seconds', label: 'Idle engine evict', type: 'number', hint: 's' },
      { path: 'engines.min_free_ram_gb', label: 'Min free RAM to load', type: 'number', hint: 'GB' },
    ],
  },
  {
    title: 'Daemon',
    fields: [
      { path: 'daemon.session_stick_seconds', label: 'Session stickiness', type: 'number', hint: 's' },
      { path: 'daemon.max_concurrent_requests', label: 'Max concurrent requests', type: 'number', min: 1 },
      { path: 'cluster.enabled', label: 'Clustering enabled', type: 'bool' },
    ],
  },
];

const TIERS = ['fast', 'balanced', 'smart'] as const;

function readPath(cfg: RuntimeConfig | null, path: string): unknown {
  let cur: unknown = cfg;
  for (const p of path.split('.')) {
    if (cur === null || typeof cur !== 'object') return undefined;
    cur = (cur as Record<string, unknown>)[p];
  }
  return cur;
}

function setPath(obj: Record<string, unknown>, path: string, value: unknown): void {
  const parts = path.split('.');
  let cur = obj;
  for (const p of parts.slice(0, -1)) {
    const nxt = cur[p];
    if (nxt === null || typeof nxt !== 'object' || Array.isArray(nxt)) cur[p] = {};
    cur = cur[p] as Record<string, unknown>;
  }
  const last = parts[parts.length - 1];
  if (last !== undefined) cur[last] = value;
}

export function SettingsDrawer(props: { open: boolean; onClose: () => void }): React.JSX.Element | null {
  const config = useStore((s) => s.config);
  const pushToast = useStore((s) => s.pushToast);
  const patchConfigLocal = useStore((s) => s.patchConfigLocal);
  const replaceConfig = useStore((s) => s.replaceConfig);
  const [draft, setDraft] = useState<Record<string, string | boolean>>({});
  const [tiers, setTiers] = useState<Record<string, string>>({});
  const [defaultModel, setDefaultModel] = useState('');
  const [token, setToken] = useState('');
  const [tab, setTab] = useState<'form' | 'json' | 'profiles'>('form');
  const [profiles, setProfiles] = useState<NonNullable<RuntimeConfig['models']>>([]);
  const [jsonText, setJsonText] = useState('');
  const [jsonErr, setJsonErr] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);

  useEffect(() => {
    if (!props.open) return;
    const next: Record<string, string | boolean> = {};
    for (const s of SECTIONS) {
      for (const f of s.fields) {
        const v = readPath(config, f.path);
        if (typeof v === 'boolean') next[f.path] = v;
        else if (typeof v === 'number') next[f.path] = String(v);
        else next[f.path] = '';
      }
    }
    setDraft(next);
    setJsonText(JSON.stringify(config ?? {}, null, 2));
    setJsonErr(null);
    setProfiles((config?.models ?? []).map((m) => ({ ...m })));
    const t: Record<string, string> = {};
    for (const tier of TIERS) t[tier] = config?.orchestrator?.tiers?.[tier]?.models?.[0] ?? '';
    setTiers(t);
    setDefaultModel(config?.orchestrator?.default_model ?? '');
    setToken(authToken());
  }, [props.open, config]);

  if (!props.open) return null;

  const modelNames = (config?.models ?? []).map((m) => m.name);

  const save = async (e: FormEvent): Promise<void> => {
    e.preventDefault();
    const patch: Record<string, unknown> = {};
    let count = 0;
    for (const s of SECTIONS) {
      for (const f of s.fields) {
        const raw = draft[f.path];
        if (raw === undefined || raw === '') continue;
        if (f.type === 'bool') {
          setPath(patch, f.path, raw === true);
          count += 1;
        } else {
          const n = Number(raw);
          if (Number.isFinite(n)) {
            setPath(patch, f.path, n);
            count += 1;
          }
        }
      }
    }
    const tierPatch: Record<string, unknown> = {};
    for (const tier of TIERS) {
      const m = tiers[tier];
      if (m) setPath(tierPatch, `orchestrator.tiers.${tier}.models`, [m]);
    }
    if (defaultModel) setPath(patch, 'orchestrator.default_model', defaultModel);
    const merged = { ...patch, ...(tierPatch.orchestrator ? { orchestrator: { ...(patch.orchestrator as object | undefined), ...(tierPatch.orchestrator as object) } } : {}) };
    if (count === 0 && Object.keys(tierPatch).length === 0 && !defaultModel) {
      pushToast('info', 'Nothing to save');
      return;
    }
    setSaving(true);
    const res = await api.putConfig(merged as unknown as ConfigPatch);
    setSaving(false);
    if (res.ok) {
      patchConfigLocal(merged as unknown as ConfigPatch);
      pushToast('success', 'Config updated', 'daemon applied + persisted the patch');
      props.onClose();
    } else {
      pushToast('error', 'Config update failed', String(res.status || 'daemon unreachable'));
    }
  };

  const saveJson = async (): Promise<void> => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(jsonText);
    } catch (e) {
      setJsonErr(String(e));
      return;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      setJsonErr('Top level must be a JSON object');
      return;
    }
    setSaving(true);
    setJsonErr(null);
    const res = await api.putConfig(parsed as unknown as ConfigPatch);
    setSaving(false);
    if (res.ok) {
      patchConfigLocal(parsed as unknown as ConfigPatch);
      const fresh = await api.getConfig();
      replaceConfig(fresh);
      pushToast('success', 'Config updated', 'full config tree pushed; changed keys merged + persisted');
      props.onClose();
    } else {
      const body = res.body as { error?: { message?: string } } | null;
      setJsonErr(body?.error?.message ?? `HTTP ${res.status}`);
    }
  };

  const saveProfiles = async (): Promise<void> => {
    const cleaned = profiles
      .map((p) => {
        const o: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(p)) {
          if (v === undefined || v === null || v === '') continue;
          if (Array.isArray(v) && v.length === 0) continue;
          o[k] = v;
        }
        return o;
      })
      .filter((p) => typeof p.name === 'string' && p.name !== '');
    if (cleaned.length !== profiles.length || cleaned.some((c, i) => c.name !== profiles[i]?.name)) {
      /* fallthrough: names trimmed */
    }
    if (cleaned.length === 0) {
      pushToast('error', 'Keep at least one profile with a name');
      return;
    }
    setSaving(true);
    const res = await api.putConfig({ models: cleaned } as unknown as ConfigPatch);
    setSaving(false);
    if (res.ok) {
      const fresh = await api.getConfig();
      replaceConfig(fresh);
      pushToast('success', 'Profiles saved', `${cleaned.length} profile(s) applied + persisted`);
      props.onClose();
    } else {
      const body = res.body as { error?: { message?: string } } | null;
      pushToast('error', 'Profiles save failed', body?.error?.message ?? String(res.status));
    }
  };

  const upd = (i: number, patch: Partial<NonNullable<RuntimeConfig['models']>[number]>): void =>
    setProfiles((ps) => ps.map((p, j) => (j === i ? { ...p, ...patch } : p)));

  const clusterOn = config?.cluster?.enabled === true;
  const nodeIds = Object.keys((config as Record<string, unknown> | null)?.nodes as Record<string, unknown> | undefined ?? {});
  const placementOf = (p: NonNullable<RuntimeConfig['models']>[number]): string => {
    const pl = p.placement ?? 'local';
    if (pl === 'local' || pl.startsWith('node:')) return pl;
    return 'split';
  };

  const profilesTab = (
    <div className="profiles">
      <p className="drawer-note">
        Full catalog · options adapt to the profile type. Saving <b>replaces</b> the whole model catalog.
      </p>
      {profiles.map((p, i) => (
        <div className="prof-card" key={`${p.name || 'new'}-${i}`}>
          <div className="prof-head">
            <input className="prof-name" placeholder="profile name" value={p.name ?? ''} onChange={(e) => upd(i, { name: e.target.value })} />
            <select
              value={p.kind ?? 'local'}
              onChange={(e) => {
                const kind = e.target.value as 'local' | 'external' | 'remote';
                upd(i, { kind: kind, ...(kind === 'local' ? { protocol: undefined, api_key: undefined, base_url: undefined, model: undefined } : { kind, gguf: undefined, flags: undefined, size_gb: undefined, ctx: undefined, placement: undefined, node: undefined }) });
              }}
            >
              <option value="local">local llama.cpp</option>
              <option value="external">external server (LAN)</option>
              <option value="remote">cloud / remote</option>
            </select>
            <select value={p.tier ?? 'balanced'} onChange={(e) => upd(i, { tier: e.target.value })}>
              <option value="fast">tier · fast</option>
              <option value="balanced">tier · balanced</option>
              <option value="smart">tier · smart</option>
            </select>
            <button className="banner-x" aria-label="Remove profile" onClick={() => setProfiles((ps) => ps.filter((_, j) => j !== i))}>✕</button>
          </div>

          {(p.kind ?? 'local') === 'local' ? (
            <>
              <div className="prof-grid">
                <label className="field">
                  <span className="field-label">GGUF path <span className="field-hint">~ and $VAR ok</span></span>
                  <input type="text" value={p.gguf ?? ''} onChange={(e) => upd(i, { gguf: e.target.value })} />
                </label>
                <label className="field">
                  <span className="field-label">size <span className="field-hint">GB</span></span>
                  <input type="number" step={0.1} value={p.size_gb ?? ''} onChange={(e) => upd(i, { size_gb: Number(e.target.value) })} />
                </label>
                <label className="field">
                  <span className="field-label">ctx</span>
                  <input type="number" step={1024} value={p.ctx ?? ''} onChange={(e) => upd(i, { ctx: Number(e.target.value) })} />
                </label>
                <label className="field">
                  <span className="field-label">placement {!clusterOn ? <span className="field-hint">split needs cluster on</span> : null}</span>
                  <select value={placementOf(p)} onChange={(e) => upd(i, { placement: e.target.value, node: undefined })}>
                    <option value="local">local</option>
                    {nodeIds.map((n) => (
                      <option key={n} value={`node:${n}`}>{`node · ${n}`}</option>
                    ))}
                    <option value="split" disabled={!clusterOn}>split (RPC, 2+ nodes)</option>
                  </select>
                </label>
                <label className="field">
                  <span className="field-label">llama.cpp flags <span className="field-hint">space separated</span></span>
                  <input type="text" placeholder="--no-mmap --flash-attn" value={(p.flags ?? []).join(' ')} onChange={(e) => upd(i, { flags: e.target.value.split(/\s+/).filter(Boolean) })} />
                </label>
              </div>
              <div className="prof-note">
                Non-RPC local profiles live on exactly one node. A <code>split</code> profile streams weights over GGML RPC to
                every eligible joined node with worker-side weight caching disabled.
              </div>
            </>
          ) : (
            <>
              <div className="prof-grid">
                <label className="field">
                  <span className="field-label">base URL <span className="field-hint">no trailing /v1</span></span>
                  <input type="text" placeholder="http://192.168.7.248:8083" value={p.base_url ?? ''} onChange={(e) => upd(i, { base_url: e.target.value })} />
                </label>
                <label className="field">
                  <span className="field-label">upstream model id</span>
                  <input type="text" placeholder={p.name ?? 'provider model id'} value={p.model ?? ''} onChange={(e) => upd(i, { model: e.target.value })} />
                </label>
                {p.kind === 'remote' ? (
                  <>
                    <label className="field">
                      <span className="field-label">protocol</span>
                      <select value={p.protocol ?? 'openai'} onChange={(e) => upd(i, { protocol: e.target.value as 'openai' | 'anthropic' })}>
                        <option value="openai">openai-compatible</option>
                        <option value="anthropic">anthropic</option>
                      </select>
                    </label>
                    <label className="field">
                      <span className="field-label">api key</span>
                      <input type="password" value={p.api_key ?? ''} onChange={(e) => upd(i, { api_key: e.target.value })} />
                    </label>
                  </>
                ) : (
                  <label className="field">
                    <span className="field-label">api key <span className="field-hint">optional</span></span>
                    <input type="password" value={p.api_key ?? ''} onChange={(e) => upd(i, { api_key: e.target.value })} />
                  </label>
                )}
              </div>
              <div className="prof-note">
                Remote/external profiles have no local weights: no ctx/KV/RAM/placement/flags options — Substation routes to
                them and proxies through the same cache, usage ledger and transparent model naming.
              </div>
            </>
          )}
        </div>
      ))}
      <div className="prof-actions">
        <button className="btn" onClick={() => setProfiles((ps) => [...ps, { name: '', kind: 'remote', tier: 'smart', protocol: 'openai' }])}>
          + Add profile
        </button>
        <button className="btn btn-primary" onClick={() => void saveProfiles()} disabled={saving}>
          {saving ? 'Saving…' : 'Save profiles to daemon'}
        </button>
      </div>
    </div>
  );

  const act = async (kind: 'tune' | 'rotate' | 'reset'): Promise<void> => {
    if (kind === 'reset' && !window.confirm('Reset config to factory defaults? This disables auth and restores the template model catalog.')) return;
    setBusy(kind);
    const res = kind === 'tune' ? await api.tuneApply() : kind === 'rotate' ? await api.rotateKey() : await api.resetConfig();
    setBusy(null);
    if (!res.ok) {
      const body = res.body as { error?: { message?: string } } | null;
      pushToast('error', kind === 'tune' ? 'Auto-tune failed' : kind === 'rotate' ? 'Key rotation failed' : 'Reset failed', body?.error?.message ?? String(res.status || 'daemon unreachable'));
      return;
    }
    if (kind === 'tune') {
      const body = res.body as { applied?: { summary?: string; picks?: { tier: string; model?: string }[] } } | null;
      const picks = (body?.applied?.picks ?? []).map((p) => `${p.tier}: ${p.model ?? '—'}`).join(' · ');
      pushToast('success', 'Auto-tuner applied', picks || body?.applied?.summary);
    } else if (kind === 'rotate') {
      const body = res.body as { key?: string } | null;
      if (body?.key) {
        setAuthToken(body.key);
        setToken(body.key);
        pushToast('success', 'API key rotated', 'New key saved in this browser. Update other clients/MCP env.');
      }
    } else {
      const cfg = await api.getConfig();
      replaceConfig(cfg);
      pushToast('success', 'Config reset to defaults');
    }
  };

  const field = (f: Field): React.JSX.Element => {
    const raw = draft[f.path];
    return (
      <label key={f.path} className="field">
        <span className="field-label">
          {f.label}
          {f.hint ? <span className="field-hint">{f.hint}</span> : null}
        </span>
        {f.type === 'bool' ? (
          <input type="checkbox" checked={raw === true} onChange={(e) => setDraft((d) => ({ ...d, [f.path]: e.target.checked }))} />
        ) : (
          <input
            type="number"
            step={f.step ?? 1}
            min={f.min}
            value={typeof raw === 'string' ? raw : ''}
            onChange={(e) => setDraft((d) => ({ ...d, [f.path]: e.target.value }))}
          />
        )}
      </label>
    );
  };

  return (
    <div className="drawer-scrim" onClick={props.onClose} role="presentation">
      <aside className="drawer drawer-wide" role="dialog" aria-label="Settings" onClick={(e) => e.stopPropagation()}>
        <header className="drawer-head">
          <h2>Settings</h2>
          <button className="banner-x" onClick={props.onClose} aria-label="Close settings">
            ✕
          </button>
        </header>
        <nav className="drawer-tabs" aria-label="Settings mode">
          <button className={`nav-btn${tab === 'form' ? ' active' : ''}`} onClick={() => setTab('form')}>
            Form
          </button>
          <button className={`nav-btn${tab === 'profiles' ? ' active' : ''}`} onClick={() => setTab('profiles')}>
            Profiles
          </button>
          <button className={`nav-btn${tab === 'json' ? ' active' : ''}`} onClick={() => setTab('json')}>
            JSON (all keys)
          </button>
        </nav>
        {tab === 'form' ? (
          <form className="drawer-form" onSubmit={(e) => void save(e)}>
          <div className="drawer-section">
            <div className="drawer-section-title">Tier models (auto routing)</div>
            {TIERS.map((t) => (
              <label key={t} className="field">
                <span className="field-label">
                  Tier <code>{t}</code>
                </span>
                <select value={tiers[t] ?? ''} onChange={(e) => setTiers((d) => ({ ...d, [t]: e.target.value }))}>
                  <option value="">— keep current —</option>
                  {modelNames.map((n) => (
                    <option key={n} value={n}>
                      {n}
                    </option>
                  ))}
                </select>
              </label>
            ))}
            <label className="field">
              <span className="field-label">
                Fallback model <span className="field-hint">when orchestrator is down</span>
              </span>
              <input type="text" placeholder="(smallest catalog model)" value={defaultModel} onChange={(e) => setDefaultModel(e.target.value)} />
            </label>
          </div>
          {SECTIONS.map((s) => (
            <div key={s.title} className="drawer-section">
              <div className="drawer-section-title">{s.title}</div>
              {s.fields.map(field)}
            </div>
          ))}
          <div className="drawer-section">
            <div className="drawer-section-title">Client API key (this browser)</div>
            <label className="field">
              <span className="field-label">
                Bearer token <span className="field-hint">stored in localStorage only</span>
              </span>
              <input
                type="text"
                placeholder="(none — auth disabled or not set here)"
                value={token}
                onChange={(e) => {
                  setToken(e.target.value);
                  setAuthToken(e.target.value);
                }}
              />
            </label>
          </div>
          <button type="submit" className="btn btn-primary drawer-save" disabled={saving}>
            {saving ? 'Saving…' : 'Save & push to daemon'}
          </button>
          </form>
        ) : null}
        {tab === 'profiles' ? profilesTab : null}
        {tab === 'json' ? (
          <div className="drawer-json">
            <p className="drawer-note">
              Full <code>/api/config</code> tree · every key editable (triage, ports, bin paths, model profiles:
              node/ctx/placement/flags…). Values are deep-merged; to <em>remove</em> a key use Reset.
            </p>
            <textarea
              className="json-editor"
              spellCheck={false}
              value={jsonText}
              onChange={(e) => {
                setJsonText(e.target.value);
                setJsonErr(null);
              }}
            />
            {jsonErr ? <div className="json-error">{jsonErr}</div> : null}
            <button className="btn btn-primary drawer-save" onClick={() => void saveJson()} disabled={saving}>
              {saving ? 'Pushing…' : 'Push full config to daemon'}
            </button>
          </div>
        ) : null}
        <div className="drawer-actions">
          <button className="btn" onClick={() => void act('tune')} disabled={busy !== null} title="POST /api/tune/apply">
            {busy === 'tune' ? 'Tuning…' : '🎛 Auto-tune & apply'}
          </button>
          <button className="btn" onClick={() => void act('rotate')} disabled={busy !== null} title="POST /api/admin/rotate-key">
            {busy === 'rotate' ? 'Rotating…' : '🔑 Rotate cluster key'}
          </button>
          <button className="btn btn-danger" onClick={() => void act('reset')} disabled={busy !== null} title="POST /api/admin/reset-config">
            {busy === 'reset' ? 'Resetting…' : '♻ Reset config to defaults'}
          </button>
        </div>
      </aside>
    </div>
  );
}
