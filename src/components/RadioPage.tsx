/**
 * components/RadioPage.tsx —— 电台页（2026-11-20 重构）
 *
 * 版式取自「简约主页」那一张：问候语 + 大标题 → 一张铺满整宽的播放卡
 * （右上角英文角标、左侧一根竖线与一枚小点、底部大字台名、右下角圆形播放键）
 * → 播放状线 → **分类页签**（音乐台 / 交通台 / 网络电台）→ 单列行表 → 页脚一句话。
 *
 * 「所属分类」写在播放卡顶部那行小字里（`传统 FM · 音乐台`），换台时跟着换；
 * 下方页签只负责筛台表，两者共用 `radioTabOf()` 那一份分类元数据。
 * 页签支持左右滑动切换（在页签 + 台表这一块横滑，松手过 56px 就翻页），
 * 键盘也能用 ←/→ 在页签间走 —— 见 [RadioTabs] 下面的手势说明。
 *
 * 在播时大卡上的同心环会一圈圈慢慢向外扩散（暂停就冻在原地，不跳回）；
 * 列表缩略图不参与，40px 里再扩散只会像噪点。
 *
 * 颜色**一个都不写死**：全部走 app.css 的主题变量，换肤 / 明暗切换时整页跟着翻。
 * 与 Flutter `lib/ui/radio_page.dart` 逐项对齐（文案、尺寸、圆角、字号、间距），
 * 改一处必须改另一处。
 */

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
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
import { BroadcastIcon, MoonIcon, MusicNoteIcon } from './PageIcons';
import { LibraryMenu } from './LibraryMenu';
import { SleepTimerButton } from './SleepTimerButton';

/** 页签滑动切换的横向位移阈值（px）——与 Flutter `kTabSwipePx` 同值。 */
const TAB_SWIPE_PX = 56;

/** 横向位移必须是纵向的这么多倍：竖着划列表不切页（与 `useTrackSwipe` 同一道闸）。 */
const TAB_SWIPE_RATIO = 1.25;

/** 起手死区：位移没过它之前还看不出方向，不抢手势。 */
const TAB_SWIPE_SLOP = 10;

/** 台表换页时从滑入方向进来的位移（px），与 Flutter `_TabSwipeArea` 同值。 */
const TAB_PANEL_IN_PX = 24;

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

/**
 * 分类页签：短名 + 台数，选中走 accent 与一根短下划线。
 *
 * 点击之外还认键盘：←/→ 在当前页签上换到相邻一页（到头折返），并同步把焦点
 * 搬到新页签 —— 这是 ARIA `tablist` 的标准走法，焦点不能留在已经 `tabIndex=-1`
 * 的那颗按钮上。手势（左右滑）由外层 `.radio-panel` 统一接。
 */
function RadioTabs({ active, onChange }: {
  active: RadioCategory;
  onChange: (category: RadioCategory) => void;
}) {
  const stripRef = useRef<HTMLDivElement>(null);

  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = RADIO_TABS.findIndex((tab) => tab.id === active);
    const target = (index + step + RADIO_TABS.length) % RADIO_TABS.length;
    onChange(RADIO_TABS[target].id);
    // 按钮节点按 id 固定 key，状态更新不重建，所以可以立刻搬焦点
    stripRef.current?.querySelectorAll<HTMLButtonElement>('.radio-tabs__btn')[target]?.focus();
  };

  return (
    <div
      className="radio-tabs"
      role="tablist"
      aria-label="电台分类"
      ref={stripRef}
      onKeyDown={onKeyDown}
    >
      {RADIO_TABS.map((tab) => {
        const count = radioStationsOf(tab.id).length;
        const selected = active === tab.id;
        return (
          <button
            key={tab.id}
            id={`radio-tab-${tab.id}`}
            className={`radio-tabs__btn${selected ? ' is-active' : ''}`}
            type="button"
            role="tab"
            aria-selected={selected}
            aria-controls="radio-panel"
            // roving tabindex：Tab 键只落在当前页签，←/→ 再在页签间走
            tabIndex={selected ? 0 : -1}
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

export function RadioPage({ onBack, onSleep }: {
  /** 回音乐播放器（不停流，电台继续在后台放） */
  onBack: () => void;
  /** 去休眠页：整页切过去（电台继续在后台放，交给 MiniRadio 交代） */
  onSleep: () => void;
}) {
  const { current } = useRadio();
  const [active, setActive] = useState<RadioCategory>(current?.category ?? 'music');
  const stations = useMemo(() => radioStationsOf(active), [active]);
  const greeting = useMemo(() => radioGreeting(), []);

  /** 往下滚（手指往上滑）时把右上角三颗收起来，往回滚再放出来。 */
  const [actionsHidden, setActionsHidden] = useState(false);

  /** 新台表从哪边进来：+1 从右（左滑翻到下一页）、-1 从左；0 是进页面，不播动画。 */
  const [enterFrom, setEnterFrom] = useState(0);
  /** 手势起点：`pointerup` 与它相减，横竖判定都按起止坐标算。 */
  const gesture = useRef<{ id: number; x: number; y: number; axis: 'x' | 'y' | null } | null>(null);
  /** 拖动过页签后浏览器仍会补一发 click，用它把那一发吃掉，别误开播。 */
  const suppressClick = useRef(false);

  useEffect(() => {
    // 电台页整页贴 body 滚（`.app` 在这页放开 overflow），所以听 window 的 scroll。
    // 收/放都留 16px 行程：手指轻抖或列表回弹不会让三颗来回闪。
    let last = window.scrollY;
    let travel = 0;
    const onScroll = () => {
      const offset = window.scrollY;
      if (offset <= 12) {
        last = offset;
        travel = 0;
        setActionsHidden(false);
        return;
      }
      const delta = offset - last;
      last = offset;
      if (delta === 0) return;
      travel = travel === 0 || Math.sign(delta) !== Math.sign(travel) ? delta : travel + delta;
      if (travel > 16) setActionsHidden(true);
      else if (travel < -16) setActionsHidden(false);
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  const activeIndex = RADIO_TABS.findIndex((tab) => tab.id === active);

  const selectTab = useCallback((next: RadioCategory, direction?: 1 | -1) => {
    if (next === active) return;
    const from = RADIO_TABS.findIndex((tab) => tab.id === active);
    const to = RADIO_TABS.findIndex((tab) => tab.id === next);
    setEnterFrom(direction ?? (to > from ? 1 : -1));
    setActive(next);
  }, [active]);

  /** 左滑 → 下一页、右滑 → 上一页；到头不动（也不回弹，本来就没跟手位移）。 */
  const swipeTab = (step: 1 | -1) => {
    const target = RADIO_TABS[activeIndex + step];
    if (!target) return;
    selectTab(target.id, step);
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    // 鼠标只认左键；触摸 / 触控笔都放行
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    gesture.current = { id: event.pointerId, x: event.clientX, y: event.clientY, axis: null };
  };

  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const start = gesture.current;
    if (!start || start.id !== event.pointerId) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (!start.axis) {
      // 死区里还看不出方向；横竖倾斜到「横向为主」才归这里，否则让页面滚
      if (Math.abs(dx) < TAB_SWIPE_SLOP && Math.abs(dy) < TAB_SWIPE_SLOP) return;
      if (Math.abs(dx) <= Math.abs(dy) * TAB_SWIPE_RATIO) {
        start.axis = 'y';
        return;
      }
      start.axis = 'x';
      suppressClick.current = true;
      try {
        event.currentTarget.setPointerCapture(event.pointerId);
      } catch {
        // 指针已经抬起（浏览器中途取消），捕获失败不影响后面的判定
      }
    }
  };

  const finishSwipe = (event: ReactPointerEvent<HTMLDivElement>) => {
    const start = gesture.current;
    gesture.current = null;
    if (!start || start.id !== event.pointerId || start.axis !== 'x') return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    // 够远且横向为主才翻页（与 Flutter `_TabSwipeArea` 同一套口径）
    if (Math.abs(dx) < TAB_SWIPE_PX || Math.abs(dx) <= Math.abs(dy) * TAB_SWIPE_RATIO) return;
    swipeTab(dx < 0 ? 1 : -1);
  };

  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    finishSwipe(event);
    // 这一发 click 若真来了会先被下头吃掉；有些浏览器要等一拍才补发，留 300ms 兜底
    window.setTimeout(() => { suppressClick.current = false; }, 300);
  };

  const onClickCapture = (event: ReactMouseEvent<HTMLDivElement>) => {
    if (!suppressClick.current) return;
    suppressClick.current = false;
    event.preventDefault();
    event.stopPropagation();
  };

  return (
    <div className="radio-page">
      <header className={`radio-head${actionsHidden ? ' is-actions-hidden' : ''}`}>
        <span className="radio-head__brand">
          <span className="radio-head__logo"><BroadcastIcon className="radio-head__logo-icon" /></span>
          <span className="radio-head__text">
            <span className="radio-head__title">电台</span>
            <span className="radio-head__sub">LIVE RADIO</span>
          </span>
        </span>
        {/* 右侧这一组：睡眠定时器 → 「休眠」互跳 → 「音乐」回退 → 「更多」。
            定时器与音乐页那几颗是同一个组件（交互一致：图标 → 滑杆选时长 +
            自定义分钟数 + 开始 / 取消；跑起来后图标旁直接显示剩余 mm:ss）。
            页头在上面，所以面板向下弹、贴按钮右缘展开；到点时它会把电台也一并
            暂停（见 state/sleep-timer.tsx）。
            「休眠」这一颗与休眠页右上角那颗「电台」互为邻居入口，两页各留一条
            回音乐页的路 —— 条上的暂停 / 关闭才是停台的地方。 */}
        <div className="radio-head__actions">
          <SleepTimerButton variant="head" />
          <button
            className="btn radio-head__sleep"
            type="button"
            aria-label="打开助眠页"
            title="打开助眠页"
            onClick={onSleep}
          >
            <MoonIcon />
            <span className="btn__text">助眠</span>
          </button>
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
        </div>
      </header>

      <section className="radio-greet" aria-label="想听点什么">
        <p className="radio-greet__hi">{greeting}</p>
        <h1 className="radio-greet__title">想听点什么？</h1>
      </section>

      <RadioHero />
      <RadioStatus />

      {/* 页签 + 台表整块接横滑：`touch-action: pan-y` 把纵向留给页面滚动，
          横向手势归这里；竖着划会被 [onPointerMove] 判成 axis='y' 直接放行。 */}
      <div
        className="radio-panel"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={() => {
          gesture.current = null;
          window.setTimeout(() => { suppressClick.current = false; }, 300);
        }}
        onClickCapture={onClickCapture}
      >
        <RadioTabs active={active} onChange={selectTab} />
        <div
          key={active}
          className={`radio-panel__page${enterFrom === 0 ? '' : ' is-enter'}`}
          style={{ '--panel-from': `${enterFrom >= 0 ? TAB_PANEL_IN_PX : -TAB_PANEL_IN_PX}px` } as CSSProperties}
          onAnimationEnd={(event) => {
            // 动画收尾就把标记摘掉，页面上不留一个永久的 transform（会凭空多一层合成）
            if (event.animationName === 'radio-panel-in') setEnterFrom(0);
          }}
        >
          <ul
            className="radio-list"
            id="radio-panel"
            role="tabpanel"
            aria-label={`${radioTabOf(active).label} ${stations.length} 台`}
          >
            {stations.map((station) => <li key={station.id} className="radio-list__item"><StationRow station={station} /></li>)}
          </ul>
        </div>
      </div>

      <p className="radio-foot">让声音，慢一点。</p>
    </div>
  );
}
