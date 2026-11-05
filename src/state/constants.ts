/**
 * constants.ts —— 与 vanilla 版同值的界面常量
 *
 * 单独抽出来是为了让组件层不必各自造轮子：快捷键步长、空态文案这些一旦分叉，
 * 两个版本的行为就会悄悄不一样。
 *
 * 键名与 vanilla 版**保持一致**：localStorage / IndexedDB 都按 origin 隔离，
 * dev server 在 :5173、vanilla 在 :8000，天然互不干扰；而 lyrics-source /
 * cover-source 里的缓存键也一样，万一以后同源部署还能直接共用已匹配的歌词与封面。
 */

export const STORAGE_KEYS = Object.freeze({
  playlist: 'playlist',
  currentId: 'currentId',
  mode: 'mode',
  volume: 'volume',
  muted: 'muted',
  /** 完整播放顺序（含本地曲目的 id），用于跨会话还原歌单顺序 */
  order: 'order',
  /** 歌词页右上角选中的波形样式 id */
  waveStyle: 'waveStyle',
  /** 波形是否带彩色；关掉只留歌词高亮色的亮度层次 */
  waveColored: 'waveColored',
  /** 歌词高亮色（空字符串 = 跟随主题默认） */
  lyricColor: 'lyricColor',
  /** 主题：mint（薄荷深色）/ light（白色） */
  /** 明暗模式：system / light / dark */
  themeMode: 'themeMode',
  /** 主题色：mint / pink / blue */
  themeColor: 'themeColor',
  /** 老版本的单值主题键，只用于迁移读取 */
  theme: 'theme',
});

/** 方向键快进/快退步长（秒）。 */
export const SEEK_STEP = 5;

/** 方向键调节音量步长（0~1）。 */
export const VOLUME_STEP = 0.05;

/** 「上一首」在已播放超过这个秒数时变为回到本曲开头。 */
export const PREV_RESTART_AFTER = 3;

/** 预读本地文件时长的超时（毫秒）。 */
export const DURATION_PROBE_TIMEOUT = 3000;

/** 空态文案。 */
export const IDLE_TITLE = '未选择曲目';
export const IDLE_ARTIST = '从播放列表选一首开始';
export const APP_TITLE = '流光音乐 · Light Music Player';

/** 允许导入的音频扩展名。 */
export const AUDIO_EXTENSIONS = new Set([
  'mp3', 'wav', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'flac', 'webm', 'weba', 'mp4',
]);

/** 歌词文件扩展名（只认 .lrc，避免普通 txt 被误当歌词）。 */
export const LYRICS_EXTENSIONS = new Set(['lrc']);
