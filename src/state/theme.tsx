/**
 * theme.tsx —— 外观设置（明暗模式 + 主题色）
 *
 * 两个维度分开存，互不影响：
 *   · 明暗模式：system（跟随系统）/ light / dark
 *   · 主题色：mint / pink / blue
 * 最终只往 <html> 上落两个属性，具体颜色全部由 CSS 变量决定，组件层不碰颜色：
 *   data-mode="dark|light"   实际生效的明暗（system 在这里解析成具体值）
 *   data-accent="mint|pink|blue"
 */

import {
  createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useState, type ReactNode,
} from 'react';
import { Storage } from '../lib/storage.js';
import { STORAGE_KEYS } from './constants';

export type ThemeMode = 'system' | 'light' | 'dark';
export type ThemeColor = 'mint' | 'pink' | 'blue';
export type ResolvedMode = 'light' | 'dark';

export interface ModeOption {
  id: ThemeMode;
  name: string;
  hint: string;
}

export interface ColorOption {
  id: ThemeColor;
  name: string;
  hint: string;
}

export const MODE_OPTIONS: ModeOption[] = [
  { id: 'system', name: '系统', hint: '跟随系统的浅色 / 深色' },
  { id: 'light', name: '浅色', hint: '浅色纸面 + 柔和阴影分层' },
  { id: 'dark', name: '深色', hint: '深色底 + 高光' },
];

export const COLOR_OPTIONS: ColorOption[] = [
  { id: 'mint', name: '薄荷', hint: '薄荷绿高光' },
  { id: 'pink', name: '粉色', hint: '玫瑰粉高光' },
  { id: 'blue', name: '蓝色', hint: '靛蓝高光' },
];

interface ThemeContextValue {
  mode: ThemeMode;
  color: ThemeColor;
  /** system 解析后的实际明暗，给需要「浅色底压暗文字」的地方用 */
  resolvedMode: ResolvedMode;
  /** 明暗 + 主题色的组合 key：波形这类「变了就重画」的地方拿它做依赖 */
  themeKey: string;
  setMode: (next: ThemeMode) => void;
  setColor: (next: ThemeColor) => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

const isMode = (value: unknown): value is ThemeMode => (
  value === 'system' || value === 'light' || value === 'dark'
);

const isColor = (value: unknown): value is ThemeColor => (
  value === 'mint' || value === 'pink' || value === 'blue'
);

/** 老版本只存一个 theme 键（mint / pink / blue / light），读到它就折成新的两个维度 */
function readLegacyTheme(): unknown {
  return Storage.read(STORAGE_KEYS.theme, null);
}

function readMode(): ThemeMode {
  const stored = Storage.read(STORAGE_KEYS.themeMode, null);
  if (isMode(stored)) {
    return stored;
  }
  const legacy = readLegacyTheme();
  if (legacy === 'system' || legacy === 'light' || legacy === 'dark') {
    return legacy;
  }
  // 老的四套主题里，浅色归到 light，其余三色都是深色底
  if (legacy === 'mint' || legacy === 'pink' || legacy === 'blue') {
    return 'dark';
  }
  return 'system';
}

function readColor(): ThemeColor {
  const stored = Storage.read(STORAGE_KEYS.themeColor, null);
  if (isColor(stored)) {
    return stored;
  }
  const legacy = readLegacyTheme();
  return isColor(legacy) ? legacy : 'mint';
}

const readSystemDark = (): boolean => window.matchMedia('(prefers-color-scheme: dark)').matches;

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(readMode);
  const [color, setColorState] = useState<ThemeColor>(readColor);
  const [systemDark, setSystemDark] = useState(readSystemDark);

  useEffect(() => {
    const query = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = (event: MediaQueryListEvent) => setSystemDark(event.matches);
    // 首帧到 effect 之间系统可能已经切过一次，补读一次
    setSystemDark(query.matches);
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);

  const resolvedMode: ResolvedMode = mode === 'system' ? (systemDark ? 'dark' : 'light') : mode;

  // 用 layout effect：首帧就换上属性，切主题不会先闪一帧旧色
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.dataset.mode = resolvedMode;
    root.dataset.accent = color;
    // 老属性留着会命中旧的 [data-theme] 选择器，清掉
    delete root.dataset.theme;
    // 手机浏览器的工具栏 / 状态栏底色跟着当前模式走：否则系统深色时，
    // 用户选了浅色，页面是浅的，浏览器那圈还是黑的
    const bg = getComputedStyle(root).getPropertyValue('--bg').trim();
    if (bg) {
      document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')?.setAttribute('content', bg);
    }
  }, [resolvedMode, color]);

  const setMode = useCallback((next: ThemeMode) => {
    setModeState(next);
    Storage.write(STORAGE_KEYS.themeMode, next);
  }, []);

  const setColor = useCallback((next: ThemeColor) => {
    setColorState(next);
    Storage.write(STORAGE_KEYS.themeColor, next);
  }, []);

  const value = useMemo<ThemeContextValue>(() => ({
    mode,
    color,
    resolvedMode,
    themeKey: `${resolvedMode}-${color}`,
    setMode,
    setColor,
  }), [mode, color, resolvedMode, setMode, setColor]);

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) {
    throw new Error('useTheme 必须在 ThemeProvider 内使用');
  }
  return ctx;
}

/* --------------------------------------------------------------------------
   颜色工具：浅色主题下把用户选的高亮色压到「白底上也读得清」
   -------------------------------------------------------------------------- */

const WHITE = { r: 255, g: 255, b: 255 };

function parseHex(hex: string): { r: number; g: number; b: number } | null {
  const match = String(hex).trim().match(/^#([0-9a-f]{6})$/i);
  if (!match) {
    return null;
  }
  const int = parseInt(match[1], 16);
  return { r: (int >> 16) & 255, g: (int >> 8) & 255, b: int & 255 };
}

const channelLum = (value: number): number => {
  const v = value / 255;
  return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
};

const luminance = ({ r, g, b }: { r: number; g: number; b: number }): number => (
  0.2126 * channelLum(r) + 0.7152 * channelLum(g) + 0.0722 * channelLum(b)
);

const contrastOnWhite = (c: { r: number; g: number; b: number }): number => (
  (luminance(WHITE) + 0.05) / (luminance(c) + 0.05)
);

const toHex = ({ r, g, b }: { r: number; g: number; b: number }): string => (
  `#${[r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('')}`
);

/**
 * 浅色主题下的高亮色。
 *
 * 用户选的薄荷 / 金 / 白这类高明度颜色放在白底歌词上几乎看不见（金 #ffe066 约 1.3:1），
 * 所以保持色相不变、按比例压暗，直到与白底的对比度够用；压到很深仍不够（极少见）就用最暗的那档。
 * @param hex 用户选的颜色
 * @param min 期望的最小对比度（正文级别 4.5）
 * @returns 可直接用于文字的颜色
 */
export function highlightOnLight(hex: string, min = 4.5): string {
  const base = parseHex(hex);
  if (!base) {
    return hex;
  }
  if (contrastOnWhite(base) >= min) {
    return toHex(base);
  }
  let best = base;
  // 每步压 6%，最多压到 12% 亮度；色相基本保持，只是变深
  for (let factor = 0.94; factor >= 0.12; factor -= 0.06) {
    const candidate = { r: base.r * factor, g: base.g * factor, b: base.b * factor };
    best = candidate;
    if (contrastOnWhite(candidate) >= min) {
      break;
    }
  }
  return toHex(best);
}
