/**
 * SleepTimerButton.tsx —— 睡眠定时器
 *
 * 控制条上方那排里的闹钟小按钮（与「T」「水滴」同规格，26px）：
 * 未启用时是个图标；倒计时跑着时按钮自己撑成一枚药丸，直接显示剩余 mm:ss。
 * 点开是一块面板：5 档预设 + 自定义分钟数 + 开始 / 取消。
 */

import { useEffect, useRef, useState } from 'react';
import {
  SLEEP_TIMER_DEFAULT_MINUTES, SLEEP_TIMER_MAX_MINUTES, SLEEP_TIMER_MIN_MINUTES,
  SLEEP_TIMER_PRESETS, useSleepTimer,
} from '../state/sleep-timer';

export function SleepTimerButton() {
  const { deadline, remainingText, ending, start, cancel } = useSleepTimer();
  const [open, setOpen] = useState(false);
  /** 面板里即将设定的分钟数（预设与自定义输入共用这一个值） */
  const [minutes, setMinutes] = useState(SLEEP_TIMER_DEFAULT_MINUTES);
  /** 自定义输入框里的原始文本（可能为空或越界，所以和 minutes 分开存） */
  const [custom, setCustom] = useState(String(SLEEP_TIMER_DEFAULT_MINUTES));
  const rootRef = useRef<HTMLDivElement>(null);

  const running = deadline !== null;

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

  /** 自定义输入：只在合法时改「即将设定的分钟数」，非法输入不影响已选的档。 */
  const onCustomChange = (text: string) => {
    setCustom(text);
    const value = Number(text);
    if (text.trim() !== '' && Number.isFinite(value)
      && value >= SLEEP_TIMER_MIN_MINUTES && value <= SLEEP_TIMER_MAX_MINUTES) {
      setMinutes(Math.round(value));
    }
  };

  return (
    <div className="sleep-timer" ref={rootRef}>
      <button
        className={`sleep-timer__trigger${running ? ' is-running' : ''}${ending ? ' is-ending' : ''}`}
        type="button"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label={running ? `睡眠定时器，剩余 ${remainingText}` : '睡眠定时器'}
        title={running ? `睡眠定时器：剩余 ${remainingText}` : '睡眠定时器'}
        onClick={() => setOpen((value) => !value)}
      >
        <svg viewBox="0 0 24 24" className="sleep-timer__icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <circle cx="12" cy="13" r="7.2" />
          <path d="M12 9.6V13l2.4 1.6" />
          <path d="M4.6 5.4 7 7.8" />
          <path d="M19.4 5.4 17 7.8" />
        </svg>
        {running && <span className="sleep-timer__time">{remainingText}</span>}
      </button>

      {open && (
        <div
          className="sleep-timer__panel"
          role="group"
          aria-label="睡眠定时器"
          /* 面板里点数字/输入别把手势冒泡到页面（滑切歌 / 点空白返回） */
          onPointerDown={(event) => event.stopPropagation()}
          onTouchStart={(event) => event.stopPropagation()}
          onDragStart={(event) => event.preventDefault()}
          onContextMenu={(event) => event.preventDefault()}
        >
          {running && (
            <div className="sleep-timer__running">
              <span className="sleep-timer__running-text">剩余 {remainingText}</span>
              <button
                type="button"
                className="sleep-timer__cancel"
                onClick={() => {
                  cancel();
                  setOpen(false);
                }}
              >
                取消定时
              </button>
            </div>
          )}

          <div className="sleep-timer__presets">
            {SLEEP_TIMER_PRESETS.map((preset) => (
              <button
                key={preset}
                type="button"
                className="sleep-timer__preset"
                aria-pressed={minutes === preset}
                data-active={minutes === preset || undefined}
                onClick={() => {
                  setMinutes(preset);
                  setCustom(String(preset));
                }}
              >
                {preset} 分钟
              </button>
            ))}
          </div>

          <label className="sleep-timer__custom">
            <span className="sleep-timer__custom-label">自定义</span>
            <input
              className="sleep-timer__input"
              type="number"
              inputMode="numeric"
              min={SLEEP_TIMER_MIN_MINUTES}
              max={SLEEP_TIMER_MAX_MINUTES}
              step={1}
              value={custom}
              aria-label="自定义分钟数"
              onChange={(event) => onCustomChange(event.target.value)}
            />
            <span className="sleep-timer__custom-label">分钟</span>
          </label>

          <button
            type="button"
            className="sleep-timer__start"
            onClick={() => {
              start(minutes);
              setOpen(false);
            }}
          >
            {running ? '重新计时' : '开始'}
          </button>
        </div>
      )}
    </div>
  );
}
