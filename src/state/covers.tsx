/**
 * covers.ts —— 封面四级兜底的显示层
 *
 * 顺序与 vanilla 版一致：
 *   1. 曲目自带的真封面（内嵌 APIC/PICTURE 转成的 data URL，或 iTunes 专辑图）
 *   2. 歌手写真图（维基条目配图，异步到达后替换）
 *   3. 本地生成的歌手封面卡（离线、确定性）
 *
 * 关键约定：**生成卡与写真都不写回 track.cover**。那个字段一有值，
 * needsCoverMatch 就认为「已经有真封面」，永久跳过在线匹配。
 * 所以它们只活在这一层，组件通过 useCover(track) 取「现在该显示什么」。
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { matchCover } from '../lib/cover-source.js';
import { matchArtistImage, normalizeArtistKey } from '../lib/artist-image.js';
import { generatedCoverUrl } from '../lib/generated-cover.js';
import { DEFAULT_COVER } from '../lib/demo-data.js';
import { isOnline } from '../lib/lyrics-source.js';
import type { Track } from './types';

/** 已拿到的歌手写真；值为 null 表示「问过，没有」，不再问第二次。 */
const artistPhotos = new Map<string, string | null>();

/** 写真图订阅者（拿到图后通知界面刷新）。 */
const photoListeners = new Set<() => void>();

function notifyPhotoArrived(): void {
  photoListeners.forEach((notify) => notify());
}

/** 这首歌是否还需要在线匹配封面。 */
export function needsCoverMatch(track: Track | null): boolean {
  return Boolean(track) && (!track?.cover || track.cover === DEFAULT_COVER);
}

/** 封面显示层只关心这三个字段，所以曲目和最近播放记录都能进来。 */
export type CoverSource = Pick<Track, 'cover' | 'artist' | 'title'>;

/** 当前该显示的封面地址。 */
export function coverForDisplay(track: CoverSource | null): string {
  if (!track) {
    return DEFAULT_COVER;
  }
  if (track.cover && track.cover !== DEFAULT_COVER) {
    return track.cover;
  }
  const photo = artistPhotos.get(normalizeArtistKey(track.artist));
  if (photo) {
    return photo;
  }
  return generatedCoverUrl(track.artist, track.title);
}

interface CoverContextValue {
  /** 为某首曲目补一次在线匹配（当前曲目用；预取走 prefetchCovers） */
  matchFor: (track: Track) => void;
  /** 把一张真封面写回曲目（内嵌图或匹配结果） */
  applyCover: (track: Track, url: string) => void;
}

const CoverContext = createContext<CoverContextValue | null>(null);

export function CoverProvider({ children }: { children: ReactNode }) {
  const [tick, forceRender] = useState(0);
  const pending = useRef(new Set<string>());

  // 写真图到位后，所有显示层要重算一次
  useEffect(() => {
    const notify = () => forceRender((value) => value + 1);
    photoListeners.add(notify);
    return () => {
      photoListeners.delete(notify);
    };
  }, []);

  const applyCover = useCallback((track: Track, url: string) => {
    if (!track || !url || track.cover === url) {
      return;
    }
    track.cover = url;
    forceRender((value) => value + 1);
  }, []);

  /** 专辑图 → 歌手写真，一路往下走；任何一级失败都静默退到下一级。 */
  const matchFor = useCallback((track: Track) => {
    const key = `${track.id}`;
    if (!needsCoverMatch(track) || pending.current.has(key) || !isOnline()) {
      return;
    }
    pending.current.add(key);
    void matchCover(track).then((result: { status: string; url?: string }) => {
      if (result.status === 'ok' && result.url) {
        pending.current.delete(key);
        applyCover(track, result.url);
        return;
      }
      pending.current.delete(key);
      void requestArtistPhoto(track.artist);
    }).catch(() => {
      pending.current.delete(key);
      void requestArtistPhoto(track.artist);
    });
  }, [applyCover]);

  /**
   * value 必须带上 tick 换身份：React 只在 context **值变化**时才通知消费者。
   * 只 forceRender 而 memo 仍返回同一个对象，写真图 / 匹配到的专辑图到位后界面不会重画，
   * 表现就是「封面一直加载不出来」。
   */
  const value = useMemo(() => ({ matchFor, applyCover }), [matchFor, applyCover, tick]);

  return <CoverContext.Provider value={value}>{children}</CoverContext.Provider>;
}

/** 同一位歌手的写真只发一次请求。 */
const photoPending = new Set<string>();

async function requestArtistPhoto(artist: string): Promise<void> {
  const key = normalizeArtistKey(artist);
  if (!key || artistPhotos.has(key) || photoPending.has(key) || !isOnline()) {
    return;
  }
  photoPending.add(key);
  try {
    const result = await matchArtistImage(artist);
    if (result.status === 'ok' && result.url) {
      artistPhotos.set(key, result.url);
      notifyPhotoArrived();
    } else if (result.status === 'not-found') {
      artistPhotos.set(key, null);
    }
  } finally {
    photoPending.delete(key);
  }
}

/** @returns 封面上下文 */
export function useCoverActions(): CoverContextValue {
  const context = useContext(CoverContext);
  if (!context) {
    throw new Error('useCoverActions 必须在 CoverProvider 内使用');
  }
  return context;
}

/** 取某首曲目当前该显示的封面。 */
export function useCover(track: Track | null): string {
  const { matchFor } = useCoverActions();
  const display = coverForDisplay(track);

  useEffect(() => {
    if (track) {
      matchFor(track);
    }
  }, [matchFor, track, display]);

  return display;
}

/** 后台预取一批曲目的封面（导入后用，切过去时图已经就位）。 */
export async function prefetchCovers(tracks: Track[]): Promise<void> {
  for (const track of tracks) {
    if (!needsCoverMatch(track)) {
      continue;
    }
    // 交给显示层同一条链路，避免两套逻辑分叉
    void matchCover(track).then((result: { status: string; url?: string }) => {
      if (result.status === 'ok' && result.url) {
        track.cover = result.url;
        notifyPhotoArrived();
      }
    }).catch(() => undefined);
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
}
