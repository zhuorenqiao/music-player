// lib/theme/app_tokens.dart
import 'package:flutter/material.dart';

/// 设计 token 表：字段名与 `src/styles/app.css` 的 `:root` 变量一一对应。
///
/// M1 只有深色薄荷（[AppTokens.dark]）一套实际值；M3 起两维换肤
/// （`ThemeMode × ThemeColor`）共 6 组静态实例，颜色值逐字取自 app.css：
/// - 深色薄荷：app.css:10-122（`:root`）
/// - 浅色薄荷：app.css:129-214（`:root[data-mode="light"]`）
/// - 浅色粉 / 蓝：app.css:229-239 / :241-251（只覆写强调色组 + bg-grad + glow，
///   其余沿用浅色薄荷）
/// - 深色粉 / 蓝：app.css:257-294 / :299-336（其余沿用深色薄荷）
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
    required this.sliderThumb,
    required this.tint1,
    required this.accentSoft,
    required this.accentLine,
    required this.dangerSoft,
    required this.dangerLine,
    required this.shadowCard,
    required this.shadowBar,
    required this.glassBlurSigma,
    required this.lightboxScrim,
    required this.glowA,
    required this.glowB,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.scrim,
    required this.scrimStrong,
    required this.pastOpacity,
    required this.pastOpacityPage,
    required this.scrollThumb,
    required this.frostSheenA,
    required this.frostSheenB,
    required this.frostBloom,
    required this.frostTint,
    required this.frostCoverOpacity,
    required this.frostCoverBlur,
    required this.frostCoverSat,
    required this.frostCoverBrightness,
    required this.frostVeilA,
    required this.frostVeilB,
    required this.vinylLow,
    required this.vinylMid,
    required this.vinylHi,
    required this.vinylLine,
    required this.accentSoftHover,
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

  /// 滑杆圆点的填充色：app.css 里是字面量 `background: #ffffff`
  /// （`.progress__input::-webkit-slider-thumb`、`.volume__input::-webkit-slider-thumb`），
  /// 不是变量，所以表里给它一个字段 —— `ui/` 内不许出现颜色字面量（T19 定的规矩）。
  final Color sliderThumb;

  /// `--tint-1: rgba(255, 255, 255, 0.04)`
  ///
  /// 最淡的一层白：双语开关的「关」态底色用它（`.lyrics-bilingual` 的
  /// `background: var(--tint-1)`，app.css:3104）。和 [progressTrack]（`--tint-3`）
  /// 是同一族的三档之一，浅色那套翻成深蓝压暗（app.css:153）。
  final Color tint1;

  /// `--accent-soft`
  final Color accentSoft;

  /// `--accent-line`
  final Color accentLine;

  /// `--danger-soft`
  final Color dangerSoft;

  /// `--danger-line`
  final Color dangerLine;

  /// `--shadow-card`：深色 `0 24px 60px -34px rgba(0,0,0,0.95)`（app.css:113），
  /// 浅色 `0 22px 46px -24px rgba(24,42,60,0.32)`（app.css:190）。
  final List<BoxShadow> shadowCard;

  /// `--shadow-bar`：深色 `0 -14px 44px -24px rgba(0,0,0,0.95)`（app.css:114），
  /// 浅色 `0 -12px 36px -22px rgba(24,42,60,0.28)`（app.css:191）。
  final List<BoxShadow> shadowBar;

  /// 毛玻璃强度：CSS 里底栏是 `backdrop-filter: blur(20px)`。
  final double glassBlurSigma;

  /// 封面放大层的遮罩色（M2b T11）：app.css:3664 的
  /// `background: rgba(4, 8, 12, 0.86)`。浅色主题的 CSS 没有覆写行
  /// （lightbox 是 M2b 新增），按逐字原则沿用深色值——浅色待真机验，M3 记录。
  final Color lightboxScrim;

  /// `--glow-a`（封面光晕呼吸的渐变端点之一，app.css:13-14；浅色 :133-134；
  /// 深色粉/蓝 :261-262/:303-304；浅色粉/蓝 :230-231/:242-243）。
  final Color glowA;

  /// `--glow-b`（光晕呼吸另一端）
  final Color glowB;

  /// `--surface`（选中态底色，app.css:16-18；浅色 :136-138；
  /// 深色粉/蓝 :264-266/:306-308。消费点见 app.css:3139-3164 的 var(--surface-2)）。
  final Color surface;

  /// `--surface-2`（浅色选中态用白底，app.css:3139-3164）
  final Color surface2;

  /// `--surface-3`（深色即 `--tint-3`）
  final Color surface3;

  /// `--scrim`（drawer/sheet 遮罩，app.css:79；浅色 :187；深色粉/蓝 :291/:333）
  final Color scrim;

  /// `--scrim-strong`（app.css:80；浅色 :188；深色粉/蓝 :292/:334）
  final Color scrimStrong;

  /// `--past-opacity`：已唱行的压暗程度。CSS 缺省 0.62（app.css:1940 的
  /// `var(--past-opacity, 0.62)`），浅色提到 0.82（app.css:196）。
  final double pastOpacity;

  /// `--past-opacity-page`：歌词页整页已唱行，缺省 0.5（app.css:3057），浅色 0.8（app.css:197）。
  final double pastOpacityPage;

  /// `--scroll-thumb`：auto-hide 滚动条滑块色（app.css:43；浅色 :157）。
  final Color scrollThumb;

  /// `--frost-sheen-a`：磨砂膜乳白雾面渐变起点（app.css:64；浅色 :173）。
  final Color frostSheenA;

  /// `--frost-sheen-b`（app.css:65；浅色 :174）
  final Color frostSheenB;

  /// `--frost-bloom`：右上白色径向晕（app.css:66；浅色 :175）。
  final Color frostBloom;

  /// `--frost-tint`：右下主题色晕染 `rgb(var(--accent-rgb) / 0.1)`，浅色 /0.12
  /// （app.css:67 / :176；粉/蓝按各自 accent-rgb）。
  final Color frostTint;

  /// `--frost-cover-opacity`：玻璃后封面垫的透明度（app.css:69 深色 0.5；浅色 :178 0.45）。
  final double frostCoverOpacity;

  /// `--frost-cover-filter` 的 blur 分量（app.css:70/:179 都是 44px；
  /// 窄屏 @media 降 30，app.css:217-225——换算由消费方做，表里只存 44）。
  final double frostCoverBlur;

  /// `--frost-cover-filter` 的 saturate 分量（深色 1.6 / 浅色 1.4）。
  final double frostCoverSat;

  /// `--frost-cover-filter` 的 brightness 分量（深色 0.7 / 浅色 1.35）。
  final double frostCoverBrightness;

  /// `--frost-veil` 渐变起点 `rgb(8 10 15 / 0.32)`（app.css:71；浅色 :180 换白色 0.2）。
  final Color frostVeilA;

  /// `--frost-veil` 渐变终点（深色 0.14 / 浅色 0.06）。
  final Color frostVeilB;

  /// `--vinyl-low`：黑胶是「实体唱片」，两套主题下都保持深色反光，
  /// 四色深浅同值（app.css:85-88），token 里只放一份。
  final Color vinylLow;

  /// `--vinyl-mid`
  final Color vinylMid;

  /// `--vinyl-hi`
  final Color vinylHi;

  /// `--vinyl-line`
  final Color vinylLine;

  /// `.btn--soft:hover` 等处的 `rgb(var(--accent-rgb) / 0.22)`
  /// （app.css:929/:3129/:3183）。虽然可由 accentRgb 派生，为了「表内无派生」
  /// 仍落成字段。
  final Color accentSoftHover;

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
    sliderThumb: Color(0xFFFFFFFF), // #ffffff（滑杆圆点底）
    tint1: Color(0x0AFFFFFF), // --tint-1: rgba(255, 255, 255, 0.04)
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
    lightboxScrim: Color(0xDB04080C), // rgba(4, 8, 12, 0.86)
    glowA: Color(0x292EE6A8), // --glow-a: rgba(46, 230, 168, 0.16)
    glowB: Color(0x216084FF), // --glow-b: rgba(96, 132, 255, 0.13)
    surface: Color(0x0AFFFFFF), // --surface = var(--tint-1)
    surface2: Color(0x13FFFFFF), // --surface-2: rgba(255, 255, 255, 0.075)
    surface3: Color(0x1CFFFFFF), // --surface-3 = var(--tint-3)
    scrim: Color(0xA804080C), // --scrim: rgba(4, 8, 12, 0.66)
    scrimStrong: Color(0xBD04080C), // --scrim-strong: rgba(4, 8, 12, 0.74)
    pastOpacity: 0.62, // app.css:1940 var(--past-opacity, 0.62)
    pastOpacityPage: 0.5, // app.css:3057 var(--past-opacity-page, 0.5)
    scrollThumb: Color(0x47FFFFFF), // --scroll-thumb: rgba(255, 255, 255, 0.28)
    frostSheenA: Color(0x1AFFFFFF), // rgb(255 255 255 / 0.1)
    frostSheenB: Color(0x08FFFFFF), // rgb(255 255 255 / 0.03)
    frostBloom: Color(0x2EFFFFFF), // rgb(255 255 255 / 0.18)
    frostTint: Color(0x1A2EE6A8), // rgb(46 230 168 / 0.1)
    frostCoverOpacity: 0.5,
    frostCoverBlur: 44, // blur(44px)
    frostCoverSat: 1.6, // saturate(1.6)
    frostCoverBrightness: 0.7, // brightness(0.7)
    frostVeilA: Color(0x52080A0F), // rgb(8 10 15 / 0.32)
    frostVeilB: Color(0x24080A0F), // rgb(8 10 15 / 0.14)
    vinylLow: Color(0x0FFFFFFF), // rgba(255, 255, 255, 0.06)
    vinylMid: Color(0x17FFFFFF), // rgba(255, 255, 255, 0.09)
    vinylHi: Color(0x29FFFFFF), // rgba(255, 255, 255, 0.16)
    vinylLine: Color(0x29FFFFFF), // rgba(255, 255, 255, 0.16)
    accentSoftHover: Color(0x382EE6A8), // rgb(46 230 168 / 0.22)
  );

  /// 深色粉：app.css:257-294 逐字；未覆写的字段沿用深色薄荷的值。
  static const AppTokens darkPink = AppTokens(
    name: 'pink-dark',
    bg: Color(0xFF100A11), // #100a11
    bgGradA: Color(0xFF1D0D17), // #1d0d17
    bgGradB: Color(0xFF0B070D), // #0b070d
    text: Color(0xFFF8EDF4), // #f8edf4
    textDim: Color(0xFFB3A1AD), // #b3a1ad
    textFaint: Color(0xFF9A8796), // #9a8796
    accent: Color(0xFFFF6AA8), // #ff6aa8
    accentLight: Color(0xFFFFD2E4), // #ffd2e4
    // CSS 的深色粉块（:257-294）没有 --accent-ink 覆写行，沿用 :root 的 #04231b。
    accentInk: Color(0xFF04231B),
    accentRgb: (255, 106, 168), // 255 106 168
    danger: Color(0xFFFF6B81), // 沿用深色默认 #ff6b81
    dangerInk: Color(0xFFFFC9D1), // 沿用深色默认 #ffc9d1
    toastBg: Color(0xF2121820), // 沿用深色默认
    toastErrorBg: Color(0xF5301319), // 沿用深色默认
    border: Color(0x1AFFFFFF), // rgba(255, 255, 255, 0.1)
    borderStrong: Color(0x2BFFFFFF), // rgba(255, 255, 255, 0.17)
    cardA: Color(0x13FFFFFF), // rgba(255, 255, 255, 0.075)
    cardB: Color(0x05FFFFFF), // rgba(255, 255, 255, 0.02)
    panelA: Color(0xFF211420), // #211420
    panelB: Color(0xFF120A11), // #120a11
    sheetA: Color(0xFF1C1119), // #1c1119
    sheetB: Color(0xFF0E080D), // #0e080d
    barA: Color(0xE01A1018), // rgba(26, 16, 24, 0.88)
    barB: Color(0xF70E090D), // rgba(14, 9, 13, 0.97)
    progressTrack: Color(0x1CFFFFFF), // 沿用深色默认（--tint-3 未覆写）
    sliderThumb: Color(0xFFFFFFFF), // 字面量白，两主题同值
    tint1: Color(0x0AFFFFFF), // 沿用深色默认（--tint-1 未覆写）
    accentSoft: Color(0x26FF6AA8), // rgba(255, 106, 168, 0.15)
    accentLine: Color(0x57FF6AA8), // rgba(255, 106, 168, 0.34)
    dangerSoft: Color(0x1FFF6B81), // 沿用深色默认
    dangerLine: Color(0x5CFF6B81), // 沿用深色默认
    shadowCard: <BoxShadow>[
      // --shadow-card 未在 :257-294 覆写，沿用深色默认。
      BoxShadow(
        color: Color(0xF2000000),
        offset: Offset(0, 24),
        blurRadius: 60,
        spreadRadius: -34,
      ),
    ],
    shadowBar: <BoxShadow>[
      BoxShadow(
        color: Color(0xF2000000),
        offset: Offset(0, -14),
        blurRadius: 44,
        spreadRadius: -24,
      ),
    ],
    glassBlurSigma: 20,
    lightboxScrim: Color(0xDB04080C), // 沿用深色默认
    glowA: Color(0x38FF6AA8), // rgba(255, 106, 168, 0.22)
    glowB: Color(0x299660FF), // rgba(150, 96, 255, 0.16)
    surface: Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
    surface2: Color(0x15FFFFFF), // rgba(255, 255, 255, 0.085)
    surface3: Color(0x1FFFFFFF), // rgba(255, 255, 255, 0.12)
    scrim: Color(0xAD0A040A), // rgba(10, 4, 10, 0.68)
    scrimStrong: Color(0xC20A040A), // rgba(10, 4, 10, 0.76)
    pastOpacity: 0.62,
    pastOpacityPage: 0.5,
    scrollThumb: Color(0x47FFFFFF), // --scroll-thumb 未覆写
    frostSheenA: Color(0x1AFFFFFF), // 磨砂组未覆写，沿用深色默认
    frostSheenB: Color(0x08FFFFFF),
    frostBloom: Color(0x2EFFFFFF),
    frostTint: Color(0x1AFF6AA8), // rgb(255 106 168 / 0.1)（accent-rgb 跟着翻）
    frostCoverOpacity: 0.5,
    frostCoverBlur: 44,
    frostCoverSat: 1.6,
    frostCoverBrightness: 0.7,
    frostVeilA: Color(0x52080A0F),
    frostVeilB: Color(0x24080A0F),
    vinylLow: Color(0x0FFFFFFF),
    vinylMid: Color(0x17FFFFFF),
    vinylHi: Color(0x29FFFFFF),
    vinylLine: Color(0x29FFFFFF),
    accentSoftHover: Color(0x38FF6AA8), // rgb(255 106 168 / 0.22)
  );

  /// 深色蓝：app.css:299-336 逐字；注意 `--accent-line` 是
  /// `rgba(141, 180, 255, 0.34)`（:321），**不是** accent 同色的 0.34。
  static const AppTokens darkBlue = AppTokens(
    name: 'blue-dark',
    bg: Color(0xFF070D17), // #070d17
    bgGradA: Color(0xFF0B1727), // #0b1727
    bgGradB: Color(0xFF050A12), // #050a12
    text: Color(0xFFE9F1FB), // #e9f1fb
    textDim: Color(0xFF9DB0C6), // #9db0c6
    textFaint: Color(0xFF7488A0), // #7488a0
    accent: Color(0xFF4D8DFF), // #4d8dff
    accentLight: Color(0xFFD3E4FF), // #d3e4ff
    // CSS 的深色蓝块（:299-336）没有 --accent-ink 覆写行，沿用 :root 的 #04231b。
    accentInk: Color(0xFF04231B),
    accentRgb: (77, 141, 255), // 77 141 255
    danger: Color(0xFFFF6B81), // 沿用深色默认
    dangerInk: Color(0xFFFFC9D1), // 沿用深色默认
    toastBg: Color(0xF2121820), // 沿用深色默认
    toastErrorBg: Color(0xF5301319), // 沿用深色默认
    border: Color(0x1AFFFFFF), // rgba(255, 255, 255, 0.1)
    borderStrong: Color(0x2BFFFFFF), // rgba(255, 255, 255, 0.17)
    cardA: Color(0x12FFFFFF), // rgba(255, 255, 255, 0.07)
    cardB: Color(0x04FFFFFF), // rgba(255, 255, 255, 0.015)
    panelA: Color(0xFF101D30), // #101d30
    panelB: Color(0xFF070D17), // #070d17
    sheetA: Color(0xFF0D1726), // #0d1726
    sheetB: Color(0xFF060B13), // #060b13
    barA: Color(0xE00C1624), // rgba(12, 22, 36, 0.88)
    barB: Color(0xF7060B12), // rgba(6, 11, 18, 0.97)
    progressTrack: Color(0x1CFFFFFF), // 沿用深色默认
    sliderThumb: Color(0xFFFFFFFF),
    tint1: Color(0x0AFFFFFF), // 沿用深色默认
    accentSoft: Color(0x294D8DFF), // rgba(77, 141, 255, 0.16)
    accentLine: Color(0x578DB4FF), // rgba(141, 180, 255, 0.34)（app.css:321 逐字）
    dangerSoft: Color(0x1FFF6B81), // 沿用深色默认
    dangerLine: Color(0x5CFF6B81), // 沿用深色默认
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0xF2000000),
        offset: Offset(0, 24),
        blurRadius: 60,
        spreadRadius: -34,
      ),
    ],
    shadowBar: <BoxShadow>[
      BoxShadow(
        color: Color(0xF2000000),
        offset: Offset(0, -14),
        blurRadius: 44,
        spreadRadius: -24,
      ),
    ],
    glassBlurSigma: 20,
    lightboxScrim: Color(0xDB04080C), // 沿用深色默认
    glowA: Color(0x384D8DFF), // rgba(77, 141, 255, 0.22)
    glowB: Color(0x2938BDF8), // rgba(56, 189, 248, 0.16)
    surface: Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
    surface2: Color(0x15FFFFFF), // rgba(255, 255, 255, 0.085)
    surface3: Color(0x1FFFFFFF), // rgba(255, 255, 255, 0.12)
    scrim: Color(0xAD03070D), // rgba(3, 7, 13, 0.68)
    scrimStrong: Color(0xC203070D), // rgba(3, 7, 13, 0.76)
    pastOpacity: 0.62,
    pastOpacityPage: 0.5,
    scrollThumb: Color(0x47FFFFFF),
    frostSheenA: Color(0x1AFFFFFF),
    frostSheenB: Color(0x08FFFFFF),
    frostBloom: Color(0x2EFFFFFF),
    frostTint: Color(0x1A4D8DFF), // rgb(77 141 255 / 0.1)
    frostCoverOpacity: 0.5,
    frostCoverBlur: 44,
    frostCoverSat: 1.6,
    frostCoverBrightness: 0.7,
    frostVeilA: Color(0x52080A0F),
    frostVeilB: Color(0x24080A0F),
    vinylLow: Color(0x0FFFFFFF),
    vinylMid: Color(0x17FFFFFF),
    vinylHi: Color(0x29FFFFFF),
    vinylLine: Color(0x29FFFFFF),
    accentSoftHover: Color(0x384D8DFF), // rgb(77 141 255 / 0.22)
  );

  /// 浅色薄荷：app.css:129-214 逐字。
  static const AppTokens lightMint = AppTokens(
    name: 'mint-light',
    bg: Color(0xFFDFE8F2), // #dfe8f2
    bgGradA: Color(0xFFD3EFE6), // #d3efe6
    bgGradB: Color(0xFFDEE5F6), // #dee5f6
    text: Color(0xFF16202B), // #16202b
    textDim: Color(0xFF4B5E70), // #4b5e70
    textFaint: Color(0xFF5D7083), // #5d7083
    accent: Color(0xFF12B98C), // #12b98c
    accentLight: Color(0xFF0A7A5D), // #0a7a5d
    // app.css:129-214 没有 --accent-ink 覆写行，逐字原则沿用 :root 的 #04231b；
    // 该值在浅色底上对比度如何是 M3 真机验项（消费点是 onPrimary，薄荷主按钮）。
    accentInk: Color(0xFF04231B),
    accentRgb: (18, 185, 140), // 18 185 140
    danger: Color(0xFFC9253F), // #c9253f
    dangerInk: Color(0xFF9D1B30), // #9d1b30
    toastBg: Color(0xFFFFFFFF), // #ffffff
    toastErrorBg: Color(0xFFFFF1F3), // #fff1f3
    border: Color(0x1F12263A), // rgba(18, 38, 58, 0.12)
    borderStrong: Color(0x3312263A), // rgba(18, 38, 58, 0.2)
    cardA: Color(0xD6FFFFFF), // rgba(255, 255, 255, 0.84)
    cardB: Color(0xE6F8FBFE), // rgba(248, 251, 254, 0.9)
    panelA: Color(0xFFFFFFFF), // #ffffff
    panelB: Color(0xFFF7FAFD), // #f7fafd
    sheetA: Color(0xFFFFFFFF), // #ffffff
    sheetB: Color(0xFFF6F9FC), // #f6f9fc
    barA: Color(0xE0FFFFFF), // rgba(255, 255, 255, 0.88)
    barB: Color(0xF7F7FAFD), // rgba(247, 250, 253, 0.97)
    progressTrack: Color(0x1C12263A), // --tint-3: rgba(18, 38, 58, 0.11)
    sliderThumb: Color(0xFFFFFFFF), // 滑杆圆点白，两主题同值
    tint1: Color(0x0B12263A), // --tint-1: rgba(18, 38, 58, 0.045)
    accentSoft: Color(0x2412B98C), // rgba(18, 185, 140, 0.14)
    accentLine: Color(0x5712B98C), // rgba(18, 185, 140, 0.34)
    dangerSoft: Color(0x17C9253F), // rgba(201, 37, 63, 0.09)
    dangerLine: Color(0x4DC9253F), // rgba(201, 37, 63, 0.3)
    shadowCard: <BoxShadow>[
      // 0 22px 46px -24px rgba(24, 42, 60, 0.32)（app.css:190）
      BoxShadow(
        color: Color(0x52182A3C), // rgba(24, 42, 60, 0.32)
        offset: Offset(0, 22),
        blurRadius: 46,
        spreadRadius: -24,
      ),
    ],
    shadowBar: <BoxShadow>[
      // 0 -12px 36px -22px rgba(24, 42, 60, 0.28)（app.css:191）
      BoxShadow(
        color: Color(0x47182A3C), // rgba(24, 42, 60, 0.28)
        offset: Offset(0, -12),
        blurRadius: 36,
        spreadRadius: -22,
      ),
    ],
    glassBlurSigma: 20,
    // 浅色 CSS 没有覆写 lightbox 遮罩（lightbox 是 M2b 新增变量），
    // 逐字原则沿用 rgba(4, 8, 12, 0.86)——浅色待真机验，M3 记录。
    lightboxScrim: Color(0xDB04080C),
    glowA: Color(0x382EE6A8), // rgba(46, 230, 168, 0.22)
    glowB: Color(0x2E6084FF), // rgba(96, 132, 255, 0.18)
    surface: Color(0xEBFFFFFF), // rgba(255, 255, 255, 0.92)
    surface2: Color(0xFFFFFFFF), // #ffffff
    surface3: Color(0xFFFFFFFF), // #ffffff
    scrim: Color(0x4D1C2A38), // rgba(28, 42, 56, 0.3)
    scrimStrong: Color(0x611C2A38), // rgba(28, 42, 56, 0.38)
    pastOpacity: 0.82, // app.css:196
    pastOpacityPage: 0.8, // app.css:197
    scrollThumb: Color(0x4212263A), // rgba(18, 38, 58, 0.26)
    frostSheenA: Color(0x8CFFFFFF), // rgb(255 255 255 / 0.55)
    frostSheenB: Color(0x29FFFFFF), // rgb(255 255 255 / 0.16)
    frostBloom: Color(0x99FFFFFF), // rgb(255 255 255 / 0.6)
    frostTint: Color(0x1F12B98C), // rgb(18 185 140 / 0.12)
    frostCoverOpacity: 0.45,
    frostCoverBlur: 44, // blur(44px)；窄屏 30 由消费方换算（app.css:222-224）
    frostCoverSat: 1.4, // saturate(1.4)
    frostCoverBrightness: 1.35, // brightness(1.35)
    frostVeilA: Color(0x33FFFFFF), // rgb(255 255 255 / 0.2)
    frostVeilB: Color(0x10FFFFFF), // rgb(255 255 255 / 0.06)（0.06×255=15.3，按任务清单取 0x10；四舍五入是 0x0F，差异已记录）
    vinylLow: Color(0x0FFFFFFF), // 黑胶四色深浅同值（app.css:85-88）
    vinylMid: Color(0x17FFFFFF),
    vinylHi: Color(0x29FFFFFF),
    vinylLine: Color(0x29FFFFFF),
    accentSoftHover: Color(0x3812B98C), // rgb(18 185 140 / 0.22)
  );

  /// 浅色粉：app.css:229-239 只覆写 glow / bg-grad / 强调色组，
  /// 其余（含 bg / danger / toast / 面 / 磨砂）沿用浅色薄荷。
  static const AppTokens lightPink = AppTokens(
    name: 'pink-light',
    bg: Color(0xFFDFE8F2), // --bg 未覆写，沿用浅色薄荷
    bgGradA: Color(0xFFF8DFEA), // #f8dfea
    bgGradB: Color(0xFFE8E3F7), // #e8e3f7
    text: Color(0xFF16202B), // 沿用浅色薄荷
    textDim: Color(0xFF4B5E70),
    textFaint: Color(0xFF5D7083),
    accent: Color(0xFFEC4F92), // #ec4f92
    accentLight: Color(0xFFA3175A), // #a3175a
    // 浅色粉同样没有 --accent-ink 覆写行，沿用 :root 的 #04231b。
    accentInk: Color(0xFF04231B),
    accentRgb: (236, 79, 146), // 236 79 146
    danger: Color(0xFFC9253F), // 浅色危险态翻转沿用浅色薄荷
    dangerInk: Color(0xFF9D1B30),
    toastBg: Color(0xFFFFFFFF),
    toastErrorBg: Color(0xFFFFF1F3),
    border: Color(0x1F12263A), // 沿用浅色薄荷
    borderStrong: Color(0x3312263A),
    cardA: Color(0xD6FFFFFF),
    cardB: Color(0xE6F8FBFE),
    panelA: Color(0xFFFFFFFF),
    panelB: Color(0xFFF7FAFD),
    sheetA: Color(0xFFFFFFFF),
    sheetB: Color(0xFFF6F9FC),
    barA: Color(0xE0FFFFFF),
    barB: Color(0xF7F7FAFD),
    progressTrack: Color(0x1C12263A),
    sliderThumb: Color(0xFFFFFFFF),
    tint1: Color(0x0B12263A),
    accentSoft: Color(0x21EC4F92), // rgba(236, 79, 146, 0.13)
    accentLine: Color(0x57EC4F92), // rgba(236, 79, 146, 0.34)
    dangerSoft: Color(0x17C9253F),
    dangerLine: Color(0x4DC9253F),
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0x52182A3C),
        offset: Offset(0, 22),
        blurRadius: 46,
        spreadRadius: -24,
      ),
    ],
    shadowBar: <BoxShadow>[
      BoxShadow(
        color: Color(0x47182A3C),
        offset: Offset(0, -12),
        blurRadius: 36,
        spreadRadius: -22,
      ),
    ],
    glassBlurSigma: 20,
    lightboxScrim: Color(0xDB04080C), // 浅色待真机验，M3 记录
    glowA: Color(0x33FF6AA8), // rgba(255, 106, 168, 0.2)
    glowB: Color(0x249660FF), // rgba(150, 96, 255, 0.14)
    surface: Color(0xEBFFFFFF), // 沿用浅色薄荷
    surface2: Color(0xFFFFFFFF),
    surface3: Color(0xFFFFFFFF),
    scrim: Color(0x4D1C2A38),
    scrimStrong: Color(0x611C2A38),
    pastOpacity: 0.82,
    pastOpacityPage: 0.8,
    scrollThumb: Color(0x4212263A),
    frostSheenA: Color(0x8CFFFFFF),
    frostSheenB: Color(0x29FFFFFF),
    frostBloom: Color(0x99FFFFFF),
    frostTint: Color(0x1FEC4F92), // rgb(236 79 146 / 0.12)
    frostCoverOpacity: 0.45,
    frostCoverBlur: 44,
    frostCoverSat: 1.4,
    frostCoverBrightness: 1.35,
    frostVeilA: Color(0x33FFFFFF),
    frostVeilB: Color(0x10FFFFFF),
    vinylLow: Color(0x0FFFFFFF),
    vinylMid: Color(0x17FFFFFF),
    vinylHi: Color(0x29FFFFFF),
    vinylLine: Color(0x29FFFFFF),
    accentSoftHover: Color(0x38EC4F92), // rgb(236 79 146 / 0.22)
  );

  /// 浅色蓝：app.css:241-251 只覆写 glow / bg-grad / 强调色组，其余沿用浅色薄荷。
  static const AppTokens lightBlue = AppTokens(
    name: 'blue-light',
    bg: Color(0xFFDFE8F2), // --bg 未覆写，沿用浅色薄荷
    bgGradA: Color(0xFFDBE8FB), // #dbe8fb
    bgGradB: Color(0xFFE3EEF7), // #e3eef7
    text: Color(0xFF16202B), // 沿用浅色薄荷
    textDim: Color(0xFF4B5E70),
    textFaint: Color(0xFF5D7083),
    accent: Color(0xFF3B7CF6), // #3b7cf6
    accentLight: Color(0xFF1B4FAE), // #1b4fae
    // 浅色蓝同样没有 --accent-ink 覆写行，沿用 :root 的 #04231b。
    accentInk: Color(0xFF04231B),
    accentRgb: (59, 124, 246), // 59 124 246
    danger: Color(0xFFC9253F), // 浅色危险态翻转沿用浅色薄荷
    dangerInk: Color(0xFF9D1B30),
    toastBg: Color(0xFFFFFFFF),
    toastErrorBg: Color(0xFFFFF1F3),
    border: Color(0x1F12263A), // 沿用浅色薄荷
    borderStrong: Color(0x3312263A),
    cardA: Color(0xD6FFFFFF),
    cardB: Color(0xE6F8FBFE),
    panelA: Color(0xFFFFFFFF),
    panelB: Color(0xFFF7FAFD),
    sheetA: Color(0xFFFFFFFF),
    sheetB: Color(0xFFF6F9FC),
    barA: Color(0xE0FFFFFF),
    barB: Color(0xF7F7FAFD),
    progressTrack: Color(0x1C12263A),
    sliderThumb: Color(0xFFFFFFFF),
    tint1: Color(0x0B12263A),
    accentSoft: Color(0x1F3B7CF6), // rgba(59, 124, 246, 0.12)
    accentLine: Color(0x573B7CF6), // rgba(59, 124, 246, 0.34)
    dangerSoft: Color(0x17C9253F),
    dangerLine: Color(0x4DC9253F),
    shadowCard: <BoxShadow>[
      BoxShadow(
        color: Color(0x52182A3C),
        offset: Offset(0, 22),
        blurRadius: 46,
        spreadRadius: -24,
      ),
    ],
    shadowBar: <BoxShadow>[
      BoxShadow(
        color: Color(0x47182A3C),
        offset: Offset(0, -12),
        blurRadius: 36,
        spreadRadius: -22,
      ),
    ],
    glassBlurSigma: 20,
    lightboxScrim: Color(0xDB04080C), // 浅色待真机验，M3 记录
    glowA: Color(0x334D8DFF), // rgba(77, 141, 255, 0.2)
    glowB: Color(0x2438BDF8), // rgba(56, 189, 248, 0.14)
    surface: Color(0xEBFFFFFF), // 沿用浅色薄荷
    surface2: Color(0xFFFFFFFF),
    surface3: Color(0xFFFFFFFF),
    scrim: Color(0x4D1C2A38),
    scrimStrong: Color(0x611C2A38),
    pastOpacity: 0.82,
    pastOpacityPage: 0.8,
    scrollThumb: Color(0x4212263A),
    frostSheenA: Color(0x8CFFFFFF),
    frostSheenB: Color(0x29FFFFFF),
    frostBloom: Color(0x99FFFFFF),
    frostTint: Color(0x1F3B7CF6), // rgb(59 124 246 / 0.12)
    frostCoverOpacity: 0.45,
    frostCoverBlur: 44,
    frostCoverSat: 1.4,
    frostCoverBrightness: 1.35,
    frostVeilA: Color(0x33FFFFFF),
    frostVeilB: Color(0x10FFFFFF),
    vinylLow: Color(0x0FFFFFFF),
    vinylMid: Color(0x17FFFFFF),
    vinylHi: Color(0x29FFFFFF),
    vinylLine: Color(0x29FFFFFF),
    accentSoftHover: Color(0x383B7CF6), // rgb(59 124 246 / 0.22)
  );

  /// 两维换肤解析器：`(mode, color)` → token 实例。
  ///
  /// `mode` 是 `'light' | 'dark'`（system 已在 ThemeState 里解析成具体明暗，
  /// 不进这张表），`color` 是 `'mint' | 'pink' | 'blue'`；未知值回落到
  /// 各维的缺省（深色薄荷），与 theme.tsx 的解析语义一致。
  static AppTokens resolve(String mode, String color) {
    switch (mode) {
      case 'light':
        switch (color) {
          case 'pink':
            return lightPink;
          case 'blue':
            return lightBlue;
          default:
            return lightMint;
        }
      default:
        switch (color) {
          case 'pink':
            return darkPink;
          case 'blue':
            return darkBlue;
          default:
            return dark;
        }
    }
  }

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
