/**
 * lyrics.tsx —— 当前曲目的歌词：解析、状态行、自动匹配与自动重试
 *
 * 高频的「当前第几行」不放在这里，而是由组件用 usePlaybackTime() 自己算 ——
 * 否则 timeupdate 会带着整个 Provider 子树重渲染。
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { parseLRC } from '../lib/lyrics.js';
import { matchLyrics, isOnline } from '../lib/lyrics-source.js';
import { toSimplified } from '../lib/chinese';
import type { LyricsState, Track } from './types';

/** 匹配失败后自动补一次的间隔（毫秒）。 */
const AUTO_RETRY_DELAY = 25000;

export interface Cue {
  time: number;
  text: string;
}

interface LyricsContextValue {
  /** 已解析的带时间轴行 */
  cues: Cue[];
  /** 无时间轴时的纯文本 */
  plain: string;
  status: string;
  state: LyricsState;
  showRetry: boolean;
  /** 手动指定歌词优先级最高，界面据此决定要不要显示「自动匹配」字样 */
  isManual: boolean;
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
    status,
    state,
    showRetry,
    isManual: track?.lyricsSource === 'manual',
    retry,
  }), [cues, plain, retry, showRetry, state, status, track?.lyricsSource]);

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
