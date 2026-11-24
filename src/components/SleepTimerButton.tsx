/**
 * SleepTimerButton.tsx —— 睡眠定时器
 *
 * 控制条上方那排里的闹钟小按钮（与「T」「水滴」同规格，26px）：
 * 未启用时是个图标；倒计时跑着时按钮自己撑成一枚药丸，直接显示剩余 mm:ss。
 * 点开是一块面板：**拖动滑杆**选时长（1 分钟 ~ 4 小时），
 * 下面另留一根**自定义**输入框。
 *
 * 面板挂在 `document.body` 上（fixed 定位），不再跟着控制条/歌词页的层级走：
 * 桌面双栏融合成一张卡之后，列表面板右缘那条分隔竖线是 `z-index: 2` 的伪元素，
 * 会压在播放卡内所有内容之上。面板留在卡里时，那条线会横穿面板（看着像「弹框
 * 是透明的、底下的元素透上来」）；挂到 body 后它自成一层，页面里再叠什么都不影响。
 * 落位按触发按钮的实时位置算：控制条那排向上弹（贴按钮左缘），
 * 歌词页页头（`head`）向下弹（贴按钮右缘），窗口缩放/滚动时跟着重算。
 */

import { createPortal } from 'react-dom';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  SLEEP_TIMER_DEFAULT_MINUTES, SLEEP_TIMER_MAX_MINUTES, SLEEP_TIMER_MIN_MINUTES,
  useSleepTimer,
} from '../state/sleep-timer';

/** 面板与触发按钮之间的缝隙（原先 CSS 的 `calc(100% + 8px)`，同一个值）。 */
const PANEL_GAP = 8;

/** 面板宽度（与 `.sleep-timer__panel` 的 244px 对齐，用来做左右夹紧）。 */
const PANEL_WIDTH = 244;

/** 面板贴屏幕边缘时留出的最小空隙（与 Flutter `ToolPanel` 的 8 一致）。 */
const PANEL_EDGE = 8;

/** 面板的落位：四个方向各给一个值，不用的那侧写 'auto'，免得被基础样式补齐成拉伸。 */
interface PanelAnchor {
  top: number | 'auto';
  right: number | 'auto';
  bottom: number | 'auto';
  left: number | 'auto';
}

export function SleepTimerButton({ variant }: { variant?: 'head' }) {
  const { deadline, remainingText, ending, start, cancel } = useSleepTimer();
  const [open, setOpen] = useState(false);
  /** 面板里即将设定的分钟数（滑杆与自定义输入共用这一个值） */
  const [minutes, setMinutes] = useState(SLEEP_TIMER_DEFAULT_MINUTES);
  /** 自定义输入框里的原始文本（可能为空或越界，所以和 minutes 分开存） */
  const [custom, setCustom] = useState(String(SLEEP_TIMER_DEFAULT_MINUTES));
  /** 落位：null = 还没量出来（打开的那一帧不渲染面板，量完立刻出现） */
  const [anchor, setAnchor] = useState<PanelAnchor | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);

  const running = deadline !== null;

  /** 滑杆位置 → 分钟数。滑杆走的是对数量级，短时长（1~30 分）占的行程更宽。 */
  const toMinutes = (position: number): number => {
    const t = position / 100;
    const min = SLEEP_TIMER_MIN_MINUTES;
    const max = SLEEP_TIMER_MAX_MINUTES;
    // 指数映射：低端分辨率高（1、2、3…分明），高端自然变粗（240…）
    const value = min * Math.pow(max / min, t);
    return Math.round(value);
  };

  /** 分钟数 → 滑杆位置（toMinutes 的反函数，给滑杆的 value 用） */
  const toPosition = (value: number): number => {
    const min = SLEEP_TIMER_MIN_MINUTES;
    const max = SLEEP_TIMER_MAX_MINUTES;
    const clamped = Math.min(max, Math.max(min, value));
    return (Math.log(clamped / min) / Math.log(max / min)) * 100;
  };

  /** 拖动滑杆：同步更新分钟数与自定义输入框的文本 */
  const onSlide = (position: number) => {
    const next = toMinutes(position);
    setMinutes(next);
    setCustom(String(next));
  };

  /**
   * 按触发按钮的实时矩形算落位。
   * 控制条那排：面板底边贴按钮上沿（向上弹），左缘对齐按钮左缘；
   * 歌词页页头：面板顶边贴按钮下沿（向下弹），右缘对齐按钮右缘 —— 面板 244px 宽，
   * 居中或贴左都会从屏幕右缘顶出去。
   */
  const measure = () => {
    const el = triggerRef.current;
    if (!el) {
      return;
    }
    const rect = el.getBoundingClientRect();
    // 页头那颗闹钟左边还有「音乐 / 更多」两颗，右缘比歌词页页头更靠里；
    // 面板又只有 244px，极窄屏（<320）贴右缘会从左边顶出去。这里把 right
    // 夹到「面板左缘至少离屏幕 8px」，与 Flutter `ToolPanel` 的夹紧一致。
    const maxRight = Math.max(
      PANEL_EDGE,
      window.innerWidth - PANEL_WIDTH - PANEL_EDGE,
    );
    const next: PanelAnchor = variant === 'head'
      ? {
        top: rect.bottom + PANEL_GAP,
        right: Math.min(Math.max(0, window.innerWidth - rect.right), maxRight),
        bottom: 'auto',
        left: 'auto',
      }
      : {
        bottom: Math.max(0, window.innerHeight - rect.top + PANEL_GAP),
        left: rect.left,
        top: 'auto',
        right: 'auto',
      };
    // 滚动时按钮常常没动：四个值都一样就沿用原对象，别为了同一处坐标反复重排
    setAnchor((prev) => (
      prev && prev.top === next.top && prev.right === next.right
        && prev.bottom === next.bottom && prev.left === next.left
        ? prev
        : next
    ));
  };

  /** 打开时量一次（layout effect：赶在绘制前落位，不会先闪一帧空位），
      期间跟着窗口缩放与滚动重算 —— 面板挂在 body 上，不会自己跟着按钮走。 */
  useLayoutEffect(() => {
    if (!open) {
      setAnchor(null);
      return;
    }
    measure();
    window.addEventListener('resize', measure);
    window.addEventListener('scroll', measure, true);
    return () => {
      window.removeEventListener('resize', measure);
      window.removeEventListener('scroll', measure, true);
    };
    // measure 只读 ref 与 variant，不需要进依赖
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, variant]);

  /** 点面板以外收起：面板已挂在 body 上，得连它一起排除。 */
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!rootRef.current?.contains(target) && !panelRef.current?.contains(target)) {
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

  /** 滑杆下方那句说明：不足 1 小时报「X 分钟」，否则报「X 小时 Y 分钟」 */
  const readout = minutes >= 60
    ? `${Math.floor(minutes / 60)} 小时${minutes % 60 ? ` ${minutes % 60} 分钟` : ''}`
    : `${minutes} 分钟`;

  /** 滑杆右端上限的同样格式（240 分钟 = 4 小时） */
  const maxReadout = SLEEP_TIMER_MAX_MINUTES >= 60
    ? `${Math.floor(SLEEP_TIMER_MAX_MINUTES / 60)} 小时${SLEEP_TIMER_MAX_MINUTES % 60 ? ` ${SLEEP_TIMER_MAX_MINUTES % 60} 分钟` : ''}`
    : `${SLEEP_TIMER_MAX_MINUTES} 分钟`;

  return (
    <div className="sleep-timer" ref={rootRef}>
      <button
        ref={triggerRef}
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

      {open && anchor && createPortal(
        <div
          className="sleep-timer__panel"
          ref={panelRef}
          role="group"
          aria-label="睡眠定时器"
          style={anchor}
          /* 面板里点数字/拖滑杆别把手势冒泡到页面（滑切歌 / 点空白返回） */
          onPointerDown={(event) => event.stopPropagation()}
          onTouchStart={(event) => event.stopPropagation()}
          /* click 也要截：portal 的事件沿组件树冒泡，不截会冒到 transport 的「点空白切歌词页」热区 */
          onClick={(event) => event.stopPropagation()}
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

          {/* 拖动滑杆选时长（1 分钟 ~ 4 小时），精确数值走下面的自定义输入 */}
          <div className="sleep-timer__slide">
            <div className="sleep-timer__slide-head">
              <span className="sleep-timer__slide-value">{readout}</span>
              <span className="sleep-timer__slide-range">
                {SLEEP_TIMER_MIN_MINUTES} 分钟 – {maxReadout}
              </span>
            </div>
            <div className="sleep-timer__range-wrap">
              <input
                className="sleep-timer__range"
                type="range"
                min={0}
                max={100}
                step={0.1}
                value={toPosition(minutes)}
                aria-label={`睡眠定时时长，当前 ${readout}`}
                aria-valuetext={readout}
                style={{ ['--sleep-percent' as string]: `${toPosition(minutes)}%` }}
                onChange={(event) => onSlide(Number(event.target.value))}
              />
            </div>
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
        </div>,
        document.body,
      )}
    </div>
  );
}
