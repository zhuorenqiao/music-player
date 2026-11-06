// lib/theme/app_tokens.dart
import 'package:flutter/material.dart';

/// 设计 token 表：字段名与 `src/styles/app.css` 的 `:root` 变量一一对应。
///
/// M1 只有深色薄荷（[AppTokens.dark]）一套实际值；M3 加浅色 / 粉 / 蓝时
/// 只往表里追加 `static const` 实例，字段名与所有调用点都不动。
///
/// 带透明度的取值一律写成具体的 `0xAARRGGBB` 字面量（与 CSS 的
/// `rgba(r,g,b,a)` 逐字节对应），不要用 `.withValues` / `.withOpacity`
/// 运行时派生：测试可以逐字断言，也不会有每帧新建对象的开销。
@immutable
class AppTokens {
  const AppTokens({
    required this.name,
    required this.bg,
    required this.bgGradA,
    required this.bgGradB,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.accentLight,
    required this.accentInk,
    required this.accentRgb,
    required this.danger,
    required this.dangerInk,
    required this.toastBg,
    required this.toastErrorBg,
    required this.border,
    required this.borderStrong,
    required this.cardA,
    required this.cardB,
    required this.panelA,
    required this.panelB,
    required this.sheetA,
    required this.sheetB,
    required this.barA,
    required this.barB,
    required this.progressTrack,
    required this.accentSoft,
    required this.accentLine,
    required this.dangerSoft,
    required this.dangerLine,
    required this.shadowCard,
    required this.shadowBar,
    required this.glassBlurSigma,
  });

  /// 主题标识，仅用于日志 / 调试与测试断言。
  final String name;

  /// `--bg`
  final Color bg;

  /// `--bg-grad-a`
  final Color bgGradA;

  /// `--bg-grad-b`
  final Color bgGradB;

  /// `--text`
  final Color text;

  /// `--text-dim`
  final Color textDim;

  /// `--text-faint`
  final Color textFaint;

  /// `--accent`
  final Color accent;

  /// `--accent-light`（歌词当前行高亮色 `--lyric-hl` 的默认值）
  final Color accentLight;

  /// `--accent-ink`
  final Color accentInk;

  /// `--accent-rgb`，形如 `46 230 168`；需要临时混色 / 阴影时从这里取分量。
  final (int, int, int) accentRgb;

  /// `--danger`
  final Color danger;

  /// `--danger-ink`
  final Color dangerInk;

  /// `--toast-bg`
  final Color toastBg;

  /// `--toast-error-bg`
  final Color toastErrorBg;

  /// `--border`
  final Color border;

  /// `--border-strong`
  final Color borderStrong;

  /// `--card-a`（卡面渐变起点）
  final Color cardA;

  /// `--card-b`（卡面渐变终点）
  final Color cardB;

  /// `--panel-a`
  final Color panelA;

  /// `--panel-b`
  final Color panelB;

  /// `--sheet-a`
  final Color sheetA;

  /// `--sheet-b`
  final Color sheetB;

  /// `--bar-a`（底栏渐变起点）
  final Color barA;

  /// `--bar-b`（底栏渐变终点）
  final Color barB;

  /// 进度条轨道（CSS 用 `--tint-3`）
  final Color progressTrack;

  /// `--accent-soft`
  final Color accentSoft;

  /// `--accent-line`
  final Color accentLine;

  /// `--danger-soft`
  final Color dangerSoft;

  /// `--danger-line`
  final Color dangerLine;

  /// `--shadow-card`：`0 24px 60px -34px rgba(0, 0, 0, 0.95)`
  final List<BoxShadow> shadowCard;

  /// `--shadow-bar`：`0 -14px 44px -24px rgba(0, 0, 0, 0.95)`
  final List<BoxShadow> shadowBar;

  /// 毛玻璃强度：CSS 里底栏是 `backdrop-filter: blur(20px)`。
  final double glassBlurSigma;

  /// 深色薄荷：`:root` 的默认值。
  static const AppTokens dark = AppTokens(
    name: 'mint-dark',
    bg: Color(0xFF080B10), // #080b10
    bgGradA: Color(0xFF0B1C1A), // #0b1c1a
    bgGradB: Color(0xFF070A10), // #070a10
    text: Color(0xFFE9F1F7), // #e9f1f7
    textDim: Color(0xFF8B9CAB), // #8b9cab
    textFaint: Color(0xFF66788C), // #66788c
    accent: Color(0xFF2EE6A8), // #2ee6a8
    accentLight: Color(0xFFB9FFE9), // #b9ffe9
    accentInk: Color(0xFF04231B), // #04231b
    accentRgb: (46, 230, 168), // 46 230 168
    danger: Color(0xFFFF6B81), // #ff6b81
    dangerInk: Color(0xFFFFC9D1), // #ffc9d1
    toastBg: Color(0xF2121820), // rgba(18, 24, 32, 0.95)
    toastErrorBg: Color(0xF5301319), // rgba(48, 19, 25, 0.96)
    border: Color(0x12FFFFFF), // --tint-2: rgba(255, 255, 255, 0.07)
    borderStrong: Color(0x29FFFFFF), // --line-strong: rgba(255, 255, 255, 0.16)
    cardA: Color(0x12FFFFFF), // rgba(255, 255, 255, 0.07)
    cardB: Color(0x04FFFFFF), // rgba(255, 255, 255, 0.015)
    panelA: Color(0xFF121924), // #121924
    panelB: Color(0xFF0A0E14), // #0a0e14
    sheetA: Color(0xFF0D1219), // #0d1219
    sheetB: Color(0xFF090C11), // #090c11
    barA: Color(0xE00E131A), // rgba(14, 19, 26, 0.88)，0.88 × 255 = 224.4 → 0xE0
    barB: Color(0xF7090C11), // rgba(9, 12, 17, 0.97)
    progressTrack: Color(0x1CFFFFFF), // --tint-3: rgba(255, 255, 255, 0.11)
    accentSoft: Color(0x242EE6A8), // rgba(46, 230, 168, 0.14)
    accentLine: Color(0x522EE6A8), // rgba(46, 230, 168, 0.32)
    dangerSoft: Color(0x1FFF6B81), // rgba(255, 107, 129, 0.12)
    dangerLine: Color(0x5CFF6B81), // rgba(255, 107, 129, 0.36)
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0xF2000000), // rgba(0, 0, 0, 0.95)
        offset: Offset(0, 24),
        blurRadius: 60,
        spreadRadius: -34,
      ),
    ],
    shadowBar: <BoxShadow>[
      BoxShadow(
        color: Color(0xF2000000), // rgba(0, 0, 0, 0.95)
        offset: Offset(0, -14),
        blurRadius: 44,
        spreadRadius: -24,
      ),
    ],
    glassBlurSigma: 20,
  );

  /// 明暗由页面底色推导：M3 往表里加浅色那套时，装配逻辑不用跟着改。
  Brightness get brightness =>
      bg.computeLuminance() > 0.4 ? Brightness.light : Brightness.dark;

  /// 只用 token 里的颜色拼出的配色方案，不引入表外的颜色。
  ColorScheme get colorScheme => ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: accentInk,
    secondary: accentLight,
    onSecondary: accentInk,
    error: danger,
    onError: dangerInk,
    surface: bg,
    onSurface: text,
    onSurfaceVariant: textDim,
    surfaceContainerHighest: panelA,
    surfaceContainer: panelB,
    outline: borderStrong,
    outlineVariant: border,
  );

  /// 基础 Material 3 主题：只用本表里的颜色，并把本表挂到 [AppTokensData] 上。
  ThemeData get themeData => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: border,
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    extensions: <ThemeExtension<dynamic>>[AppTokensData(tokens: this)],
  );
}

/// 把 token 表塞进 `ThemeData.extensions`，供 `context.tokens` 取用。
@immutable
class AppTokensData extends ThemeExtension<AppTokensData> {
  const AppTokensData({required this.tokens});

  final AppTokens tokens;

  @override
  AppTokensData copyWith({AppTokens? tokens}) =>
      AppTokensData(tokens: tokens ?? this.tokens);

  @override
  AppTokensData lerp(covariant AppTokensData? other, double t) =>
      other == null ? this : (t < 0.5 ? this : other);
}

extension AppTokensContext on BuildContext {
  /// 当前主题的 token 表。用 `buildTheme` / `AppTokens.themeData` 装配时一定非空。
  AppTokens get tokens => Theme.of(this).extension<AppTokensData>()!.tokens;
}
