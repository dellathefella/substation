import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import { api, authToken, setAuthToken } from '../api.js';
import { useStore } from '../store.js';
import type { ConfigPatch, RuntimeConfig } from '../types.js';

interface Field {
  path: string;
  label: string;
  type: 'number' | 'bool' | 'text';
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
      { path: 'cluster.controller_id', label: 'Controller id', type: 'text' },
      { path: 'cluster.heartbeat_ms', label: 'Heartbeat interval', type: 'number', hint: 'ms' },
      { path: 'cluster.auto_heal', label: 'Auto-heal (restart dead engines + rpc workers)', type: 'bool' },
      { path: 'node.agent_port', label: 'My agent port', type: 'number' },
      { path: 'node.rpc_port', label: 'My RPC port', type: 'number' },
    ],
  },
];


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
  const [tierRows, setTierRows] = useState<{ name: string; priority: string; desc: string; models: string[] }[]>([]);
  const [defaultModel, setDefaultModel] = useState('');
  const [token, setToken] = useState('');
  const [tab, setTab] = useState<'form' | 'tiers' | 'profiles' | 'json'>('form');
  const [profiles, setProfiles] = useState<NonNullable<RuntimeConfig['models']>>([]);
  const [jsonText, setJsonText] = useState('');
  const [jsonErr, setJsonErr] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [nodesDraft, setNodesDraft] = useState<Record<string, { host: string; agent_port: string; rpc_port: string }>>({});
  const [joinCode, setJoinCode] = useState<string | null>(null);
  const [rpcUp, setRpcUp] = useState<boolean | null>(null);


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
    const rawNodes = ((config as Record<string, unknown> | null)?.nodes ?? {}) as Record<string, { host?: string; agent_port?: number; rpc_port?: number }>;
    setNodesDraft(Object.fromEntries(Object.entries(rawNodes).map(([id, n]) => [id, { host: n.host ?? '', agent_port: String(n.agent_port ?? 8801), rpc_port: String(n.rpc_port ?? 50052) }])));
    setRpcUp((config as Record<string, unknown> | null)?.cluster != null ? true : null);
    const rawTiers = (config?.orchestrator?.tiers ?? {}) as Record<string, { models?: string[]; priority?: number; desc?: string }>;
    setTierRows(Object.entries(rawTiers)
      .map(([name, v]) => ({
        name,
        priority: String(v?.priority ?? (name === 'fast' ? 0 : name === 'smart' ? 2 : 1)),
        desc: v?.desc ?? '',
        models: v?.models ?? [],
      }))
      .sort((a, b) => Number(a.priority) - Number(b.priority) || a.name.localeCompare(b.name)));
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
        } else if (f.type === 'text') {
          setPath(patch, f.path, String(raw));
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
    if (defaultModel) setPath(patch, 'orchestrator.default_model', defaultModel);
    const merged = { ...patch };
    if (count === 0 && !defaultModel) {
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
              {placementOf(p) === 'split' ? (
                <label className="field">
                  <span className="field-label">
                    split workers <span className="field-hint">blank = all joined + healthy</span>
                  </span>
                  <input
                    type="text"
                    placeholder="local studio0 studio1"
                    value={(p.placement ?? '').startsWith('split:') ? (p.placement ?? '').slice(6).split('+').join(' ') : ''}
                    onChange={(e) => {
                      const ids = e.target.value.split(/[\s,]+/).filter(Boolean);
                      upd(i, { placement: ids.length > 0 ? `split:${ids.join('+')}` : 'split' });
                    }}
                  />
                </label>
              ) : null}
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

  const updn = (id: string, key: 'host' | 'agent_port' | 'rpc_port', v: string): void =>
    setNodesDraft((ns) => ({ ...ns, [id]: { ...(ns[id] ?? { host: '', agent_port: '8801', rpc_port: '50052' }), [key]: v } }));

  const addNode = (): void =>
    setNodesDraft((ns) => {
      let id = 'studio-new';
      let i = 2;
      while (ns[id] !== undefined) id = `studio-${i++}`;
      return { ...ns, [id]: { host: '', agent_port: '8801', rpc_port: '50052' } };
    });

  const saveNodes = async (): Promise<void> => {
    const nodes: Record<string, unknown> = {};
    for (const [id, n] of Object.entries(nodesDraft)) {
      if (!n.host) continue;
      nodes[id] = { host: n.host, agent_port: Number(n.agent_port) || 8801, rpc_port: Number(n.rpc_port) || 50052 };
    }
    setSaving(true);
    const res = await api.putConfig({ nodes } as unknown as ConfigPatch);
    setSaving(false);
    if (res.ok) {
      replaceConfig(await api.getConfig());
      pushToast('success', 'Nodes saved', '[nodes] table updated + persisted to TOML');
    } else {
      pushToast('error', 'Nodes save failed', String(res.status));
    }
  };

  const removeNode = async (id: string): Promise<void> => {
    const res = await api.unjoin(id);
    setNodesDraft((ns) => {
      const c = { ...ns };
      delete c[id];
      return c;
    });
    replaceConfig(await api.getConfig());
    if (res.ok) pushToast('success', `Node ${id} unjoined`);
    else pushToast('error', `Unjoin ${id} failed`, String(res.status));
  };

  const genCode = async (): Promise<void> => {
    setBusy('join');
    const res = await api.joinCode();
    setBusy(null);
    if (res.ok) {
      const b = res.body as { code?: string };
      setJoinCode(b?.code ?? null);
    } else {
      pushToast('error', 'Join code failed', String(res.status));
    }
  };

  const rpcSelfToggle = async (): Promise<void> => {
    setBusy('rpc');
    const res = await api.rpcSelf(!(rpcUp ?? true));
    setBusy(null);
    if (res.ok) {
      const b = res.body as { rpc_up?: boolean };
      setRpcUp(b?.rpc_up ?? null);
      pushToast('success', `RPC worker ${b?.rpc_up ? 'started' : 'stopped'}`);
    } else {
      pushToast('error', 'RPC worker toggle failed', String(res.status));
    }
  };

  const act = async (kind: 'tune' | 'rotate' | 'reset' | 'restart'): Promise<void> => {
    if (kind === 'reset' && !window.confirm('Reset config to factory defaults? This disables auth and restores the template model catalog.')) return;
    if (kind === 'restart' && !window.confirm('Restart the daemon on this Mac AND every joined node? In-flight requests will fail for a few seconds.')) return;
    setBusy(kind);
    const res = kind === 'tune' ? await api.tuneApply()
      : kind === 'rotate' ? await api.rotateKey()
      : kind === 'restart' ? await api.restartDaemons()
      : await api.resetConfig();
    setBusy(null);
    if (kind === 'restart' && res.ok) {
      pushToast('success', 'Daemons restarting', 'all nodes re-executing; dashboard will blink offline');
      return;
    }
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

  const upTier = (name: string, patch: Partial<{ priority: string; desc: string; models: string[] }>): void =>
    setTierRows((rows) => rows.map((r) => (r.name === name ? { ...r, ...patch } : r)));

  const moveModel = (name: string, i: number, dir: -1 | 1): void =>
    setTierRows((rows) => rows.map((r) => {
      if (r.name !== name) return r;
      const j = i + dir;
      if (j < 0 || j >= r.models.length) return r;
      const ms = [...r.models];
      const moved = ms.splice(i, 1)[0];
      if (moved === undefined) return r;
      ms.splice(j, 0, moved);
      return { ...r, models: ms };
    }));

  const addTier = (): void =>
    setTierRows((rows) => {
      let name = 'new-tier';
      let i = 2;
      while (rows.some((r) => r.name === name)) name = `new-tier-${i++}`;
      const maxP = rows.reduce((m, r) => Math.max(m, Number(r.priority) || 0), -1);
      return [...rows, { name, priority: String(maxP + 1), desc: '', models: [] }];
    });

  const renameTier = (old: string, next: string): void =>
    setTierRows((rows) => rows.map((r) => (r.name === old ? { ...r, name: next.trim() } : r)));

  const removeTier = async (name: string): Promise<void> => {
    const res = await api.erase(`orchestrator.tiers.${name}`);
    setTierRows((rows) => rows.filter((r) => r.name !== name));
    replaceConfig(await api.getConfig());
    if (res.ok) pushToast('success', `Tier ${name} removed`);
    else pushToast('error', `Remove tier ${name} failed`, String(res.status));
  };

  const saveTiers = async (): Promise<void> => {
    const tiers: Record<string, unknown> = {};
    for (const r of tierRows) {
      if (!r.name.trim()) continue;
      const entry: Record<string, unknown> = { models: r.models, priority: Number(r.priority) || 0 };
      if (r.desc.trim()) entry.desc = r.desc.trim();
      tiers[r.name.trim()] = entry;
    }
    if (Object.keys(tiers).length !== tierRows.length || Object.keys(tiers).length === 0) {
      pushToast('error', 'Every tier needs a name');
      return;
    }
    setSaving(true);
    const res = await api.putConfig({ orchestrator: { tiers } } as unknown as ConfigPatch);
    setSaving(false);
    if (res.ok) {
      replaceConfig(await api.getConfig());
      pushToast('success', 'Tiers saved', 'triage prompt + routing updated');
    } else {
      const body = res.body as { error?: { message?: string } } | null;
      pushToast('error', 'Tiers save failed', body?.error?.message ?? String(res.status));
    }
  };

  const tiersTab = (
    <div className="tiers">
          <div className="drawer-section">
            <div className="drawer-section-title">Tiers (auto routing)</div>
            <div className="prof-note">
              Priority = routing order (low → light/cheap … high → heavy). Triage classifies into these names;
              session stickiness one-way upgrades toward higher priority. Models are tried top-to-bottom.
            </div>
            {tierRows.map((r) => (
              <div className="tier-card" key={r.name}>
                <div className="tier-head">
                  <input
                    className="prof-name"
                    value={r.name}
                    disabled={r.name === 'auto'}
                    onChange={(e) => renameTier(r.name, e.target.value)}
                    onBlur={(e) => renameTier(r.name, e.target.value)}
                  />
                  <label className="tier-prio" title="priority">
                    prio
                    <input type="number" step={1} value={r.priority} onChange={(e) => upTier(r.name, { priority: e.target.value })} />
                  </label>
                  <button className="banner-x" aria-label={`Remove ${r.name}`} onClick={() => void removeTier(r.name)}>✕</button>
                </div>
                <input className="prof-name tier-desc" placeholder="description for triage (optional)" value={r.desc} onChange={(e) => upTier(r.name, { desc: e.target.value })} />
                {r.models.length > 0 ? (
                  <ul className="tier-models">
                    {r.models.map((m, i) => (
                      <li key={m}>
                        <span className="tier-mi">{i + 1}</span>
                        <code>{m}</code>
                        <span className="tier-mtools">
                          <button className="btn btn-sm" disabled={i === 0} onClick={() => moveModel(r.name, i, -1)} aria-label="raise priority">↑</button>
                          <button className="btn btn-sm" disabled={i === r.models.length - 1} onClick={() => moveModel(r.name, i, 1)} aria-label="lower priority">↓</button>
                          <button className="btn btn-sm" onClick={() => upTier(r.name, { models: r.models.filter((x) => x !== m) })} aria-label="remove from tier">✕</button>
                        </span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <span className="dim tier-empty">no models — pick one below</span>
                )}
                <select
                  value=""
                  onChange={(e) => {
                    const m = e.target.value;
                    if (m && !r.models.includes(m)) upTier(r.name, { models: [...r.models, m] });
                  }}
                >
                  <option value="">+ add model to {r.name}…</option>
                  {modelNames.filter((n) => !r.models.includes(n)).map((n) => (
                    <option key={n} value={n}>{n}</option>
                  ))}
                </select>
              </div>
            ))}
            <div className="prof-actions">
              <button type="button" className="btn" onClick={addTier}>+ Add tier</button>
              <button type="button" className="btn btn-primary" onClick={() => void saveTiers()} disabled={saving}>Save tiers</button>
            </div>
            <label className="field">
              <span className="field-label">
                Fallback model <span className="field-hint">when orchestrator is down</span>
              </span>
              <input type="text" placeholder="(smallest catalog model)" value={defaultModel} onChange={(e) => setDefaultModel(e.target.value)} />
            </label>
          </div>
    </div>
  );
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
        ) : f.type === 'text' ? (
          <input type="text" value={typeof raw === 'string' ? raw : ''} onChange={(e) => setDraft((d) => ({ ...d, [f.path]: e.target.value }))} />
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
          <button className={`nav-btn${tab === 'tiers' ? ' active' : ''}`} onClick={() => setTab('tiers')}>
            Tiers
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
          {SECTIONS.map((s) => (
            <div key={s.title} className="drawer-section">
              <div className="drawer-section-title">{s.title}</div>
              {s.fields.map(field)}
            </div>
          ))}
          <div className="drawer-section">
            <div className="drawer-section-title">Cluster nodes — [nodes] table</div>
            {Object.entries(nodesDraft).map(([id, n]) => (
              <div className="node-row" key={id}>
                <span className="node-id">{id}</span>
                <input className="prof-name" placeholder="host / ip" value={n.host} onChange={(e) => updn(id, 'host', e.target.value)} />
                <input className="prof-name node-port" type="number" title="agent port" value={n.agent_port} onChange={(e) => updn(id, 'agent_port', e.target.value)} />
                <input className="prof-name node-port" type="number" title="rpc port" value={n.rpc_port} onChange={(e) => updn(id, 'rpc_port', e.target.value)} />
                <button type="button" className="banner-x" aria-label={`Remove ${id}`} onClick={() => void removeNode(id)}>✕</button>
              </div>
            ))}
            <div className="prof-actions">
              <button type="button" className="btn" onClick={addNode}>+ Add node</button>
              <button type="button" className="btn btn-primary" onClick={() => void saveNodes()} disabled={saving}>Save nodes</button>
            </div>
            <div className="prof-note">
              host/ports must match the peer’s own [node] table. ✕ unjoins (forgets + removes from TOML); rejoin via a fresh code.
            </div>
          </div>
          <div className="drawer-section">
            <div className="drawer-section-title">RPC & join</div>
            <div className="prof-actions">
              <button type="button" className="btn" onClick={() => void genCode()} disabled={busy !== null}>⚡ New join code</button>
              <button type="button" className="btn" onClick={() => void rpcSelfToggle()} disabled={busy !== null}>
                {busy === 'rpc' ? 'Working…' : rpcUp === false ? '▶ RPC worker: start (this Mac)' : '⏹ RPC worker: stop (this Mac)'}
              </button>
            </div>
            {joinCode ? (
              <div className="code-box" role="button" onClick={() => void navigator.clipboard?.writeText(joinCode).then(() => pushToast('success', 'Join code copied'))}>
                <code>{joinCode}</code> <span className="dim">· click to copy · enter on the peer within 10 min</span>
              </div>
            ) : null}
          </div>
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
        {tab === 'tiers' ? tiersTab : null}
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
          <button className="btn" onClick={() => void act('restart')} disabled={busy !== null} title="POST /api/cluster/restart-daemons — re-execs every substationd">
            {busy === 'restart' ? 'Restarting…' : '🔁 Restart daemons (all)'}
          </button>
          <button className="btn btn-danger" onClick={() => void act('reset')} disabled={busy !== null} title="POST /api/admin/reset-config">
            {busy === 'reset' ? 'Resetting…' : '♻ Reset config to defaults'}
          </button>
        </div>
      </aside>
    </div>
  );
}
