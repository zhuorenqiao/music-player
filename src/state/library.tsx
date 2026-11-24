/**
 * library.tsx —— 导入：文件校验 → 入列 → 读内嵌标签 → 探时长 → 写 IndexedDB → 预取封面
 *
 * 顺序是刻意排的：**先读标签再联网**。文件名既可能是「歌手 - 歌名」也可能是
 * 「歌名 - 歌手」，拆反了之后歌词与封面全都匹配不上。标签解析本身抽到 tagging.ts，
 * 因为启动还原老库时还要跑同一份逻辑。
 */

import { useCallback, useEffect, useRef } from 'react';
import { splitArtistTitle } from '../lib/lyrics-source.js';
import { saveMany as saveLocalTracks, patchTrack as patchLocalRecord } from '../lib/local-store.js';
import { createLimiter } from '../lib/async-limit.js';
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

/**
 * 时长探针的同时并发上限。
 *
 * 一次导入 2000 首时，原实现会为每首歌立刻 `new Audio()` 并加载 metadata：
 * 2000 个媒体元素同时抢解码线程，轻则整页卡住，重则渲染进程被系统回收。
 * 3 条并发仍能让列表在几秒内陆续出现真实时长，峰值媒体资源却只有 3 个。
 */
const durationProbeGate = createLimiter(3);

export function useLibrary() {
  const { playlist, refresh, persist, player } = usePlayer();
  const { show } = useToast();

  /** 探时长（公共实现，见 state/duration.ts：填上后会自己写回 IndexedDB）。 */
  const probeDuration = probeTrackDuration;

  /**
   * 单首时长探完后的合并刷新。
   *
   * 一次导入几十首时，`loadedmetadata` 可能在一两百毫秒内连爆一串；每首直接
   * `refresh()` 会让整棵播放树跟着重建。这里按 200ms 窗口合并一次，既能让
   * 列表在第一首落地后马上从「-:--」变成真实时长，又不至于连刷几十帧。
   */
  const durationNotifyRef = useRef<number | null>(null);
  const scheduleDurationRefresh = useCallback(() => {
    if (durationNotifyRef.current !== null) return;
    durationNotifyRef.current = window.setTimeout(() => {
      durationNotifyRef.current = null;
      refresh();
    }, 200);
  }, [refresh]);
  useEffect(
    () => () => {
      if (durationNotifyRef.current !== null) {
        window.clearTimeout(durationNotifyRef.current);
        durationNotifyRef.current = null;
      }
    },
    [],
  );

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
      // 手动歌词没有线上来源：清掉上次自动匹配留下的来源 id，
      // 否则状态行会先显示「已使用手动指定的歌词」，重开后又变成别的来源。
      target.lyricsOrigin = '';
      void patchLocalRecord(target.id, {
        lyrics: result.text,
        lyricsPlain: '',
        lyricsSource: 'manual',
        lyricsOrigin: '',
      });
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

  /**
   * 导入一批已经通过校验的音频；文件多选与文件夹导入共用这一条链路。
   * @returns 实际入列的首数
   */
  const importSelection = useCallback(async (
    accepted: File[],
    lyricsFiles: File[],
    options: { toastMessage?: (added: number) => string } = {},
  ): Promise<number> => {
    // 只拖了歌词文件：直接挂歌词，不该被当成「没有可导入的文件」
    if (accepted.length === 0) {
      if (lyricsFiles.length > 0) {
        void applyLyricsFiles(lyricsFiles);
      }
      return 0;
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
      return 0;
    }
    refresh();
    persist();

    const addedTracks = (playlist.tracks as Track[]).slice(firstIndex, firstIndex + added);
    // 时长探针有 3 秒上限；把 Promise 留着，歌词预取要等它收敛，但不让导入返回等它。
    // 闸门是模块级的：连续导入两批时，探针总数也不会叠加成 2× 并发。
    const durationProbes = addedTracks.map((track) =>
      durationProbeGate(() => probeDuration(track, scheduleDurationRefresh)),
    );
    void saveLocalTracks(
      addedTracks.map((track) => ({ track, file: blobById.get(track.id) as unknown as File })),
    );

    if (loadedFirst) {
      playlist.setCurrentIndex(firstIndex);
      player.load(addedTracks[0], { autoplay: true });
      refresh();
      persist();
    }

    // 标签 → 封面 ∥ 歌词：先纠正歌手 / 曲名，再拿纠正后的词去联网匹配。
    // 封面不依赖时长，标签一读完就开跑；歌词等时长探针收敛（带时长查得准），
    // 两者**并行**，别让 50 首的封面把歌词队列堵在后面。
    // .lrc 放在音频入列并纠正名字**之后**再挂，否则同名歌词配不到刚加进来的曲目上。
    void (async () => {
      try {
        const renamed = await applyAudioTags(addedTracks, blobById, playlist.tracks as Track[]);
        if (renamed.length > 0) {
          refresh();
          persist();
        }
        const coversDone = prefetchCovers(addedTracks);
        if (lyricsFiles.length > 0) {
          await applyLyricsFiles(lyricsFiles);
        }
        // 探针失败（超时 / 坏文件）也照样查：宁可少一个时长参考，也别整批跳过。
        await Promise.allSettled(durationProbes);
        const lyricsDone = prefetchLyrics(addedTracks, (playlist.current as Track | null)?.id ?? null, {
          allowMissingDuration: true,
        });
        await Promise.all([coversDone, lyricsDone]);
        refresh();
      } catch (error) {
        console.error('[library] 标签解析出错，按文件名继续：', error);
      }
    })();

    show(options.toastMessage?.(added) ?? `已添加 ${added} 首本地音频`, 'info');
    return added;
  }, [
    applyLyricsFiles,
    persist,
    player,
    playlist,
    probeDuration,
    refresh,
    scheduleDurationRefresh,
    show,
  ]);

  /** 导入一批文件：音频进列表，.lrc 挂歌词。 */
  const importFiles = useCallback(async (input: FileList | File[]): Promise<number> => {
    const files = Array.from(input);
    if (files.length === 0) {
      return 0;
    }
    const lyricsFiles = files.filter((file) => LYRICS_EXTENSIONS.has(getExtension(file.name)));
    const mediaFiles = files.filter((file) => !LYRICS_EXTENSIONS.has(getExtension(file.name)));
    const accepted = mediaFiles.filter(isSupportedAudioFile);
    const rejected = mediaFiles.filter((file) => !isSupportedAudioFile(file));
    if (rejected.length > 0) {
      show(`已跳过 ${rejected.length} 个不支持的文件`, 'error', 5000);
    }
    return importSelection(accepted, lyricsFiles);
  }, [importSelection, show]);

  return { importFiles };
}
