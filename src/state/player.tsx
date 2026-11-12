/**
 * player.tsx —— 播放核心：Player 实例 + Playlist 模型 + 持久化 + 最近播放
 *
 * 对应 vanilla 版 app.js 里「播放器 + 列表 + 编排」那一大块。三点结构性差别：
 *
 * 1) **进度值走 useSyncExternalStore，不走 useState**。`timeupdate` 一秒约 4 次，
 *    塞进 Context 会让整棵树跟着抖；进度条这类高频值单独开 store，
 *    只有订阅它的组件才重渲染。
 * 2) **Playlist 是可变对象**，React 看不见内部变化，所以每次改完 `refresh()` 递增
 *    version，让消费方拿到新快照。
 * 3) **audio / Player 用模块级懒建单例**。整个应用只有一个播放器；放在 render 里
 *    `new` 会在 StrictMode 双跑时造出两个实例，第二个还挂在 audio 上没被释放。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState,
  useSyncExternalStore, type ReactNode,
} from 'react';
import { Player } from '../lib/player.js';
import { Playlist, PLAY_MODES, MODE_LABELS, normalizeTrack } from '../lib/playlist.js';
import { Storage, readNumber, readBoolean } from '../lib/storage.js';
import { loadRecent, recordPlay, removeRecent as removeRecentEntry } from '../lib/recent-store.js';
import { loadAll as loadLocalRecords, recordToTrack, remove as removeLocalRecord, requestPersistentStorage } from '../lib/local-store.js';
import { createDemoTracks, DEFAULT_COVER } from '../lib/demo-data.js';
import { applyAudioTags } from './tagging';
import { prefetchCovers } from './covers';
import { prefetchLyrics } from './lyrics-prefetch';
import { probeDurations } from './duration';

/** 自动播放被拦后，最多主动重试几次（绝不无限重试）。 */
const MAX_AUTOPLAY_RETRIES = 3;

/** 常驻提示条的内容。 */
export interface Notice {
  message: string;
  actionLabel?: string;
}
import { APP_TITLE, PREV_RESTART_AFTER, STORAGE_KEYS } from './constants';
import type { PlayMode, RecentEntry, Track } from './types';
import { useToast } from './toast';

// ---------------------------------------------------------------------------
// 高频值的外部 store
// ---------------------------------------------------------------------------

function createStore<T>(initial: T) {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set(next: T): void {
      if (Object.is(next, value)) {
        return;
      }
      value = next;
      listeners.forEach((notify) => notify());
    },
    subscribe(notify: () => void): () => void {
      listeners.add(notify);
      return () => {
        listeners.delete(notify);
      };
    },
  };
}

const timeStore = createStore(0);
const bufferedStore = createStore(0);

/** 当前播放进度（秒）。高频更新，单独订阅，别塞进 Context。 */
export function usePlaybackTime(): number {
  return useSyncExternalStore(timeStore.subscribe, timeStore.get, timeStore.get);
}

/** 已缓冲到的位置（秒）。 */
export function useBufferedEnd(): number {
  return useSyncExternalStore(bufferedStore.subscribe, bufferedStore.get, bufferedStore.get);
}

// ---------------------------------------------------------------------------
// 模块级单例
// ---------------------------------------------------------------------------

let sharedPlayer: Player | null = null;

/** 全应用共用的播放器实例（内部自建 <audio>，不需要渲染到 DOM）。 */
export function getSharedPlayer(): Player {
  if (!sharedPlayer) {
    sharedPlayer = new Player(new Audio());
  }
  return sharedPlayer;
}

const sharedPlaylist = new Playlist({ tracks: [], mode: PLAY_MODES.LIST });

/** 首次运行（完全没有持久化记录）时才塞示例曲目。 */
function hasStoredLibrary(): boolean {
  return Storage.read(STORAGE_KEYS.playlist, null) !== null || Storage.read(STORAGE_KEYS.order, null) !== null;
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

interface PlayerContextValue {
  tracks: Track[];
  current: Track | null;
  currentIndex: number;
  mode: PlayMode;
  modeLabel: string;
  playing: boolean;
  loading: boolean;
  /** 总时长（秒），未知为 NaN */
  duration: number;
  volume: number;
  muted: boolean;
  /** 已知损坏的曲目 id（列表上显示角标） */
  failedIds: string[];
  recent: RecentEntry[];
  player: Player;
  playlist: Playlist;
  togglePlay: () => void;
  /** 幂等暂停（睡眠定时器到点时用） */
  pause: () => void;
  playAt: (index: number, options?: { autoplay?: boolean }) => void;
  playNext: (options?: { auto?: boolean }) => void;
  playPrev: () => void;
  /** 跳过「回到本曲开头」的约定，直接切上一首（手势切歌用） */
  playPrevTrack: () => void;
  seek: (seconds: number) => void;
  seekBy: (delta: number) => void;
  setVolume: (value: number) => void;
  toggleMute: () => void;
  cycleMode: () => void;
  removeTrack: (id: string) => void;
  moveTrack: (id: string, delta: number) => void;
  clearList: () => void;
  /** 列表结构变了（导入流程直接改 playlist 后要调一次） */
  refresh: () => void;
  /** 把当前列表元数据写进 localStorage */
  persist: () => void;
  /** 写入并同步「最近播放」 */
  syncRecent: () => void;
  /** 从最近播放中移除一条记录 */
  removeRecent: (id: string) => void;
  clearFailure: (id: string) => void;
  /** 常驻提示条（自动播放被拦、全列表失败这类需要一直看得见的事） */
  notice: Notice | null;
  showNotice: (message: string, actionLabel?: string) => void;
  hideNotice: () => void;
  /** 提示条上的按钮 / 页面任意一次真实交互都会走这里 */
  resumeAutoplay: () => void;
}

const PlayerContext = createContext<PlayerContextValue | null>(null);

export function PlayerProvider({ children }: { children: ReactNode }) {
  const { show } = useToast();
  const player = getSharedPlayer();
  const playlist = sharedPlaylist;

  const [version, setVersion] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [duration, setDuration] = useState(Number.NaN);
  const [volume, setVolumeState] = useState(0.7);
  const [muted, setMutedState] = useState(false);
  const [mode, setMode] = useState<PlayMode>(PLAY_MODES.LIST as PlayMode);
  const [failedIds, setFailedIds] = useState<string[]>([]);
  const [recent, setRecent] = useState<RecentEntry[]>([]);

  const consecutiveFailures = useRef(0);
  const failureTimer = useRef(0);
  /** 「自动播放被浏览器策略拦住、等用户手势恢复」状态 */
  const pendingAutoPlay = useRef(false);
  const autoplayAttempts = useRef(0);
  /** 常驻提示条：被拦、全列表失败这类需要一直看得见的事，不该用会消失的 toast */
  const [notice, setNotice] = useState<Notice | null>(null);

  const showNotice = useCallback((message: string, actionLabel = '') => {
    setNotice({ message, actionLabel: actionLabel || undefined });
  }, []);
  const hideNotice = useCallback(() => setNotice(null), []);

  const clearPendingAutoplay = useCallback(() => {
    pendingAutoPlay.current = false;
    autoplayAttempts.current = 0;
  }, []);

  /**
   * 尝试把被拦住的播放拉起来：有限次重试（MAX_AUTOPLAY_RETRIES），
   * 用完就提示用户手动点播放，绝不无限打转。
   * 页面任意一次真实交互（pointerdown / 非空格回车的按键）都会调它。
   */
  const resumeAutoplay = useCallback(() => {
    if (!pendingAutoPlay.current) {
      return;
    }
    if (!player.paused) {
      // 用户自己的操作已经把播放拉起来了
      clearPendingAutoplay();
      hideNotice();
      return;
    }
    if (autoplayAttempts.current >= MAX_AUTOPLAY_RETRIES) {
      clearPendingAutoplay();
      hideNotice();
      show('仍无法自动恢复播放，请点击播放按钮', 'error');
      return;
    }
    autoplayAttempts.current += 1;
    void Promise.resolve(player.play()).then((started: unknown) => {
      if (started) {
        clearPendingAutoplay();
        hideNotice();
      }
    });
  }, [clearPendingAutoplay, hideNotice, player, show]);

  const refresh = useCallback(() => setVersion((value) => value + 1), []);
  const syncRecent = useCallback(() => setRecent(loadRecent() as RecentEntry[]), []);
  const removeRecent = useCallback((id: string) => {
    setRecent(removeRecentEntry(id) as RecentEntry[]);
  }, []);

  // -- 持久化 --------------------------------------------------------------

  const persist = useCallback(() => {
    const serializable = (playlist.tracks as Track[])
      .filter((track) => !track.isLocal && !track.src.startsWith('blob:'))
      .map((track) => ({
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        cover: track.cover,
        src: track.src,
        duration: Number.isFinite(track.duration) ? track.duration : null,
        isLocal: false,
        // 用户为内置曲目手动挂载的 .lrc 也要跟着持久化
        lyrics: track.lyrics || '',
        lyricsPlain: track.lyricsPlain || '',
      }));
    Storage.write(STORAGE_KEYS.playlist, serializable);
    Storage.write(STORAGE_KEYS.order, (playlist.tracks as Track[]).map((track) => track.id));
    const current = playlist.current as Track | null;
    if (current) {
      Storage.write(STORAGE_KEYS.currentId, current.id);
    } else {
      Storage.remove(STORAGE_KEYS.currentId);
    }
  }, [playlist]);

  // -- 播放编排 ------------------------------------------------------------

  const goTo = useCallback((index: number, options: { autoplay?: boolean } = {}) => {
    const { autoplay = true } = options;
    if (index < 0 || index >= playlist.size) {
      return;
    }
    playlist.setCurrentIndex(index);
    const track = playlist.current as Track | null;
    if (!track) {
      return;
    }
    timeStore.set(0);
    bufferedStore.set(0);
    setDuration(Number.isFinite(track.duration) ? track.duration : Number.NaN);
    document.title = `${track.title} · 流光音乐`;
    player.load(track, { autoplay });
    refresh();
    persist();
  }, [persist, player, playlist, refresh]);

  const playNext = useCallback((options: { auto?: boolean } = {}) => {
    const next = playlist.nextIndex(options);
    if (next >= 0) {
      goTo(next, { autoplay: true });
    }
  }, [goTo, playlist]);

  /** 无条件切到上一首：手势切歌不该被「回到本曲开头」的按钮约定打断 */
  const playPrevTrack = useCallback(() => {
    const prev = playlist.prevIndex();
    if (prev >= 0) {
      goTo(prev, { autoplay: true });
    }
  }, [goTo, playlist]);

  const playPrev = useCallback(() => {
    // 已播放超过 3 秒：「上一首」回到本曲开头，这是播放器通用约定
    if (player.currentTime > PREV_RESTART_AFTER) {
      player.seek(0);
      timeStore.set(0);
      return;
    }
    playPrevTrack();
  }, [playPrevTrack, player]);

  const togglePlay = useCallback(() => {
    if (playlist.size === 0) {
      show('播放列表为空，请先添加音频文件', 'info');
      return;
    }
    if (!playlist.current || !player.track) {
      goTo(playlist.currentIndex >= 0 ? playlist.currentIndex : 0, { autoplay: true });
      return;
    }
    if (player.paused) {
      consecutiveFailures.current = 0;
    }
    /**
     * `toggle()` 返回的是「切换后是否在播放」：暂停本来就返回 false，
     * 不能拿它当「被浏览器拦住了」来弹提示 —— 那样每按一次暂停就假报一次。
     * 真被拦时 Player 会发 playblocked（NotAllowedError），由提示条处理；
     * 用户主动暂停造成的 AbortError 是正常流程，Player 也不发事件。
     */
    void Promise.resolve(player.toggle()).then((started: unknown) => {
      if (started) {
        clearPendingAutoplay();
        hideNotice();
      }
    });
  }, [clearPendingAutoplay, goTo, hideNotice, player, playlist, show]);

  const seek = useCallback((seconds: number) => {
    player.seek(seconds);
    timeStore.set(seconds);
  }, [player]);

  /**
   * 幂等暂停：睡眠定时器到点时调用。
   *
   * 不能拿 [togglePlay] 顶替 —— 那是「切换」语义：定时器触发的那一刻用户可能
   * 刚好手动暂停过，再 toggle 一下就把音乐放出来了。这里只保证「此刻是暂停」。
   */
  const pause = useCallback(() => {
    if (!player.paused) {
      player.pause();
    }
    setPlaying(false);
    clearPendingAutoplay();
  }, [clearPendingAutoplay, player]);

  const seekBy = useCallback((delta: number) => player.seekBy(delta), [player]);

  const setVolume = useCallback((value: number) => {
    player.setVolume(value);
    Storage.write(STORAGE_KEYS.volume, player.volume);
  }, [player]);

  const toggleMute = useCallback(() => {
    player.toggleMute();
    Storage.write(STORAGE_KEYS.muted, player.muted);
  }, [player]);

  const cycleMode = useCallback(() => {
    const next = playlist.cycleMode() as PlayMode;
    setMode(next);
    Storage.write(STORAGE_KEYS.mode, next);
    // 同一个 key：连点只在原位置改文案并重新计时，不叠一条新的
    show(`播放模式：${MODE_LABELS[next] ?? next}`, 'info', 2000, 'play-mode');
  }, [playlist, show]);

  const removeTrack = useCallback((id: string) => {
    const at = playlist.indexOfId(id);
    if (at < 0) {
      return;
    }
    const wasCurrent = at === playlist.currentIndex;
    const { removed: rawRemoved, currentChanged } = playlist.removeById(id);
    const removed = rawRemoved as Track | null;
    // 本地曲目要把音频体一起从 IndexedDB 抹掉，否则删了记录还占着配额；
    // blob: 地址也要 revoke，不然整个 File 一直被页面引用着。
    if (removed?.isLocal) {
      void removeLocalRecord(id);
    }
    if (removed?.src?.startsWith('blob:')) {
      URL.revokeObjectURL(removed.src);
    }
    setFailedIds((current) => current.filter((item) => item !== id));
    if (playlist.size === 0) {
      player.stop();
      timeStore.set(0);
      setDuration(Number.NaN);
      document.title = APP_TITLE;
    } else if (wasCurrent || currentChanged) {
      goTo(playlist.currentIndex, { autoplay: wasCurrent });
    }
    refresh();
    persist();
  }, [goTo, persist, player, playlist, refresh]);

  const moveTrack = useCallback((id: string, delta: number) => {
    if (!playlist.move(id, delta)) {
      return;
    }
    refresh();
    persist();
  }, [persist, playlist, refresh]);

  const clearList = useCallback(() => {
    playlist.clear();
    player.stop();
    timeStore.set(0);
    setDuration(Number.NaN);
    document.title = APP_TITLE;
    refresh();
    persist();
  }, [persist, player, playlist, refresh]);

  const clearFailure = useCallback((id: string) => {
    setFailedIds((current) => current.filter((item) => item !== id));
    consecutiveFailures.current = 0;
  }, []);

  // -- 播放器事件 ----------------------------------------------------------

  useEffect(() => {
    const handlers: Array<[string, (detail: never) => void]> = [];
    const on = (type: string, handler: (detail: never) => void) => {
      handlers.push([type, handler]);
      player.on(type, handler);
    };

    on('statechange', (detail: { playing?: boolean }) => {
      setPlaying(Boolean(detail?.playing));
      if (detail?.playing) {
        consecutiveFailures.current = 0;
        // 真的播起来了，之前的失败 / 被拦提示就该收掉
        hideNotice();
        const track = playlist.current as Track | null;
        if (track) {
          setRecent(recordPlay(track) as RecentEntry[]);
        }
      }
    });
    on('timeupdate', (detail: { currentTime?: number; duration?: number }) => {
      timeStore.set(Number(detail?.currentTime) || 0);
      const total = Number(detail?.duration);
      if (Number.isFinite(total) && total > 0) {
        setDuration(total);
      }
    });
    on('durationchange', (detail: { duration?: number }) => {
      const total = Number(detail?.duration);
      setDuration(Number.isFinite(total) ? total : Number.NaN);
    });
    on('progress', (detail: { bufferedEnd?: number }) => {
      bufferedStore.set(Number(detail?.bufferedEnd) || 0);
    });
    on('volumechange', (detail: { volume?: number; muted?: boolean }) => {
      setVolumeState(Number(detail?.volume) || 0);
      setMutedState(Boolean(detail?.muted));
    });
    on('loading', (detail: { loading?: boolean }) => setLoading(Boolean(detail?.loading)));
    on('ended', () => playNext({ auto: true }));
    on('playblocked', () => {
      // 只在「首次进入待恢复态」时清零计数，否则每次失败都把计数抹平，上限就成了摆设
      if (!pendingAutoPlay.current) {
        autoplayAttempts.current = 0;
      }
      pendingAutoPlay.current = true;
      showNotice('浏览器阻止了自动播放。点击「继续播放」，或在页面任意处点一下即可恢复。', '继续播放');
    });
    on('error', (detail: { message?: string }) => {
      setPlaying(false);
      setLoading(false);
      const track = playlist.current as Track | null;
      if (track) {
        setFailedIds((current) => (current.includes(track.id) ? current : [...current, track.id]));
      }
      consecutiveFailures.current += 1;
      show(detail?.message || '音频播放失败，请稍后重试', 'error', 5000);
      if (consecutiveFailures.current >= Math.max(1, playlist.size)) {
        // 全列表都试过一轮：停手并说清楚，别静默卡在那里
        window.clearTimeout(failureTimer.current);
        failureTimer.current = 0;
        consecutiveFailures.current = 0;
        player.pause();
        setPlaying(false);
        showNotice('播放列表中的曲目都无法播放，已停止自动跳转。请检查音频文件后重新添加。');
        show('列表内曲目均无法播放，已暂停播放', 'error', 6400);
        return;
      }
      // 还没试完一轮，隔一会儿自动跳下一首
      window.clearTimeout(failureTimer.current);
      failureTimer.current = window.setTimeout(() => playNext({ auto: true }), 900);
    });

    return () => {
      handlers.forEach(([type, handler]) => player.off(type, handler));
      window.clearTimeout(failureTimer.current);
    };
  }, [hideNotice, playNext, player, playlist, show]);

  // -- 启动还原 ------------------------------------------------------------

  useEffect(() => {
    let cancelled = false;
    (async () => {
      player.setVolume(readNumber(STORAGE_KEYS.volume, 0.7, 0, 1));
      if (readBoolean(STORAGE_KEYS.muted, false)) {
        player.setMuted(true);
      }

      const records = await loadLocalRecords();
      if (cancelled) {
        return;
      }
      const localTracks = (records as Array<Record<string, unknown> | null>)
        .map((record) => (record ? recordToTrack(record, DEFAULT_COVER) : null))
        .filter(Boolean) as Track[];

      let initial: Track[];
      if (!hasStoredLibrary()) {
        initial = [...(createDemoTracks() as Track[]), ...localTracks];
      } else {
        const stored = (Storage.read(STORAGE_KEYS.playlist, []) as Track[]) ?? [];
        const remote = stored
          .map((item) => normalizeTrack(item) as Track | null)
          .filter((track) => track && !track.src.startsWith('blob:')) as Track[];
        const pool = new Map<string, Track>();
        remote.forEach((track) => pool.set(track.id, track));
        localTracks.forEach((track) => pool.set(track.id, track));
        const order = (Storage.read(STORAGE_KEYS.order, []) as string[]) ?? [];
        const ordered: Track[] = [];
        order.forEach((id) => {
          const track = pool.get(id);
          if (track) {
            ordered.push(track);
            pool.delete(id);
          }
        });
        pool.forEach((track) => ordered.push(track));
        initial = ordered;
      }

      if (initial.length > 0) {
        playlist.addMany(initial);
      }
      /**
       * 老库补跑标签解析：早于标签功能导入的曲目，IndexedDB 里存的是文件名拆出来的
       * （可能是反着的）歌手与曲名，也没有内嵌封面。vanilla 版在启动时就跑这一遍，
       * 移植时漏了 —— 不补的话，用户不重新导入就永远看不到纠正后的信息。
       */
      const restoredLocal = (playlist.tracks as Track[]).filter((track) => track.isLocal);
      let tagsDone: Promise<unknown> = Promise.resolve();
      /** 老记录里 duration 可能是 null（早期没落库），不补探就永远「总时长 0:00」 */
      const needDuration = (playlist.tracks as Track[]).filter((track) => track.isLocal && !Number.isFinite(track.duration));
      if (needDuration.length > 0) {
        tagsDone = tagsDone.then(() => probeDurations(needDuration)).then(() => setVersion((value) => value + 1));
      }
      if (restoredLocal.length > 0) {
        const blobById = new Map<string, Blob>(
          (records as Array<{ id?: string; blob?: Blob } | null>)
            .filter((record) => record?.id && record?.blob)
            .map((record) => [String(record?.id), record?.blob as Blob]),
        );
        tagsDone = applyAudioTags(restoredLocal, blobById, playlist.tracks as Track[])
          .then(async (renamed) => {
            for (const track of renamed) {
              await prefetchCovers([track]);
            }
            setVersion((value) => value + 1);
          })
          .catch((error) => {
            console.error('[player] 启动时读取内嵌标签失败，按现有信息继续：', error);
          });
      }
      const storedId = Storage.read(STORAGE_KEYS.currentId, null) as string | null;
      const index = storedId && playlist.indexOfId(storedId) >= 0 ? playlist.indexOfId(storedId) : 0;
      if (playlist.size > 0) {
        playlist.setCurrentIndex(index);
        const track = playlist.current as Track | null;
        if (track) {
          // 只加载不自动播放：遵循浏览器自动播放策略
          player.load(track, { autoplay: false });
          setDuration(Number.isFinite(track.duration) ? track.duration : Number.NaN);
          document.title = `${track.title} · 流光音乐`;
        }
      }
      playlist.setMode(Storage.read(STORAGE_KEYS.mode, PLAY_MODES.LIST));
      setMode(playlist.mode as PlayMode);
      setVolumeState(player.volume);
      setMutedState(player.muted);
      setRecent(loadRecent() as RecentEntry[]);
      setVersion((value) => value + 1);

      /**
       * 申请持久化存储：本地音频是几十 MB 的 Blob，默认配额下浏览器在空间紧张时
       * 可以整块清掉 IndexedDB。vanilla 版启动就申请，移植时漏了。
       */
      void requestPersistentStorage();

      // 后台把没歌词的曲目预取一遍，切过去时不用现场等十几秒。
      // 必须等标签纠正完再发 —— 否则拿反着的歌手/曲名去查，白跑一轮还写进缓存。
      void tagsDone
        .then(() => prefetchLyrics(playlist.tracks as Track[], (playlist.current as Track | null)?.id ?? null))
        .then(() => setVersion((value) => value + 1));
    })();
    return () => {
      cancelled = true;
    };
  }, [player, playlist]);

  const tracks = useMemo(() => playlist.tracks as Track[], [playlist, version]);
  const current = (playlist.current as Track | null) ?? null;

  const actions = useMemo(() => ({
    togglePlay, playAt: goTo, playNext, playPrev, playPrevTrack, seek, seekBy, setVolume, toggleMute,
    cycleMode, removeTrack, moveTrack, clearList, refresh, syncRecent, removeRecent, clearFailure, persist,
    notice, showNotice, hideNotice, resumeAutoplay, pause,
  }), [
    clearFailure, cycleMode, clearList, goTo, moveTrack, notice, pause, persist, playNext, playPrev, playPrevTrack,
    refresh, removeTrack, removeRecent, resumeAutoplay, seek, seekBy, setVolume, showNotice, hideNotice,
    syncRecent, toggleMute, togglePlay,
  ]);

  const value = useMemo<PlayerContextValue>(() => ({
    tracks,
    current,
    currentIndex: playlist.currentIndex,
    mode,
    modeLabel: MODE_LABELS[mode] ?? '列表循环',
    playing,
    loading,
    duration,
    volume,
    muted,
    failedIds,
    recent,
    player,
    playlist,
    ...actions,
  /**
   * version 必须在依赖里：`refresh()` 只动 version，而 `playlist.tracks` getter 返回的是
   * 同一个数组引用 —— 少了它，context 值身份不变，React 就不会通知消费者，
   * 表现是改了曲目（挂歌词、改名、补时长）但界面不重画。
   */
  }), [actions, current, duration, failedIds, loading, mode, muted, player, playlist, playing, recent, tracks, version, volume]);

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>;
}

/** @returns 播放核心上下文 */
export function usePlayer(): PlayerContextValue {
  const context = useContext(PlayerContext);
  if (!context) {
    throw new Error('usePlayer 必须在 PlayerProvider 内使用');
  }
  return context;
}
