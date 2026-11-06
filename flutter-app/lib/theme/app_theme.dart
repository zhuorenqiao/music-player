// lib/theme/app_theme.dart
import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 把 token 表装配成可用的 Material 主题：文字色、滑杆色、分隔线、去水波纹。
///
/// M3 加浅色 / 粉 / 蓝时只换 [tokens]，这里与 `ui/` 都不用改。
ThemeData buildTheme({AppTokens tokens = AppTokens.dark}) {
  final base = tokens.themeData;
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: tokens.text,
      displayColor: tokens.text,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      bodyColor: tokens.text,
      displayColor: tokens.text,
    ),
    iconTheme: base.iconTheme.copyWith(color: tokens.textDim),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: tokens.accent,
      inactiveTrackColor: tokens.progressTrack,
      thumbColor: Colors.white,
      overlayColor: tokens.accentSoft,
      disabledActiveTrackColor: tokens.accentSoft,
      disabledInactiveTrackColor: tokens.progressTrack,
    ),
    dividerColor: tokens.border,
    dividerTheme: DividerThemeData(
      color: tokens.border,
      thickness: 1,
      space: 1,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
}
