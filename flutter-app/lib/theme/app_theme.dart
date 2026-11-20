// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      thumbColor: tokens.sliderThumb,
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

/// 沉浸式系统栏样式：状态栏与手势条一律**透明**，图标明暗与页面主题相反。
///
/// 必须与 `main()` 里的 `SystemUiMode.edgeToEdge` 配套：窗口铺到系统栏底下之后，
/// 系统栏自己那层底色只有透明，页面背景（渐变 + 播放卡）才能真的画上去 ——
/// 否则顶部依旧是系统给的那一条黑边。
///
/// 两个 brightness 字段是两端的口径，都要填：`statusBarIconBrightness` 归
/// Android（直接指定图标颜色），`statusBarBrightness` 归 iOS（描述的是**背景**
/// 明暗，系统据此反推图标颜色）。
SystemUiOverlayStyle systemOverlayStyleFor(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    // 手势条（iOS / Android 手势导航）透明；三键导航下系统会给图标加对比底色，
    // 不会被卡面吃掉。
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
  );
}
