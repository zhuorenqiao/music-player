/**
 * Drawer.tsx —— 从右边缘滑入的抽屉
 *
 * 换肤和「菜单」共用：遮罩、滑入/滑出动画、焦点进出、Esc 关闭、Tab 环路都在这里，
 * 内容由调用方通过 children 传进来。
 */

import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';

/** 抽屉滑出 / 收回的时长（与 CSS 动画一致）。 */
export const EXIT_MS = 200;

const CloseIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
    <path d="M6 6l12 12M18 6L6 18" />
  </svg>
);

export function Drawer({ open, onClose, title, hint, label, width = 'default', children }: {
  open: boolean;
  onClose: () => void;
  title: string;
  hint?: string;
  /** 读屏用的对话框名称，默认用 title */
  label?: string;
  /** narrow：一级菜单那种窄抽屉；default：内容型（换肤） */
  width?: 'narrow' | 'default';
  children: ReactNode;
}) {
  /** 保留到退场动画结束再卸载，否则抽屉会瞬间消失 */
  const [mounted, setMounted] = useState(open);
  const [phase, setPhase] = useState<'in' | 'out'>('in');
  const panelRef = useRef<HTMLDivElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (open) {
      returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      setMounted(true);
      setPhase('in');
      return;
    }
    setPhase('out');
    const timer = window.setTimeout(() => setMounted(false), EXIT_MS);
    const back = returnFocus.current;
    returnFocus.current = null;
    if (back) {
      window.requestAnimationFrame(() => {
        if (document.contains(back)) {
          back.focus({ preventScroll: true });
        }
      });
    }
    return () => window.clearTimeout(timer);
  }, [open]);

  /** 打开时把焦点放进抽屉；Tab 在抽屉里循环，不跑到背后的播放器上 */
  useEffect(() => {
    if (open && mounted) {
      panelRef.current?.focus({ preventScroll: true });
    }
  }, [open, mounted]);

  if (!mounted) {
    return null;
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      onClose();
      return;
    }
    if (event.key !== 'Tab' || !panelRef.current) {
      return;
    }
    const items = Array.from(
      panelRef.current.querySelectorAll<HTMLElement>('button:not([disabled]), [href], input:not([disabled]), [tabindex]:not([tabindex="-1"])'),
    ).filter((element) => element.offsetParent !== null);
    if (items.length === 0) {
      return;
    }
    const first = items[0];
    const last = items[items.length - 1];
    if (event.shiftKey && (document.activeElement === first || !panelRef.current.contains(document.activeElement))) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !panelRef.current.contains(document.activeElement))) {
      event.preventDefault();
      first.focus();
    }
  };

  return (
    <div className={`drawer drawer--${phase}`}>
      <div className="drawer__scrim" onClick={onClose} />
      <div
        ref={panelRef}
        className={`drawer__panel${width === 'narrow' ? ' drawer__panel--narrow' : ''}`}
        role="dialog"
        aria-modal="true"
        aria-label={label ?? title}
        tabIndex={-1}
        onKeyDown={onKeyDown}
      >
        <header className="drawer__head">
          <div className="drawer__titles">
            <p className="drawer__title">{title}</p>
            {hint && <p className="drawer__hint">{hint}</p>}
          </div>
          <button className="drawer__close" type="button" aria-label={`关闭${title}`} title="关闭" onClick={onClose}>
            <CloseIcon />
          </button>
        </header>
        <div className="drawer__body">{children}</div>
      </div>
    </div>
  );
}
