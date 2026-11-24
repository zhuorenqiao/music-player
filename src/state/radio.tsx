/**
 * state/radio.tsx —— 电台状态：当前在收听哪一台 + 在响 / 在缓冲 / 出错
 *
 * 与 Flutter `lib/radio/radio_state.dart` 同一套语义：
 *   1. 同一台再点一次是**暂停 / 续播**（不重开流 —— 直播流重开要重新缓冲）；
 *   2. 换台先清错误、置 loading，再换 src + play；失败落回「没在响」的稳定态；
 *   3. 离开电台页**不停流**：电台继续在后台放，音乐页底部那条迷你电台条接着
 *      交代「还在响的是哪一台」；点它回电台页，条上的暂停 / 关闭才真的停。
 *   4. **断流自己接上**：直播流是长连接，上游 CDN 播十几分钟会把连接掐掉
 *      （浏览器报 `error` / `ended`）。从前这里只把 playing 落 false，用户听到的
 *      就是「播一会儿就停了」，屏幕上还挂着音乐页，看起来像「自动切去放音乐」。
 *      现在只要不是用户自己按的暂停，就按退避重连同一台；次数用尽才落错误态。
 *   5. **在播时按钮不转圈**：浏览器在直播流正常出声时也会偶发 `waiting` /
 *      `stalled`（每次等下一段数据就报一次），而 `playing` 未必再补一条 ——
 *      从前这里直接把 loading 打开，按钮就停在转圈上，声音其实还在。现在
 *      loading 只由「起播 / 续播 / 重连」打开，播放头（`timeupdate`）一动就收掉；
 *      `waiting` / `stalled` 只喂看门狗，不再动按钮。
 *
 * 出声用一枚独立的 `<audio>` 元素，**不经过**曲库播放器：电台是无限长、不可 seek
 * 的另一条链路，混进 usePlayer 那台设备会让「暂停音乐」变成「暂停电台」、
 * 让进度条拿一个永远未知的时长去画。两条链路的互斥在这里做：开播 / 续播前
 * 都先 `pause()` 音乐（不做这一步就是两路声音叠在一起）。
 *
 * 流地址是跨域直链，但不设 `crossOrigin`：`<audio>` 播放本身不受同源策略约束，
 * 设成 anonymous 反而会因为服务端没给 CORS 头而整条流播不出来。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode,
} from 'react';
import { radioStationById, type RadioStation } from '../lib/radio';
import { usePlayer } from './player';

interface RadioContextValue {
  /** 当前选中的台；null = 还没选过（或刚 stop 过） */
  current: RadioStation | null;
  playing: boolean;
  loading: boolean;
  /** 断流后正在自动重连（界面把「连接中」说得更准确） */
  reconnecting: boolean;
  error: string | null;
  /** 这一台是不是正在响（界面据此高亮卡 / 画均衡柱） */
  isLive: (station: RadioStation) => boolean;
  tune: (station: RadioStation) => void;
  toggle: () => void;
  /** 无条件往「暂停」走（不看当前在不在响；保留当前台） */
  pause: () => void;
  stop: () => void;
  /** 用户可读的错误文案（内核原文不进界面） */
  errorMessage: string;
}

const RadioContext = createContext<RadioContextValue | null>(null);

/**
 * 重连次数上限与退避（与 Flutter `RadioState.defaultReconnectDelay` 同一套）。
 *
 * 首次只等 0.8 秒：这是一条已经断开的长连接，晚一秒开流，用户耳朵里就多一秒
 * 静默；真正「上游还在掐」的情况，后面的档位会自己拉开（2/4/8/12 秒）。
 * 次数给到 8：直播流断一次接一次是常态，4 次往往在用户还没抬头时就耗尽。
 */
const MAX_RECONNECTS = 8;
const RECONNECT_DELAYS = [800, 2000, 4000, 8000, 12000];
/**
 * 卡在 `stalled` / `waiting` 多久算断流。
 *
 * Chrome 在长连接被上游掐掉时**经常不给 `error`**：它只是停在 `stalled` 上等
 * 数据，等多久都不报错。从前的版本只把这一步记成「连接中」，于是界面一直转圈、
 * 声音早就没了，也不会重连 —— 用户听到的就是「播着播着断了，还不自己回来」。
 * 12 秒足够跨过正常的起播缓冲（实测首帧要 3~6 秒）。
 */
const STALL_TIMEOUT = 12000;

export function RadioProvider({ children }: { children: ReactNode }) {
  const { pause: pauseMusic, playing: musicPlaying } = usePlayer();
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [current, setCurrent] = useState<RadioStation | null>(null);
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [reconnecting, setReconnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** 当前这台是否已经挂过 src（同台判定用；stop 之后要清掉） */
  const openedRef = useRef(false);
  /** 当前台的 id：异步回调（play 的 Promise）里读的是最新值，不吃闭包旧值 */
  const currentIdRef = useRef<string | null>(null);
  /** 当前台的整条记录（重连要重新 `audio.src = station.streamUrl`） */
  const stationRef = useRef<RadioStation | null>(null);
  /** 用户自己按的暂停：只有它能让「断流重连」闭嘴（让位于音乐也算用户侧决定） */
  const userPausedRef = useRef(false);
  /** 已用掉的重连次数（真出声就归零） */
  const attemptRef = useRef(0);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** 卡死看门狗：从 `stalled` 起算，到点还没数据就自己重开 */
  const stallTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** 两个互指的回调（重连失败要再排一次，排到点又要再连）走 ref 避开循环依赖 */
  const scheduleReconnectRef = useRef<() => void>(() => {});
  const reconnectNowRef = useRef<() => void>(() => {});

  const clearReconnectTimer = useCallback(() => {
    if (reconnectTimerRef.current !== null) {
      clearTimeout(reconnectTimerRef.current);
      reconnectTimerRef.current = null;
    }
    // 换台 / 用户暂停 / 电台停掉：上一路的「卡住」计时也不该再留着开火。
    if (stallTimerRef.current !== null) {
      clearTimeout(stallTimerRef.current);
      stallTimerRef.current = null;
    }
    setReconnecting(false);
  }, []);

  // 一枚常驻 audio：反复 new Audio 会泄漏解码线程，而且切台时要能立刻掐掉上一路
  useEffect(() => {
    const audio = new Audio();
    audio.preload = 'none';
    audio.setAttribute('playsinline', '');

    /** 有数据进来了 / 出声了：把这轮「卡住」的计时收掉 */
    const clearStall = () => {
      if (stallTimerRef.current !== null) {
        clearTimeout(stallTimerRef.current);
        stallTimerRef.current = null;
      }
    };
    /**
     * 起了缓冲就上表：到点还停在 loading、又本该在响，就当作断流自己重开。
     * `audio.paused` 是最后一道闸 —— 用户按过暂停（或被音乐挤停）的流不该被看门狗推翻。
     */
    const armStall = () => {
      if (stallTimerRef.current !== null) return;
      stallTimerRef.current = setTimeout(() => {
        stallTimerRef.current = null;
        const el = audioRef.current;
        if (!el || el.paused || userPausedRef.current || !openedRef.current) return;
        scheduleReconnectRef.current();
      }, STALL_TIMEOUT);
    };

    const onPlaying = () => {
      clearStall();
      setPlaying(true);
      setLoading(false);
      // 接上了：额度归零，下一次断流还能从头退避。
      attemptRef.current = 0;
      setReconnecting(false);
      setError(null);
    };
    /**
     * `waiting` = 这一路暂时没数据可放了，Chrome 在正常出声的直播流上也会偶发
     * （每次等下一段数据都报一次，而 `playing` 未必再补一条）。它只喂看门狗，
     * **不动按钮**：loading 只由起播 / 续播 / 重连打开，播放头一动就收掉。
     * 真卡死 12 秒后看门狗重开，界面那时才走「重连中」。
     */
    const onWaiting = () => armStall();
    /**
     * `stalled` 只表示「下载停顿」，播放可能仍在从缓冲区继续 —— 不动按钮，
     * 交给看门狗：12 秒还没新数据就重开这一台。
     */
    const onStalled = () => armStall();
    /** 播放头在走 → 声音确实在响：把残留的 loading 收掉（与 Flutter position 同义）。 */
    const onTimeUpdate = () => {
      clearStall();
      const el = audioRef.current;
      if (!el || el.paused || userPausedRef.current) return;
      setPlaying(true);
      setLoading(false);
    };
    const onPause = () => {
      // 暂停是稳定态：按钮必须回到播放图形，不能停在上一段缓冲的转圈上。
      setPlaying(false);
      setLoading(false);
    };
    /** 还有数据在进来：证明这一路活着，看门狗不用开火。 */
    const onProgress = () => clearStall();
    const onError = () => {
      setPlaying(false);
      setLoading(false);
      scheduleReconnectRef.current();
    };
    const onEnded = () => {
      // 直播流被上游掐断时浏览器报 `ended`（播到头）—— 与用户暂停长得一样，
      // 只能靠 userPausedRef 区分。
      setPlaying(false);
      scheduleReconnectRef.current();
    };
    audio.addEventListener('playing', onPlaying);
    audio.addEventListener('waiting', onWaiting);
    audio.addEventListener('stalled', onStalled);
    // 这三条是「这一路还活着」的证据：只要还在进数据，看门狗就不该开火。
    audio.addEventListener('progress', onProgress);
    audio.addEventListener('timeupdate', onTimeUpdate);
    audio.addEventListener('loadeddata', onProgress);
    audio.addEventListener('pause', onPause);
    audio.addEventListener('error', onError);
    audio.addEventListener('ended', onEnded);
    audioRef.current = audio;
    return () => {
      audio.removeEventListener('playing', onPlaying);
      audio.removeEventListener('waiting', onWaiting);
      audio.removeEventListener('stalled', onStalled);
      audio.removeEventListener('progress', onProgress);
      audio.removeEventListener('timeupdate', onTimeUpdate);
      audio.removeEventListener('loadeddata', onProgress);
      audio.removeEventListener('pause', onPause);
      audio.removeEventListener('error', onError);
      audio.removeEventListener('ended', onEnded);
      if (reconnectTimerRef.current !== null) clearTimeout(reconnectTimerRef.current);
      clearStall();
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
      audioRef.current = null;
    };
  }, []);

  /**
   * 断流后自己接回同一台：置 loading、按退避排一次重开。
   *
   * 四个否：没选台 / 流没开过 / 用户自己按的暂停 / 额度用尽（用尽才落错误态）。
   */
  const scheduleReconnect = useCallback(() => {
    if (userPausedRef.current || !openedRef.current) return;
    const station = stationRef.current;
    if (!station) return;
    if (reconnectTimerRef.current !== null) {
      // 已经排上了：同一场断流往往先报 `error` 再报 `ended`，每条都重排一次
      // 会让重连一直往后拖，这里只认第一次。
      return;
    }
    if (attemptRef.current >= MAX_RECONNECTS) {
      setReconnecting(false);
      setLoading(false);
      setError('stream unreachable');
      return;
    }
    // 重连期间不挂错误文案：界面上「这台暂时连不上」会让人以为只能换台。
    setError(null);
    // 这一路已经没声了（不管是 error / ended 还是看门狗抓到的卡死），
    // 先落回「没在响」，别让状态点亮着 LIVE 却一点声音都没有。
    setPlaying(false);
    setReconnecting(true);
    setLoading(true);
    const delay = RECONNECT_DELAYS[Math.min(attemptRef.current, RECONNECT_DELAYS.length - 1)];
    reconnectTimerRef.current = setTimeout(() => reconnectNowRef.current(), delay);
  }, []);

  const reconnectNow = useCallback(() => {
    reconnectTimerRef.current = null;
    const station = stationRef.current;
    const audio = audioRef.current;
    if (!station || !audio || !openedRef.current) return;
    attemptRef.current += 1;
    // 重连也要让音乐先让位：用户可能在被断流的空档里点了歌单。
    pauseMusic();
    audio.src = station.streamUrl;
    const promise = audio.play();
    if (promise && typeof promise.catch === 'function') {
      promise.catch((reason: unknown) => {
        if (currentIdRef.current !== station.id) return;
        // 自动播放被拒（页面被判成「没有用户手势」）：重连一百次也接不上，
        // 别把 8 次额度耗在一件永远做不成的事上 —— 直接落稳定态等用户点一下。
        if ((reason as { name?: string } | null)?.name === 'NotAllowedError') {
          setReconnecting(false);
          setLoading(false);
          setError('stream unreachable');
          return;
        }
        scheduleReconnectRef.current();
      });
    }
  }, [pauseMusic]);

  // 渲染期不许写 ref：改在 effect 里同步最新回调。ref 的所有读取都在
  // 定时器 / Promise 回调里（必晚于 effect），读取语义不变。
  useEffect(() => {
    scheduleReconnectRef.current = scheduleReconnect;
    reconnectNowRef.current = reconnectNow;
  }, [scheduleReconnect, reconnectNow]);

  /** 起播：换 src → play。失败一律落到稳定态并留一句人话错误。 */
  const start = useCallback((station: RadioStation) => {
    const audio = audioRef.current;
    if (!audio) return;
    clearReconnectTimer();
    attemptRef.current = 0;
    userPausedRef.current = false;
    setLoading(true);
    setError(null);
    audio.src = station.streamUrl;
    openedRef.current = true;
    currentIdRef.current = station.id;
    stationRef.current = station;
    const promise = audio.play();
    if (promise && typeof promise.catch === 'function') {
      promise.catch((reason: unknown) => {
        // 用户切台太快时上一路的 play() 会以 AbortError 结束，不该把新台标成失败
        if (currentIdRef.current !== station.id) return;
        const name = (reason as { name?: string } | null)?.name;
        if (name === 'NotAllowedError') {
          // 自动播放策略拦下（页面还没有用户手势）：重试多少次都接不上，
          // 直接落到稳定态，让用户点一下。
          setError('stream unreachable');
          setPlaying(false);
          setLoading(false);
          return;
        }
        // 其余（首帧迟迟没下来、连接在握手阶段就断了）统统交给重连：
        // 从前这里直接落「这台暂时连不上」，用户体感就是「点了就断」。
        scheduleReconnectRef.current();
      });
    }
  }, [clearReconnectTimer]);

  const tune = useCallback((station: RadioStation) => {
    // 同台再点：暂停 / 续播
    if (current?.id === station.id && openedRef.current) {
      const audio = audioRef.current;
      if (!audio) return;
      if (!audio.paused) {
        // 用户自己按的暂停：断流重连不许把它推翻。
        userPausedRef.current = true;
        clearReconnectTimer();
        audio.pause();
        return;
      }
      // 续播也要让音乐先让位：电台可能是被「音乐开声」挤停的，用户此刻在音乐页
      // 点这条的播放键，音乐正好在响 —— 少了这一步就是两路声音叠在一起。
      pauseMusic();
      clearReconnectTimer();
      attemptRef.current = 0;
      userPausedRef.current = false;
      setError(null);
      setLoading(true);
      const promise = audio.play();
      if (promise && typeof promise.catch === 'function') {
        promise.catch(() => {
          if (currentIdRef.current !== station.id) return;
          setError('stream unreachable');
          setLoading(false);
        });
      }
      return;
    }
    // 换台：先让音乐让位，再开流（顺序反了会有一瞬间两路声音叠在一起）
    pauseMusic();
    clearReconnectTimer();
    attemptRef.current = 0;
    userPausedRef.current = false;
    stationRef.current = station;
    setCurrent(station);
    setPlaying(false);
    start(station);
  }, [clearReconnectTimer, current?.id, pauseMusic, start]);

  const toggle = useCallback(() => {
    const station = current;
    if (!station || !openedRef.current) return;
    tune(station);
  }, [current, tune]);

  /**
   * 无条件暂停（保留当前台，迷你条显示「已暂停」）。
   *
   * 与 [toggle] 的区别：这个不看当前在不在响，也不会把暂停翻成续播 ——
   * 睡眠定时器到点、用户在音乐页按下播放，都需要电台无条件让位，
   * 不能因为状态晚到一拍而反过来把音乐切了。
   *
   * 重连／卡死看门狗一并取消：定时结束时电台正处在「等下一次重连」的空档，
   * 少了这一步，它到点后还会自己接回来重新出声。
   */
  const pause = useCallback(() => {
    const audio = audioRef.current;
    userPausedRef.current = true;
    clearReconnectTimer();
    if (audio && !audio.paused) {
      audio.pause();
    }
    // 元素已经停住时不会补发 pause 事件，这里把两个状态一起落定
    setPlaying(false);
    setLoading(false);
  }, [clearReconnectTimer]);

  const stop = useCallback(() => {
    const audio = audioRef.current;
    clearReconnectTimer();
    attemptRef.current = 0;
    userPausedRef.current = false;
    if (audio) {
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
    }
    currentIdRef.current = null;
    stationRef.current = null;
    openedRef.current = false;
    setCurrent(null);
    setPlaying(false);
    setLoading(false);
    setError(null);
  }, [clearReconnectTimer]);

  const isLive = useCallback(
    (station: RadioStation) => current?.id === station.id && playing,
    [current?.id, playing],
  );

  /**
   * 反方向的互斥：用户在音乐页按下播放、点列表里的歌、或切上一首 / 下一首，
   * 电台都要先让位。当前台**保留**（迷你条显示「已暂停」，点一下能续播）。
   *
   * 依赖它而不能只靠「用户会先来点电台」：列表里双击一首歌同样会让两路声音
   * 叠在一起，而这里只监听一个布尔量就够了。
   */
  useEffect(() => {
    if (!musicPlaying) return;
    // 让位是用户侧的决定（他刚在音乐页按了播放）：断流重连不许把它推翻，
    // 否则「音乐开声 → 电台暂停 → 重连把音乐又挤停」就成了一段死循环。
    // pause() 里已经置了 userPausedRef 并清掉重连，这里不必再写一遍。
    pause();
  }, [musicPlaying, pause]);

  /**
   * 回来的时候自己看一眼。
   *
   * 浏览器在后台会掐掉长连接，也会把 `setTimeout` 节流到一分钟一次 —— 只靠退避
   * 定时器，「切出去一会儿再回来」就是一段长静默。回前台 / 网络恢复时把额度清零、
   * 立刻重接一次，用户看到的只是一下「连接中」。
   */
  useEffect(() => {
    const kick = () => {
      const audio = audioRef.current;
      if (!audio || !openedRef.current || userPausedRef.current) return;
      // 还在响、或者已经排上重连，都不用多插一脚
      if (!audio.paused || reconnectTimerRef.current !== null) return;
      attemptRef.current = 0;
      setError(null);
      setReconnecting(true);
      setLoading(true);
      reconnectNowRef.current();
    };
    const onVisibility = () => {
      if (document.visibilityState === 'visible') kick();
    };
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('online', kick);
    window.addEventListener('focus', kick);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('online', kick);
      window.removeEventListener('focus', kick);
    };
  }, []);

  const value = useMemo<RadioContextValue>(() => ({
    current,
    playing,
    loading,
    reconnecting,
    error,
    isLive,
    tune,
    toggle,
    pause,
    stop,
    errorMessage: error ? '这台暂时连不上，换一台试试' : '',
  }), [current, error, isLive, loading, pause, playing, reconnecting, stop, toggle, tune]);

  return <RadioContext.Provider value={value}>{children}</RadioContext.Provider>;
}

export function useRadio(): RadioContextValue {
  const value = useContext(RadioContext);
  if (!value) throw new Error('useRadio 必须在 RadioProvider 内使用');
  return value;
}

/** 按 id 还原一条台（播放态只存 id 时要读回整条记录）。 */
export function useRadioStationById(id: string | null): RadioStation | null {
  return useMemo(() => (id ? radioStationById(id) ?? null : null), [id]);
}
