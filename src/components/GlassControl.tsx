/**
 * GlassControl.tsx —— 播放卡的透明度与毛玻璃
 *
 * 频谱条左端「T」右边的水滴小按钮，点开是两条滑杆：
 *   · 透明：卡面 alpha，往右越透，页面底色透上来
 *   · 磨砂：模糊封面色雾 + 雾面 / 颗粒 / 高光 + 背景模糊，往右越像毛玻璃
 * 两个值分开写进 localStorage，下次进来还是上次的设置。
 */

import { useEffect, useRef, useState } from 'react';
import { MAX_GLASS_TRANSPARENCY, useGlass } from '../state/glass';

export function GlassControl() {
  const { transparency, frost, setTransparency, setFrost } = useGlass();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

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
    <div className="glass-control" ref={rootRef}>
      <button
        className="glass-control__trigger"
        type="button"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label="卡面透明度与毛玻璃"
        title="卡面透明度与毛玻璃"
        onClick={() => setOpen((value) => !value)}
      >
        <svg viewBox="0 0 24 24" className="glass-control__icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M12 3.6c3.4 3.9 6 7 6 10.1a6 6 0 0 1-12 0c0-3.1 2.6-6.2 6-10.1Z" />
          <path d="M9.6 13.7a2.6 2.6 0 0 0 2.4 2.7" />
        </svg>
      </button>

      {open && (
        <div
          className="glass-control__panel"
          role="group"
          aria-label="卡面透明度与毛玻璃"
          /* 拖滑杆时别让手势冒泡到页面（滑切歌 / 点空白返回），
             也别触发浏览器的文字拖动和长按菜单 */
          onPointerDown={(event) => event.stopPropagation()}
          onTouchStart={(event) => event.stopPropagation()}
          onDragStart={(event) => event.preventDefault()}
          onContextMenu={(event) => event.preventDefault()}
        >
          <label className="glass-control__row">
            <span className="glass-control__label">透明</span>
            <input
              className="glass-control__slider"
              type="range"
              min={0}
              max={MAX_GLASS_TRANSPARENCY}
              step={1}
              value={transparency}
              aria-label="卡面透明度"
              aria-valuetext={`${transparency}%`}
              style={{ ['--slider-percent' as string]: `${transparency}%` }}
              onChange={(event) => setTransparency(Number(event.target.value))}
            />
            <span className="glass-control__value">{transparency}%</span>
          </label>
          <label className="glass-control__row">
            <span className="glass-control__label">磨砂</span>
            <input
              className="glass-control__slider"
              type="range"
              min={0}
              max={MAX_GLASS_TRANSPARENCY}
              step={1}
              value={frost}
              aria-label="毛玻璃强度"
              aria-valuetext={`${frost}%`}
              style={{ ['--slider-percent' as string]: `${frost}%` }}
              onChange={(event) => setFrost(Number(event.target.value))}
            />
            <span className="glass-control__value">{frost}%</span>
          </label>
        </div>
      )}
    </div>
  );
}
