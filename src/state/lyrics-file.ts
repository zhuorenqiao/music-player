/**
 * lyrics-file.ts —— 用户提供的 .lrc 文件：读取、按文件名配对到曲目
 *
 * 优先级规则（与 vanilla 版一致，也是这条链路的重点）：
 *   手动 .lrc  >  联网自动匹配  >  无歌词
 * 一旦某首曲目带上 `lyricsSource === 'manual'`，自动匹配就不会再覆盖它；
 * 反过来，自动匹配的结果也不会伪装成手动歌词。
 */

import { parseLRC } from '../lib/lyrics.js';
import { splitArtistTitle } from '../lib/lyrics-source.js';
import type { Track } from './types';

/** 单个歌词文件的体积上限（512KB 够放任何正规歌词，超了多半是选错文件）。 */
export const MAX_LYRICS_BYTES = 512 * 1024;

const normalizeName = (value: string): string => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ');

const stripExtension = (value: string): string => {
  const name = String(value ?? '');
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(0, dot) : name;
};

/** 本地文件的占位歌手名没有匹配价值。 */
function isRealArtist(artist: string): boolean {
  const value = normalizeName(artist);
  return Boolean(value) && value !== '本地文件' && value !== '未知歌手';
}

/**
 * 为一个 .lrc 文件名找目标曲目，按可信度取最高分：
 *   50 「歌手 - 歌名」组合名完全一致
 *   45 拆出歌名且歌手也对得上
 *   40 曲名完全一致
 *   30 只有拆出的歌名一致
 * 一分都没有就返回 null（宁可跳过，也别把 N 份歌词轮流盖到同一首正在播的歌上）。
 * @param fileName 歌词文件名
 * @param tracks 播放列表里的曲目
 * @returns 匹配到的曲目或 null
 */
export function matchLyricsTrack(fileName: string, tracks: Track[]): Track | null {
  const raw = stripExtension(fileName);
  const base = normalizeName(raw);
  if (!base) {
    return null;
  }
  const split = splitArtistTitle(raw);
  const titleOnly = split ? normalizeName(split.title) : '';
  const artistOnly = split ? normalizeName(split.artist) : '';

  let best: Track | null = null;
  let bestScore = 0;
  for (const track of tracks) {
    const title = normalizeName(track.title);
    const artist = normalizeName(track.artist);
    const hasArtist = isRealArtist(track.artist);
    let score = 0;

    if (title === base) {
      score = 40;
    }
    if (hasArtist && normalizeName(`${track.artist} - ${track.title}`) === base) {
      score = Math.max(score, 50);
    }
    if (titleOnly && title === titleOnly) {
      const artistAlsoMatched = Boolean(artistOnly) && hasArtist && artist === artistOnly;
      score = Math.max(score, artistAlsoMatched ? 45 : 30);
    }
    if (score > bestScore) {
      best = track;
      bestScore = score;
    }
  }
  return bestScore > 0 ? best : null;
}

/**
 * 读歌词文本并校验。
 * @returns 文本与解析出的行数；不合格时返回 null 并给出原因
 */
export async function readLyricsFile(file: File): Promise<{ text: string; lineCount: number } | { error: string }> {
  if (file.size > MAX_LYRICS_BYTES) {
    return { error: `歌词文件过大，已跳过：${file.name}` };
  }
  let text = '';
  try {
    // File.text() 按 UTF-8 解码；GBK 歌词会解出乱码，在「无时间轴」这一步被拦下
    text = await file.text();
  } catch (error) {
    console.error('[lyrics-file] 读取失败：', file.name, error);
    return { error: `读取歌词失败：${file.name}` };
  }
  const parsed = parseLRC(text);
  if (parsed.lines.length === 0) {
    return { error: `「${file.name}」里没有可识别的时间轴歌词，已跳过` };
  }
  return { text, lineCount: parsed.lines.length };
}
