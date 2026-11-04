/**
 * tagging.ts —— 「读内嵌标签并回填曲目」的公共实现
 *
 * 抽出来是因为有**两个**入口都要跑它，逻辑必须完全一致：
 *   1. 导入时（library.tsx）—— 刚创建的曲目；
 *   2. 启动还原时（player.tsx）—— 早于标签功能导入、库里存着旧值的老曲目。
 * 少了第 2 条，老库会永远显示文件名拆出来的（可能反着的）歌手与曲名，
 * 也不会去补内嵌封面 —— vanilla 版两条都跑，这里对齐。
 */

import { readAudioTags, mergeTaggedNames } from '../lib/audio-tags.js';
import { patchTrack as patchLocalRecord } from '../lib/local-store.js';
import { DEFAULT_COVER } from '../lib/demo-data.js';
import type { Track } from './types';

/** 内嵌封面缩放上限（像素）：够 600 见方显示，又不会把 IndexedDB 撑爆。 */
const EMBEDDED_COVER_MAX_SIDE = 600;

/**
 * 内嵌封面 → 缩放后的 JPEG data URL。
 * 用 data URL 而不是 objectURL：它是普通字符串，能直接进 IndexedDB 记录，
 * 刷新后照样显示，不用管 objectURL 的 revoke 生命周期。
 * @param blob 图片字节
 */
export function pictureToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    const finish = (settle: (value: never) => void, value: unknown) => {
      URL.revokeObjectURL(url);
      settle(value as never);
    };
    img.onload = () => {
      try {
        const longest = Math.max(img.naturalWidth, img.naturalHeight) || 1;
        const scale = Math.min(1, EMBEDDED_COVER_MAX_SIDE / longest);
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
        const ctx = canvas.getContext('2d');
        if (!ctx) {
          throw new Error('canvas 2d 上下文不可用');
        }
        // JPEG 没有透明通道，先铺底色，透明 PNG 封面才不会变黑块
        ctx.fillStyle = '#0b0f14';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        finish(resolve, canvas.toDataURL('image/jpeg', 0.82));
      } catch (error) {
        finish(reject, error);
      }
    };
    img.onerror = () => finish(reject, new Error('内嵌封面解码失败'));
    img.src = url;
  });
}

/**
 * 读一批本地文件的内嵌标签，把歌手 / 曲名 / 专辑 / 封面回填到曲目上。
 *
 * 文件名既有「歌手 - 歌名」也有「歌名 - 歌手」两种习惯，只按一种拆就会把
 * 标题和歌手弄反 —— 界面显示错，歌词与封面还永远匹配不上（查询参数是反的）。
 * 标签是文件自带的权威信息，优先用它。
 * @param tracks 待处理的曲目（可以不是列表里的活对象）
 * @param blobById 曲目 id → 音频字节（导入是 File，还原是 IndexedDB 里的 Blob）
 * @param liveTracks 播放列表里的活对象；传了就按 id 找回再改
 * @returns 被改过名字的曲目（调用方据此决定要不要重新联网匹配）
 */
export async function applyAudioTags(
  tracks: Track[],
  blobById: Map<string, Blob>,
  liveTracks?: Track[],
): Promise<Track[]> {
  const renamed: Track[] = [];

  await Promise.all(tracks.map(async (source) => {
    // Playlist.addMany 会克隆对象，直接改传进来的那份可能改到副本上
    const track = liveTracks?.find((item) => item.id === source.id) ?? source;
    const blob = blobById.get(track.id);
    if (!track.isLocal || !blob) {
      return;
    }
    let tags: {
      title?: string; artist?: string; album?: string; albumArtist?: string;
      picture?: { blob: Blob } | null;
    } = {};
    try {
      tags = await readAudioTags(blob as File);
    } catch (error) {
      console.error('[tagging] 读取标签失败：', track.title, error);
      return;
    }

    const merged = mergeTaggedNames(tags, { title: track.title, artist: track.artist });
    const changed = merged.title !== track.title || merged.artist !== track.artist;
    if (merged.title) {
      track.title = merged.title;
    }
    if (merged.artist) {
      track.artist = merged.artist;
    }
    if (tags.album && !track.album) {
      track.album = tags.album;
    }
    if (changed) {
      renamed.push(track);
      void patchLocalRecord(track.id, { title: track.title, artist: track.artist, album: track.album });
    }

    if (tags.picture && (!track.cover || track.cover === DEFAULT_COVER)) {
      try {
        const dataUrl = await pictureToDataUrl(tags.picture.blob);
        track.cover = dataUrl;
        void patchLocalRecord(track.id, { cover: dataUrl });
      } catch (error) {
        console.error('[tagging] 内嵌封面不可用：', track.title, error);
      }
    }
  }));

  return renamed;
}
