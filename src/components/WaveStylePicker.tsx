/**
 * WaveStylePicker.tsx —— 歌词页右上角的波形样式下拉
 *
 * 触发按钮显示当前样式名，点开是一列「左边静态缩略图 + 右边样式名」的选项，
 * 选中后由下方的 WaveStrip 用同一段渲染代码画出来。
 *
 * 面板常驻 DOM、用 hidden 收起：useAutoHideScroll 的监听只在挂载时挂一次，
 * 条件渲染的话滚动条永远点不亮；顺带也省掉每次展开重画 17 张缩略图的开销。
 *
 * 键盘走 listbox 的 aria-activedescendant 模式：焦点留在面板上，上下键移动高亮，
 * Enter 选中，Esc 退回触发按钮。
 */

import { useEffect, useMemo, useRef, useState } from 'react';
import { useWaveStyle } from '../state/wave-style';
import { useAutoHideScroll } from '../state/useAutoHideScroll';
import { WAVE_STYLES, type WaveStyle } from '../lib/wave-styles';
import { renderWaveThumb, THUMB_HEIGHT, THUMB_WIDTH } from '../lib/wave-thumb';

const WaveIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden="true">
    <path d="M3 12h1.6M20.4 12H22" />
    <path d="M7 8.5v7M11 5.5v13M15 9.5v5" />
  </svg>
);

const CaretIcon = () => (
  <svg viewBox="0 0 24 24" className="icon icon--caret" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M6 9.5l6 6 6-6" />
  </svg>
);

const CheckIcon = () => (
  <svg viewBox="0 0 24 24" className="icon icon--check" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M5 12.5l4.6 4.6L19 7.4" />
  </svg>
);

/** 单个样式的静态缩略图：跑真实渲染器，只是喂固定种子而不是音频数据。 */
function Thumb({ style }: { style: WaveStyle }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (ref.current) {
      renderWaveThumb(ref.current, style);
    }
  }, [style]);
  return (
    <canvas
      ref={ref}
      className="wave-style__thumb"
      width={THUMB_WIDTH}
      height={THUMB_HEIGHT}
      style={{ width: THUMB_WIDTH, height: THUMB_HEIGHT }}
      aria-hidden="true"
    />
  );
}

export function WaveStylePicker() {
  const { style, select } = useWaveStyle();
  const currentIndex = useMemo(() => Math.max(0, WAVE_STYLES.indexOf(style)), [style]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(currentIndex);
  const rootRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const itemRefs = useRef<Array<HTMLDivElement | null>>([]);
  const { ref: listRef, scrolling } = useAutoHideScroll<HTMLDivElement>();

  /** 面板常驻，靠 hidden 收起，所以打开时要把焦点挪过去。 */
  useEffect(() => {
    if (!open) {
      return;
    }
    const raf = window.requestAnimationFrame(() => listRef.current?.focus());
    return () => window.cancelAnimationFrame(raf);
  }, [open, listRef]);

  /** 点面板以外任何地方收起。 */
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener('pointerdown', onPointerDown, true);
    return () => document.removeEventListener('pointerdown', onPointerDown, true);
  }, [open]);

  const close = (backToButton: boolean) => {
    setOpen(false);
    if (backToButton) {
      buttonRef.current?.focus();
    }
  };

  const choose = (index: number) => {
    select(WAVE_STYLES[index].id);
    close(true);
  };

  const moveActive = (next: number) => {
    const clamped = Math.max(0, Math.min(WAVE_STYLES.length - 1, next));
    setActive(clamped);
    itemRefs.current[clamped]?.scrollIntoView({ block: 'nearest' });
  };

  /**
   * 面板开着时这些键归下拉自己：Esc 在应用层是「退出歌词页」，上下键是「调音量」，
   * 不截断冒泡的话，选样式会顺手把音量改了、页面也一起关掉。
   */
  const onListKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const consume = () => {
      event.preventDefault();
      event.stopPropagation();
    };
    switch (event.key) {
      case 'Escape':
        consume();
        close(true);
        return;
      case 'Tab':
        close(false);
        return;
      case 'ArrowDown':
        consume();
        moveActive(active + 1);
        return;
      case 'ArrowUp':
        consume();
        moveActive(active - 1);
        return;
      case 'Home':
        consume();
        moveActive(0);
        return;
      case 'End':
        consume();
        moveActive(WAVE_STYLES.length - 1);
        return;
      case 'Enter':
      case ' ':
        consume();
        choose(active);
        return;
      default:
    }
  };

  return (
    <div className="wave-style" ref={rootRef}>
      <button
        ref={buttonRef}
        className="wave-style__trigger"
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls="wave-style-list"
        aria-label={`波形样式：${style.name}`}
        title="选择波形样式"
        onClick={() => {
          if (open) {
            close(false);
          } else {
            setActive(currentIndex);
            setOpen(true);
          }
        }}
      >
        <WaveIcon />
        <span className="wave-style__name">{style.name}</span>
        <CaretIcon />
      </button>

      <div
        id="wave-style-list"
        ref={listRef}
        className={`wave-style__panel${scrolling ? ' is-scrolling' : ''}`}
        role="listbox"
        aria-label="波形样式"
        aria-activedescendant={open ? `wave-style-opt-${active}` : undefined}
        tabIndex={-1}
        hidden={!open}
        onKeyDown={onListKeyDown}
      >
        {WAVE_STYLES.map((option, i) => (
          <div
            key={option.id}
            id={`wave-style-opt-${i}`}
            ref={(el) => {
              itemRefs.current[i] = el;
            }}
            className="wave-style__option"
            role="option"
            aria-selected={i === currentIndex}
            data-active={i === active || undefined}
            onMouseMove={() => setActive(i)}
            onClick={() => choose(i)}
          >
            <Thumb style={option} />
            <span className="wave-style__label">{option.name}</span>
            {i === currentIndex && <CheckIcon />}
          </div>
        ))}
      </div>
    </div>
  );
}
