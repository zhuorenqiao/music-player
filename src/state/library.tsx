/**
 * library.tsx —— 导入：文件校验 → 入列 → 读内嵌标签 → 探时长 → 写 IndexedDB → 预取封面
 *
 * 顺序是刻意排的：**先读标签再联网**。文件名既可能是「歌手 - 歌名」也可能是
 * 「歌名 - 歌手」，拆反了之后歌词与封面全都匹配不上。标签解析本身抽到 tagging.ts，
 * 因为启动还原老库时还要跑同一份逻辑。
 */

import { useCallback } from 'react';
import { splitArtistTitle } from '../lib/lyrics-source.js';
import { saveMany as saveLocalTracks, patchTrack as patchLocalRecord } from '../lib/local-store.js';
import { DEFAULT_COVER } from '../lib/demo-data.js';
import { AUDIO_EXTENSIONS, LYRICS_EXTENSIONS } from './constants';
import type { Track } from './types';
import { usePlayer } from './player';
import { useToast } from './toast';
import { applyAudioTags } from './tagging';
import { prefetchCovers } from './covers';
import { prefetchLyrics } from './lyrics-prefetch';
import { probeTrackDuration } from './duration';
import { matchLyricsTrack, readLyricsFile } from './lyrics-file';

const getExtension = (name: string): string => {
  const value = String(name ?? '');
  const dot = value.lastIndexOf('.');
  return dot > 0 ? value.slice(dot + 1).toLowerCase() : '';
};

const stripExtension = (name: string): string => {
  const value = String(name ?? '');
  const dot = value.lastIndexOf('.');
  return dot > 0 ? value.slice(0, dot) : value;
};

function createId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return `local-${crypto.randomUUID()}`;
  }
  return `local-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** 按 MIME 与扩展名白名单预校验文件是否可能是音频。 */
function isSupportedAudioFile(file: File): boolean {
  if (!file) {
    return false;
  }
  const type = String(file.type ?? '').toLowerCase();
  if (type.startsWith('audio/')) {
    return true;
  }
  return AUDIO_EXTENSIONS.has(getExtension(file.name));
}

export function useLibrary() {
  const { playlist, refresh, persist, player } = usePlayer();
  const { show } = useToast();

  /** 探时长（公共实现，见 state/duration.ts：填上后会自己写回 IndexedDB）。 */
  const probeDuration = probeTrackDuration;

  /**
   * 挂用户提供的 .lrc。
   *
   * 手动歌词优先级最高：挂上后 `lyricsSource = 'manual'`，
   * 自动匹配那条路会显式跳过它（见 state/lyrics.tsx）。
   * 文件名匹配不到曲目时一律拒绝（不再兜底挂到当前曲目）——
   * 名字对不上的歌词很可能属于另一首歌，覆盖上去比不挂更糟。
   */
  const applyLyricsFiles = useCallback(async (files: File[]) => {
    const live = () => playlist.tracks as Track[];
    let unmatched = 0;

    for (const file of files) {
      const result = await readLyricsFile(file);
      if ('error' in result) {
        show(result.error, 'error', 6000);
        continue;
      }
      const current = playlist.current as Track | null;
      const target = matchLyricsTrack(file.name, live());

      if (!target) {
        unmatched += 1;
        if (unmatched <= 2) {
          show(`未找到与「${file.name}」同名的曲目，已拒绝替换`, 'info', 6000);
        }
        continue;
      }

      target.lyrics = result.text;
      target.lyricsPlain = '';
      target.lyricsSource = 'manual';
      void patchLocalRecord(target.id, { lyrics: result.text, lyricsPlain: '', lyricsSource: 'manual' });
      refresh();
      persist();
      show(
        target.id === current?.id
          ? `已为「${target.title}」加载 ${result.lineCount} 行歌词`
          : `已为「${target.title}」配好 ${result.lineCount} 行歌词，切到这首即可查看`,
        'info',
        6000,
      );
    }

    if (unmatched > 2) {
      show(`另有 ${unmatched - 2} 个歌词文件没有找到对应曲目`, 'info', 6000);
    }
  }, [persist, playlist, refresh, show]);

  /** 导入一批文件：音频进列表，.lrc 挂歌词。 */
  const importFiles = useCallback(async (input: FileList | File[]) => {
    const files = Array.from(input);
    if (files.length === 0) {
      return;
    }
    const lyricsFiles = files.filter((file) => LYRICS_EXTENSIONS.has(getExtension(file.name)));
    const mediaFiles = files.filter((file) => !LYRICS_EXTENSIONS.has(getExtension(file.name)));
    const accepted = mediaFiles.filter(isSupportedAudioFile);
    const rejected = mediaFiles.filter((file) => !isSupportedAudioFile(file));
    if (rejected.length > 0) {
      show(`已跳过 ${rejected.length} 个不支持的文件`, 'error', 5000);
    }
    // 只拖了歌词文件：直接挂歌词，不该被当成「没有可导入的文件」
    if (accepted.length === 0) {
      if (lyricsFiles.length > 0) {
        void applyLyricsFiles(lyricsFiles);
      }
      return;
    }

    const blobById = new Map<string, Blob>();
    const created = accepted.map((file) => {
      const rawName = stripExtension(file.name) || '未命名音频';
      const parsed = splitArtistTitle(rawName);
      const id = createId();
      blobById.set(id, file);
      return {
        id,
        title: parsed ? parsed.title : rawName,
        artist: parsed ? parsed.artist : '本地文件',
        album: '',
        cover: DEFAULT_COVER,
        src: URL.createObjectURL(file),
        duration: Number.NaN,
        isLocal: true,
      } satisfies Track;
    });

    const { added, firstIndex, loadedFirst } = playlist.addMany(created);
    if (added === 0) {
      created.forEach((track) => URL.revokeObjectURL(track.src));
      return;
    }
    refresh();
    persist();

    const addedTracks = (playlist.tracks as Track[]).slice(firstIndex, firstIndex + added);
    addedTracks.forEach(probeDuration);
    void saveLocalTracks(
      addedTracks.map((track) => ({ track, file: blobById.get(track.id) as unknown as File })),
    );

    if (loadedFirst) {
      playlist.setCurrentIndex(firstIndex);
      player.load(addedTracks[0], { autoplay: true });
      refresh();
      persist();
    }

    // 标签 → 封面 → 歌词：先纠正歌手 / 曲名，再拿纠正后的词去联网匹配。
    // .lrc 放在音频入列并纠正名字**之后**再挂，否则同名歌词配不到刚加进来的曲目上。
    void (async () => {
      try {
        const renamed = await applyAudioTags(addedTracks, blobById, playlist.tracks as Track[]);
        if (renamed.length > 0) {
          refresh();
          persist();
        }
        if (lyricsFiles.length > 0) {
          await applyLyricsFiles(lyricsFiles);
        }
        await prefetchCovers(addedTracks);
        await prefetchLyrics(addedTracks, (playlist.current as Track | null)?.id ?? null);
        refresh();
      } catch (error) {
        console.error('[library] 标签解析出错，按文件名继续：', error);
      }
    })();

    show(`已添加 ${added} 首本地音频`, 'info');
  }, [applyLyricsFiles, persist, player, playlist, probeDuration, refresh, show]);

  return { importFiles };
}
