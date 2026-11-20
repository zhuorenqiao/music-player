// lib/radio/radio_station.dart
//
// 电台目录：模型 + 分组 + 精选台表。对译 React `src/lib/radio.ts`，两份**逐条同源**
//（id / 台名 / 频率 / 城市 / 分类 / 流地址 / 视觉种子都一一对应），改一处必须改另一处。
//
// 选台口径（2026-11-20 落地）：
//   * 只收**直连音频流**（http(s) 的 mp3 / aac），不收 m3u8 —— 桌面浏览器原生不支持
//     HLS，双端要同一套地址才能保证「点一下就出声」；
//   * 每条流地址都实测过 200 + `audio/mpeg`（见 docs 的验收记录），qtfm 系 CDN
//     （蜻蜓 FM 的公开直播源）是当下最稳的一批；
//   * 分类按用户的三个抽屉来：传统 FM 分「音乐台 / 交通台」，其余归「网络电台 / 播客」。
//
// 这里**不放任何颜色**：电台卡的渐变由 token + seed 现场拼（ui/radio_page.dart），
// 换肤时自动跟着换色 —— 目录只表达「是哪一台」，不表达「长什么样」。
import 'dart:math' as math;

/// 电台分类：决定落在哪个分组、以及卡面渐变的色相偏移。
enum RadioCategory {
  /// 传统 FM · 音乐台
  music,

  /// 传统 FM · 交通台
  traffic,

  /// 网络电台 / 播客
  net,
}

/// 一台电台。
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.freq,
    required this.city,
    required this.kind,
    required this.category,
    required this.streamUrl,
    required this.seed,
  });

  /// 稳定 id（界面 key / 播放态判定都靠它，别跟着台名改）。
  final String id;

  /// 台名（界面上的一行主文案）。
  final String name;

  /// 频率 / 频道号；网络台没有频率时留空串。
  final String freq;

  /// 城市或所属机构；网络台写内容类型（如「故事 · 播客」）。
  final String city;

  /// 类型角标：`FM` / `网络台` / `播客`。
  final String kind;

  final RadioCategory category;

  /// 直播流地址（mp3 / aac 直连）。
  final String streamUrl;

  /// 视觉种子 0~1：同一分类里的卡面靠它错开环心、光晕与波段相位。
  final double seed;

  /// 副标题：有频率时「FM97.4 · 北京」，没有时只写城市。
  String get detail => freq.isEmpty ? city : '$freq · $city';
}

/// 精选台表。**顺序即界面顺序**：越靠前越是常听的头部台。
const List<RadioStation> kRadioStations = <RadioStation>[
  // ---- 传统 FM · 音乐台 ----
  RadioStation(
    id: 'fm-beijing-music',
    name: '北京音乐广播',
    freq: 'FM97.4',
    city: '北京',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/332/64k.mp3',
    seed: 0.12,
  ),
  RadioStation(
    id: 'fm-shanghai-101',
    name: '上海动感101',
    freq: 'FM101.7',
    city: '上海',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qingting.fm/live/274/64k.mp3',
    seed: 0.28,
  ),
  RadioStation(
    id: 'fm-guangdong-music',
    name: '广东音乐之声',
    freq: 'FM99.3',
    city: '广州',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/1260/64k.mp3',
    seed: 0.44,
  ),
  RadioStation(
    id: 'fm-shanghai-1037',
    name: '上海经典金曲',
    freq: 'FM103.7',
    city: '上海',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp-hw.qtfm.cn/live/273/64k.mp3',
    seed: 0.60,
  ),
  RadioStation(
    id: 'fm-jiangsu-classic',
    name: '江苏经典流行音乐',
    freq: '',
    city: '南京',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/4938/64k.mp3',
    seed: 0.76,
  ),
  RadioStation(
    id: 'fm-sichuan-music',
    name: '四川音乐广播',
    freq: '',
    city: '成都',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/1110/64k.mp3',
    seed: 0.20,
  ),
  RadioStation(
    id: 'fm-changsha-music',
    name: '长沙音乐广播',
    freq: 'FM88.6',
    city: '长沙',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/20847/64k.mp3',
    seed: 0.52,
  ),
  RadioStation(
    id: 'fm-jinan-music',
    name: '济南音乐广播',
    freq: '',
    city: '济南',
    kind: 'FM',
    category: RadioCategory.music,
    streamUrl: 'https://lhttp.qtfm.cn/live/1671/64k.mp3',
    seed: 0.88,
  ),

  // ---- 传统 FM · 交通台 ----
  RadioStation(
    id: 'fm-beijing-traffic',
    name: '北京交通广播',
    freq: 'FM103.9',
    city: '北京',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qingting.fm/live/336/64k.mp3',
    seed: 0.16,
  ),
  RadioStation(
    id: 'fm-guangdong-traffic',
    name: '广东交通之声',
    freq: '',
    city: '广州',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qtfm.cn/live/1262/64k.mp3',
    seed: 0.32,
  ),
  RadioStation(
    id: 'fm-shenzhen-traffic',
    name: '深圳交通广播',
    freq: '',
    city: '深圳',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qingting.fm/live/1272/64k.mp3',
    seed: 0.48,
  ),
  RadioStation(
    id: 'fm-shaanxi-traffic',
    name: '陕西交通广播',
    freq: '',
    city: '西安',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qtfm.cn/live/1601/64k.mp3',
    seed: 0.64,
  ),
  RadioStation(
    id: 'fm-hangzhou-traffic',
    name: '杭州交通经济广播',
    freq: '',
    city: '杭州',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qtfm.cn/live/1133/64k.mp3',
    seed: 0.80,
  ),
  RadioStation(
    id: 'fm-sichuan-traffic',
    name: '四川交通广播',
    freq: '',
    city: '成都',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qtfm.cn/live/4886/64k.mp3',
    seed: 0.24,
  ),
  RadioStation(
    id: 'fm-guangxi-traffic',
    name: '广西交通广播',
    freq: '',
    city: '南宁',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp-hw.qtfm.cn/live/1758/64k.mp3',
    seed: 0.40,
  ),
  RadioStation(
    id: 'fm-anhui-traffic',
    name: '安徽交通广播',
    freq: '',
    city: '合肥',
    kind: 'FM',
    category: RadioCategory.traffic,
    streamUrl: 'https://lhttp.qtfm.cn/live/1949/64k.mp3',
    seed: 0.72,
  ),

  // ---- 网络电台 / 播客 ----
  RadioStation(
    id: 'net-story-ajmide',
    name: '阿基米德故事会',
    freq: '',
    city: '故事 · 播客',
    kind: '播客',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp.qtfm.cn/live/20500182/64k.mp3',
    seed: 0.08,
  ),
  RadioStation(
    id: 'net-xiangsheng',
    name: '听云相声台',
    freq: '',
    city: '相声 · 播客',
    kind: '播客',
    category: RadioCategory.net,
    streamUrl: 'https://m.tyradio.uk/tyxs.mp3',
    seed: 0.36,
  ),
  RadioStation(
    id: 'net-star',
    name: '星空电台',
    freq: '',
    city: '流行 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp-hw.qtfm.cn/live/5022379/64k.mp3',
    seed: 0.56,
  ),
  RadioStation(
    id: 'net-classical',
    name: '50首经典古典音乐',
    freq: '',
    city: '古典 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp-hw.qtfm.cn/live/5022308/64k.mp3',
    seed: 0.68,
  ),
  RadioStation(
    id: 'net-asiafm',
    name: 'AsiaFM 亚洲音乐台',
    freq: '',
    city: '音乐 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp.qingting.fm/live/4581/64k.mp3',
    seed: 0.84,
  ),
  RadioStation(
    id: 'net-liangguang',
    name: '两广之声音乐台',
    freq: '',
    city: '怀旧 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp.qtfm.cn/live/20500149/64k.mp3',
    seed: 0.14,
  ),
  RadioStation(
    id: 'net-intl-news',
    name: '国际新闻',
    freq: '',
    city: '资讯 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp.qtfm.cn/live/20500172/64k.mp3',
    seed: 0.46,
  ),
  RadioStation(
    id: 'net-yueju',
    name: '听 · 越剧',
    freq: '',
    city: '戏曲 · 网络台',
    kind: '网络台',
    category: RadioCategory.net,
    streamUrl: 'https://lhttp.qtfm.cn/live/20500178/64k.mp3',
    seed: 0.92,
  ),
];

/// 按 id 找台（播放态持久化只存 id，冷启动读回时要还原成整条记录）。
RadioStation? radioStationById(String id) {
  for (final station in kRadioStations) {
    if (station.id == id) return station;
  }
  return null;
}

/// 一个分类页签：短名（页签上）、长名（播放卡里写「所属分类」）、英文角标。
class RadioTab {
  const RadioTab({
    required this.id,
    required this.label,
    required this.section,
    required this.en,
  });

  final RadioCategory id;

  /// 页签上的短名：音乐台 / 交通台 / 网络电台。
  final String label;

  /// 播放卡里那行小字：传统 FM · 音乐台。
  final String section;

  /// 卡片右上角的英文角标：MUSIC / TRAFFIC / PODCAST。
  final String en;
}

/// 三个页签（顺序即界面顺序）。
List<RadioTab> radioTabs() => const [
  RadioTab(
    id: RadioCategory.music,
    label: '音乐台',
    section: '传统 FM · 音乐台',
    en: 'MUSIC',
  ),
  RadioTab(
    id: RadioCategory.traffic,
    label: '交通台',
    section: '传统 FM · 交通台',
    en: 'TRAFFIC',
  ),
  RadioTab(
    id: RadioCategory.net,
    label: '网络电台',
    section: '网络电台 / 播客',
    en: 'PODCAST',
  ),
];

/// 分类 → 页签元数据（播放卡写「所属分类」时用）。
RadioTab radioTabOf(RadioCategory category) =>
    radioTabs().firstWhere((tab) => tab.id == category);

/// 该分类下的台表（页签切换时用，顺序与目录一致）。
List<RadioStation> radioStationsOf(RadioCategory category) => [
  for (final station in kRadioStations)
    if (station.category == category) station,
];

/// 问候语：按本地时间分档。与 React `radioGreeting` 的阈值逐条一致
/// （两端同一时刻必须显示同一句，否则并排一比就露馅）。
String radioGreeting(int hour) {
  if (hour >= 5 && hour < 11) return '早上好';
  if (hour >= 11 && hour < 13) return '中午好';
  if (hour >= 13 && hour < 18) return '下午好';
  if (hour >= 18 && hour < 23) return '晚上好';
  return '夜深了';
}

/// 台名首字（无封面时的字标）：中文取第一个字，英文名取首字母。
String radioMonogram(RadioStation station) {
  final name = station.name.trim();
  if (name.isEmpty) return '·';
  final first = name.substring(0, 1);
  return first.toUpperCase();
}

/// 分类色相偏移：三类电台在 token 之外只差一点点角度，不引入表外颜色。
///
/// 返回 0~1 的偏移量，卡面绘制时用它去插值 accent 与 accentLight 的混色比例。
double radioTintBias(RadioCategory category) {
  switch (category) {
    case RadioCategory.music:
      return 0.0;
    case RadioCategory.traffic:
      return 0.17;
    case RadioCategory.net:
      return 0.34;
  }
}

/// 卡面渐变两端的比例（0~1）：起点偏 accent，终点回落到背景色。
///
/// seed 的跨度拉得比较开（0.40~0.72）：42px 的小圆碟上，混色比例只差 5% 时
/// 八台看起来会是同一个绿点；拉开之后每台各有深浅，才像「不同的台」。
(double, double) radioArtMix(RadioStation station) {
  final bias = radioTintBias(station.category);
  final start = math.min(1.0, 0.40 + bias * 0.50 + station.seed * 0.30);
  final end = math.max(0.0, 0.04 + bias * 0.25 + station.seed * 0.10);
  return (start, end);
}
