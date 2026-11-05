/**
 * lyrics.tsx —— 当前曲目的歌词：解析、状态行、自动匹配、自动重试与中文译文
 *
 * 高频的「当前第几行」不放在这里，而是由组件用 usePlaybackTime() 自己算 ——
 * 否则 timeupdate 会带着整个 Provider 子树重渲染。
 *
 * 译文（非中文歌词的中文对照）走另一条链：原文到位后按需异步取，
 * 取回的是「整份译文 LRC」，落到哪一行由 alignTranslation 现算，
 * 所以歌词从纯文本升级成带时间轴时不必重新联网。
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { parseLRC } from '../lib/lyrics.js';
import { matchLyrics, isOnline } from '../lib/lyrics-source.js';
import { alignTranslation, fetchTranslation, needsTranslation } from '../lib/translate-source.js';
import { toSimplified } from '../lib/chinese';
import type { LyricsState, Track } from './types';

/** 匹配失败后自动补一次的间隔（毫秒）。 */
const AUTO_RETRY_DELAY = 25000;

/** 双语显示偏好的存储键（默认开）。 */
const BILINGUAL_KEY = 'light-music.bilingual';

export interface Cue {
  time: number;
  text: string;
}

/** 取回的一份译文：原文 + 译文都用得上（原文行用来估时间轴偏移）。 */
interface Translation {
  translatedLrc: string;
  originalLrc: string;
  source: string;
}

/** 译文这一路的进度，界面只在 loading / none / error / unavailable 时给提示。 */
export type TranslationState = 'idle' | 'off' | 'loading' | 'ready' | 'none' | 'unavailable' | 'error';

/** 歌词文本指纹：同一首歌词在本次会话里只取一次译文。 */
function fingerprint(text: string): string {
  return `${text.length}:${text.slice(0, 24)}:${text.slice(-24)}`;
}

function readBilingualPref(): boolean {
  try {
    return window.localStorage.getItem(BILINGUAL_KEY) !== '0';
  } catch {
    return true;
  }
}

interface LyricsContextValue {
  /** 已解析的带时间轴行 */
  cues: Cue[];
  /** 无时间轴时的纯文本 */
  plain: string;
  /** 纯文本按行拆开（去掉首尾空行），与 trans 对齐 */
  plainLines: string[];
  status: string;
  state: LyricsState;
  showRetry: boolean;
  /** 手动指定歌词优先级最高，界面据此决定要不要显示「自动匹配」字样 */
  isManual: boolean;
  /** 与当前显示行一一对齐的中文译文；关双语、无需翻译或还没取到 → 全空串 */
  trans: string[];
  /** 这首歌词需不需要中文译文（非中文才为真） */
  translatable: boolean;
  transState: TranslationState;
  /** 显示在状态行里的译文说明，没有要说明的就是空串 */
  transNote: string;
  bilingual: boolean;
  setBilingual: (value: boolean) => void;
  retry: () => void;
}

const LyricsContext = createContext<LyricsContextValue | null>(null);

/** 二分查找当前行；0.12s 容差避免在行边界来回跳。 */
export function findActiveCue(cues: Cue[], time: number): number {
  if (cues.length === 0) {
    return -1;
  }
  let low = 0;
  let high = cues.length - 1;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (cues[mid].time - 0.12 <= time) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return cues[low].time - 0.12 <= time ? low : -1;
}

export function LyricsProvider({ track, children }: { track: Track | null; children: ReactNode }) {
  const [state, setState] = useState<LyricsState>('idle');
  const [status, setStatus] = useState('');
  const [showRetry, setShowRetry] = useState(false);
  const [tick, setTick] = useState(0);
  const abortRef = useRef<AbortController | null>(null);
  const retriedRef = useRef(new Set<string>());
  /** 每首曲目本次会话只尝试把纯文本歌词升级为带时间轴版本一次 */
  const upgradedRef = useRef(new Set<string>());
  /** 用户点「重试」后下一次匹配要绕过本地缓存 */
  const forceNextRef = useRef(false);
  const retryTimer = useRef(0);
  const requestId = useRef(0);

  const cues = useMemo<Cue[]>(() => {
    if (!track?.lyrics) {
      return [];
    }
    // 在线歌词多为繁体：显示前转简体；手动导入的 .lrc 保持原样
    const text = track.lyricsSource === 'manual' ? track.lyrics : toSimplified(track.lyrics);
    return parseLRC(text, { title: track.title, artist: track.artist }).lines as Cue[];
  }, [track, track?.lyrics, track?.lyricsSource]);
  const plain = useMemo(() => {
    const raw = track?.lyricsPlain || '';
    return raw && track?.lyricsSource !== 'manual' ? toSimplified(raw) : raw;
  }, [track?.lyricsPlain, track?.lyricsSource]);

  /** 纯文本歌词拆行：组件里不再自己 split，否则译文对齐会对不上。 */
  const plainLines = useMemo(() => {
    if (!plain) {
      return [];
    }
    const lines = plain.replace(/\r\n/g, '\n').split('\n');
    while (lines.length > 0 && lines[0].trim() === '') {
      lines.shift();
    }
    while (lines.length > 0 && lines[lines.length - 1].trim() === '') {
      lines.pop();
    }
    return lines.map((line) => line.trim());
  }, [plain]);

  /** 当前真正显示的行：有时间轴用 cues，否则用纯文本行。译文按这一套对齐。 */
  const displayLines = useMemo(
    () => (cues.length > 0 ? cues : plainLines.map((text) => ({ text }))),
    [cues, plainLines],
  );

  const lyricsText = track?.lyrics || track?.lyricsPlain || '';
  const translatable = useMemo(
    () => displayLines.length > 0 && needsTranslation(lyricsText),
    [displayLines.length, lyricsText],
  );

  const [bilingual, setBilingualState] = useState(readBilingualPref);
  const [translation, setTranslation] = useState<Translation | null>(null);
  const [transState, setTransState] = useState<TranslationState>('idle');
  /** 查不到译文的具体原因：曲名/歌手没对上，还是这首歌本身没有译文 —— 用户要的处理方式不同 */
  const [transReason, setTransReason] = useState('');
  const [transTick, setTransTick] = useState(0);
  const transAbortRef = useRef<AbortController | null>(null);
  /** 用户手动打开双语时绕过缓存再要一次（关掉又打开就是「重新获取」） */
  const transForceRef = useRef(false);
  /** 本次会话内每首歌词只问一次译文，连「没有」也记住，避免切回来又打一遍接口 */
  const transCacheRef = useRef(new Map<string, { translation: Translation | null; state: TranslationState; reason: string }>());

  const trans = useMemo<string[]>(() => {
    if (!bilingual || !translation || displayLines.length === 0) {
      return displayLines.map(() => '');
    }
    return alignTranslation(displayLines, translation.translatedLrc, translation.originalLrc);
  }, [bilingual, displayLines, translation]);

  const setBilingual = useCallback((value: boolean) => {
    setBilingualState(value);
    try {
      window.localStorage.setItem(BILINGUAL_KEY, value ? '1' : '0');
    } catch {
      // 隐私模式下写不进去，本次会话内仍然有效
    }
    if (value) {
      transForceRef.current = true;
      setTransTick((current) => current + 1);
    }
  }, []);

  useEffect(() => {
    transAbortRef.current?.abort();
    const controller = new AbortController();
    transAbortRef.current = controller;
    const force = transForceRef.current;
    transForceRef.current = false;

    if (!track || !translatable) {
      setTranslation(null);
      setTransState('idle');
      setTransReason('');
      return () => controller.abort();
    }
    if (!bilingual) {
      setTranslation(null);
      setTransState('off');
      setTransReason('');
      return () => controller.abort();
    }

    const cacheKey = `${track.id}|${fingerprint(lyricsText)}`;
    // force（用户重开开关）要连会话缓存一起绕开，否则「上次说没有」会一直盖住这次重试
    if (force) {
      transCacheRef.current.delete(cacheKey);
    }
    const hit = transCacheRef.current.get(cacheKey);
    if (hit) {
      setTranslation(hit.translation);
      setTransState(hit.state);
      setTransReason(hit.reason);
      return () => controller.abort();
    }

    setTranslation(null);
    setTransState('loading');
    setTransReason('');
    void fetchTranslation(track, { signal: controller.signal, useCache: !force }).then((result: {
      status: string; reason?: string; message?: string; source?: string; translatedLyrics?: string; originalLyrics?: string;
    }) => {
      if (controller.signal.aborted) {
        return;
      }
      if (result.status === 'ok' && result.translatedLyrics) {
        const value: Translation = {
          translatedLrc: result.translatedLyrics,
          originalLrc: result.originalLyrics || '',
          source: result.source || '网易云译文库',
        };
        transCacheRef.current.set(cacheKey, { translation: value, state: 'ready', reason: '' });
        setTranslation(value);
        setTransState('ready');
        return;
      }
      /**
       * 「没有译文」和「静态部署」记进会话缓存，短期内不再问；
       * 网络/超时类失败不记，留给下一次（或用户重开开关）重试。
       */
      const state: TranslationState = result.status === 'not-found'
        ? 'none'
        : (result.status === 'unavailable' ? 'unavailable' : 'error');
      const reason = result.reason || '';
      if (state !== 'error') {
        transCacheRef.current.set(cacheKey, { translation: null, state, reason });
      }
      setTransState(state);
      setTransReason(reason);
    }).catch(() => {
      // 只有主动取消会抛到这里，界面已经切到别的歌了
    });

    return () => controller.abort();
    // lyricsText 变（首次匹配到 / 纯文本升级成带时间轴）才需要重新对齐一次
  }, [track, track?.id, lyricsText, bilingual, translatable, transTick]);

  const transNote = useMemo(() => {
    if (transState === 'loading') {
      return '正在匹配中文译文…';
    }
    if (transState === 'none') {
      if (transReason === 'song-not-matched') {
        return '译文库没匹配到这首歌（曲名/歌手对不上）';
      }
      if (transReason === 'no-translation') {
        return '这首歌还没有中文译文';
      }
      return '译文库里没有这首歌的中文译文';
    }
    if (transState === 'unavailable') {
      return '中文译文需要本地代理服务（npm run dev）';
    }
    if (transState === 'error') {
      return '中文译文获取失败，关掉再打开「双语」可重试';
    }
    return '';
  }, [transReason, transState]);

  const retry = useCallback(() => {
    if (track) {
      retriedRef.current.delete(track.id);
      upgradedRef.current.delete(track.id);
    }
    forceNextRef.current = true;
    setTick((value) => value + 1);
  }, [track]);

  useEffect(() => {
    abortRef.current?.abort();
    window.clearTimeout(retryTimer.current);
    const force = forceNextRef.current;
    forceNextRef.current = false;

    if (!track) {
      setState('idle');
      setStatus('');
      setShowRetry(false);
      return;
    }
    // 已有歌词（内置 / 手动 / 之前匹配过）就不再联网
    if (track.lyrics || track.lyricsPlain) {
      setState('ready');
      setStatus(track.lyricsSource === 'manual'
        ? '已使用手动指定的歌词'
        : (track.lyrics ? '歌词自动匹配自 LRCLIB线上库' : '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示'));
      setShowRetry(false);
      /**
       * 之前匹配到的是纯文本：后台再问一次源站。
       * LRCLIB 的搜索里常有带时间轴的版本，成功就替换并恢复逐行高亮；
       * 失败继续保持静态显示，不打扰用户。每首曲目每个会话只试一次。
       */
      if (!track.lyrics && track.lyricsPlain && track.lyricsSource !== 'manual'
        && !upgradedRef.current.has(track.id) && isOnline()) {
        const controller = new AbortController();
        abortRef.current = controller;
        const apply = (result: { status: string; syncedLyrics?: string }) => {
          if (controller.signal.aborted) {
            return;
          }
          if (result.status !== 'ok' || !result.syncedLyrics) {
            return;
          }
          if (track.lyricsSource === 'manual' || track.lyrics) {
            return;
          }
          track.lyrics = result.syncedLyrics;
          track.lyricsPlain = '';
          track.lyricsSource = 'auto';
          setStatus('歌词自动匹配自 LRCLIB线上库');
          setTick((value) => value + 1);
        };
        // 先看缓存：之前升级成功过的话这里瞬间完成，不必每次重打上游
        void matchLyrics(track, { signal: controller.signal, useCache: true }).then((cached: {
          status: string; syncedLyrics?: string;
        }) => {
          if (controller.signal.aborted) {
            return;
          }
          if (cached.status === 'ok' && cached.syncedLyrics) {
            apply(cached);
            return;
          }
          // 缓存里仍是纯文本：绕过缓存再问一次（老结果没有同步版本的情况）
          return matchLyrics(track, { signal: controller.signal, useCache: false }).then(apply);
        }).catch(() => {
          // 升级失败继续用纯文本，不影响当前显示
        }).finally(() => {
          // 被 StrictMode / 切歌打断的不算试过，下次进来还要再试
          if (!controller.signal.aborted) {
            upgradedRef.current.add(track.id);
          }
        });
        return () => controller.abort();
      }
      return;
    }
    if (!isOnline()) {
      setState('missing');
      setStatus('当前离线，且这首歌还没有歌词');
      setShowRetry(false);
      return;
    }
    // 本地文件时长还没探到时先等，带时长查准得多
    if (track.isLocal && !Number.isFinite(track.duration)) {
      setState('loading');
      setStatus('正在读取音频信息…');
      setShowRetry(false);
      return;
    }

    const id = requestId.current + 1;
    requestId.current = id;
    const controller = new AbortController();
    abortRef.current = controller;
    setState('loading');
    setStatus('正在按曲名与歌手匹配歌词…');
    setShowRetry(false);

    // 首次查询在本机可能要十几秒，4 秒后换个说法，避免看起来卡住
    const slowHint = window.setTimeout(() => {
      if (requestId.current === id) {
        setStatus('正在匹配歌词…首次查询较慢，成功后会缓存在本地');
      }
    }, 4000);

    void matchLyrics(track, { signal: controller.signal, useCache: !force }).then((result: {
      status: string; message?: string; reason?: string; syncedLyrics?: string; plainLyrics?: string;
    }) => {
      window.clearTimeout(slowHint);
      if (requestId.current !== id || controller.signal.aborted) {
        return;
      }
      if (result.status === 'ok' && (result.syncedLyrics || result.plainLyrics)) {
        // 请求期间用户可能手动导入了 .lrc：手动优先级最高
        if (track.lyricsSource !== 'manual' && !track.lyrics && !track.lyricsPlain) {
          if (result.syncedLyrics) {
            track.lyrics = result.syncedLyrics;
          } else {
            track.lyricsPlain = result.plainLyrics || '';
          }
          track.lyricsSource = 'auto';
          setTick((value) => value + 1);
        }
        setState('ready');
        setStatus(track.lyrics ? '歌词自动匹配自 LRCLIB线上库' : '歌词匹配自 LRCLIB线上库 · 原文无时间轴，仅静态显示');
        setShowRetry(false);
        return;
      }
      if (result.status === 'not-found') {
        setState('missing');
        setStatus(`未找到「${track.title}」的歌词`);
        setShowRetry(true);
        return;
      }
      if (result.status === 'aborted') {
        return;
      }
      const message = result.message || '歌词匹配失败';
      setState('error');
      setStatus(message);
      setShowRetry(true);
      // 网络/限流类失败自动补一次，每首只补一次
      const retryable = ['timeout', 'unreachable', 'rate-limit', 'upstream'].includes(String(result.reason))
        || /限流|超时|暂时不可用/.test(message);
      if (retryable && !retriedRef.current.has(track.id)) {
        retriedRef.current.add(track.id);
        const seconds = Math.round(AUTO_RETRY_DELAY / 1000);
        setStatus(`${message}（${seconds} 秒后自动重试）`);
        retryTimer.current = window.setTimeout(() => {
          if (requestId.current === id) {
            setTick((value) => value + 1);
          }
        }, AUTO_RETRY_DELAY);
      }
    }).catch((error: unknown) => {
      window.clearTimeout(slowHint);
      if (requestId.current !== id) {
        return;
      }
      console.error('[lyrics] 匹配失败：', error);
      setState('error');
      setStatus('歌词匹配失败');
      setShowRetry(true);
    });

    return () => {
      window.clearTimeout(slowHint);
    };
    // tick 用于「重试」触发；track 换了也要重来
  }, [track, tick, track?.id, track?.lyrics, track?.lyricsPlain]);

  const value = useMemo<LyricsContextValue>(() => ({
    cues,
    plain,
    plainLines,
    status,
    state,
    showRetry,
    isManual: track?.lyricsSource === 'manual',
    trans,
    translatable,
    transState,
    transNote,
    bilingual,
    setBilingual,
    retry,
  }), [
    cues, plain, plainLines, retry, setBilingual, showRetry, state, status,
    trans, transNote, transState, bilingual, track?.lyricsSource, translatable,
  ]);

  return <LyricsContext.Provider value={value}>{children}</LyricsContext.Provider>;
}

/** @returns 当前曲目的歌词状态 */
export function useLyrics(): LyricsContextValue {
  const context = useContext(LyricsContext);
  if (!context) {
    throw new Error('useLyrics 必须在 LyricsProvider 内使用');
  }
  return context;
}
