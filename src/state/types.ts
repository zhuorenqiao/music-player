/**
 * types.ts —— 跨模块共用的类型
 *
 * src/lib/ 下那些模块是从 vanilla 版原样搬来的 .js（tsconfig 开了 allowJs、
 * 没开 checkJs），它们只带 JSDoc 注释。这里把 React 层真正关心的字段声明出来，
 * 好处是组件侧有类型约束，同时不必为了编译通过去改动已经验证过的解析代码。
 */

/** 一首曲目。`isLocal` 为真表示来自用户导入，音频体存在 IndexedDB 里。 */
export interface Track {
  id: string;
  title: string;
  artist: string;
  album: string;
  /** 已拿到的真封面地址（内嵌图 / iTunes / 歌手写真）；空或默认图表示还需要匹配 */
  cover: string;
  src: string;
  /** 秒；NaN 表示尚未探到 */
  duration: number;
  isLocal: boolean;
  /** 带时间轴的 LRC 文本 */
  lyrics?: string;
  /** 无时间轴的纯文本歌词 */
  lyricsPlain?: string;
  /** auto = 联网匹配；manual = 用户导入的 .lrc */
  lyricsSource?: string;
  /** 从 IndexedDB 还原出来的标记 */
  restored?: boolean;
}

/** 最近播放的一条记录。 */
export interface RecentEntry {
  id: string;
  title: string;
  artist: string;
  cover: string;
  duration: number | null;
  at: number;
}

/** 播放模式（与 lib/playlist.js 的 PLAY_MODES 对齐）。 */
export type PlayMode = 'list' | 'one' | 'shuffle';

/** 歌词状态行的四种态。 */
export type LyricsState = 'idle' | 'loading' | 'ready' | 'missing' | 'error';

/** 轻提示类型。 */
export type ToastKind = 'info' | 'success' | 'error';

export interface ToastItem {
  id: number;
  message: string;
  kind: ToastKind;
  duration: number;
}
