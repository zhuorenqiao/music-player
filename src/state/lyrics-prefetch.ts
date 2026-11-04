/**
 * lyrics-prefetch.ts —— 后台预取歌词
 *
 * vanilla 版在「导入后」和「启动还原后」都会把列表里没歌词的曲目排队预取一遍，
 * 移植时漏了，表现就是每次切歌都要现场等 LRCLIB 十几秒。
 *
 * 节奏：串行 + 每条间隔 350ms。歌词库是社区公共服务，并行打过去等于自己造限流；
 * 当前曲目不走这里，它由 LyricsProvider 走带状态提示的正常流程。
 */

import { matchLyrics, isOnline } from '../lib/lyrics-source.js';
import { patchTrack as patchLocalRecord } from '../lib/local-store.js';
import type { Track } from './types';

/** 相邻两条预取之间的间隔（毫秒）。 */
const PREFETCH_GAP = 350;

/** 同一进程内已发起过预取的曲目，避免重复排队。 */
const queued = new Set<string>();

/**
 * 为一批曲目后台补歌词。
 * @param tracks 候选曲目（已有歌词的会被跳过）
 * @param currentId 当前播放曲目 id（它有自己的带状态流程，这里跳过）
 * @returns 实际补齐的曲目数
 */
export async function prefetchLyrics(tracks: Track[], currentId?: string | null): Promise<number> {
  if (!isOnline()) {
    return 0;
  }
  let filled = 0;

  for (const track of tracks) {
    if (!track || track.isLocal === undefined) {
      continue;
    }
    if (track.id === currentId || track.lyrics || track.lyricsPlain || queued.has(track.id)) {
      continue;
    }
    // 本地文件时长还没探到时先跳过：带时长查准率高得多，探到后下一轮会补上
    if (track.isLocal && !Number.isFinite(track.duration)) {
      continue;
    }
    queued.add(track.id);
    try {
      const result = await matchLyrics(track);
      if (result.status === 'ok' && (result.syncedLyrics || result.plainLyrics)) {
        // 期间用户可能手动挂了 .lrc —— 手动优先，不覆盖
        if (track.lyricsSource !== 'manual' && !track.lyrics && !track.lyricsPlain) {
          track.lyrics = result.syncedLyrics || '';
          track.lyricsPlain = result.syncedLyrics ? '' : (result.plainLyrics || '');
          track.lyricsSource = 'auto';
          void patchLocalRecord(track.id, {
            lyrics: track.lyrics,
            lyricsPlain: track.lyricsPlain,
            lyricsSource: 'auto',
          });
          filled += 1;
        }
      }
    } catch (error) {
      console.error('[lyrics-prefetch] 预取失败：', track.title, error);
    }
    await new Promise((resolve) => setTimeout(resolve, PREFETCH_GAP));
  }

  return filled;
}
