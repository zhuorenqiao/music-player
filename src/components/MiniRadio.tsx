/**
 * components/MiniRadio.tsx —— 迷你电台条
 *
 * 电台离开页面后继续在后台放（用户要求「退到播放器后台继续放」），那么音乐页
 * 必须交代「现在还在响的是什么」—— 否则一条看不见的直播流会让人以为播放器坏了。
 * 这条 = 状态（点 + 电台 / 台名 / 频率）+ 三个动作：点主体回电台页、播放暂停、关闭。
 *
 * 位置：`.player` 卡内、控制条正上方（见 App.tsx）。窄屏上它就是「播放器底部的
 * 一条迷你条」，桌面落在右列控制区上方 —— 两档都不用另起一行动骨架。
 * 与 Flutter `lib/ui/radio_bar.dart` 成对：高度 46、圆角 14、左右 16 外边距、
 * 字号与字距逐项对齐；颜色全走 token。
 */

import { radioDetail } from '../lib/radio';
import { useRadio } from '../state/radio';
import { PlayGlyph } from './RadioPage';

export function MiniRadio({ onOpen }: {
  /** 回电台页（不重新开流，页面直接显示当前台） */
  onOpen: () => void;
}) {
  const { current, playing, loading, toggle, stop } = useRadio();
  // 没选过台（或已经关闭）就不占位
  if (!current) return null;

  return (
    <div className="mini-radio" role="group" aria-label={`电台 ${current.name}`}>
      <button
        className="mini-radio__main"
        type="button"
        aria-label={`回到电台页 ${current.name}`}
        title="回到电台页"
        onClick={onOpen}
      >
        <span
          className={`mini-radio__dot${playing ? ' is-live' : ''}${loading ? ' is-loading' : ''}`}
          aria-hidden="true"
        />
        <span className="mini-radio__tag">电台</span>
        <span className="mini-radio__name">{current.name}</span>
        <span className="mini-radio__detail">{radioDetail(current)}</span>
      </button>
      <button
        className="mini-radio__btn"
        type="button"
        aria-label={playing ? '暂停电台' : '继续播放电台'}
        title={playing ? '暂停电台' : '继续播放电台'}
        onClick={toggle}
      >
        {/* 与 Flutter `radio_bar.dart` 同一口径：这条上的按钮永远是播放 / 暂停
            图形，连接中只由左侧状态点交代 —— 电台在播时它不该突然变成转圈。 */}
        <PlayGlyph playing={playing} />
      </button>
      <button
        className="mini-radio__btn mini-radio__btn--close"
        type="button"
        aria-label="关闭电台"
        title="关闭电台"
        onClick={stop}
      >
        <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true">
          <path d="M7 7 L17 17 M17 7 L7 17" />
        </svg>
      </button>
    </div>
  );
}
