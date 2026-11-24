/**
 * lib/sleep.ts —— 休眠模块的目录：模型 + 分类 + 文案 + 视觉种子
 *
 * 与 Flutter `lib/sleep/sleep_track.dart` **逐条同源**（id / 曲名 / 副标题 /
 * 分类 / 生成配方 / 卡片配色一一对应），改一处必须改另一处 —— 两端要像素级
 * 对齐，目录各写一份的话，页签计数与顺序迟早对不上。
 *
 * 曲目不是外部版权音频：每一条都是**程序化生成的助眠声景**（雨、潮、风、
 * 溪涧、鸟鸣、篝火、虫鸣、摇篮、音乐盒、夜曲、白噪、飞瀑），32 秒无缝循环，
 * 不依赖网络、不随包携带音频文件。
 * 生成器在 `sleep-audio.ts`（React）与 `sleep/sleep_audio.dart`（Flutter）。
 */

export type SleepCategory = 'scape' | 'lullaby' | 'noise';

/** 生成配方：同一份配方两端各实现一遍，听感一致。 */
export type SleepRecipe =
  | 'rain'
  | 'ocean'
  | 'wind'
  | 'stream'
  | 'birds'
  | 'campfire'
  | 'crickets'
  | 'lullaby'
  | 'musicbox'
  | 'nocturne'
  | 'noise'
  | 'waterfall';

export interface SleepTrack {
  /** 稳定 id（React key / 播放态判定 / 音频缓存都靠它） */
  id: string;
  name: string;
  /** 副标题：声音质地 + 场景 */
  detail: string;
  category: SleepCategory;
  recipe: SleepRecipe;
  /** 视觉种子 0~1：缩略图与卡面微光按它错开 */
  seed: number;
  /** 缩略图渐变两端（固定色，夜色不随主题翻） */
  artFrom: string;
  artTo: string;
  /** 卡面右上微光与缩略图高光（rgb 分量，供 rgb(...) 使用） */
  glowRgb: string;
}

export interface SleepTab {
  id: SleepCategory;
  /** 页签上的短名 */
  label: string;
  /** 播放卡顶部那行小字 */
  section: string;
  /** 卡片右上角英文角标 */
  en: string;
}

/** 循环长度（秒）：两端生成器必须同值，otherwise 听感/时长文案会不一致。 */
export const SLEEP_LOOP_SECONDS = 32;

/** 采样率：22050 单声道 16bit —— 助眠声景不需要 44.1k，文件小一半。 */
export const SLEEP_SAMPLE_RATE = 22050;

export const SLEEP_TABS: SleepTab[] = [
  { id: 'scape', label: '声景', section: '环境声 · 声景', en: 'SOUNDSCAPE' },
  { id: 'lullaby', label: '摇篮', section: '轻音乐 · 摇篮', en: 'LULLABY' },
  { id: 'noise', label: '白噪', section: '低声压 · 白噪', en: 'NOISE' },
];

export const SLEEP_TRACKS: SleepTrack[] = [
  {
    id: 'sleep-rain',
    name: '夜雨 · 屋檐',
    detail: '雨声 · 窗外 · 32 秒循环',
    category: 'scape',
    recipe: 'rain',
    seed: 0.14,
    artFrom: '#16233D',
    artTo: '#0A0F1D',
    glowRgb: '108 155 232',
  },
  {
    id: 'sleep-ocean',
    name: '潮汐 · 退岸',
    detail: '海浪 · 低频 · 32 秒循环',
    category: 'scape',
    recipe: 'ocean',
    seed: 0.38,
    artFrom: '#103044',
    artTo: '#07121C',
    glowRgb: '85 194 207',
  },
  {
    id: 'sleep-wind',
    name: '林风 · 晚径',
    detail: '风声 · 林间 · 32 秒循环',
    category: 'scape',
    recipe: 'wind',
    seed: 0.62,
    artFrom: '#182C33',
    artTo: '#0A151A',
    glowRgb: '140 199 180',
  },
  {
    id: 'sleep-lullaby',
    name: '月光摇篮',
    detail: '柔钢琴 · 摇篮 · 32 秒循环',
    category: 'lullaby',
    recipe: 'lullaby',
    seed: 0.22,
    artFrom: '#241F3D',
    artTo: '#0E0B1B',
    glowRgb: '198 180 255',
  },
  {
    id: 'sleep-musicbox',
    name: '星子入梦',
    detail: '音乐盒 · 星夜 · 32 秒循环',
    category: 'lullaby',
    recipe: 'musicbox',
    seed: 0.47,
    artFrom: '#2A2234',
    artTo: '#120D19',
    glowRgb: '255 211 155',
  },
  {
    id: 'sleep-noise',
    name: '深夜白噪',
    detail: '低频噪声 · 安睡 · 32 秒循环',
    category: 'noise',
    recipe: 'noise',
    seed: 0.71,
    artFrom: '#221F1C',
    artTo: '#0E0C0B',
    glowRgb: '200 169 143',
  },
  {
    id: 'sleep-stream',
    name: '溪涧 · 石上',
    detail: '流水 · 山涧 · 32 秒循环',
    category: 'scape',
    recipe: 'stream',
    seed: 0.26,
    artFrom: '#123039',
    artTo: '#08161C',
    glowRgb: '95 198 190',
  },
  {
    id: 'sleep-birds',
    name: '晨林 · 鸟鸣',
    detail: '鸟叫 · 林梢 · 32 秒循环',
    category: 'scape',
    recipe: 'birds',
    seed: 0.55,
    artFrom: '#1B3327',
    artTo: '#0A1710',
    glowRgb: '150 214 160',
  },
  {
    id: 'sleep-campfire',
    name: '篝火 · 木屋',
    detail: '柴火 · 噼啪 · 32 秒循环',
    category: 'scape',
    recipe: 'campfire',
    seed: 0.83,
    artFrom: '#33241A',
    artTo: '#160E0A',
    glowRgb: '255 172 96',
  },
  {
    id: 'sleep-crickets',
    name: '虫鸣 · 夏夜',
    detail: '蟋蟀 · 草间 · 32 秒循环',
    category: 'scape',
    recipe: 'crickets',
    seed: 0.09,
    artFrom: '#1D2A2E',
    artTo: '#0B1214',
    glowRgb: '176 208 138',
  },
  {
    id: 'sleep-nocturne',
    name: '夜曲 · 低回',
    detail: '柔弦乐 · 夜曲 · 32 秒循环',
    category: 'lullaby',
    recipe: 'nocturne',
    seed: 0.66,
    artFrom: '#232038',
    artTo: '#0D0C18',
    glowRgb: '186 190 255',
  },
  {
    id: 'sleep-waterfall',
    name: '飞瀑 · 白噪',
    detail: '瀑布 · 宽带 · 32 秒循环',
    category: 'noise',
    recipe: 'waterfall',
    seed: 0.34,
    artFrom: '#1B2626',
    artTo: '#0B1212',
    glowRgb: '190 220 210',
  },
];

export const SLEEP_FIRST_TRACK = SLEEP_TRACKS[0];

/** 分类 → 页签元数据。 */
export function sleepTabOf(category: SleepCategory): SleepTab {
  return SLEEP_TABS.find((tab) => tab.id === category) ?? SLEEP_TABS[0];
}

/** 该分类下的曲目（顺序与目录一致）。 */
export function sleepTracksOf(category: SleepCategory): SleepTrack[] {
  return SLEEP_TRACKS.filter((track) => track.category === category);
}

/**
 * 问候语：按本地时间分档。与 Flutter `sleepGreeting` 的阈值逐条一致
 * （两端同一时刻必须显示同一句）。
 */
export function sleepGreeting(hour: number = new Date().getHours()): string {
  if (hour >= 5 && hour < 11) return '早安，也可以再歇一会儿';
  if (hour >= 11 && hour < 13) return '午间，闭上眼睛歇一会儿';
  if (hour >= 13 && hour < 18) return '午后，把节奏慢下来';
  if (hour >= 18 && hour < 23) return '夜色慢慢落下来了';
  return '夜深了，该睡了';
}
