/**
 * media-refresh.ts —— 播放列表面板上的「重新获取封面与歌词」
 *
 * 和导入时的后台预取（lyrics-prefetch.ts / covers.tsx 的 prefetchCovers）不同，
 * 这里做的是**用户主动要的强制刷新**：
 *   1. 先清两张查询结果缓存（否则第二次点击还是拿到同一批旧结果）；
 *   2. 逐首绕过缓存重新查询（matchLyrics / matchCover 的 useCache:false）；
 *   3. 只覆盖能拿到的结果 —— 查询失败 / 未命中不清掉现有封面与歌词，
 *      手动挂的 .lrc（lyricsSource === 'manual'）不参与、也不覆盖；
 *   4. 命中结果写回：本地曲目落 IndexedDB，非本地曲目走 onCommit（调用方传
 *      player 的 persist）写回 localStorage —— 否则页面一重载就回滚成旧值。
 *
 * 两条链路（封面 iTunes / 歌词 LRCLIB）互相独立，所以**并行**跑：封面 400ms
 * 一条、歌词 350ms 一条，各自串行节流，对公共接口保持和预取一样的客气节奏。
 * 全列表 50 首大约 20 秒跑完，期间面板按钮转圈、界面按 400ms 节流刷新。
 */

import { clearLyricsCache, isOnline, lyricsOriginOf, matchLyrics } from '../lib/lyrics-source.js';
import { clearCoverCache, matchCover } from '../lib/cover-source.js';
import { patchTrack as patchLocalRecord } from '../lib/local-store.js';
import { clearArtistPhotos } from './covers';
import type { Track } from './types';

/** 封面相邻两条的间隔（毫秒），与 prefetchCovers 同值。 */
const COVER_GAP = 400;

/** 歌词相邻两条的间隔（毫秒），与 lyrics-prefetch.ts 同值。 */
const LYRICS_GAP = 350;

/** 界面重绘节流：整批刷新会把每首的命中都写回，不必每次都惊动整棵树。 */
const NOTIFY_INTERVAL = 400;

export interface MediaRefreshResult {
  /** 成功拿到（并写回）的歌词条数 */
  lyrics: number;
  /** 成功拿到（并写回）的封面张数 */
  covers: number;
  /** 本次参与刷新的曲目数 */
  total: number;
  /** 因手动歌词而跳过的条数 */
  manual: number;
  /** 当前是否离线（离线时上面三个计数都是 0） */
  offline: boolean;
}

/** 同一时刻只允许一批刷新：连点按钮（或弹层里再点一次）复用同一份 Promise。 */
let active: Promise<MediaRefreshResult> | null = null;

/** 是否已有刷新在跑（面板挂载时据此恢复转圈状态）。 */
export function isMediaRefreshRunning(): boolean {
  return active !== null;
}

/**
 * 重新获取一批曲目的封面与歌词。
 *
 * @param tracks 播放列表里的活对象
 * @param options.onUpdate 有结果落地时的节流回调（调用方用 refresh() 重绘）
 * @param options.onCommit 非本地曲目命中后的持久化回调（调用方传 persist）。
 *   用回调注入而不是 import player 状态模块，避免 state 模块之间成环。
 */
export async function refreshAllMedia(
  tracks: Track[],
  { onUpdate, onCommit }: { onUpdate?: () => void; onCommit?: () => void } = {},
): Promise<MediaRefreshResult> {
  if (active) {
    return active;
  }
  const job = runRefresh(tracks, onUpdate, onCommit);
  active = job;
  try {
    return await job;
  } finally {
    active = null;
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

async function runRefresh(
  tracks: Track[],
  onUpdate?: () => void,
  onCommit?: () => void,
): Promise<MediaRefreshResult> {
  const result: MediaRefreshResult = {
    lyrics: 0,
    covers: 0,
    total: tracks.length,
    manual: 0,
    offline: false,
  };
  if (!isOnline()) {
    result.offline = true;
    return result;
  }

  // 「重新获取」而不是「查缓存」：两张表先清掉。封面写回时还会按曲目重新落库，
  // 歌词也一样，所以清表不会让已经显示的封面 / 歌词消失。
  clearLyricsCache();
  clearCoverCache();
  // 歌手写真是封面第三级兜底，也属于「封面」；不清的话永远停在上次那张。
  clearArtistPhotos();

  let lastNotify = 0;
  const notify = (force = false) => {
    const now = Date.now();
    if (!force && now - lastNotify < NOTIFY_INTERVAL) {
      return;
    }
    lastNotify = now;
    onUpdate?.();
  };

  const coverJob = (async () => {
    for (const track of tracks) {
      // 内嵌封面是文件自带的权威图，在线图抢不过它，跳过省一次请求。
      if (track.cover && track.cover.startsWith('data:')) {
        continue;
      }
      try {
        const match = await matchCover(track, { useCache: false }) as {
          status: string;
          url?: string;
        };
        if (match.status === 'ok' && match.url) {
          track.cover = match.url;
          if (track.isLocal) {
            void patchLocalRecord(track.id, { cover: match.url });
          } else {
            // 非本地曲目没有 IndexedDB 记录，不写回 localStorage 重载就回滚
            onCommit?.();
          }
          result.covers += 1;
          notify();
        }
      } catch (error) {
        console.error('[media-refresh] 封面刷新失败：', track.title, error);
      }
      await delay(COVER_GAP);
    }
  })();

  const lyricsJob = (async () => {
    for (const track of tracks) {
      if (track.lyricsSource === 'manual') {
        result.manual += 1;
        continue;
      }
      try {
        const match = await matchLyrics(track, { useCache: false }) as {
          status: string;
          syncedLyrics?: string;
          plainLyrics?: string;
          source?: string;
        };
        if (match.status === 'ok' && (match.syncedLyrics || match.plainLyrics)) {
          // 强制刷新：旧的自动歌词可以被覆盖；手动歌词在上一步已经整个跳过。
          track.lyrics = match.syncedLyrics || '';
          track.lyricsPlain = match.syncedLyrics ? '' : (match.plainLyrics || '');
          track.lyricsSource = 'auto';
          track.lyricsOrigin = lyricsOriginOf(match.source);
          if (track.isLocal) {
            void patchLocalRecord(track.id, {
              lyrics: track.lyrics,
              lyricsPlain: track.lyricsPlain,
              lyricsSource: 'auto',
              lyricsOrigin: track.lyricsOrigin,
            });
          } else {
            // 同封面：非本地曲目命中后也要持久化
            onCommit?.();
          }
          result.lyrics += 1;
          notify();
        }
      } catch (error) {
        console.error('[media-refresh] 歌词刷新失败：', track.title, error);
      }
      await delay(LYRICS_GAP);
    }
  })();

  // 并行：两个上游互不相关，串行等会让 50 首从 20 秒变成 40 秒。
  await Promise.all([coverJob, lyricsJob]);
  notify(true);
  return result;
}
