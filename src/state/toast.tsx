/**
 * toast.tsx —— 轻提示
 *
 * 与 vanilla 版一致：同屏最多 3 条，**多出来的排队等位**（不是挤掉最旧的一条）。
 * 一次性导入几十首时，「已跳过 N 个不支持的文件」这类提示不该把更早的有用信息顶掉。
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { ToastItem, ToastKind } from './types';

/** 同屏最多几条（再多就挡住控制区了）。 */
const MAX_VISIBLE = 3;

/** 默认停留时长（毫秒）。 */
const DEFAULT_DURATION = 3200;

interface ToastContextValue {
  toasts: ToastItem[];
  show: (message: string, kind?: ToastKind, duration?: number) => void;
  dismiss: (id: number) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const seq = useRef(0);
  const timers = useRef(new Map<number, number>());
  const waiting = useRef<ToastItem[]>([]);
  const slots = useRef(0);

  /** 空出一个位子就从队列里补一条进来。 */
  const flush = useCallback(() => {
    if (slots.current >= MAX_VISIBLE || waiting.current.length === 0) {
      return;
    }
    const next = waiting.current.shift() as ToastItem;
    slots.current += 1;
    setToasts((current) => [...current, next]);
    const timer = window.setTimeout(() => dismissRef.current(next.id), next.duration);
    timers.current.set(next.id, timer);
    // 一次只补一条，剩下的等各自的定时器
  }, []);

  const dismiss = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer !== undefined) {
      window.clearTimeout(timer);
      timers.current.delete(id);
    }
    setToasts((current) => {
      const next = current.filter((toast) => toast.id !== id);
      if (next.length !== current.length) {
        slots.current = Math.max(0, next.length);
      }
      return next;
    });
    // state 更新后再补位，避免读到旧的 slots
    window.setTimeout(flush, 0);
  }, [flush]);

  // dismiss 要能被 flush 调用（两者互相引用），用 ref 打破环
  const dismissRef = useRef(dismiss);
  useEffect(() => {
    dismissRef.current = dismiss;
  }, [dismiss]);

  const show = useCallback((message: string, kind: ToastKind = 'info', duration = DEFAULT_DURATION) => {
    if (!message) {
      return;
    }
    seq.current += 1;
    const item: ToastItem = { id: seq.current, message, kind, duration };

    if (slots.current >= MAX_VISIBLE) {
      waiting.current.push(item);
      return;
    }
    slots.current += 1;
    setToasts((current) => [...current, item]);
    const timer = window.setTimeout(() => dismissRef.current(item.id), duration);
    timers.current.set(item.id, timer);
  }, []);

  useEffect(() => () => {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    timers.current.clear();
  }, []);

  const value = useMemo(() => ({ toasts, show, dismiss }), [toasts, show, dismiss]);

  return <ToastContext.Provider value={value}>{children}</ToastContext.Provider>;
}

/** @returns 轻提示的上下文 */
export function useToast(): ToastContextValue {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast 必须在 ToastProvider 内使用');
  }
  return context;
}
