/**
 * wave-style.tsx —— 波形样式与歌词配色的全局选择
 *
 * WaveStrip 只挂在进度条上方那一行（沉浸模式），全局只有一条；样式选择仍放在
 * provider 里而不是组件内部，选择写进 localStorage，下次进来还是上次的样式。
 *
 * 配色也放这里：彩色 / 单色、以及歌词高亮色（当前行文字 + 非彩色波形跟着走）。
 * 歌词字号缩放与歌词字体也一并放这里（同一块「歌词外观」面板、同样要跨会话记住）。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode,
} from 'react';
import { Storage } from '../lib/storage.js';
import { DEFAULT_LYRIC_FONT, ensureLyricWebFont, findLyricFont } from '../lib/lyric-fonts';
import { DEFAULT_WAVE_STYLE_ID, findWaveStyle, setWaveAccent, type WaveStyle } from '../lib/wave-styles';
import { highlightOnLight, useTheme } from './theme';
import { STORAGE_KEYS } from './constants';

/** 歌词字号的缩放范围（百分比）。100 = 设计稿原值。 */
export const LYRIC_SCALE_MIN = 70;
export const LYRIC_SCALE_MAX = 150;
export const LYRIC_SCALE_DEFAULT = 100;

interface WaveStyleContextValue {
  style: WaveStyle;
  select: (id: string) => void;
  /** true = 按样式自带色带；false = 只留歌词高亮色的亮度层次 */
  colored: boolean;
  setColored: (value: boolean) => void;
  /** 歌词高亮色；空字符串表示跟随主题默认 */
  lyricColor: string;
  setLyricColor: (hex: string) => void;
  /** 歌词字号缩放百分比（LYRIC_SCALE_MIN ~ LYRIC_SCALE_MAX） */
  lyricScale: number;
  setLyricScale: (value: number) => void;
  /** 歌词字体的 id（见 LYRIC_FONTS；default = 跟随界面字体） */
  lyricFont: string;
  setLyricFont: (id: string) => void;
}

const WaveStyleContext = createContext<WaveStyleContextValue | null>(null);

export function WaveStyleProvider({ children }: { children: ReactNode }) {
  const [id, setId] = useState<string>(() => {
    const stored = Storage.read(STORAGE_KEYS.waveStyle, DEFAULT_WAVE_STYLE_ID);
    // 样式以后增删过，存下来的 id 可能已经不存在：findWaveStyle 会兜回默认那条
    return typeof stored === 'string' ? stored : DEFAULT_WAVE_STYLE_ID;
  });
  const [colored, setColoredState] = useState<boolean>(() => Storage.read(STORAGE_KEYS.waveColored, true) !== false);
  const [lyricColor, setLyricColorState] = useState<string>(() => {
    const stored = Storage.read(STORAGE_KEYS.lyricColor, '');
    return typeof stored === 'string' ? stored : '';
  });
  const [lyricScale, setLyricScaleState] = useState<number>(() => {
    const stored = Storage.read(STORAGE_KEYS.lyricScale, LYRIC_SCALE_DEFAULT);
    // 存下来的值可能是旧版写坏的（字符串 / 越界）：一律夹回合法区间
    if (typeof stored !== 'number' || !Number.isFinite(stored)) {
      return LYRIC_SCALE_DEFAULT;
    }
    return Math.min(LYRIC_SCALE_MAX, Math.max(LYRIC_SCALE_MIN, Math.round(stored)));
  });
  const [lyricFont, setLyricFontState] = useState<string>(() => {
    const stored = Storage.read(STORAGE_KEYS.lyricFont, DEFAULT_LYRIC_FONT.id);
    // 字体清单可能增删过，存下来的 id 未必还在：findLyricFont 会兜回默认那条
    return typeof stored === 'string' ? findLyricFont(stored).id : DEFAULT_LYRIC_FONT.id;
  });

  const select = useCallback((next: string) => {
    setId(next);
    Storage.write(STORAGE_KEYS.waveStyle, next);
  }, []);

  const setColored = useCallback((next: boolean) => {
    setColoredState(next);
    Storage.write(STORAGE_KEYS.waveColored, next);
  }, []);

  const setLyricColor = useCallback((next: string) => {
    setLyricColorState(next);
    Storage.write(STORAGE_KEYS.lyricColor, next);
  }, []);

  const setLyricScale = useCallback((next: number) => {
    const safe = Math.min(LYRIC_SCALE_MAX, Math.max(LYRIC_SCALE_MIN, Math.round(next)));
    setLyricScaleState(safe);
    Storage.write(STORAGE_KEYS.lyricScale, safe);
  }, []);

  const setLyricFont = useCallback((next: string) => {
    const safe = findLyricFont(next).id;
    setLyricFontState(safe);
    Storage.write(STORAGE_KEYS.lyricFont, safe);
  }, []);

  /**
   * 高亮色通过 CSS 变量下发（当前行文字 / 辉光都用它），
   * 同时告诉波形渲染器：非彩色模式要跟着换色相。
   * 浅色主题下先把颜色压到白底上也读得清（浅金、浅白这类原色直接上白底等于看不见）。
   */
  const { resolvedMode } = useTheme();
  useEffect(() => {
    const root = document.documentElement;
    const effective = resolvedMode === 'light' && lyricColor ? highlightOnLight(lyricColor) : lyricColor;
    if (effective) {
      root.style.setProperty('--lyric-hl', effective);
    } else {
      root.style.removeProperty('--lyric-hl');
    }
    setWaveAccent(effective || null);
  }, [lyricColor, resolvedMode]);

  /**
   * 字号缩放同样走 CSS 变量：歌词行的 font-size 用 calc(原值 * var(--lyric-scale))。
   * 放在 <html> 上，首页紧凑歌词与歌词页两处一起生效。
   */
  useEffect(() => {
    document.documentElement.style.setProperty('--lyric-scale', String(lyricScale / 100));
  }, [lyricScale]);

  /**
   * 字体同样走 CSS 变量（--lyric-font），.lyrics 的 font-family 读它，紧凑预览与
   * 歌词页一起换。选回「默认」就把变量移除，让歌词重新跟着界面字体走。
   */
  useEffect(() => {
    const root = document.documentElement;
    const font = findLyricFont(lyricFont);
    // 上次选的是内置字体（文楷 / 得意黑）：进页面就得把样式表挂上，否则会一直落到降级字体
    ensureLyricWebFont(font.webFont);
    if (font.stack) {
      root.style.setProperty('--lyric-font', font.stack);
    } else {
      root.style.removeProperty('--lyric-font');
    }
  }, [lyricFont]);

  const value = useMemo(
    () => ({
      style: findWaveStyle(id),
      select,
      colored,
      setColored,
      lyricColor,
      setLyricColor,
      lyricScale,
      setLyricScale,
      lyricFont,
      setLyricFont,
    }),
    [
      id, select, colored, setColored, lyricColor, setLyricColor,
      lyricScale, setLyricScale, lyricFont, setLyricFont,
    ],
  );

  return <WaveStyleContext.Provider value={value}>{children}</WaveStyleContext.Provider>;
}

export function useWaveStyle(): WaveStyleContextValue {
  const ctx = useContext(WaveStyleContext);
  if (!ctx) {
    throw new Error('useWaveStyle 必须在 WaveStyleProvider 内使用');
  }
  return ctx;
}
