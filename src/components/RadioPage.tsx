/**
 * components/RadioPage.tsx —— 电台页（2026-11-20 重构）
 *
 * 版式取自「简约主页」那一张：问候语 + 大标题 → 一张铺满整宽的播放卡
 * （右上角英文角标、左侧一根竖线与一枚小点、底部大字台名、右下角圆形播放键）
 * → 播放状线 → **分类页签**（音乐台 / 交通台 / 网络电台）→ 单列行表 → 页脚一句话。
 *
 * 「所属分类」写在播放卡顶部那行小字里（`传统 FM · 音乐台`），换台时跟着换；
 * 下方页签只负责筛台表，两者共用 `radioTabOf()` 那一份分类元数据。
 *
 * 在播时大卡上的同心环会一圈圈慢慢向外扩散（暂停就冻在原地，不跳回）；
 * 列表缩略图不参与，40px 里再扩散只会像噪点。
 *
 * 颜色**一个都不写死**：全部走 app.css 的主题变量，换肤 / 明暗切换时整页跟着翻。
 * 与 Flutter `lib/ui/radio_page.dart` 逐项对齐（文案、尺寸、圆角、字号、间距），
 * 改一处必须改另一处。
 */

import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from 'react';
import {
  RADIO_STATIONS,
  RADIO_TABS,
  radioArtEndColor,
  radioArtMix,
  radioDetail,
  radioGreeting,
  radioStationsOf,
  radioTabOf,
  type RadioCategory,
  type RadioStation,
} from '../lib/radio';
import { useRadio } from '../state/radio';
import { LibraryMenu } from './LibraryMenu';

/** 广播波图标：下方实心点 + 上方三道同心弧（与 Flutter `_BroadcastPainter` 同规格）。 */
export function BroadcastIcon({ className = 'icon' }: { className?: string }) {
  const arcs = [4.6, 7.2, 9.8].map((radius) => (
    `M ${12 - radius} 17.2 A ${radius} ${radius} 0 0 1 ${12 + radius} 17.2`
  ));
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true">
      <circle cx="12" cy="17.2" r="1.9" fill="currentColor" stroke="none" />
      {arcs.map((d) => <path key={d} d={d} />)}
    </svg>
  );
}

/** 音符图标（回音乐播放器）。 */
function MusicNoteIcon({ className = 'icon' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M9 16.6V5.4l9-1.6v10.4" />
      <circle cx="6.6" cy="16.8" r="2.6" />
      <circle cx="15.6" cy="14.4" r="2.6" />
    </svg>
  );
}

/** 播放 / 暂停图形。 */
export function PlayGlyph({ playing }: { playing: boolean }) {
  if (playing) {
    return (
      <svg viewBox="0 0 24 24" className="icon" fill="currentColor" aria-hidden="true">
        <rect x="7.2" y="4.6" width="3.8" height="14.8" rx="1.9" />
        <rect x="13" y="4.6" width="3.8" height="14.8" rx="1.9" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" className="icon" fill="currentColor" aria-hidden="true">
      <path d="M9 5.4v13.2l9-6.6z" />
    </svg>
  );
}

/**
 * 台面的同心圆：静止的三道环 + 播放时不断往外推的涟漪。
 *
 * 播过一次之后静止环淡出，画面里只剩四道等相位的水波：每道从最内圈
 * 推到 2.6 倍再淡掉，16 秒一轮、彼此错开 4 秒 —— 任何时刻都有三、四圈
 * 在向外走，像水面上一圈圈荡开的波纹。暂停只把相位冻住（不跳回），
 * 继续播就从原地接着推。
 *
 * 环的半径按卡面「最短边」取，与 Flutter 的 `size.shortestSide` 同一支：
 * 0.18 / 0.31 / 0.44 三档静止环，水波从最内圈起步、匀速推到 2.6 倍。
 * 扩张用线性曲线（不吃缓动），四道环在任意时刻的半径间隔都相等 ——
 * 看着才是一圈圈匀称地荡开，而不是先挤在中心、再堆到外圈。
 */
function StationRings({ station, ripple = false, live = false }: {
  station: RadioStation;
  /** 只给大卡开水波；缩略图 40px 里放不下，也会糊成噪声 */
  ripple?: boolean;
  /** 是否正在播（决定水波跑不跑） */
  live?: boolean;
}) {
  const hostRef = useRef<HTMLSpanElement>(null);
  const [box, setBox] = useState({ width: 0, height: 0 });
  const [armed, setArmed] = useState(false);

  useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host) return undefined;
    const measure = () => setBox({ width: host.clientWidth, height: host.clientHeight });
    measure();
    if (typeof ResizeObserver !== 'function') {
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }
    const observer = new ResizeObserver(measure);
    observer.observe(host);
    return () => observer.disconnect();
  }, []);

  // 播过一次就切到「全是水波」的画面：静止环淡出，之后暂停也保留冻结的波纹
  useEffect(() => {
    if (ripple && live) setArmed(true);
  }, [ripple, live]);

  // 环心与台面渐变同一组百分比
  const ringX = Math.round((74 + station.seed * 8) * 10) / 10;
  const ringY = Math.round((26 + station.seed * 5) * 10) / 10;
  // 半径按「最短边」算（与 Flutter 的 size.shortestSide 完全同源）：
  // 18/31/44% 三档就是三道静止环；大卡虽然更宽，圆也不会被拉成横的。
  const short = Math.min(box.width, box.height);
  const waveSize = short * 0.36;
  const style = {
    '--ring-cx': `${ringX}%`,
    '--ring-cy': `${ringY}%`,
  } as CSSProperties;

  return (
    <span ref={hostRef} className="radio-art__rings" style={style} aria-hidden="true">
      {[0, 1, 2].map((index) => (
        <i
          key={`ring-${index}`}
          className={`radio-art__ring${armed ? ' is-hidden' : ''}`}
          style={{
            width: `${short * (0.36 + index * 0.26)}px`,
            height: `${short * (0.36 + index * 0.26)}px`,
            borderColor: `rgb(var(--accent-rgb) / ${0.32 - index * 0.09})`,
          }}
        />
      ))}
      {ripple ? (
        <span className={`radio-art__waves${armed ? ' is-armed' : ''}${live ? ' is-live' : ''}`}>
          {[0, 1, 2, 3].map((index) => (
            <i
              key={`wave-${index}`}
              style={{
                width: `${waveSize}px`,
                height: `${waveSize}px`,
                '--wave-delay': `${-index * 4}s`,
              } as CSSProperties}
            />
          ))}
        </span>
      ) : null}
    </span>
  );
}

/**
 * 台面：主题色渐变 + 右上光晕 + 同心底纹（静止环 / 播放时的水波）+ 底部静息波段。
 *
 * 全部由 CSS 变量 + seed 派生，没有一张外部图片 —— 换肤、切明暗之后整页跟着换调子。
 * 大播放卡与列表缩略图共用这一个组件，只靠外层尺寸缩放（`radio-hero` 里把
 * 波段隐掉，版式才像那张参考图）。`ripple` 只给大卡开：缩略图太小，
 * 一圈水波在 40px 里扩散反而像噪点。
 */
function StationArt({ station, ripple = false, live = false }: {
  station: RadioStation;
  /** 大卡才挂扩散水波 */
  ripple?: boolean;
  /** 当前是否正在播（决定水波跑不跑） */
  live?: boolean;
}) {
  const style = useMemo(() => {
    const [start, end] = radioArtMix(station);
    const startPct = Math.round(start * 100);
    const endPct = Math.round(end * 100);
    return {
      backgroundImage: [
        'radial-gradient(circle at 82% 16%, rgb(var(--accent-rgb) / 0.30), transparent 62%)',
        `linear-gradient(150deg, color-mix(in srgb, var(--accent) ${startPct}%, var(--panel-b)), color-mix(in srgb, var(--accent) ${endPct}%, var(--panel-b)))`,
      ].join(', '),
    } as CSSProperties;
  }, [station]);

  const bars = useMemo(() => [0, 1, 2, 3, 4].map((index) => {
    const phase = station.seed * Math.PI + index * 0.9;
    return 10 + 10 * (0.5 + 0.5 * Math.sin(phase));
  }), [station.seed]);

  return (
    <span className="radio-art" style={style} aria-hidden="true">
      <StationRings station={station} ripple={ripple} live={live} />
      <span className="radio-art__bars">
        {bars.map((height, index) => (
          <i key={index} style={{ height: `${height}%` }} />
        ))}
      </span>
    </span>
  );
}

/** 大播放卡：没选台时先拿目录第一台当门面，点一下就从它开始。 */
function RadioHero() {
  const { current, playing, loading, error, errorMessage, toggle, tune } = useRadio();
  const station = current ?? RADIO_STATIONS[0];
  const tab = radioTabOf(station.category);
  // 压底层的落点色随台走：与台面渐变同一支色，换台 / 换肤都由 CSS 变量重算
  const heroStyle: CSSProperties & { '--hero-end': string } = {
    '--hero-end': radioArtEndColor(station),
  };

  return (
    <section className={`radio-hero${playing ? ' is-live' : ''}`} style={heroStyle} aria-label={`当前电台：${station.name}`}>
      <StationArt station={station} ripple live={playing} />
      <span className="radio-hero__veil" aria-hidden="true" />

      <div className="radio-hero__labels">
        <span className="radio-hero__cat">{tab.section}</span>
        <span className="radio-hero__en">{tab.en}</span>
      </div>

      {/* 竖线 + 小点：参考图里那枚「播放头」，点随收听状态亮起 */}
      <span className={`radio-hero__stem${playing ? ' is-live' : ''}`} aria-hidden="true" />

      <div className="radio-hero__body">
        <p className="radio-hero__name">{station.name}</p>
        <p className="radio-hero__detail">{radioDetail(station)}</p>
        {error ? <p className="radio-hero__error">{errorMessage}</p> : null}
      </div>

      <button
        className="radio-hero__play"
        type="button"
        aria-label={playing ? `暂停 ${station.name}` : `播放 ${station.name}`}
        title={playing ? '暂停' : '播放'}
        onClick={() => {
          if (!current) tune(station);
          else toggle();
        }}
      >
        {loading
          ? <span className="radio-hero__spinner" aria-hidden="true" />
          : <PlayGlyph playing={playing} />}
      </button>
    </section>
  );
}

/** 播放状线：左侧状态（点 + 文案），右侧一句 LIVE / IDLE，底线一根发丝线。 */
function RadioStatus() {
  const { current, playing, loading, reconnecting } = useRadio();
  // 断流自动重连（state/radio.tsx 的 scheduleReconnect）：说「重连中」而不是
  // 干巴巴的「连接中」—— 用户刚才明明在听，突然静音再自己接上。
  const status = reconnecting ? '重连中' : loading ? '连接中' : playing ? '正在收听' : current ? '已暂停' : '还没在听';
  return (
    <div className="radio-status">
      <span className={`radio-status__dot${playing ? ' is-live' : ''}`} aria-hidden="true" />
      <span className="radio-status__text">{status}</span>
      <span className={`radio-status__right${playing ? ' is-live' : ''}`}>{playing ? 'LIVE' : 'IDLE'}</span>
    </div>
  );
}

/** 分类页签：短名 + 台数，选中走 accent 与一根短下划线。 */
function RadioTabs({ active, onChange }: {
  active: RadioCategory;
  onChange: (category: RadioCategory) => void;
}) {
  return (
    <div className="radio-tabs" role="tablist" aria-label="电台分类">
      {RADIO_TABS.map((tab) => {
        const count = radioStationsOf(tab.id).length;
        const selected = active === tab.id;
        return (
          <button
            key={tab.id}
            className={`radio-tabs__btn${selected ? ' is-active' : ''}`}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls={`radio-list-${tab.id}`}
            onClick={() => onChange(tab.id)}
          >
            <span className="radio-tabs__label">{tab.label}</span>
            <span className="radio-tabs__count">{count}</span>
          </button>
        );
      })}
    </div>
  );
}

/** 一行台：缩略 + 台名 / 频率城市 + 右侧角标（在播时换成均衡柱）。 */
function StationRow({ station }: { station: RadioStation }) {
  const { current, isLive, tune } = useRadio();
  const selected = current?.id === station.id;
  const live = isLive(station);
  return (
    <button
      className={`radio-row${selected ? ' is-selected' : ''}`}
      type="button"
      aria-pressed={selected}
      title={`${station.name} ${radioDetail(station)}`}
      onClick={() => tune(station)}
    >
      <span className="radio-row__thumb">
        <StationArt station={station} />
      </span>
      <span className="radio-row__body">
        <span className="radio-row__name">{station.name}</span>
        <span className="radio-row__detail">{radioDetail(station)}</span>
      </span>
      {live
        ? (
          <span className="radio-eq" aria-label="在播">
            <i /><i /><i />
          </span>
        )
        : <span className="radio-row__kind">{station.kind}</span>}
    </button>
  );
}

export function RadioPage({ onBack }: {
  /** 回音乐播放器（不停流，电台继续在后台放） */
  onBack: () => void;
}) {
  const { current } = useRadio();
  const [active, setActive] = useState<RadioCategory>(current?.category ?? 'music');
  const stations = useMemo(() => radioStationsOf(active), [active]);
  const greeting = useMemo(() => radioGreeting(), []);

  return (
    <div className="radio-page">
      <header className="radio-head">
        <span className="radio-head__brand">
          <span className="radio-head__logo"><BroadcastIcon className="radio-head__logo-icon" /></span>
          <span className="radio-head__text">
            <span className="radio-head__title">电台</span>
            <span className="radio-head__sub">LIVE RADIO</span>
          </span>
        </span>
        <button
          className="btn radio-head__back"
          type="button"
          aria-label="返回音乐播放器"
          title="返回音乐播放器"
          onClick={onBack}
        >
          <MusicNoteIcon />
          <span className="btn__text">音乐</span>
        </button>
        {/* 右上角「更多」：只留「换肤」这一项（`showLibraryActions={false}`）。
            电台是另一条音频链路，这页不提供添加 / 清空播放列表，免得听着电台
            误操作了音乐曲库；换肤不再只能回音乐页才找得到。 */}
        <LibraryMenu className="radio-head__menu" showLibraryActions={false} />
      </header>

      <section className="radio-greet" aria-label="想听点什么">
        <p className="radio-greet__hi">{greeting}</p>
        <h1 className="radio-greet__title">想听点什么？</h1>
      </section>

      <RadioHero />
      <RadioStatus />
      <RadioTabs active={active} onChange={setActive} />

      <ul
        className="radio-list"
        id={`radio-list-${active}`}
        role="tabpanel"
        aria-label={`${radioTabOf(active).label} ${stations.length} 台`}
      >
        {stations.map((station) => <li key={station.id} className="radio-list__item"><StationRow station={station} /></li>)}
      </ul>

      <p className="radio-foot">让声音，慢一点。</p>
    </div>
  );
}
