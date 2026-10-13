import { useStore } from '../store.js';

export function Toasts(): React.JSX.Element | null {
  const toasts = useStore((s) => s.toasts);
  const dismiss = useStore((s) => s.dismissToast);
  if (toasts.length === 0) return null;
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast toast-${t.level}`}>
          <div className="toast-body">
            <span className="toast-title">{t.title}</span>
            {t.msg ? <span className="toast-msg">{t.msg}</span> : null}
          </div>
          <button className="banner-x" onClick={() => dismiss(t.id)} aria-label="Dismiss">
            ✕
          </button>
        </div>
      ))}
    </div>
  );
}
