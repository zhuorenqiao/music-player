/**
 * glass.tsx —— 播放卡的透明度与毛玻璃强度
 *
 * 两个维度分开存、分开调：
 *   · 透明度：0 = 各主题原本的卡面，100 = 卡面彻底透出页面底色
 *   · 毛玻璃：0 = 普通卡面，100 = 模糊封面色雾 + 雾面 / 颗粒 / 高光 + 背景模糊
 * 值写进 localStorage，同时把 0~1 的 --glass-level / --frost-level 落到 <html>，
 * 由 .player 按它们各自缩放卡面 alpha 和磨砂层。
 */

import {
  createContext, useCallback, useContext, useLayoutEffect, useMemo, useState, type ReactNode,
} from 'react';
import { Storage, readNumber } from '../lib/storage.js';
import { STORAGE_KEYS } from './constants';

export const MAX_GLASS_TRANSPARENCY = 100;

const clamp = (value: number): number => Math.min(MAX_GLASS_TRANSPARENCY, Math.max(0, Math.round(value)));

interface GlassContextValue {
  /** 0~100，越大越透 */
  transparency: number;
  /** 0~100，越大越磨砂 */
  frost: number;
  setTransparency: (value: number) => void;
  setFrost: (value: number) => void;
}

const GlassContext = createContext<GlassContextValue | null>(null);

export function GlassProvider({ children }: { children: ReactNode }) {
  const [transparency, setTransparencyState] = useState<number>(
    () => readNumber(STORAGE_KEYS.cardTransparency, 0, 0, MAX_GLASS_TRANSPARENCY),
  );
  // 拆两个滑块之前「磨砂浓度 = 透明度」，没有 cardFrost 这个键时按透明度回填，保持原来的样子
  const [frost, setFrostState] = useState<number>(
    () => readNumber(
      STORAGE_KEYS.cardFrost,
      readNumber(STORAGE_KEYS.cardTransparency, 0, 0, MAX_GLASS_TRANSPARENCY),
      0,
      MAX_GLASS_TRANSPARENCY,
    ),
  );

  const setTransparency = useCallback((next: number) => {
    const value = clamp(next);
    setTransparencyState(value);
    Storage.write(STORAGE_KEYS.cardTransparency, value);
  }, []);

  const setFrost = useCallback((next: number) => {
    const value = clamp(next);
    setFrostState(value);
    Storage.write(STORAGE_KEYS.cardFrost, value);
  }, []);

  // layout effect：首帧就带上上次的设置，刷新时不会先闪一帧实心卡面
  useLayoutEffect(() => {
    const root = document.documentElement.style;
    root.setProperty('--glass-level', String(1 - transparency / 100));
    root.setProperty('--frost-level', String(frost / 100));
  }, [transparency, frost]);

  const value = useMemo<GlassContextValue>(
    () => ({ transparency, frost, setTransparency, setFrost }),
    [transparency, frost, setTransparency, setFrost],
  );

  return <GlassContext.Provider value={value}>{children}</GlassContext.Provider>;
}

export function useGlass(): GlassContextValue {
  const ctx = useContext(GlassContext);
  if (!ctx) {
    throw new Error('useGlass 必须在 GlassProvider 内使用');
  }
  return ctx;
}
