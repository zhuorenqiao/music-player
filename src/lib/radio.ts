/**
 * lib/radio.ts —— 电台目录：模型 + 分组 + 精选台表
 *
 * 与 Flutter `lib/radio/radio_station.dart` **逐条同源**（id / 台名 / 频率 / 城市 /
 * 分类 / 流地址 / 视觉种子一一对应），改一处必须改另一处 —— 两端 UI 要像素级一致，
 * 目录要是各写一份，分组计数与顺序迟早对不上。
 *
 * 选台口径（2026-11-20 落地）：
 *   * 只收直连音频流（http(s) 的 mp3 / aac），不收 m3u8 —— Chrome 桌面原生不支持
 *     HLS，双端共用一套地址才能保证「点一下就出声」；
 *   * 每条地址都实测过 200 + `audio/mpeg`；
 *   * 分类按三个抽屉走：传统 FM 分「音乐台 / 交通台」，其余归「网络电台 / 播客」。
 */

export type RadioCategory = 'music' | 'traffic' | 'net';

export interface RadioStation {
  /** 稳定 id（React key / 播放态判定都靠它） */
  id: string;
  name: string;
  /** 频率 / 频道号；网络台没有频率时为空串 */
  freq: string;
  /** 城市，或内容类型（如「故事 · 播客」） */
  city: string;
  /** 角标：FM / 网络台 / 播客 */
  kind: string;
  category: RadioCategory;
  /** 直播流地址（mp3 / aac 直连） */
  streamUrl: string;
  /** 视觉种子 0~1：同分类的卡面靠它错开环心与波段相位 */
  seed: number;
}

/** 一个分类页签：短名（页签上）、长名（播放卡里写「所属分类」）、英文角标。 */
export interface RadioTab {
  id: RadioCategory;
  /** 页签上的短名：音乐台 / 交通台 / 网络电台 */
  label: string;
  /** 播放卡里那行小字：传统 FM · 音乐台 */
  section: string;
  /** 卡片右上角的英文角标：MUSIC / TRAFFIC / PODCAST */
  en: string;
}

export const RADIO_TABS: RadioTab[] = [
  { id: 'music', label: '音乐台', section: '传统 FM · 音乐台', en: 'MUSIC' },
  { id: 'traffic', label: '交通台', section: '传统 FM · 交通台', en: 'TRAFFIC' },
  { id: 'net', label: '网络电台', section: '网络电台 / 播客', en: 'PODCAST' },
];

/** 分类 → 页签元数据（播放卡写「所属分类」时用）。 */
export function radioTabOf(category: RadioCategory): RadioTab {
  return RADIO_TABS.find((tab) => tab.id === category) ?? RADIO_TABS[0];
}

/** 该分类下的台表（页签切换时用，顺序与目录一致）。 */
export function radioStationsOf(category: RadioCategory): RadioStation[] {
  return RADIO_STATIONS.filter((station) => station.category === category);
}

/**
 * 问候语：按本地时间分档。与 Flutter `radioGreeting` 的阈值逐条一致
 * （两端同一时刻必须显示同一句，否则并排一比就露馅）。
 */
export function radioGreeting(hour: number = new Date().getHours()): string {
  if (hour >= 5 && hour < 11) return '早上好';
  if (hour >= 11 && hour < 13) return '中午好';
  if (hour >= 13 && hour < 18) return '下午好';
  if (hour >= 18 && hour < 23) return '晚上好';
  return '夜深了';
}

/** 副标题：有频率时「FM97.4 · 北京」，没有时只写城市。 */
export function radioDetail(station: RadioStation): string {
  return station.freq ? `${station.freq} · ${station.city}` : station.city;
}

/** 精选台表。顺序即界面顺序。 */
export const RADIO_STATIONS: RadioStation[] = [
  // ---- 传统 FM · 音乐台 ----
  { id: 'fm-beijing-music', name: '北京音乐广播', freq: 'FM97.4', city: '北京', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/332/64k.mp3', seed: 0.12 },
  { id: 'fm-shanghai-101', name: '上海动感101', freq: 'FM101.7', city: '上海', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qingting.fm/live/274/64k.mp3', seed: 0.28 },
  { id: 'fm-guangdong-music', name: '广东音乐之声', freq: 'FM99.3', city: '广州', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/1260/64k.mp3', seed: 0.44 },
  { id: 'fm-shanghai-1037', name: '上海经典金曲', freq: 'FM103.7', city: '上海', kind: 'FM', category: 'music', streamUrl: 'https://lhttp-hw.qtfm.cn/live/273/64k.mp3', seed: 0.6 },
  { id: 'fm-jiangsu-classic', name: '江苏经典流行音乐', freq: '', city: '南京', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/4938/64k.mp3', seed: 0.76 },
  { id: 'fm-sichuan-music', name: '四川音乐广播', freq: '', city: '成都', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/1110/64k.mp3', seed: 0.2 },
  { id: 'fm-changsha-music', name: '长沙音乐广播', freq: 'FM88.6', city: '长沙', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/20847/64k.mp3', seed: 0.52 },
  { id: 'fm-jinan-music', name: '济南音乐广播', freq: '', city: '济南', kind: 'FM', category: 'music', streamUrl: 'https://lhttp.qtfm.cn/live/1671/64k.mp3', seed: 0.88 },

  // ---- 传统 FM · 交通台 ----
  { id: 'fm-beijing-traffic', name: '北京交通广播', freq: 'FM103.9', city: '北京', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qingting.fm/live/336/64k.mp3', seed: 0.16 },
  { id: 'fm-guangdong-traffic', name: '广东交通之声', freq: '', city: '广州', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qtfm.cn/live/1262/64k.mp3', seed: 0.32 },
  { id: 'fm-shenzhen-traffic', name: '深圳交通广播', freq: '', city: '深圳', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qingting.fm/live/1272/64k.mp3', seed: 0.48 },
  { id: 'fm-shaanxi-traffic', name: '陕西交通广播', freq: '', city: '西安', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qtfm.cn/live/1601/64k.mp3', seed: 0.64 },
  { id: 'fm-hangzhou-traffic', name: '杭州交通经济广播', freq: '', city: '杭州', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qtfm.cn/live/1133/64k.mp3', seed: 0.8 },
  { id: 'fm-sichuan-traffic', name: '四川交通广播', freq: '', city: '成都', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qtfm.cn/live/4886/64k.mp3', seed: 0.24 },
  { id: 'fm-guangxi-traffic', name: '广西交通广播', freq: '', city: '南宁', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp-hw.qtfm.cn/live/1758/64k.mp3', seed: 0.4 },
  { id: 'fm-anhui-traffic', name: '安徽交通广播', freq: '', city: '合肥', kind: 'FM', category: 'traffic', streamUrl: 'https://lhttp.qtfm.cn/live/1949/64k.mp3', seed: 0.72 },

  // ---- 网络电台 / 播客 ----
  { id: 'net-story-ajmide', name: '阿基米德故事会', freq: '', city: '故事 · 播客', kind: '播客', category: 'net', streamUrl: 'https://lhttp.qtfm.cn/live/20500182/64k.mp3', seed: 0.08 },
  { id: 'net-xiangsheng', name: '听云相声台', freq: '', city: '相声 · 播客', kind: '播客', category: 'net', streamUrl: 'https://m.tyradio.uk/tyxs.mp3', seed: 0.36 },
  { id: 'net-star', name: '星空电台', freq: '', city: '流行 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp-hw.qtfm.cn/live/5022379/64k.mp3', seed: 0.56 },
  { id: 'net-classical', name: '50首经典古典音乐', freq: '', city: '古典 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp-hw.qtfm.cn/live/5022308/64k.mp3', seed: 0.68 },
  { id: 'net-asiafm', name: 'AsiaFM 亚洲音乐台', freq: '', city: '音乐 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp.qingting.fm/live/4581/64k.mp3', seed: 0.84 },
  { id: 'net-liangguang', name: '两广之声音乐台', freq: '', city: '怀旧 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp.qtfm.cn/live/20500149/64k.mp3', seed: 0.14 },
  { id: 'net-intl-news', name: '国际新闻', freq: '', city: '资讯 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp.qtfm.cn/live/20500172/64k.mp3', seed: 0.46 },
  { id: 'net-yueju', name: '听 · 越剧', freq: '', city: '戏曲 · 网络台', kind: '网络台', category: 'net', streamUrl: 'https://lhttp.qtfm.cn/live/20500178/64k.mp3', seed: 0.92 },
];

export function radioStationById(id: string): RadioStation | undefined {
  return RADIO_STATIONS.find((station) => station.id === id);
}

/** 分类色相偏移：三类电台在 token 之外只差一点点混色比例，不引入表外颜色。 */
export function radioTintBias(category: RadioCategory): number {
  switch (category) {
    case 'traffic':
      return 0.17;
    case 'net':
      return 0.34;
    default:
      return 0;
  }
}

/**
 * 卡面渐变两端（0~1）：起点偏 accent，终点回落到 panelB。
 *
 * seed 的跨度拉得比较开（0.40~0.72）：42px 的小圆碟上，混色比例只差 5% 时
 * 八台看起来会是同一个绿点；拉开之后每台各有深浅，才像「不同的台」。
 */
export function radioArtMix(station: RadioStation): [number, number] {
  const bias = radioTintBias(station.category);
  return [
    Math.min(1, 0.4 + bias * 0.5 + station.seed * 0.3),
    Math.max(0, 0.04 + bias * 0.25 + station.seed * 0.1),
  ];
}

/**
 * 卡面渐变的收尾色：与 `radioArtMix()` 的终点同源，只是换成 CSS 能算的写法。
 *
 * 大播放卡的压底层（`.radio-hero__veil`）必须落在这支色上，不能落回页面底色
 * `--bg`：浅色主题里 `--bg` 是冷调灰蓝（#dfe8f2），压在暖色卡面上会在下半张卡
 * 里拐出一道灰带（粉 → 灰 → 冷白），渐变的三段就成了两截。
 * 收尾色自带 accent 的色相，压底层与台面渐变从顶到底走同一支色 —— 只加深、不换调。
 */
export function radioArtEndColor(station: RadioStation): string {
  const [, end] = radioArtMix(station);
  return `color-mix(in srgb, var(--accent) ${Math.round(end * 100)}%, var(--panel-b))`;
}
