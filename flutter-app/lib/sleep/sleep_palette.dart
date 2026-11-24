// lib/sleep/sleep_palette.dart
//
// 休眠模块的「夜色」固定配色。
//
// 与页面其余部分不同：夜色卡（月亮 / 星点 / 呼吸环 / 卡面文字）不随主题翻。
// 深蓝底 + 月金在浅色主题下也保持同一块「另一个时空」，换肤不会把它变成
// 粉底或冷白。色值逐字取自 React `src/styles/app.css` 的 `T32 · 休眠` 区块，
// 改一处必须改另一处。
import 'package:flutter/material.dart';

abstract final class SleepPalette {
  /// 夜空卡底：三段深蓝（CSS `linear-gradient(155deg,#101830,#070b16 55%,#04060c)`）。
  static const Color nightTop = Color(0xFF101830);
  static const Color nightMid = Color(0xFF070B16);
  static const Color nightBottom = Color(0xFF04060C);

  /// 月亮（径向渐变由内到外）与光晕 / 呼吸环。
  static const Color moonCore = Color(0xFFFFFDF2);
  static const Color moonMid = Color(0xFFF2E5C8);
  static const Color moonEdge = Color(0xFFD9C49A);
  static const Color moonHalo = Color(0xFFE9D8B4);

  /// 环形山（月亮表面的三枚淡斑）。
  static const Color craterStrong = Color(0x38B09A70);
  static const Color craterSoft = Color(0x29B09A70);

  /// 卡面文字：曲名、副标题、顶部分类 / 英文角标。
  static const Color cardText = Color(0xFFF7F0DD);
  static const Color cardTextMuted = Color(0xFFF4ECD8);
  static const Color cardLabel = Color(0x94F4ECD8); // alpha 0.58
  static const Color cardLabelDim = Color(0x61F4ECD8); // alpha 0.38
  static const Color cardDetail = Color(0x9EF4ECD8); // alpha 0.62

  /// 播放键：月金底 + 墨色图标。
  static const Color playBg = Color(0xFFE9D8B4);
  static const Color playInk = Color(0xFF171009);
  static const Color error = Color(0xFFFF9AA7);

  /// 星点与右下压暗。
  static const Color star = Color(0xFFF7F1DF);
  static const Color horizon = Color(0x9E03050A); // alpha 0.62

  /// 卡面描边：CSS `rgba(255,255,255,0.1)`。
  static const Color cardLine = Color(0x1AFFFFFF);

  /// 缩略图里的小月亮 / 星点。
  static const Color thumbMoon = Color(0xFFF0E3C4);

  /// 页头 logo 的夜色方块与月金描边（CSS `linear-gradient(150deg,#26304f,#0c1120)`、
  /// `border: 1px solid rgba(233,216,180,.3)`）。
  static const Color logoTop = Color(0xFF26304F);
  static const Color logoBottom = Color(0xFF0C1120);
  static const Color logoLine = Color(0x4DE9D8B4); // alpha 0.3
}
