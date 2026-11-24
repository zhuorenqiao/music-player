/**
 * components/MiniSleep.tsx —— 迷你休眠条
 *
 * 休眠声景离开页面后继续在后台放（睡前场景本来就要放着睡着），音乐页必须
 * 交代「现在还在响的是哪一段」—— 否则一条看不见的声音会让人以为播放器坏了。
 * 这条 = 状态（点 + 休眠 / 曲名 / 质地）+ 三个动作：点主体回休眠页、
 * 播放暂停、关闭。与 Flutter `lib/ui/sleep_bar.dart` 成对：
 * 高度 46、圆角 14、左右 16 外边距、字号与字距逐项对齐。
 */

import { useSleep } from '../state/sleep';
import { PlayGlyph } from './RadioPage';
import { MoonIcon } from './PageIcons';

export function MiniSleep({ onOpen }: {
  /** 回休眠页（继续播当前声景，不重新生成） */
  onOpen: () => void;
}) {
  const { current, playing, loading, toggle, stop } = useSleep();
  if (!current) return null;

  return (
    <div className="mini-sleep" role="group" aria-label={`助眠 ${current.name}`}>
      <button
        className="mini-sleep__main"
        type="button"
        aria-label={`回到助眠页 ${current.name}`}
        title="回到助眠页"
        onClick={onOpen}
      >
        <span className={`mini-sleep__dot${playing ? ' is-live' : ''}${loading ? ' is-loading' : ''}`} aria-hidden="true" />
        <span className="mini-sleep__tag"><MoonIcon className="mini-sleep__tag-icon" />助眠</span>
        <span className="mini-sleep__name">{current.name}</span>
        <span className="mini-sleep__detail">{current.detail}</span>
      </button>
      <button
        className="mini-sleep__btn"
        type="button"
        aria-label={playing ? '暂停助眠声景' : '继续播放助眠声景'}
        title={playing ? '暂停助眠声景' : '继续播放助眠声景'}
        onClick={toggle}
      >
        <PlayGlyph playing={playing} />
      </button>
      <button
        className="mini-sleep__btn mini-sleep__btn--close"
        type="button"
        aria-label="关闭助眠声景"
        title="关闭助眠声景"
        onClick={stop}
      >
        <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true">
          <path d="M7 7 L17 17 M17 7 L7 17" />
        </svg>
      </button>
    </div>
  );
}
