/**
 * LyricColorButton.tsx —— 歌词高亮色
 *
 * 频谱条左端一个「T」小按钮，点开是一排色板：选中的颜色同时作用于
 * 当前行歌词（文字 + 辉光）和非彩色频谱的色相，选择写进 localStorage。
 * 第一颗「薄荷」是主题默认（不写死颜色，主题换了它也跟着换）。
 */

import { useEffect, useRef, useState } from 'react';
import { useWaveStyle } from '../state/wave-style';
import { highlightOnLight, useTheme } from '../state/theme';

/** 色板顺序按色相排，默认那颗放最前面。 */
const PRESETS: Array<{ name: string; color: string }> = [
  { name: '薄荷（默认）', color: '' },
  { name: '青', color: '#7de3ff' },
  { name: '蓝', color: '#8aa9ff' },
  { name: '紫', color: '#b98cff' },
  { name: '玫红', color: '#ff8fc7' },
  { name: '橙', color: '#ffb066' },
  { name: '金', color: '#ffe066' },
  { name: '白', color: '#f2f7fb' },
];

export function LyricColorButton() {
  const { lyricColor, setLyricColor } = useWaveStyle();
  const { resolvedMode } = useTheme();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  /** 白色主题下预览要跟实际效果一致：浅色会被自动压暗到白底读得清 */
  const swatchColor = (color: string): string => {
    if (!color) {
      return 'var(--accent-light)';
    }
    return resolvedMode === 'light' ? highlightOnLight(color) : color;
  };

  /** 点面板以外收起；捕获阶段监听，免得先被别的点击处理掉。 */
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        setOpen(false);
      }
    };
    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('keydown', onKeyDown, true);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('keydown', onKeyDown, true);
    };
  }, [open]);

  return (
    <div className="lyric-color" ref={rootRef}>
      <button
        className="lyric-color__trigger"
        type="button"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label="歌词高亮颜色"
        title="歌词高亮颜色"
        onClick={() => setOpen((value) => !value)}
      >
        T
      </button>

      {open && (
        <div className="lyric-color__panel" role="group" aria-label="歌词高亮颜色">
          {PRESETS.map((preset) => {
            const active = lyricColor === preset.color;
            return (
              <button
                key={preset.name}
                className="lyric-color__swatch"
                type="button"
                style={{ background: swatchColor(preset.color) }}
                aria-label={preset.name}
                aria-pressed={active}
                title={preset.name}
                data-active={active || undefined}
                onClick={() => {
                  setLyricColor(preset.color);
                  setOpen(false);
                }}
              />
            );
          })}
        </div>
      )}
    </div>
  );
}
