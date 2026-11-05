/**
 * wave-style.tsx —— 波形样式与歌词配色的全局选择
 *
 * 桌面右栏和窄屏进度条上方各渲染一条 WaveStrip，切样式必须两处一起变，
 * 所以状态放在 provider 里而不是组件内部；选择写进 localStorage，下次进来还是上次的样式。
 *
 * 配色也放这里：彩色 / 单色、以及歌词高亮色（当前行文字 + 非彩色波形跟着走）。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode,
} from 'react';
import { Storage } from '../lib/storage.js';
import { DEFAULT_WAVE_STYLE_ID, findWaveStyle, setWaveAccent, type WaveStyle } from '../lib/wave-styles';
import { highlightOnLight, useTheme } from './theme';
import { STORAGE_KEYS } from './constants';

interface WaveStyleContextValue {
  style: WaveStyle;
  select: (id: string) => void;
  /** true = 按样式自带色带；false = 只留歌词高亮色的亮度层次 */
  colored: boolean;
  setColored: (value: boolean) => void;
  /** 歌词高亮色；空字符串表示跟随主题默认 */
  lyricColor: string;
  setLyricColor: (hex: string) => void;
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

  const value = useMemo(
    () => ({ style: findWaveStyle(id), select, colored, setColored, lyricColor, setLyricColor }),
    [id, select, colored, setColored, lyricColor, setLyricColor],
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
