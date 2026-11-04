/**
 * App.tsx —— 界面层
 *
 * 结构与 vanilla 版 index.html 一一对应（类名保持一致，直接复用搬过来的 styles.css），
 * 差别只在「谁驱动渲染」：vanilla 是命令式改 DOM，这里是 React 状态。
 *
 * 几个刻意保留的细节：
 * · 三张圆碟（主封面 / 歌词页头部 / 控制条）由 CSS 动画驱动，播放时 running、
 *   暂停时 paused —— 停在当前角度而不是跳回 0deg；相位由 spin.ts 对齐。
 * · 点封面 = 放大看完整方图；点曲目区其它位置 = 进完整歌词页；点歌词行 = 定位播放。
 * · 进度值走 usePlaybackTime()（useSyncExternalStore），不会带着整棵树每帧重渲染。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ToastProvider, useToast } from './state/toast';
import { PlayerProvider, usePlayer, usePlaybackTime, useBufferedEnd } from './state/player';
import { CoverProvider, coverForDisplay, useCover } from './state/covers';
import { LyricsProvider, useLyrics, findActiveCue } from './state/lyrics';
import { useLibrary } from './state/library';
import { useSpinFollower } from './state/spin';
import { useAutoHideScroll } from './state/useAutoHideScroll';
import { WaveStrip } from './components/WaveStrip';
import { clearRecent as clearRecentStore, formatRelativeTime } from './lib/recent-store.js';
import { remove as removeLocalRecord } from './lib/local-store.js';
import { DEFAULT_COVER } from './lib/demo-data.js';
import { APP_TITLE, IDLE_ARTIST, IDLE_TITLE, SEEK_STEP, VOLUME_STEP } from './state/constants';
import type { Track } from './state/types';

// ---------------------------------------------------------------------------
// 图标
// ---------------------------------------------------------------------------

const PlayIcon = () => (
  <svg viewBox="0 0 24 24" className="icon icon--play" fill="currentColor" aria-hidden="true">
    {/* 三角形包围盒已对齐 viewBox 中心 (12,12) */}
    <path d="M6.46 6a1 1 0 0 1 1.5-.87l9.1 6.03a1 1 0 0 1 0 1.7l-9.1 6.02A1 1 0 0 1 6.46 18z" />
  </svg>
);

const PauseIcon = () => (
  <svg viewBox="0 0 24 24" className="icon icon--pause" fill="currentColor" aria-hidden="true">
    <path d="M7 5h3.2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1m6.8 0H17a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-3.2a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1" />
  </svg>
);

const PrevIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="currentColor" aria-hidden="true">
    <path d="M7 5a1 1 0 0 1 2 0v5.2l8.4-5.6A1 1 0 0 1 19 5.4v13.2a1 1 0 0 1-1.6.8L9 13.8V19a1 1 0 0 1-2 0z" />
  </svg>
);

const NextIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="currentColor" aria-hidden="true">
    <path d="M17 5a1 1 0 0 0-2 0v5.2L6.6 4.6A1 1 0 0 0 5 5.4v13.2a1 1 0 0 0 1.6.8l8.4-5.6V19a1 1 0 0 0 2 0z" />
  </svg>
);

const ModeIcon = ({ name }: { name: 'list' | 'one' | 'shuffle' }) => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M17 2l4 4-4 4" /><path d="M3 11V9a4 4 0 0 1 4-4h14" />
    <path d="M7 22l-4-4 4-4" /><path d="M21 13v2a4 4 0 0 1-4 4H3" />
    {name === 'one' && <path d="M11.2 10.4l1.6-1v5.2" />}
    {name === 'shuffle' && (<><path d="M17 14l4 4-4 4" /><path d="M3 6h4l10 12h4" /><path d="M3 18h4l2.4-2.9" /><path d="M14.6 9.1L17 6h4" /></>)}
  </svg>
);

const VolumeIcon = ({ level }: { level: 'high' | 'low' | 'mute' }) => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M11 5 6.5 9H3v6h3.5L11 19z" />
    {level === 'high' && <path d="M15.5 8.5a5 5 0 0 1 0 7" />}
    {level === 'high' && <path d="M18.5 6a9 9 0 0 1 0 12" />}
    {level === 'low' && <path d="M15.5 8.5a5 5 0 0 1 0 7" />}
    {level === 'mute' && <path d="M16 9.5l5 5M21 9.5l-5 5" />}
  </svg>
);

const BackIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M14 6l-6 6 6 6" />
  </svg>
);

const PlusIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden="true">
    <path d="M12 5v14M5 12h14" />
  </svg>
);

const TrashIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13" />
  </svg>
);

const CloseIcon = () => (
  <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
    <path d="M6 6l12 12M18 6L6 18" />
  </svg>
);

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

const formatTime = (seconds: number): string => {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return '--:--';
  }
  const total = Math.floor(seconds);
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  return `${minutes}:${String(rest).padStart(2, '0')}`;
};

// ---------------------------------------------------------------------------
// 顶部栏
// ---------------------------------------------------------------------------

function Header() {
  const { clearList, playlist, refresh, persist } = usePlayer();
  const { importFiles } = useLibrary();
  const { show } = useToast();
  const inputRef = useRef<HTMLInputElement>(null);

  const onFiles = useCallback((event: React.ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files;
    if (files && files.length > 0) {
      void importFiles(files);
    }
    event.target.value = '';
  }, [importFiles]);

  const onClear = useCallback(() => {
    if (playlist.size === 0) {
      show('播放列表已经是空的', 'info');
      return;
    }
    if (!window.confirm('确定清空播放列表？本地音频的缓存记录也会一并删除。')) {
      return;
    }
    (playlist.tracks as Track[]).filter((track) => track.isLocal).forEach((track) => {
      void removeLocalRecord(track.id);
      if (track.src.startsWith('blob:')) {
        URL.revokeObjectURL(track.src);
      }
    });
    clearList();
    show('已清空播放列表', 'success');
    refresh();
    persist();
  }, [clearList, persist, playlist, refresh, show]);

  return (
    <header className="app__header">
      <div className="brand">
        <span className="brand__logo" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4" />
          </svg>
        </span>
        <span className="brand__text">
          <span className="brand__title">流光音乐</span>
          <span className="brand__sub">LIGHT MUSIC PLAYER</span>
        </span>
      </div>
      <div className="app__actions">
        <button className="btn btn--soft" type="button" onClick={() => inputRef.current?.click()}>
          <PlusIcon />
          <span className="btn__text">添加音乐</span>
        </button>
        <button className="btn btn--ghost" type="button" onClick={onClear}>
          <TrashIcon />
          <span className="btn__text">清空</span>
        </button>
        <input ref={inputRef} type="file" accept="audio/*,.mp3,.flac,.m4a,.wav,.ogg,.opus,.lrc" multiple hidden onChange={onFiles} />
      </div>
    </header>
  );
}

// ---------------------------------------------------------------------------
// 歌词视图（紧凑预览 / 完整页共用）
// ---------------------------------------------------------------------------

function LyricsView({ variant }: { variant: 'compact' | 'full' }) {
  const { cues, plain } = useLyrics();
  const { seek, current } = usePlayer();
  const time = usePlaybackTime();
  const activeIndex = useMemo(() => findActiveCue(cues, time), [cues, time]);
  // 这个 ref 同时用于「滚动到当前行」和「滚动时才显示滚动条」
  const { ref: listRef, scrolling } = useAutoHideScroll<HTMLUListElement>();

  // 当前行滚到中间；手动滚动后 2.6s 再回到跟随
  const manualUntil = useRef(0);
  useEffect(() => {
    const list = listRef.current;
    if (!list || activeIndex < 0 || Date.now() < manualUntil.current) {
      return;
    }
    const line = list.children[activeIndex] as HTMLElement | undefined;
    if (line) {
      list.scrollTo({ top: line.offsetTop - (list.clientHeight - line.clientHeight) / 2, behavior: 'smooth' });
    }
  }, [activeIndex]);

  if (cues.length === 0 && plain) {
    // 纯文本歌词按原文换行拆成行：直接塞进容器会被 HTML 折叠成一整段
    const lines = plain.replace(/\r\n/g, '\n').split('\n');
    while (lines.length > 0 && lines[0].trim() === '') {
      lines.shift();
    }
    while (lines.length > 0 && lines[lines.length - 1].trim() === '') {
      lines.pop();
    }
    return (
      <ul
        ref={listRef}
        className={`lyrics lyrics--${variant} lyrics--plain${scrolling ? ' is-scrolling' : ''}`}
        aria-label="歌词"
      >
        {lines.map((line, index) => {
          const text = line.trim();
          return (
            <li
              key={index}
              className={`lyrics__line lyrics__line--plain${text ? '' : ' lyrics__line--gap'}`}
            >
              <span className="lyrics__text">{text || '·'}</span>
            </li>
          );
        })}
      </ul>
    );
  }
  if (cues.length === 0) {
    return <ul ref={listRef} className={`lyrics lyrics--${variant}${scrolling ? ' is-scrolling' : ''}`} aria-label="歌词" />;
  }

  return (
    <ul
      ref={listRef}
      className={`lyrics lyrics--${variant}${scrolling ? ' is-scrolling' : ''}`}
      aria-label="歌词"
      onWheel={() => { manualUntil.current = Date.now() + 2600; }}
      onTouchMove={() => { manualUntil.current = Date.now() + 2600; }}
    >
      {cues.map((cue, index) => (
        <li
          key={`${cue.time}-${index}`}
          className={[
            'lyrics__line',
            index === activeIndex ? 'is-active' : '',
            index < activeIndex ? 'is-past' : '',
          ].filter(Boolean).join(' ')}
          title={current ? `跳到 ${formatTime(cue.time)}` : undefined}
          onClick={() => seek(cue.time)}
        >
          <span className="lyrics__text">{cue.text || '·'}</span>
        </li>
      ))}
    </ul>
  );
}

// ---------------------------------------------------------------------------
// 曲目区
// ---------------------------------------------------------------------------

function Stage({ onOpenLightbox, discRef, masterRef }: { onOpenLightbox: (trigger?: HTMLElement | null) => void; discRef: React.RefObject<HTMLImageElement>; masterRef: React.RefObject<HTMLImageElement> }) {
  const { current, playing, loading, seek } = usePlayer();
  const { cues, status, state, showRetry, retry } = useLyrics();
  const time = usePlaybackTime();
  const cover = useCover(current);
  const activeIndex = useMemo(() => findActiveCue(cues, time), [cues, time]);

  // 首页紧凑歌词也做成可滚动列表：默认跟随当前行，手动滑动后 2.6s 再恢复跟随
  const compactScroll = useAutoHideScroll<HTMLUListElement>();
  const compactManualUntil = useRef(0);

  useEffect(() => {
    const list = compactScroll.ref.current;
    if (!list) {
      return;
    }
    if (activeIndex < 0) {
      list.scrollTo({ top: 0 });
      return;
    }
    if (Date.now() < compactManualUntil.current) {
      return;
    }
    const line = list.children[activeIndex] as HTMLElement | undefined;
    if (line) {
      list.scrollTo({ top: line.offsetTop - (list.clientHeight - line.clientHeight) / 2, behavior: 'smooth' });
    }
  }, [activeIndex, compactScroll.ref]);

  // 从歌词页回来时主封面元素是重新挂载的，动画会从 0deg 开始 —— 与母钟对齐一次
  useSpinFollower(discRef, masterRef, [current?.id]);

  const onStageClick = useCallback((event: React.MouseEvent<HTMLElement>) => {
    const target = event.target as HTMLElement;
    // 歌词行 = 定位播放；按钮 = 各自的交互（封面放大、重试）
    if (target.closest('.lyrics__line, button, a, input, [role="button"]')) {
      return;
    }
    if (window.getSelection()?.toString()) {
      return;
    }
    window.dispatchEvent(new CustomEvent('app:open-lyrics-page'));
  }, []);

  return (
    <section className="stage" aria-label="当前播放曲目" onClick={onStageClick}>
      <button
        className={`stage__cover-wrap${playing ? ' is-playing' : ''}`}
        type="button"
        aria-label="放大封面图片"
        title="点击放大封面"
        onClick={(event) => {
          event.stopPropagation();
          onOpenLightbox(event.currentTarget);
        }}
      >
        <span className="stage__vinyl" aria-hidden="true" />
        <img
          ref={discRef}
          className={`stage__cover${playing ? ' is-spinning' : ''}`}
          src={cover}
          alt={current ? `${current.title} 封面` : ''}
          width={400}
          height={400}
          decoding="async"
          onError={(event) => {
            const img = event.currentTarget;
            if (img.dataset.fallbackApplied === '1') return;
            img.dataset.fallbackApplied = '1';
            img.src = DEFAULT_COVER;
          }}
        />
        {/* 封面/音频加载中的微光骨架屏（vanilla 用 #coverSkeleton + .is-visible） */}
        <span className={`stage__skeleton${loading ? ' is-visible' : ''}`} aria-hidden="true" />
        {/* 唱臂：播放时落到盘面，暂停时摆到右侧（由 .is-playing 驱动） */}
        <span className="stage__tonearm" aria-hidden="true">
          <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
            <defs>
              {/* 金属臂杆：从支点到唱头方向的高光渐变 */}
              <linearGradient id="stageArmMetal" gradientUnits="userSpaceOnUse" x1="97" y1="3" x2="78.5" y2="29.5">
                <stop offset="0%" stopColor="#e4e9ed" />
                <stop offset="48%" stopColor="#97a2aa" />
                <stop offset="100%" stopColor="#525b62" />
              </linearGradient>
              {/* 支点底座：深色同心金属盘 */}
              <radialGradient id="stageArmBase" cx="0.42" cy="0.38" r="0.62">
                <stop offset="0%" stopColor="#39424a" />
                <stop offset="62%" stopColor="#171c20" />
                <stop offset="100%" stopColor="#0a0e11" />
              </radialGradient>
            </defs>
            {/* 支点底座 + 薄荷绿轴心 */}
            <circle cx="97" cy="3" r="3.6" fill="url(#stageArmBase)" stroke="rgba(255,255,255,0.3)" strokeWidth="0.5" />
            <circle cx="97" cy="3" r="1.5" fill="none" stroke="url(#stageArmMetal)" strokeWidth="0.7" />
            <circle cx="97" cy="3" r="0.75" fill="var(--accent, #2ee6a8)" />
            {/* 臂杆：投影 → 深色轮廓 → 金属内芯 → 顶部高光 */}
            <path d="M95.6 4.6 C 91 12, 85 21, 78.5 29.5" fill="none" stroke="rgba(0,0,0,0.55)" strokeWidth="3" strokeLinecap="round" transform="translate(0.7,0.9)" />
            <path d="M95.6 4.6 C 91 12, 85 21, 78.5 29.5" fill="none" stroke="#0a0e11" strokeWidth="2.5" strokeLinecap="round" />
            <path d="M95.6 4.6 C 91 12, 85 21, 78.5 29.5" fill="none" stroke="url(#stageArmMetal)" strokeWidth="1.7" strokeLinecap="round" />
            <path d="M95.6 4.6 C 91 12, 85 21, 78.5 29.5" fill="none" stroke="rgba(255,255,255,0.5)" strokeWidth="0.5" strokeLinecap="round" transform="translate(0.15,-0.3)" />
            {/* 唱头：深色壳体 + 薄荷绿识别线 */}
            <g transform="rotate(-45 78.5 29.5)">
              <rect x="75" y="27.5" width="7" height="4" rx="2" fill="#12181c" stroke="rgba(255,255,255,0.26)" strokeWidth="0.4" />
              <rect x="76.4" y="28.9" width="4.2" height="1.1" rx="0.55" fill="var(--accent, #2ee6a8)" opacity="0.9" />
            </g>
          </svg>
        </span>
      </button>

      <div className="stage__meta">
        <h1 className="stage__title" title={current?.title}>{current?.title ?? IDLE_TITLE}</h1>
        <p className="stage__artist">{current?.artist || IDLE_ARTIST}</p>
        {current?.album ? <p className="stage__album">{current.album}</p> : <p className="stage__album" hidden />}
      </div>

      <div className="stage__lyrics">
        {status && (
          <p className="stage__lyrics-status" data-state={state} role="status" aria-live="polite">
            <span className="stage__lyrics-status-text">{status}</span>
            {showRetry && (
              <button className="stage__lyrics-retry" type="button" onClick={(event) => { event.stopPropagation(); retry(); }}>
                重试
              </button>
            )}
          </p>
        )}
        <ul
          ref={compactScroll.ref}
          className={`lyrics lyrics--compact${compactScroll.scrolling ? ' is-scrolling' : ''}`}
          aria-label="歌词"
          onWheel={() => { compactManualUntil.current = Date.now() + 2600; }}
          onTouchMove={() => { compactManualUntil.current = Date.now() + 2600; }}
        >
          {cues.map((cue, index) => (
            <li
              key={`${cue.time}-${index}`}
              className={['lyrics__line', index === activeIndex ? 'is-active' : '', index < activeIndex ? 'is-past' : ''].filter(Boolean).join(' ')}
              onClick={() => seek(cue.time)}
            >
              <span className="lyrics__text">{cue.text || '·'}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// 右侧面板（播放列表 / 最近）
// ---------------------------------------------------------------------------

function Panel() {
  const { tracks, currentIndex, playing, playAt, removeTrack, removeRecent, recent, syncRecent, failedIds, notice, hideNotice, resumeAutoplay } = usePlayer();
  const { show } = useToast();
  const [tab, setTab] = useState<'playlist' | 'recent'>('playlist');
  // 两个列表各自滚动，滚动条都在滚动时才浮现
  const playlistScroll = useAutoHideScroll<HTMLUListElement>();
  const recentScroll = useAutoHideScroll<HTMLUListElement>();

  /**
   * 总时长就地算，不要 useMemo。
   * `Playlist.tracks` getter 返回的是同一个数组引用，时长又是入列后异步探到、
   * 原地写回对象字段的 —— memo 的依赖永远不变，结果会一直停在首次的 0:00。
   */
  const totalDuration = tracks.reduce(
    (sum, track) => sum + (Number.isFinite(track.duration) ? track.duration : 0),
    0,
  );

  return (
    <aside className="panel" aria-label="播放列表与最近播放">
      <div className="panel__head">
        <div
          className="panel__tabs"
          role="tablist"
          aria-label="面板内容"
          onKeyDown={(event) => {
            // WAI-ARIA tabs：← → 在标签间移动焦点并跟随切换
            if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
              return;
            }
            event.preventDefault();
            event.stopPropagation();
            setTab(event.key === 'ArrowRight' ? 'recent' : 'playlist');
            (event.target as HTMLElement).focus();
          }}
        >
          <button className="panel__tab" role="tab" type="button" tabIndex={tab === 'playlist' ? 0 : -1} aria-selected={tab === 'playlist'} aria-controls="panePlaylist" onClick={() => setTab('playlist')}>
            播放列表<span className="panel__tab-count">{tracks.length}</span>
          </button>
          <button className="panel__tab" role="tab" type="button" tabIndex={tab === 'recent' ? 0 : -1} aria-selected={tab === 'recent'} aria-controls="paneRecent" onClick={() => setTab('recent')}>
            最近<span className="panel__tab-count">{recent.length}</span>
          </button>
        </div>
        <span className="panel__hint">拖入音频 / .lrc 即可添加</span>
      </div>

      <p className="panel__count">
        {tracks.length} 首 · 总时长 {formatTime(totalDuration)}
      </p>

      {/* 常驻提示条：自动播放被拦、全列表失败这类事不该用会消失的 toast。位置与 vanilla 一致 */}
      {notice && (
        <div className="panel__notice" role="alert">
          <span className="panel__notice-text">{notice.message}</span>
          {notice.actionLabel && (
            <button className="panel__notice-action" type="button" onClick={resumeAutoplay}>
              {notice.actionLabel}
            </button>
          )}
          <button className="panel__notice-close" type="button" aria-label="关闭提示" onClick={hideNotice}>✕</button>
        </div>
      )}

      <div className="panel__body">
        <div className="panel__pane" id="panePlaylist" role="tabpanel" hidden={tab !== 'playlist'}>
          <ul ref={playlistScroll.ref} className={`panel__list${playlistScroll.scrolling ? ' is-scrolling' : ''}`}>
            {tracks.map((track, index) => {
              const isActive = index === currentIndex;
              return (
                <li key={track.id} className={`track${isActive ? ' is-active' : ''}`}>
                  <button
                    className="track__main"
                    type="button"
                    data-action="play"
                    aria-label={`播放《${track.title}》`}
                    aria-current={isActive ? 'true' : undefined}
                    onClick={() => playAt(index, { autoplay: true })}
                  >
                    <img className="track__cover" src={coverForDisplay(track)} alt="" width={44} height={44} loading="lazy" />
                    <span className="track__info">
                      <span className="track__title">{track.title}</span>
                      <span className="track__sub">{[track.artist, track.album].filter(Boolean).join(' · ')}</span>
                    </span>
                    <span className="track__tail">
                      {isActive && (
                        <span className={`track__bars${playing ? ' is-playing' : ''}`} aria-hidden="true">
                          {/* 3 根，与 vanilla 同数；动画挂在 .is-playing 上，少了这个类就是静止的 */}
                          <i />
                          <i />
                          <i />
                        </span>
                      )}
                      <span className="track__duration">{formatTime(track.duration)}</span>
                      {failedIds.includes(track.id) && (
                        <span className="track__badge" title="该曲目加载失败">损坏</span>
                      )}
                    </span>
                  </button>
                  <button
                    className="track__remove"
                    type="button"
                    data-action="remove"
                    aria-label={`从播放列表移除《${track.title}》`}
                    title="从播放列表中移除"
                    onClick={() => { removeTrack(track.id); show(`已移除《${track.title}》`, 'info'); }}
                  >
                    ✕
                  </button>
                </li>
              );
            })}
          </ul>
          {tracks.length === 0 && (
            <div className="panel__empty">
              <p className="panel__empty-title">播放列表是空的</p>
              <p className="panel__empty-text">点击「添加音乐」，或把音频文件拖到页面上</p>
            </div>
          )}
        </div>

        <div className="panel__pane" id="paneRecent" role="tabpanel" hidden={tab !== 'recent'}>
          <div className="recent__bar">
            <span className="recent__hint">按播放时间排序，最多保留 50 首</span>
            <button className="recent__clear" type="button" disabled={recent.length === 0} onClick={() => { clearRecentStore(); syncRecent(); }}>清空历史</button>
          </div>
          <ul ref={recentScroll.ref} className={`recent${recentScroll.scrolling ? ' is-scrolling' : ''}`} aria-label="最近播放">
            {recent.map((entry) => {
              const stillIn = tracks.some((track) => track.id === entry.id);
              return (
                <li key={entry.id} className="recent__row">
                  <button className={`recent__item${stillIn ? '' : ' is-missing'}`} type="button" aria-label={stillIn ? `播放 ${entry.title}` : `${entry.title}（已不在播放列表中）`} onClick={() => {
                    const at = tracks.findIndex((track) => track.id === entry.id);
                    if (at >= 0) {
                      playAt(at, { autoplay: true });
                    } else {
                      show('这首歌已经不在播放列表里了', 'info');
                    }
                  }}>
                    <img className="recent__cover" src={coverForDisplay(entry)} alt="" loading="lazy" />
                    <span className="recent__info">
                      <span className="recent__title">{entry.title}</span>
                      <span className="recent__meta">{formatRelativeTime(entry.at)}</span>
                    </span>
                    <span className="recent__time">{formatTime(entry.duration ?? Number.NaN)}</span>
                  </button>
                  <button
                    className="recent__remove"
                    type="button"
                    aria-label={`从最近播放中移除《${entry.title}》`}
                    title="从最近播放中移除"
                    onClick={() => { removeRecent(entry.id); show(`已从最近播放移除《${entry.title}》`, 'info'); }}
                  >
                    ✕
                  </button>
                </li>
              );
            })}
          </ul>
          {recent.length === 0 && (
            <div className="panel__empty">
              <p className="panel__empty-title">还没有播放记录</p>
              <p className="panel__empty-text">播放过的歌会自动出现在这里</p>
            </div>
          )}
        </div>
      </div>
    </aside>
  );
}

// ---------------------------------------------------------------------------
// 控制区
// ---------------------------------------------------------------------------

function Transport({ masterDiscRef }: { masterDiscRef: React.RefObject<HTMLImageElement> }) {
  const { current, playing, loading, duration, volume, muted, mode, modeLabel, togglePlay, playNext, playPrev, seek, setVolume, toggleMute, cycleMode } = usePlayer();
  const { importFiles } = useLibrary();
  const time = usePlaybackTime();
  const buffered = useBufferedEnd();
  /**
   * 拖拽中：本地暂存目标位置，**不 seek**，也不让 timeupdate 把滑块拽回去。
   * 松手（change）才真正跳转，blur 兜底复位 —— 与 vanilla 的 isSeeking 同一套语义。
   * 少了它，拖动过程中每移一格都在 seek，播放时钟会跟手指打架。
   */
  const [scrub, setScrub] = useState<number | null>(null);
  const shownTime = scrub ?? time;
  /**
   * 总时长：优先播放器报的 duration，其次曲目元数据。
   * 两处都可能是 NaN（刚切歌、或时长还没探到），而 NaN 灌进 <input max> 会让 React 报
   * 「Received NaN for the max attribute」，所以必须显式收敛成 0。
   */
  const metaDuration = current && Number.isFinite(current.duration) ? current.duration : 0;
  const total = Number.isFinite(duration) && duration > 0 ? duration : metaDuration;
  const percent = total > 0 ? Math.min(100, (shownTime / total) * 100) : 0;
  const bufferedPercent = total > 0 ? Math.min(100, (buffered / total) * 100) : 0;
  const cover = useCover(current);
  const fileRef = useRef<HTMLInputElement>(null);

  const volumePercent = muted ? 0 : Math.round(volume * 100);
  const level = muted || volume === 0 ? 'mute' : volume < 0.5 ? 'low' : 'high';

  return (
    <section className="transport" aria-label="播放控制">
      <div className="progress">
        <span className="progress__time">{formatTime(shownTime)}</span>
        <div className="progress__slider">
          <span className="progress__rail" aria-hidden="true" />
          <span className="progress__buffer" aria-hidden="true" style={{ width: `${bufferedPercent}%` }} />
          <span className="progress__fill" aria-hidden="true" style={{ width: `${percent}%` }} />
          <input
            className="progress__input"
            type="range"
            min={0}
            max={Math.max(total, 0.1)}
            step={0.1}
            value={Math.min(shownTime, total || 0)}
            aria-label="播放进度"
            aria-valuetext={`${formatTime(shownTime)} / ${formatTime(total)}`}
            disabled={!current}
            onPointerDown={() => setScrub(time)}
            onInput={(event) => setScrub(Number(event.currentTarget.value))}
            onChange={(event) => {
              const value = Number(event.currentTarget.value);
              seek(value);
              setScrub(null);
            }}
            onBlur={() => setScrub(null)}
          />
        </div>
        <span className="progress__time">{formatTime(total)}</span>
      </div>

      <div className="controls">
        <button
          ref={undefined}
          className={`controls__disc${playing ? ' is-spinning' : ''}`}
          type="button"
          aria-label="打开完整歌词页"
          title="查看完整歌词"
          onClick={() => window.dispatchEvent(new CustomEvent('app:toggle-lyrics-page'))}
        >
          <img
            ref={masterDiscRef}
            className="controls__disc-img"
            src={cover}
            alt=""
            width={46}
            height={46}
            decoding="async"
            onError={(event) => {
              const img = event.currentTarget;
              if (img.dataset.fallbackApplied === '1') return;
              img.dataset.fallbackApplied = '1';
              img.src = DEFAULT_COVER;
            }}
          />
        </button>

        <button className="btn btn--icon" type="button" aria-label={`播放模式：${modeLabel}`} title={modeLabel} onClick={cycleMode}>
          <ModeIcon name={mode === 'one' ? 'one' : mode === 'shuffle' ? 'shuffle' : 'list'} />
        </button>
        <button className="btn btn--icon" type="button" aria-label="上一首" title="上一首" onClick={playPrev}><PrevIcon /></button>
        <button className={`btn btn--play${loading ? ' is-loading' : ''}`} type="button" aria-label={playing ? '暂停' : '播放'} title={playing ? '暂停' : '播放'} onClick={togglePlay}>
          {playing ? <PauseIcon /> : <PlayIcon />}
          <span className="btn__spinner" aria-hidden="true" />
        </button>
        <button className="btn btn--icon" type="button" aria-label="下一首" title="下一首" onClick={() => playNext()}><NextIcon /></button>

        <div className="volume">
          <button className="btn btn--icon" type="button" aria-label={muted ? '取消静音' : '静音'} title={muted ? '取消静音' : '静音'} onClick={toggleMute}>
            <VolumeIcon level={level} />
          </button>
          <input
            className="volume__input"
            type="range"
            min={0}
            max={100}
            step={1}
            value={volumePercent}
            aria-label="音量"
            aria-valuetext={`${volumePercent}%`}
            style={{ ['--volume-percent' as string]: `${volumePercent}%` }}
            onChange={(event) => setVolume(Number(event.target.value) / 100)}
          />
        </div>
      </div>
      <input ref={fileRef} type="file" accept="audio/*,.lrc" multiple hidden onChange={(event) => {
        if (event.target.files?.length) void importFiles(event.target.files);
        event.target.value = '';
      }} />
    </section>
  );
}

// ---------------------------------------------------------------------------
// 完整歌词页 / 放大层 / 拖放 / 轻提示
// ---------------------------------------------------------------------------

function LyricsPage({ onOpenLightbox }: { onOpenLightbox: (trigger?: HTMLElement | null) => void }) {
  const { current } = usePlayer();
  const { status, state, showRetry, retry } = useLyrics();
  const cover = useCover(current);

  return (
    <section className="lyrics-page" aria-label="完整歌词">
      <header className="lyrics-page__head">
        <button className="lyrics-page__back" type="button" aria-label="返回播放界面（Esc）" onClick={() => window.dispatchEvent(new CustomEvent('app:close-lyrics-page'))}>
          <BackIcon />
          <span className="lyrics-page__back-text">返回</span>
        </button>
        <div className="lyrics-page__meta">
          <p className="lyrics-page__title">{current?.title ?? '—'}</p>
          <p className="lyrics-page__artist">{[current?.artist, current?.album].filter(Boolean).join(' · ') || '未知歌手'}</p>
        </div>
      </header>
      {/* 已有歌词时，顶部保留来源 / 纯文本提示；未就绪 / 失败的状态放到下方内容区 */}
      {status && state === 'ready' && (
        <div className="lyrics-page__status-row">
          <p className="lyrics-page__status" role="status" aria-live="polite">{status}</p>
        </div>
      )}
      {/* 左歌词、右封面；封面在这页只是展示用，不参与旋转（没有 is-spinning） */}
      <div className="lyrics-page__body">
        {state === 'loading' || state === 'missing' || state === 'error' ? (
          <div className="lyrics-page__empty" role="status" aria-live="polite">
            <p className="lyrics-page__empty-title">{status || '正在加载歌词…'}</p>
            {showRetry && (
              <button className="lyrics-page__retry" type="button" onClick={retry}>
                重试
              </button>
            )}
          </div>
        ) : (
          <LyricsView variant="full" />
        )}
        <aside className="lyrics-page__art">
          <button
            className="lyrics-page__art-btn"
            type="button"
            aria-label="放大封面图片"
            title="点击放大封面"
            onClick={(event) => onOpenLightbox(event.currentTarget)}
          >
            <img
              className="lyrics-page__cover"
              src={cover}
              alt=""
              width={600}
              height={600}
              decoding="async"
              onError={(event) => {
                const img = event.currentTarget;
                if (img.dataset.fallbackApplied === '1') return;
                img.dataset.fallbackApplied = '1';
                img.src = DEFAULT_COVER;
              }}
            />
          </button>
          {/* 律动波形收在右栏最下面 */}
          <WaveStrip />
        </aside>
      </div>
    </section>
  );
}

/** 放大层里缩放的上限（再大就是马赛克了）。 */
const LIGHTBOX_MAX_SCALE = 4;

/** 滚轮一格缩放多少（指数缩放，手感均匀）。 */
const LIGHTBOX_ZOOM_RATE = 0.0016;

function Lightbox({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { current } = usePlayer();
  const cover = useCover(current);
  const closeRef = useRef<HTMLButtonElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const [scale, setScale] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  /**
   * 视图状态以 ref 为准，state 只用于渲染。
   * 滚轮事件可能在同一帧内连发（触控板惯性就是），若每次都从 state 读 scale，
   * 后面的几次都会基于旧值计算，八次缩放只生效一次 —— 手感和数值都不对。
   */
  const scaleRef = useRef(1);
  const offsetRef = useRef({ x: 0, y: 0 });
  const applyView = useCallback((nextScale: number, nextOffset: { x: number; y: number }) => {
    scaleRef.current = nextScale;
    offsetRef.current = nextOffset;
    setScale(nextScale);
    setOffset(nextOffset);
  }, []);
  const dragging = useRef<{ pointerId: number; startX: number; startY: number; baseX: number; baseY: number } | null>(null);
  const [isDragging, setIsDragging] = useState(false);

  useEffect(() => {
    if (open) {
      closeRef.current?.focus();
    }
  }, [open]);

  // 每次打开 / 换图都回到 1×居中，不把上一首的缩放状态带过去
  useEffect(() => {
    applyView(1, { x: 0, y: 0 });
  }, [applyView, open, cover]);

  /**
   * 把位移限制在「图片边缘不跑到视口里」的范围内。
   * 图片是居中 + 以自身中心缩放，所以单边最大位移 = 尺寸 × (scale - 1) / 2。
   */
  const clampOffset = useCallback((next: { x: number; y: number }, nextScale: number) => {
    const img = imgRef.current;
    if (!img) {
      return next;
    }
    const maxX = (img.offsetWidth * (nextScale - 1)) / 2;
    const maxY = (img.offsetHeight * (nextScale - 1)) / 2;
    return {
      x: Math.min(maxX, Math.max(-maxX, next.x)),
      y: Math.min(maxY, Math.max(-maxY, next.y)),
    };
  }, []);

  /**
   * 滚轮缩放，以光标位置为锚点：光标底下那片像素保持不动。
   *
   * 必须用原生非 passive 监听：React 的 onWheel 绑在根节点上且是 passive 的，
   * 里面 preventDefault 不生效（浏览器会警告并继续滚页面）。
   */
  useEffect(() => {
    const stage = stageRef.current;
    if (!open || !stage) {
      return;
    }
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      const img = imgRef.current;
      if (!img) {
        return;
      }
      const current = scaleRef.current;
      const currentOffset = offsetRef.current;
      const nextScale = Math.min(
        LIGHTBOX_MAX_SCALE,
        Math.max(1, current * Math.exp(-event.deltaY * LIGHTBOX_ZOOM_RATE)),
      );
      if (nextScale === current) {
        return;
      }
      // 光标相对图片中心的坐标
      const rect = img.getBoundingClientRect();
      const cx = event.clientX - (rect.left + rect.width / 2);
      const cy = event.clientY - (rect.top + rect.height / 2);
      // 换算到缩放前的图片本地坐标，缩放后让同一点落回光标下
      const localX = (cx - currentOffset.x) / current;
      const localY = (cy - currentOffset.y) / current;
      applyView(nextScale, clampOffset(
        { x: cx - localX * nextScale, y: cy - localY * nextScale },
        nextScale,
      ));
    };
    stage.addEventListener('wheel', onWheel, { passive: false });
    return () => stage.removeEventListener('wheel', onWheel);
  }, [applyView, clampOffset, open]);

  const onPointerDown = (event: React.PointerEvent<HTMLImageElement>) => {
    // 1× 时没有可拖的内容，交给外层「点空白关闭」的逻辑
    if (scaleRef.current <= 1) {
      return;
    }
    dragging.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      baseX: offsetRef.current.x,
      baseY: offsetRef.current.y,
    };
    setIsDragging(true);
    try {
      // 指针捕获让手指/鼠标移出图片后仍能继续拖；个别环境会抛 NotFoundError，不该影响拖拽
      event.currentTarget.setPointerCapture(event.pointerId);
    } catch {
      // 忽略：没有捕获时，指针离开图片会中断拖拽，属于可接受的降级
    }
  };

  const onPointerMove = (event: React.PointerEvent<HTMLImageElement>) => {
    const state = dragging.current;
    if (!state || state.pointerId !== event.pointerId) {
      return;
    }
    applyView(scaleRef.current, clampOffset({
      x: state.baseX + (event.clientX - state.startX),
      y: state.baseY + (event.clientY - state.startY),
    }, scaleRef.current));
  };

  const endDrag = (event: React.PointerEvent<HTMLImageElement>) => {
    if (dragging.current?.pointerId === event.pointerId) {
      try {
        event.currentTarget.releasePointerCapture(event.pointerId);
      } catch {
        // 没捕获成功过，忽略
      }
    }
    dragging.current = null;
    setIsDragging(false);
  };

  if (!open || !current) {
    return null;
  }
  return (
    <div
      ref={stageRef}
      className="lightbox"
      role="dialog"
      aria-modal="true"
      aria-label="封面大图"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <button className="lightbox__close" ref={closeRef} type="button" aria-label="关闭大图（Esc）" title="关闭（Esc）" onClick={onClose}>
        <CloseIcon />
      </button>
      <img
        ref={imgRef}
        className={`lightbox__img${scale > 1 ? ' is-zoomed' : ''}${isDragging ? ' is-dragging' : ''}`}
        src={cover}
        alt={`${current.title} 封面大图`}
        width={600}
        height={600}
        decoding="async"
        draggable={false}
        style={{ transform: `translate(${offset.x}px, ${offset.y}px) scale(${scale})` }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
      />
      <p className="lightbox__caption">{[current.title, current.artist, current.album].filter(Boolean).join(' · ')}</p>
    </div>
  );
}

function Toasts() {
  const { toasts, dismiss } = useToast();
  return (
    <div className="toast-host" aria-live="polite">
      {toasts.map((toast) => (
        <div key={toast.id} className={`toast toast--${toast.kind}`} role="status">
          <span className="toast__text">{toast.message}</span>
          <button className="toast__close" type="button" aria-label="关闭提示" onClick={() => dismiss(toast.id)}>×</button>
        </div>
      ))}
    </div>
  );
}

function DropOverlay({ visible }: { visible: boolean }) {
  return (
    <div className={`drop-overlay${visible ? ' is-visible' : ''}`} aria-hidden="true">
      <div className="drop-overlay__inner">
        <svg viewBox="0 0 24 24" className="icon" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M12 16V4M8 8l4-4 4 4" /><path d="M4 16v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
        </svg>
        <p>松手即可添加到播放列表</p>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 外壳：视图切换、快捷键、拖放
// ---------------------------------------------------------------------------

function Shell() {
  const { current, togglePlay, seekBy, setVolume, volume, playNext, playPrev, resumeAutoplay } = usePlayer();
  const { importFiles } = useLibrary();
  const [lyricsPage, setLyricsPage] = useState(false);
  const [lightbox, setLightbox] = useState(false);
  /** 放大层可以用两个入口打开（曲目区封面 / 歌词页右栏），焦点要还给实际的那个 */
  const lightboxReturnFocus = useRef<HTMLElement | null>(null);
  const openLightbox = useCallback((trigger?: HTMLElement | null) => {
    lightboxReturnFocus.current = trigger
      ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    setLightbox(true);
  }, []);
  const closeLightbox = useCallback(() => {
    setLightbox(false);
    const back = lightboxReturnFocus.current;
    lightboxReturnFocus.current = null;
    window.requestAnimationFrame(() => {
      if (back && document.contains(back)) {
        back.focus({ preventScroll: true });
      }
    });
  }, []);
  const [dragging, setDragging] = useState(false);
  const dragDepth = useRef(0);
  /** 打开歌词页前的焦点元素，返回时还回去 —— 键盘用户按 Esc 后不该掉到 body 上。
      必须声明在组件顶层，放 useEffect 回调里就是非法 hook 调用（会把整棵树弄崩）。 */
  const returnFocus = useRef<HTMLElement | null>(null);
  const stageDiscRef = useRef<HTMLImageElement>(null);
  const masterDiscRef = useRef<HTMLImageElement>(null);

  // 视图切换：body 上的类决定布局（与 vanilla 同一套 CSS 开关）
  useEffect(() => {
    document.body.classList.toggle('is-lyrics-page', lyricsPage);
  }, [lyricsPage]);
  useEffect(() => {
    document.body.classList.toggle('is-lightbox-open', lightbox);
  }, [lightbox]);

  useEffect(() => {
    const open = () => {
      if (!document.body.classList.contains('is-lyrics-page')) {
        returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      }
      setLyricsPage(true);
    };
    const close = () => {
      setLyricsPage(false);
      const back = returnFocus.current;
      returnFocus.current = null;
      window.requestAnimationFrame(() => {
        const target = back && document.contains(back) ? back : document.querySelector<HTMLElement>('.stage__cover-wrap');
        target?.focus({ preventScroll: true });
      });
    };
    const toggle = () => (document.body.classList.contains('is-lyrics-page') ? close() : open());
    window.addEventListener('app:open-lyrics-page', open);
    window.addEventListener('app:close-lyrics-page', close);
    window.addEventListener('app:toggle-lyrics-page', toggle);
    return () => {
      window.removeEventListener('app:open-lyrics-page', open);
      window.removeEventListener('app:close-lyrics-page', close);
      window.removeEventListener('app:toggle-lyrics-page', toggle);
    };
  }, []);

  /**
   * 任意一次真实交互都可能解除自动播放限制 —— 但只试有限次（计数在 player 里）。
   * 播放按钮和列表项自己的点击本来就会发起播放，交给它们，别互相打断；
   * 空格 / 回车会触发按钮自身的 click，同样让开。
   */
  useEffect(() => {
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (target instanceof Element && target.closest('.btn--play, .panel__list')) {
        return;
      }
      resumeAutoplay();
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.code === 'Space' || event.code === 'Enter') {
        return;
      }
      resumeAutoplay();
    };
    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('keydown', onKey, true);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('keydown', onKey, true);
    };
  }, [resumeAutoplay]);

  // 快捷键：放大层开着时只认 Esc
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (lightbox) {
        if (event.key === 'Escape') {
          event.preventDefault();
          // 走 closeLightbox 而不是 setLightbox(false)：要触发焦点归还
          closeLightbox();
        }
        return;
      }
      if (event.key === 'Escape' && lyricsPage) {
        event.preventDefault();
        setLyricsPage(false);
        return;
      }
      if (event.altKey || event.ctrlKey || event.metaKey) {
        return;
      }
      const target = event.target as HTMLElement | null;
      const tag = target?.tagName ?? '';
      const isRange = tag === 'INPUT' && (target as HTMLInputElement).type === 'range';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target?.isContentEditable) {
        return;
      }
      switch (event.code) {
        case 'Space':
          if (tag === 'BUTTON' || tag === 'A') return;
          event.preventDefault();
          togglePlay();
          break;
        case 'ArrowLeft':
          if (isRange) return;
          event.preventDefault();
          seekBy(-SEEK_STEP);
          break;
        case 'ArrowRight':
          if (isRange) return;
          event.preventDefault();
          seekBy(SEEK_STEP);
          break;
        case 'ArrowUp':
          if (isRange) return;
          event.preventDefault();
          setVolume(Math.min(1, volume + VOLUME_STEP));
          break;
        case 'ArrowDown':
          if (isRange) return;
          event.preventDefault();
          setVolume(Math.max(0, volume - VOLUME_STEP));
          break;
        case 'KeyN':
          playNext();
          break;
        case 'KeyP':
          playPrev();
          break;
        case 'KeyL':
          setLyricsPage((value) => !value);
          break;
        default:
          break;
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [closeLightbox, lightbox, lyricsPage, playNext, playPrev, seekBy, setVolume, togglePlay, volume]);

  // 整页拖放导入
  useEffect(() => {
    const onDragEnter = (event: DragEvent) => {
      if (!event.dataTransfer?.types.includes('Files')) return;
      dragDepth.current += 1;
      setDragging(true);
    };
    const onDragOver = (event: DragEvent) => {
      if (event.dataTransfer?.types.includes('Files')) {
        event.preventDefault();
      }
    };
    const onDragLeave = () => {
      dragDepth.current = Math.max(0, dragDepth.current - 1);
      if (dragDepth.current === 0) setDragging(false);
    };
    const onDrop = (event: DragEvent) => {
      if (!event.dataTransfer?.files?.length) return;
      event.preventDefault();
      dragDepth.current = 0;
      setDragging(false);
      void importFiles(event.dataTransfer.files);
    };
    window.addEventListener('dragenter', onDragEnter);
    window.addEventListener('dragover', onDragOver);
    window.addEventListener('dragleave', onDragLeave);
    window.addEventListener('drop', onDrop);
    return () => {
      window.removeEventListener('dragenter', onDragEnter);
      window.removeEventListener('dragover', onDragOver);
      window.removeEventListener('dragleave', onDragLeave);
      window.removeEventListener('drop', onDrop);
    };
  }, [importFiles]);

  useEffect(() => {
    document.title = current ? `${current.title} · 流光音乐` : APP_TITLE;
  }, [current]);

  return (
    <>
      <a className="skip-link" href="#btnPlay">跳到播放控制</a>
      <div className="app">
        <Header />
        <main className="app__main">
          {lyricsPage
            ? <LyricsPage onOpenLightbox={openLightbox} />
            : <Stage onOpenLightbox={openLightbox} discRef={stageDiscRef} masterRef={masterDiscRef} />}
          <Panel />
          <Transport masterDiscRef={masterDiscRef} />
        </main>
      </div>
      <Lightbox open={lightbox} onClose={closeLightbox} />
      <DropOverlay visible={dragging} />
      <Toasts />
    </>
  );
}

/**
 * LyricsProvider 需要 current，而 current 来自 PlayerProvider，
 * 所以中间隔一层把两者接起来。
 */
function WithLyrics() {
  const { current } = usePlayer();
  return (
    <LyricsProvider track={current}>
      <Shell />
    </LyricsProvider>
  );
}

export default function App() {
  return (
    <ToastProvider>
      <PlayerProvider>
        <CoverProvider>
          <WithLyrics />
        </CoverProvider>
      </PlayerProvider>
    </ToastProvider>
  );
}
