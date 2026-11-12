/**
 * sleep-timer.tsx —— 睡眠定时器
 *
 * 设定一个时长，倒计时归零时**暂停播放**（保留当前进度，再按播放即可继续）。
 *
 * 状态只有一个：**截止时刻（deadline，墙钟时间戳）**。没有 deadline = 未启用。
 * 剩余时间由 1s 的 tick 现算（deadline - now），不另存一个会漂移的倒计时器。
 *
 * 定时器按墙钟走：切歌不重置、暂停 / 播放歌曲都不影响它 —— 它只认时间。
 * deadline 写进 localStorage：刷新页面或重开应用后倒计时接着走；否则用户刷新
 * 一下定时器就凭空失效，太意外。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode,
} from 'react';
import { Storage } from '../lib/storage.js';
import { STORAGE_KEYS } from './constants';
import { usePlayer } from './player';
import { useToast } from './toast';

/** 预设档位（分钟）。10 分钟是默认档。 */
export const SLEEP_TIMER_PRESETS = [10, 15, 20, 30, 60] as const;

/** 缺省时长（分钟）：面板打开时这一档默认选中，自定义输入也预填它。 */
export const SLEEP_TIMER_DEFAULT_MINUTES = 10;

/** 自定义输入的范围（分钟）。 */
export const SLEEP_TIMER_MIN_MINUTES = 1;
export const SLEEP_TIMER_MAX_MINUTES = 999;

/** 剩余不足这一分钟就算「快到了」（按钮上换个颜色提醒）。 */
const ENDING_THRESHOLD_MS = 60_000;

export interface SleepTimerContextValue {
  /** 截止时刻（时间戳 ms）；null = 未启用 */
  deadline: number | null;
  /** 剩余毫秒；未启用为 0 */
  remaining: number;
  /** 剩余时间的 mm:ss（未启用为空串） */
  remainingText: string;
  /** 剩余不足一分钟 */
  ending: boolean;
  /** 设定定时器（分钟；越界会被夹到合法区间） */
  start: (minutes: number) => void;
  /** 取消定时器 */
  cancel: () => void;
}

const SleepTimerContext = createContext<SleepTimerContextValue | null>(null);

/** 剩余毫秒 → mm:ss。分钟可以超过 59（60 分钟档就是 60:00）。 */
function formatRemaining(ms: number): string {
  const total = Math.ceil(Math.max(0, ms) / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

export function SleepTimerProvider({ children }: { children: ReactNode }) {
  const { pause } = usePlayer();
  const { show } = useToast();

  const [deadline, setDeadline] = useState<number | null>(() => {
    const stored = Storage.read(STORAGE_KEYS.sleepTimer, null);
    if (typeof stored !== 'number' || !Number.isFinite(stored)) {
      return null;
    }
    // 关了很久再打开：deadline 早就过了 → 当作没设过，顺手清掉
    if (stored <= Date.now()) {
      Storage.remove(STORAGE_KEYS.sleepTimer);
      return null;
    }
    return stored;
  });
  const [now, setNow] = useState(() => Date.now());

  /** 到点只触发一次；重新设定后要能再触发。 */
  const firedRef = useRef(false);

  /**
   * pause / show 走 ref：它们的身份可能因为别的状态变化而换，
   * 而倒计时的 tick 必须在整个期间一直有效（把它们放进依赖里会让定时器
   * 跟着无关的渲染反复重排）。
   */
  const pauseRef = useRef(pause);
  const showRef = useRef(show);
  useEffect(() => {
    pauseRef.current = pause;
    showRef.current = show;
  }, [pause, show]);

  useEffect(() => {
    if (deadline === null) {
      return;
    }
    const tick = () => {
      const current = Date.now();
      setNow(current);
      if (current < deadline || firedRef.current) {
        return;
      }
      firedRef.current = true;
      setDeadline(null);
      Storage.remove(STORAGE_KEYS.sleepTimer);
      pauseRef.current();
      showRef.current('定时结束，已暂停播放');
    };
    const timer = window.setInterval(tick, 1000);
    // 补一次：挂上这一刻可能已经过了截止时刻（页面被挂起过、或定时器是重启后恢复的）
    tick();
    return () => window.clearInterval(timer);
  }, [deadline]);

  const start = useCallback((minutes: number) => {
    const safe = Math.min(
      SLEEP_TIMER_MAX_MINUTES,
      Math.max(SLEEP_TIMER_MIN_MINUTES, Math.round(minutes)),
    );
    const next = Date.now() + safe * 60_000;
    firedRef.current = false;
    setDeadline(next);
    setNow(Date.now());
    Storage.write(STORAGE_KEYS.sleepTimer, next);
  }, []);

  const cancel = useCallback(() => {
    firedRef.current = false;
    setDeadline(null);
    Storage.remove(STORAGE_KEYS.sleepTimer);
  }, []);

  const remaining = deadline === null ? 0 : Math.max(0, deadline - now);
  const remainingText = useMemo(() => formatRemaining(remaining), [remaining]);

  const value = useMemo<SleepTimerContextValue>(() => ({
    deadline,
    remaining,
    remainingText,
    ending: remaining > 0 && remaining <= ENDING_THRESHOLD_MS,
    start,
    cancel,
  }), [cancel, deadline, remaining, remainingText, start]);

  return <SleepTimerContext.Provider value={value}>{children}</SleepTimerContext.Provider>;
}

/** @returns 睡眠定时器的状态与操作 */
export function useSleepTimer(): SleepTimerContextValue {
  const context = useContext(SleepTimerContext);
  if (!context) {
    throw new Error('useSleepTimer 必须在 SleepTimerProvider 内使用');
  }
  return context;
}
