/**
 * wave-style.tsx —— 波形样式的全局选择
 *
 * 桌面右栏和窄屏进度条上方各渲染一条 WaveStrip，切样式必须两处一起变，
 * 所以状态放在 provider 里而不是组件内部；选择写进 localStorage，下次进来还是上次的样式。
 */

import {
  createContext, useCallback, useContext, useMemo, useState, type ReactNode,
} from 'react';
import { Storage } from '../lib/storage.js';
import { DEFAULT_WAVE_STYLE_ID, findWaveStyle, type WaveStyle } from '../lib/wave-styles';
import { STORAGE_KEYS } from './constants';

interface WaveStyleContextValue {
  style: WaveStyle;
  select: (id: string) => void;
}

const WaveStyleContext = createContext<WaveStyleContextValue | null>(null);

export function WaveStyleProvider({ children }: { children: ReactNode }) {
  const [id, setId] = useState<string>(() => {
    const stored = Storage.read(STORAGE_KEYS.waveStyle, DEFAULT_WAVE_STYLE_ID);
    // 样式以后增删过，存下来的 id 可能已经不存在：findWaveStyle 会兜回默认那条
    return typeof stored === 'string' ? stored : DEFAULT_WAVE_STYLE_ID;
  });

  const select = useCallback((next: string) => {
    setId(next);
    Storage.write(STORAGE_KEYS.waveStyle, next);
  }, []);

  const value = useMemo(
    () => ({ style: findWaveStyle(id), select }),
    [id, select],
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
