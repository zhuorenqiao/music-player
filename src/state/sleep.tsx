/**
 * state/sleep.tsx —— 休眠模块的播放状态
 *
 * 与电台同一套思路：**独立的第三条音频链路**（一枚常驻 `<audio loop>`），
 * 不经过曲库播放器 —— 休眠是「无限循环的声景」，混进 usePlayer 会让进度条
 * 拿一个假时长、让「暂停音乐」变成「暂停声景」。
 *
 * 三条互斥规则：
 *   1. 开始 / 续播休眠前，先暂停音乐与电台；
 *   2. 音乐或电台一开声，休眠自动让位（保留当前曲目，回到休眠页可续播）；
 *   3. 离开休眠页**不停声**：睡前声景要在后台一直放，音乐页底部的迷你条
 *      交代「还在响的是哪一段」，想关掉只有条上的关闭或回到页面按暂停。
 *
 * 曲目是程序化生成的（见 `lib/sleep-audio.ts`），首次点开会有极短的一次
 * 生成；之后同一首走 Blob URL 缓存，瞬时出声。
 */

import {
  createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode,
} from 'react';
import { SLEEP_FIRST_TRACK, type SleepTrack } from '../lib/sleep';
import { sleepAudioUrl } from '../lib/sleep-audio';
import { usePlayer } from './player';
import { useRadio } from './radio';

/** 略低于音乐音量：睡前声景是“垫在环境里的”，不该抢过正常听歌的响度。 */
const TARGET_VOLUME = 0.72;
/** 起播淡入时长：从 0 缓缓推到目标音量，避免“啪”一下出声。 */
const FADE_IN_MS = 1400;

interface SleepContextValue {
  /** 当前选中的声景；null = 还没选过（页面仍以第一首作门面） */
  current: SleepTrack | null;
  playing: boolean;
  loading: boolean;
  error: string | null;
  /** 选一条声景并开始播（会先暂停音乐与电台） */
  tune: (track: SleepTrack) => void;
  /** 同一条再点 = 暂停 / 续播 */
  toggle: () => void;
  /** 无条件往暂停走（保留当前曲目；睡眠定时器到点也走它） */
  pause: () => void;
  /** 关掉（清空当前曲目，页面回到「还没开始」） */
  stop: () => void;
}

const SleepContext = createContext<SleepContextValue | null>(null);

export function SleepProvider({ children }: { children: ReactNode }) {
  const player = usePlayer();
  const radio = useRadio();
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [current, setCurrent] = useState<SleepTrack | null>(null);
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  /** 播放态的最新值：音频事件 / 让位 effect 里读的是它，不吃闭包旧值。 */
  const playingRef = useRef(false);
  playingRef.current = playing;
  /** 当前曲目 id：异步起播回调里判断「用户是不是已经换了别的」。 */
  const currentIdRef = useRef<string | null>(null);
  currentIdRef.current = current?.id ?? null;
  /** 淡入的 rAF 句柄：换曲 / 暂停时要立刻掐掉。 */
  const fadeRef = useRef<number | null>(null);

  const cancelFade = useCallback(() => {
    if (fadeRef.current !== null) {
      window.cancelAnimationFrame(fadeRef.current);
      fadeRef.current = null;
    }
  }, []);

  const fadeIn = useCallback((audio: HTMLAudioElement) => {
    cancelFade();
    const startedAt = performance.now();
    audio.volume = 0;
    const tick = (now: number) => {
      const progress = Math.min(1, (now - startedAt) / FADE_IN_MS);
      // 缓出：一开始进得快一点，尾巴慢慢贴到目标音量
      audio.volume = TARGET_VOLUME * (1 - (1 - progress) ** 3);
      if (progress < 1 && !audio.paused) {
        fadeRef.current = window.requestAnimationFrame(tick);
      } else {
        fadeRef.current = null;
      }
    };
    fadeRef.current = window.requestAnimationFrame(tick);
  }, [cancelFade]);

  useEffect(() => {
    const audio = new Audio();
    audio.preload = 'auto';
    audio.loop = true;
    audio.setAttribute('playsinline', '');

    const onPlaying = () => {
      setPlaying(true);
      setLoading(false);
      setError(null);
    };
    const onPause = () => {
      setPlaying(false);
      setLoading(false);
    };
    const onWaiting = () => {
      // 本地 Blob 不该卡；只有首次解码会短暂 waiting，超过一瞬再上转圈
      if (!audio.paused) setLoading(true);
    };
    const onError = () => {
      setPlaying(false);
      setLoading(false);
      setError('这段声景没能出声，再点一次试试');
    };
    const onEnded = () => {
      // loop=true 理论上不会 ended；兜底自己接上，别让用户半夜醒来发现静了
      if (currentIdRef.current) {
        audio.currentTime = 0;
        void audio.play().catch(() => setPlaying(false));
      }
    };

    audio.addEventListener('playing', onPlaying);
    audio.addEventListener('pause', onPause);
    audio.addEventListener('waiting', onWaiting);
    audio.addEventListener('error', onError);
    audio.addEventListener('ended', onEnded);
    audioRef.current = audio;

    return () => {
      audio.removeEventListener('playing', onPlaying);
      audio.removeEventListener('pause', onPause);
      audio.removeEventListener('waiting', onWaiting);
      audio.removeEventListener('error', onError);
      audio.removeEventListener('ended', onEnded);
      cancelFade();
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
      audioRef.current = null;
    };
  }, [cancelFade]);

  /** 内部暂停：不碰 current，让「已暂停」也能在迷你条上继续操作。 */
  const pause = useCallback(() => {
    cancelFade();
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
    }
    setPlaying(false);
    setLoading(false);
  }, [cancelFade]);

  /** 音乐 / 电台一开声，休眠让位（当前曲目保留，回页面可续播）。 */
  useEffect(() => {
    if ((player.playing || radio.playing) && playingRef.current) {
      pause();
    }
  }, [pause, player.playing, radio.playing]);

  const tune = useCallback((track: SleepTrack) => {
    const audio = audioRef.current;
    if (!audio) return;
    // 两条链路都先让位：不做这一步就是两路声音叠在一起
    player.pause();
    radio.pause();
    cancelFade();
    setError(null);
    setLoading(true);
    setCurrent(track);
    // 生成是同步的短计算；抛到下一拍，先让「准备中」的一帧有机会画出来
    window.setTimeout(() => {
      if (currentIdRef.current !== track.id || !audioRef.current) return;
      const url = sleepAudioUrl(track.id, track.recipe, track.seed);
      audio.src = url;
      audio.loop = true;
      audio.volume = 0;
      const promise = audio.play();
      if (promise && typeof promise.catch === 'function') {
        promise.then(() => {
          if (currentIdRef.current === track.id) fadeIn(audio);
        }).catch(() => {
          if (currentIdRef.current === track.id) {
            setPlaying(false);
            setLoading(false);
            setError('这段声景没能出声，再点一次试试');
          }
        });
      } else {
        fadeIn(audio);
      }
    }, 30);
  }, [cancelFade, fadeIn, player, radio]);

  const toggle = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    if (!current) {
      tune(SLEEP_FIRST_TRACK);
      return;
    }
    if (playingRef.current && !audio.paused) {
      pause();
      return;
    }
    player.pause();
    radio.pause();
    setError(null);
    setLoading(true);
    audio.volume = 0;
    const promise = audio.play();
    if (promise && typeof promise.catch === 'function') {
      promise.then(() => fadeIn(audio)).catch(() => {
        setPlaying(false);
        setLoading(false);
        setError('这段声景没能出声，再点一次试试');
      });
    } else {
      fadeIn(audio);
    }
  }, [current, fadeIn, pause, player, radio, tune]);

  const stop = useCallback(() => {
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      audio.removeAttribute('src');
      audio.load();
    }
    cancelFade();
    setPlaying(false);
    setLoading(false);
    setError(null);
    setCurrent(null);
  }, [cancelFade]);

  const value = useMemo<SleepContextValue>(() => ({
    current,
    playing,
    loading,
    error,
    tune,
    toggle,
    pause,
    stop,
  }), [current, error, loading, pause, playing, stop, toggle, tune]);

  return <SleepContext.Provider value={value}>{children}</SleepContext.Provider>;
}

export function useSleep(): SleepContextValue {
  const context = useContext(SleepContext);
  if (!context) {
    throw new Error('useSleep 必须在 SleepProvider 内使用');
  }
  return context;
}
