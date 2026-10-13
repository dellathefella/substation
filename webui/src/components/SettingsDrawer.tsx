import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import { api } from '../api.js';
import { useStore } from '../store.js';
import type { ConfigPatch, RuntimeConfig } from '../types.js';

interface Field {
  key: string;
  label: string;
  type: 'number' | 'text' | 'bool';
  step?: number;
  min?: number;
  hint?: string;
}

const FIELDS: readonly Field[] = [
  { key: 'default_ctx', label: 'Default context window', type: 'number', step: 1024, hint: 'tokens' },
  { key: 'session_stick_seconds', label: 'Session stickiness', type: 'number', hint: 's' },
  { key: 'max_concurrent_requests', label: 'Max concurrent requests', type: 'number', min: 1 },
  { key: 'triage_timeout_ms', label: 'Triage timeout', type: 'number', hint: 'ms' },
  { key: 'triage_upgrade_confidence', label: 'Triage upgrade confidence', type: 'number', step: 0.05, hint: '0..1' },
  { key: 'cache_enabled', label: 'Prompt cache enabled', type: 'bool' },
  { key: 'cache_max_entries', label: 'Cache max entries', type: 'number' },
  { key: 'cache_max_bytes_mb', label: 'Cache max bytes', type: 'number', hint: 'MB' },
  { key: 'idle_evict_seconds', label: 'Idle engine evict', type: 'number', hint: 's' },
  { key: 'min_free_ram_gb', label: 'Min free RAM to load', type: 'number', hint: 'GB' },
];

function readField(cfg: RuntimeConfig | null, key: string): string | boolean {
  if (key === 'cluster.enabled') return cfg?.cluster?.enabled === true;
  const v = (cfg as Record<string, unknown> | null | undefined)?.[key];
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return String(v);
  return '';
}

export function SettingsDrawer(props: { open: boolean; onClose: () => void }): React.JSX.Element | null {
  const config = useStore((s) => s.config);
  const pushToast = useStore((s) => s.pushToast);
  const patchConfigLocal = useStore((s) => s.patchConfigLocal);
  const [draft, setDraft] = useState<Record<string, string | boolean>>({});
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!props.open) return;
    const next: Record<string, string | boolean> = {};
    for (const f of FIELDS) next[f.key] = readField(config, f.key);
    setDraft(next);
  }, [props.open, config]);

  if (!props.open) return null;

  const save = async (e: FormEvent): Promise<void> => {
    e.preventDefault();
    const patch: ConfigPatch = {};
    for (const f of FIELDS) {
      const raw = draft[f.key];
      if (raw === undefined || raw === '') continue;
      if (f.type === 'bool') {
        patch[f.key] = raw === true;
      } else {
        const n = Number(raw);
        if (Number.isFinite(n)) patch[f.key] = n;
      }
    }
    if (Object.keys(patch).length === 0) {
      pushToast('info', 'Nothing to save');
      return;
    }
    setSaving(true);
    const res = await api.putConfig(patch);
    setSaving(false);
    if (res.ok) {
      patchConfigLocal(patch);
      pushToast('success', 'Config updated', Object.keys(patch).join(', '));
      props.onClose();
    } else {
      pushToast('error', 'Config update failed', String(res.status || 'daemon unreachable'));
    }
  };

  return (
    <div className="drawer-scrim" onClick={props.onClose} role="presentation">
      <aside className="drawer" role="dialog" aria-label="Settings" onClick={(e) => e.stopPropagation()}>
        <header className="drawer-head">
          <h2>Settings</h2>
          <button className="banner-x" onClick={props.onClose} aria-label="Close settings">
            ✕
          </button>
        </header>
        <p className="drawer-note">
          PUT <code>/api/config</code> partial patch · daemon applies live, persists to config TOML and broadcasts{' '}
          <code>config.changed</code>.
        </p>
        <form className="drawer-form" onSubmit={(e) => void save(e)}>
          {FIELDS.map((f) => {
            const raw = draft[f.key];
            return (
              <label key={f.key} className="field">
                <span className="field-label">
                  {f.label}
                  {f.hint ? <span className="field-hint">{f.hint}</span> : null}
                </span>
                {f.type === 'bool' ? (
                  <input
                    type="checkbox"
                    checked={raw === true}
                    onChange={(e) => setDraft((d) => ({ ...d, [f.key]: e.target.checked }))}
                  />
                ) : (
                  <input
                    type="number"
                    step={f.step ?? 1}
                    min={f.min}
                    value={typeof raw === 'string' ? raw : ''}
                    onChange={(e) => setDraft((d) => ({ ...d, [f.key]: e.target.value }))}
                  />
                )}
              </label>
            );
          })}
          <button type="submit" className="btn btn-primary drawer-save" disabled={saving}>
            {saving ? 'Saving…' : 'Save & push to daemon'}
          </button>
        </form>
      </aside>
    </div>
  );
}
