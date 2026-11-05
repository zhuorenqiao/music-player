/**
 * toast.tsx —— 轻提示
 *
 * 与 vanilla 版一致：同屏最多 3 条，**多出来的排队等位**（不是挤掉最旧的一条）。
 * 一次性导入几十首时，「已跳过 N 个不支持的文件」这类提示不该把更早的有用信息顶掉。
 *
 * 另外：**同一条提示不会堆叠**。带 key 的提示（例如播放模式）在屏幕上只保留一条，
 * 再来时改文案、重新计时；不传 key 的按文案去重。连点按钮不会挂出一串一样的弹框。
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { ToastItem, ToastKind } from './types';

/** 同屏最多几条（再多就挡住控制区了）。 */
const MAX_VISIBLE = 3;

/** 默认停留时长（毫秒）。 */
const DEFAULT_DURATION = 3200;

interface ToastContextValue {
  toasts: ToastItem[];
  /**
   * @param message 文案
   * @param kind 类型
   * @param duration 停留时长
   * @param key 去重键：同 key 只会有一条，再发就替换文案并重新计时
   */
  show: (message: string, kind?: ToastKind, duration?: number, key?: string) => void;
  dismiss: (id: number) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const seq = useRef(0);
  const timers = useRef(new Map<number, number>());
  /** 正在显示的（同步的真相源，state 只是它的渲染副本） */
  const visible = useRef<ToastItem[]>([]);
  /** 等位的（超过 MAX_VISIBLE 时排队） */
  const waiting = useRef<ToastItem[]>([]);

  const publish = useCallback(() => {
    setToasts([...visible.current]);
  }, []);

  const schedule = useCallback((item: ToastItem) => {
    const existing = timers.current.get(item.id);
    if (existing !== undefined) {
      window.clearTimeout(existing);
    }
    const timer = window.setTimeout(() => dismissRef.current(item.id), item.duration);
    timers.current.set(item.id, timer);
  }, []);

  /** 空出一个位子就从队列里补一条进来。 */
  const flush = useCallback(() => {
    if (visible.current.length >= MAX_VISIBLE || waiting.current.length === 0) {
      return;
    }
    const next = waiting.current.shift() as ToastItem;
    visible.current = [...visible.current, next];
    publish();
    schedule(next);
  }, [publish, schedule]);

  const dismiss = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer !== undefined) {
      window.clearTimeout(timer);
      timers.current.delete(id);
    }
    const next = visible.current.filter((toast) => toast.id !== id);
    if (next.length !== visible.current.length) {
      visible.current = next;
      publish();
    }
    // 等这一轮渲染提交后再补位，避免同帧里补进来又被覆盖
    window.setTimeout(flush, 0);
  }, [flush, publish]);

  // dismiss 要能被 schedule 调用（两者互相引用），用 ref 打破环
  const dismissRef = useRef(dismiss);
  useEffect(() => {
    dismissRef.current = dismiss;
  }, [dismiss]);

  const show = useCallback((message: string, kind: ToastKind = 'info', duration = DEFAULT_DURATION, key?: string) => {
    if (!message) {
      return;
    }
    const dedupeKey = key ?? message;
    const sameKey = (toast: ToastItem) => (toast.key ?? toast.message) === dedupeKey;

    // 已经挂在屏幕上：换文案 + 重新计时，不新增一条
    const current = visible.current.find(sameKey);
    if (current) {
      visible.current = visible.current.map((toast) => (
        toast === current ? { ...toast, message, kind, duration } : toast
      ));
      publish();
      schedule(visible.current.find((toast) => toast.id === current.id) as ToastItem);
      return;
    }

    // 还在排队：直接把排队里的那条换掉，位子不重复占
    const queued = waiting.current.find(sameKey);
    if (queued) {
      waiting.current = waiting.current.map((toast) => (
        toast === queued ? { ...toast, message, kind, duration } : toast
      ));
      return;
    }

    seq.current += 1;
    const item: ToastItem = { id: seq.current, message, kind, duration, key };
    if (visible.current.length >= MAX_VISIBLE) {
      waiting.current.push(item);
      return;
    }
    visible.current = [...visible.current, item];
    publish();
    schedule(item);
  }, [publish, schedule]);

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
