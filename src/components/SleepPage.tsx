/**
 * components/SleepPage.tsx —— 休眠页
 *
 * 版式沿用电台页那套：品牌行 + 问候 → 一张铺满整宽的夜色播放卡
 * （右上角英文角标、左侧竖线 + 小点、底部大字曲名、右下角圆形播放键）
 * → 播放状线 → 分类页签（声景 / 摇篮 / 白噪）→ 单列行表 → 页脚一句话。
 *
 * 夜色卡不随主题翻：深蓝底 + 月亮 + 极轻的呼吸环，是休眠模块唯一的
 * 「另一个时空」；页面其余部分（问候、页签、状态、行表）仍走 token，
 * 换肤 / 明暗时照常跟着翻。
 *
 * 页头右侧四颗：睡眠定时器 → 「电台」（互跳到电台页）→ 「音乐」（回播放器）
 * → 「更多」。「电台」是这一页新开的邻居入口，与电台页那颗「休眠」互为一对。
 * 与 Flutter `lib/ui/sleep_page.dart` 逐项对齐，改一处必须改另一处。
 */

import { useMemo, useState, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import {
  SLEEP_FIRST_TRACK,
  SLEEP_TABS,
  sleepGreeting,
  sleepTabOf,
  sleepTracksOf,
  type SleepCategory,
  type SleepTrack,
} from '../lib/sleep';
import { useSleep } from '../state/sleep';
import { BroadcastIcon, MoonIcon, MusicNoteIcon } from './PageIcons';
import { LibraryMenu } from './LibraryMenu';
import { SleepTimerButton } from './SleepTimerButton';
import { PlayGlyph } from './RadioPage';

/**
 * 卡面上的星点：固定坐标（百分比 + px 直径 + 透明度），两端共用同一张表。
 * 放在一个 `<span>` 里绝对定位，不参与布局，也不抢文字。
 */
const STARS = [
  { x: 7, y: 13, size: 1.6, alpha: 0.55 },
  { x: 18, y: 8, size: 1.2, alpha: 0.4 },
  { x: 31, y: 18, size: 1.9, alpha: 0.7 },
  { x: 44, y: 7, size: 1.2, alpha: 0.45 },
  { x: 58, y: 15, size: 1.5, alpha: 0.6 },
  { x: 69, y: 6, size: 1.0, alpha: 0.35 },
  { x: 12, y: 34, size: 1.2, alpha: 0.45 },
  { x: 25, y: 30, size: 0.9, alpha: 0.3 },
  { x: 38, y: 27, size: 1.4, alpha: 0.5 },
  { x: 52, y: 33, size: 1.1, alpha: 0.4 },
  { x: 66, y: 29, size: 1.7, alpha: 0.65 },
  { x: 78, y: 38, size: 1.0, alpha: 0.35 },
  { x: 9, y: 57, size: 0.9, alpha: 0.3 },
  { x: 21, y: 51, size: 1.3, alpha: 0.5 },
  { x: 35, y: 61, size: 1.0, alpha: 0.35 },
  { x: 48, y: 48, size: 1.2, alpha: 0.45 },
  { x: 62, y: 56, size: 0.8, alpha: 0.28 },
  { x: 74, y: 63, size: 1.4, alpha: 0.45 },
  { x: 88, y: 44, size: 1.1, alpha: 0.35 },
];

/** 星星层 + 流星 + 月亮 + 呼吸环：全部是装饰，不许吃鼠标。 */
function SleepSky({ track, playing }: { track: SleepTrack; playing: boolean }) {
  const style = {
    '--sleep-glow-rgb': track.glowRgb,
  } as CSSProperties;
  return (
    <span className="sleep-art" style={style} aria-hidden="true">
      <span className="sleep-art__stars">
        {STARS.map((star, index) => (
          <i
            key={index}
            style={{
              left: `${star.x}%`,
              top: `${star.y}%`,
              width: `${star.size}px`,
              height: `${star.size}px`,
              opacity: star.alpha,
            }}
          />
        ))}
      </span>
      {/* 流星：只在正在播放时出现，每 5 秒从卡面右上沿一条极轻微的弧线掠向左下，
          1.25 秒飞完后收掉。轨迹、转角与节奏都写在 `.sleep-art__meteor` 里（与 Flutter 同参数）。 */}
      <span className="sleep-art__meteor" aria-hidden="true">
        <i />
      </span>
      <span className={`sleep-art__rings${playing ? ' is-live' : ''}`}>
        {[0, 1, 2].map((index) => (
          <i key={index} style={{ '--ring-delay': `${-index * 3.7}s` } as CSSProperties} />
        ))}
      </span>
      <span className="sleep-art__moon">
        <i className="sleep-art__crater sleep-art__crater--a" />
        <i className="sleep-art__crater sleep-art__crater--b" />
        <i className="sleep-art__crater sleep-art__crater--c" />
      </span>
      <span className="sleep-art__horizon" />
    </span>
  );
}

/** 行首缩略：夜色渐变 + 小月亮。 */
function SleepThumb({ track }: { track: SleepTrack }) {
  return (
    <span
      className="sleep-row__thumb"
      style={{
        backgroundImage: `linear-gradient(150deg, ${track.artFrom}, ${track.artTo})`,
      }}
      aria-hidden="true"
    >
      <MoonIcon className="sleep-row__moon" />
      <i className="sleep-row__star" />
    </span>
  );
}

/** 大播放卡：没选过曲目时先拿目录第一首当门面，点一下就从它开始。 */
function SleepHero() {
  const { current, playing, loading, error, toggle, tune } = useSleep();
  const track = current ?? SLEEP_FIRST_TRACK;
  const tab = sleepTabOf(track.category);

  return (
    <section
      className={`sleep-hero${playing ? ' is-live' : ''}`}
      style={{ '--sleep-glow-rgb': track.glowRgb } as CSSProperties}
      aria-label={`当前声景：${track.name}`}
    >
      <SleepSky track={track} playing={playing} />
      <span className="sleep-hero__veil" aria-hidden="true" />

      <div className="sleep-hero__labels">
        <span className="sleep-hero__cat">此刻声景</span>
        <span className="sleep-hero__en">{tab.en}</span>
      </div>

      <span className={`sleep-hero__stem${playing ? ' is-live' : ''}`} aria-hidden="true" />

      <div className="sleep-hero__body">
        <p className="sleep-hero__name">{track.name}</p>
        <p className="sleep-hero__detail">{track.detail}</p>
        {error ? <p className="sleep-hero__error">{error}</p> : null}
      </div>

      <button
        className="sleep-hero__play"
        type="button"
        aria-label={playing ? `暂停 ${track.name}` : `播放 ${track.name}`}
        title={playing ? '暂停' : '播放'}
        onClick={() => {
          if (!current) tune(track);
          else toggle();
        }}
      >
        {loading
          ? <span className="sleep-hero__spinner" aria-hidden="true" />
          : <PlayGlyph playing={playing} />}
      </button>
    </section>
  );
}

/** 播放状线：左侧状态（点 + 文案），右侧一句 REST / IDLE，底线一根发丝线。 */
function SleepStatus() {
  const { current, playing, loading } = useSleep();
  const status = loading ? '准备中' : playing ? '正在播放' : current ? '已暂停' : '还没开始';
  return (
    <div className="sleep-status">
      <span className={`sleep-status__dot${playing ? ' is-live' : ''}`} aria-hidden="true" />
      <span className="sleep-status__text">{status}</span>
      <span className={`sleep-status__right${playing ? ' is-live' : ''}`}>{playing ? 'REST' : 'IDLE'}</span>
    </div>
  );
}

/**
 * 分类页签：短名 + 曲目数，选中走 accent 与一根短下划线。
 * 键盘 ←/→ 在页签间换页（ARIA tablist 的标准走法，焦点跟着搬）。
 */
function SleepTabs({ active, onChange }: {
  active: SleepCategory;
  onChange: (category: SleepCategory) => void;
}) {
  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = SLEEP_TABS.findIndex((tab) => tab.id === active);
    const target = (index + step + SLEEP_TABS.length) % SLEEP_TABS.length;
    const next = SLEEP_TABS[target].id;
    onChange(next);
    document.querySelectorAll<HTMLButtonElement>('.sleep-tabs__btn')[target]?.focus();
  };

  return (
    <div className="sleep-tabs" role="tablist" aria-label="助眠分类" onKeyDown={onKeyDown}>
      {SLEEP_TABS.map((tab) => {
        const count = sleepTracksOf(tab.id).length;
        const selected = active === tab.id;
        return (
          <button
            key={tab.id}
            id={`sleep-tab-${tab.id}`}
            className={`sleep-tabs__btn${selected ? ' is-active' : ''}`}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls="sleep-panel"
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(tab.id)}
          >
            <span className="sleep-tabs__label">{tab.label}</span>
            <span className="sleep-tabs__count">{count}</span>
          </button>
        );
      })}
    </div>
  );
}

/** 一行声景：缩略 + 曲名 / 质地 + 右侧「循环」或均衡柱。 */
function SleepRow({ track }: { track: SleepTrack }) {
  const { current, playing, tune, toggle } = useSleep();
  const selected = current?.id === track.id;
  const live = selected && playing;
  return (
    <button
      className={`sleep-row${selected ? ' is-selected' : ''}`}
      type="button"
      aria-pressed={selected}
      title={`${track.name} ${track.detail}`}
      onClick={() => {
        if (selected) toggle();
        else tune(track);
      }}
    >
      <SleepThumb track={track} />
      <span className="sleep-row__body">
        <span className="sleep-row__name">{track.name}</span>
        <span className="sleep-row__detail">{track.detail}</span>
      </span>
      {live
        ? (
          <span className="sleep-eq" aria-label="在播">
            <i /><i /><i />
          </span>
        )
        : <span className="sleep-row__kind">循环</span>}
    </button>
  );
}

export function SleepPage({ onBack, onRadio }: {
  /** 回音乐播放器（不停止声景，继续在后台放） */
  onBack: () => void;
  /** 去电台页：整页切过去（休眠声景继续在后台放，交给 MiniSleep 交代） */
  onRadio: () => void;
}) {
  const { current } = useSleep();
  const [active, setActive] = useState<SleepCategory>(current?.category ?? 'scape');
  const tracks = useMemo(() => sleepTracksOf(active), [active]);
  const greeting = useMemo(() => sleepGreeting(), []);

  return (
    <div className="sleep-page">
      <header className="sleep-head">
        <span className="sleep-head__brand">
          <span className="sleep-head__logo"><MoonIcon className="sleep-head__logo-icon" /></span>
          <span className="sleep-head__text">
            <span className="sleep-head__title">助眠</span>
            <span className="sleep-head__sub">SLEEP MODE</span>
          </span>
        </span>
        {/* 右侧：睡眠定时器 → 「电台」互跳 → 「音乐」回退 → 「更多」（只留换肤）。
            定时器与电台页 / 音乐页是同一颗，到点会把休眠声景也一并暂停；
            「电台」这一颗与电台页右上角那颗「休眠」互为邻居入口，两页各留一条
            回音乐页的路 —— 条上的暂停 / 关闭才是停声景的地方。 */}
        <div className="sleep-head__actions">
          <SleepTimerButton variant="head" />
          <button
            className="btn sleep-head__radio"
            type="button"
            aria-label="打开电台页"
            title="打开电台页"
            onClick={onRadio}
          >
            <BroadcastIcon />
            <span className="btn__text">电台</span>
          </button>
          <button
            className="btn sleep-head__back"
            type="button"
            aria-label="返回音乐播放器"
            title="返回音乐播放器"
            onClick={onBack}
          >
            <MusicNoteIcon />
            <span className="btn__text">音乐</span>
          </button>
          <LibraryMenu className="sleep-head__menu" showLibraryActions={false} />
        </div>
      </header>

      <section className="sleep-greet" aria-label="该歇一会儿了">
        <p className="sleep-greet__hi">{greeting}</p>
        <h1 className="sleep-greet__title">把今天，轻轻放下</h1>
      </section>

      <SleepHero />
      <SleepStatus />

      <div className="sleep-panel">
        <SleepTabs active={active} onChange={setActive} />
        <div className="sleep-panel__page">
          <ul
            className="sleep-list"
            id="sleep-panel"
            role="tabpanel"
            aria-label={`${sleepTabOf(active).label} ${tracks.length} 段`}
          >
            {tracks.map((track) => (
              <li key={track.id} className="sleep-list__item">
                <SleepRow track={track} />
              </li>
            ))}
          </ul>
        </div>
      </div>

      <p className="sleep-foot">晚安，好梦。</p>
    </div>
  );
}
