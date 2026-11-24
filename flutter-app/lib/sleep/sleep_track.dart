// lib/sleep/sleep_track.dart
//
// 休眠模块的目录：模型 + 分类 + 文案 + 视觉种子。
//
// 与 React `src/lib/sleep.ts` **逐条同源**（id / 曲名 / 副标题 / 分类 /
// 生成配方 / 卡片配色一一对应），改一处必须改另一处 —— 两端要像素级对齐，
// 目录各写一份的话，页签计数与顺序迟早对不上。
//
// 曲目不是外部版权音频：每一条都是程序化生成的助眠声景（雨、潮、风、
// 溪涧、鸟鸣、篝火、虫鸣、摇篮、音乐盒、夜曲、白噪、飞瀑），32 秒无缝循环，
// 不依赖网络、不随包携带音频文件。
// 生成器在 `sleep_audio.dart`（Flutter）与 `src/lib/sleep-audio.ts`（React）。
import 'package:flutter/material.dart';

/// 生成配方：同一份配方两端各实现一遍，听感一致。
enum SleepRecipe {
  rain,
  ocean,
  wind,
  lullaby,
  musicbox,
  noise,
  stream,
  birds,
  campfire,
  crickets,
  nocturne,
  waterfall,
}

/// 三个页签。
enum SleepCategory { scape, lullaby, noise }

/// 循环长度（秒）：两端生成器必须同值，否则时长文案会不一致。
const int kSleepLoopSeconds = 32;

/// 采样率：22050 单声道 16bit —— 助眠声景不需要 44.1k，文件小一半。
const int kSleepSampleRate = 22050;

@immutable
class SleepTab {
  const SleepTab({
    required this.id,
    required this.label,
    required this.section,
    required this.en,
  });

  final SleepCategory id;

  /// 页签上的短名。
  final String label;

  /// 播放卡顶部那行小字。
  final String section;

  /// 卡片右上角英文角标。
  final String en;
}

const List<SleepTab> kSleepTabs = <SleepTab>[
  SleepTab(
    id: SleepCategory.scape,
    label: '声景',
    section: '环境声 · 声景',
    en: 'SOUNDSCAPE',
  ),
  SleepTab(
    id: SleepCategory.lullaby,
    label: '摇篮',
    section: '轻音乐 · 摇篮',
    en: 'LULLABY',
  ),
  SleepTab(
    id: SleepCategory.noise,
    label: '白噪',
    section: '低声压 · 白噪',
    en: 'NOISE',
  ),
];

@immutable
class SleepTrack {
  const SleepTrack({
    required this.id,
    required this.name,
    required this.detail,
    required this.category,
    required this.recipe,
    required this.seed,
    required this.artFrom,
    required this.artTo,
    required this.glow,
  });

  /// 稳定 id（列表 key / 播放态判定 / 音频缓存都靠它）。
  final String id;
  final String name;

  /// 副标题：声音质地 + 场景。
  final String detail;
  final SleepCategory category;
  final SleepRecipe recipe;

  /// 视觉种子 0~1：缩略图与卡面微光按它错开。
  final double seed;

  /// 缩略图渐变两端（固定色，夜色不随主题翻）。
  final Color artFrom;
  final Color artTo;

  /// 卡面右上微光与缩略图高光。
  final Color glow;
}

const List<SleepTrack> kSleepTracks = <SleepTrack>[
  SleepTrack(
    id: 'sleep-rain',
    name: '夜雨 · 屋檐',
    detail: '雨声 · 窗外 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.rain,
    seed: 0.14,
    artFrom: Color(0xFF16233D),
    artTo: Color(0xFF0A0F1D),
    glow: Color(0xFF6C9BE8),
  ),
  SleepTrack(
    id: 'sleep-ocean',
    name: '潮汐 · 退岸',
    detail: '海浪 · 低频 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.ocean,
    seed: 0.38,
    artFrom: Color(0xFF103044),
    artTo: Color(0xFF07121C),
    glow: Color(0xFF55C2CF),
  ),
  SleepTrack(
    id: 'sleep-wind',
    name: '林风 · 晚径',
    detail: '风声 · 林间 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.wind,
    seed: 0.62,
    artFrom: Color(0xFF182C33),
    artTo: Color(0xFF0A151A),
    glow: Color(0xFF8CC7B4),
  ),
  SleepTrack(
    id: 'sleep-lullaby',
    name: '月光摇篮',
    detail: '柔钢琴 · 摇篮 · 32 秒循环',
    category: SleepCategory.lullaby,
    recipe: SleepRecipe.lullaby,
    seed: 0.22,
    artFrom: Color(0xFF241F3D),
    artTo: Color(0xFF0E0B1B),
    glow: Color(0xFFC6B4FF),
  ),
  SleepTrack(
    id: 'sleep-musicbox',
    name: '星子入梦',
    detail: '音乐盒 · 星夜 · 32 秒循环',
    category: SleepCategory.lullaby,
    recipe: SleepRecipe.musicbox,
    seed: 0.47,
    artFrom: Color(0xFF2A2234),
    artTo: Color(0xFF120D19),
    glow: Color(0xFFFFD39B),
  ),
  SleepTrack(
    id: 'sleep-noise',
    name: '深夜白噪',
    detail: '低频噪声 · 安睡 · 32 秒循环',
    category: SleepCategory.noise,
    recipe: SleepRecipe.noise,
    seed: 0.71,
    artFrom: Color(0xFF221F1C),
    artTo: Color(0xFF0E0C0B),
    glow: Color(0xFFC8A98F),
  ),
  SleepTrack(
    id: 'sleep-stream',
    name: '溪涧 · 石上',
    detail: '流水 · 山涧 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.stream,
    seed: 0.26,
    artFrom: Color(0xFF123039),
    artTo: Color(0xFF08161C),
    glow: Color(0xFF5FC6BE),
  ),
  SleepTrack(
    id: 'sleep-birds',
    name: '晨林 · 鸟鸣',
    detail: '鸟叫 · 林梢 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.birds,
    seed: 0.55,
    artFrom: Color(0xFF1B3327),
    artTo: Color(0xFF0A1710),
    glow: Color(0xFF96D6A0),
  ),
  SleepTrack(
    id: 'sleep-campfire',
    name: '篝火 · 木屋',
    detail: '柴火 · 噼啪 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.campfire,
    seed: 0.83,
    artFrom: Color(0xFF33241A),
    artTo: Color(0xFF160E0A),
    glow: Color(0xFFFFAC60),
  ),
  SleepTrack(
    id: 'sleep-crickets',
    name: '虫鸣 · 夏夜',
    detail: '蟋蟀 · 草间 · 32 秒循环',
    category: SleepCategory.scape,
    recipe: SleepRecipe.crickets,
    seed: 0.09,
    artFrom: Color(0xFF1D2A2E),
    artTo: Color(0xFF0B1214),
    glow: Color(0xFFB0D08A),
  ),
  SleepTrack(
    id: 'sleep-nocturne',
    name: '夜曲 · 低回',
    detail: '柔弦乐 · 夜曲 · 32 秒循环',
    category: SleepCategory.lullaby,
    recipe: SleepRecipe.nocturne,
    seed: 0.66,
    artFrom: Color(0xFF232038),
    artTo: Color(0xFF0D0C18),
    glow: Color(0xFFBABEFF),
  ),
  SleepTrack(
    id: 'sleep-waterfall',
    name: '飞瀑 · 白噪',
    detail: '瀑布 · 宽带 · 32 秒循环',
    category: SleepCategory.noise,
    recipe: SleepRecipe.waterfall,
    seed: 0.34,
    artFrom: Color(0xFF1B2626),
    artTo: Color(0xFF0B1212),
    glow: Color(0xFFBEDCD2),
  ),
];

/// 目录第一首：页面还没选过曲目时的门面。
final SleepTrack kSleepFirstTrack = kSleepTracks.first;

/// 分类 → 页签元数据。
SleepTab sleepTabOf(SleepCategory category) {
  for (final tab in kSleepTabs) {
    if (tab.id == category) return tab;
  }
  return kSleepTabs.first;
}

/// 该分类下的曲目（顺序与目录一致）。
List<SleepTrack> sleepTracksOf(SleepCategory category) =>
    kSleepTracks.where((track) => track.category == category).toList();

/// 按 id 找曲目；找不到返回 null（缓存 / 恢复播放态时用）。
SleepTrack? sleepTrackById(String id) {
  for (final track in kSleepTracks) {
    if (track.id == id) return track;
  }
  return null;
}

/// 问候语：按本地时间分档。与 React `sleepGreeting` 的阈值逐条一致
/// （两端同一时刻必须显示同一句）。
String sleepGreeting(int hour) {
  if (hour >= 5 && hour < 11) return '早安，也可以再歇一会儿';
  if (hour >= 11 && hour < 13) return '午间，闭上眼睛歇一会儿';
  if (hour >= 13 && hour < 18) return '午后，把节奏慢下来';
  if (hour >= 18 && hour < 23) return '夜色慢慢落下来了';
  return '夜深了，该睡了';
}
