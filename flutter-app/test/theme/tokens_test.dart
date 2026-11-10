// 设计 token 与断点：值全部逐字取自 src/styles/app.css 的 :root / @media。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/breakpoints.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';

void main() {
  test('深色薄荷的实际取值逐字对齐 app.css :root', () {
    const tokens = AppTokens.dark;
    expect(tokens.bg, const Color(0xFF080B10));
    expect(tokens.text, const Color(0xFFE9F1F7));
    expect(tokens.textDim, const Color(0xFF8B9CAB));
    expect(tokens.textFaint, const Color(0xFF66788C));
    expect(tokens.accent, const Color(0xFF2EE6A8));
    expect(tokens.accentLight, const Color(0xFFB9FFE9));
    expect(tokens.accentInk, const Color(0xFF04231B));
    expect(tokens.danger, const Color(0xFFFF6B81));
    expect(tokens.dangerInk, const Color(0xFFFFC9D1)); // #ffc9d1
    expect(tokens.bgGradA, const Color(0xFF0B1C1A)); // #0b1c1a
    expect(tokens.bgGradB, const Color(0xFF070A10)); // #070a10
    expect(tokens.panelA, const Color(0xFF121924)); // #121924
    expect(tokens.panelB, const Color(0xFF0A0E14)); // #0a0e14
    expect(tokens.sheetA, const Color(0xFF0D1219)); // #0d1219
    expect(tokens.sheetB, const Color(0xFF090C11)); // #090c11
    expect(tokens.name, 'mint-dark');
  });

  test('带透明度的强调色是写死的常量，透明度与 accentRgb 对得上', () {
    const tokens = AppTokens.dark;
    // rgba(46, 230, 168, 0.14) / rgba(46, 230, 168, 0.32)
    expect(tokens.accentSoft, const Color(0x242EE6A8));
    expect(tokens.accentLine, const Color(0x522EE6A8));
    expect(tokens.accentRgb, (46, 230, 168));
    expect(tokens.accentSoft.a, closeTo(0.14, 0.005));
    expect(tokens.accentLine.a, closeTo(0.32, 0.005));
  });

  test('边框 / 危险 / 提示 / 面板层同样逐字节对齐', () {
    const tokens = AppTokens.dark;
    expect(tokens.border, const Color(0x12FFFFFF)); // rgba(255,255,255,0.07)
    expect(tokens.borderStrong, const Color(0x29FFFFFF)); // rgba(255,255,255,0.16)
    expect(tokens.toastBg, const Color(0xF2121820)); // rgba(18,24,32,0.95)
    expect(tokens.toastErrorBg, const Color(0xF5301319)); // rgba(48,19,25,0.96)
    expect(tokens.dangerSoft, const Color(0x1FFF6B81)); // rgba(255,107,129,0.12)
    expect(tokens.dangerLine, const Color(0x5CFF6B81)); // rgba(255,107,129,0.36)
    expect(tokens.dangerSoft.a, closeTo(0.12, 0.005));
    expect(tokens.dangerLine.a, closeTo(0.36, 0.005));
    // 卡面 / 进度轨道 / 底栏：0.07×255=17.85→0x12、0.015×255=3.8→0x04、
    // 0.11×255=28.05→0x1C、0.88×255=224.4→0xE0、0.97×255=247.35→0xF7。
    expect(tokens.cardA, const Color(0x12FFFFFF)); // rgba(255,255,255,0.07)
    expect(tokens.cardB, const Color(0x04FFFFFF)); // rgba(255,255,255,0.015)
    expect(tokens.progressTrack, const Color(0x1CFFFFFF)); // rgba(255,255,255,0.11)
    expect(tokens.barA, const Color(0xE00E131A)); // rgba(14,19,26,0.88)
    expect(tokens.barB, const Color(0xF7090C11)); // rgba(9,12,17,0.97)
    // 滑杆圆点的白：app.css 里是字面量 `background: #ffffff`
    // （`.progress__input::-webkit-slider-thumb` / `.volume__input::-…`），
    // 从前 ui/progress_slider.dart 直接写 Colors.white —— ui/ 内不许有颜色字面量，
    // 换成 token 字段后 M3 加浅色那套才不用回来改界面（终审 minor 1）。
    expect(tokens.sliderThumb, const Color(0xFFFFFFFF));
    // 阴影与毛玻璃：颜色 / 位移 / 模糊 / 扩散逐项对齐 app.css。
    expect(tokens.shadowCard, hasLength(1));
    expect(tokens.shadowCard.single.color, const Color(0xF2000000));
    expect(tokens.shadowCard.single.offset, const Offset(0, 24));
    expect(tokens.shadowCard.single.blurRadius, 60);
    expect(tokens.shadowCard.single.spreadRadius, -34);
    expect(tokens.shadowBar, hasLength(1));
    expect(tokens.shadowBar.single.color, const Color(0xF2000000));
    expect(tokens.shadowBar.single.offset, const Offset(0, -14));
    expect(tokens.shadowBar.single.blurRadius, 44);
    expect(tokens.shadowBar.single.spreadRadius, -24);
    expect(tokens.glassBlurSigma, 20); // backdrop-filter: blur(20px)
  });

  test('断点阈值：900 含、480 不含', () {
    expect(Breaks.desktop, 900);
    expect(Breaks.compact, 480);
    expect(isDesktop(900), isTrue);
    expect(isDesktop(899.9), isFalse);
    expect(isUltraCompact(479), isTrue);
    expect(isUltraCompact(480), isFalse);
  });

  test('封面尺寸三档 clamp', () {
    // <900：clamp(108, 24vh, 150)
    expect(kCoverSize(360, viewportHeight: 300), 108);
    expect(kCoverSize(360, viewportHeight: 500), closeTo(120, 0.01));
    expect(kCoverSize(360, viewportHeight: 900), 150);
    // ≥900：clamp(166, 18vw, 232)
    expect(kCoverSize(900), 166);
    expect(kCoverSize(1000), closeTo(180, 0.01));
    // ≥1180：固定 248
    expect(kCoverSize(1180), 248);
    // 桌面端再受 min(基准值, 46vh, 340px) 夹紧：视口矮时按 46vh 收。
    expect(kCoverSize(1300, viewportHeight: 400), 184); // min(248, 184, 340)
    expect(kCoverSize(1300, viewportHeight: 900), 248); // min(248, 414, 340)
  });

  test('主题装配把 token 挂到 ThemeExtension 上，滑杆 / 分隔线 / 去水波纹都接上', () {
    final theme = buildTheme();
    expect(theme.scaffoldBackgroundColor, AppTokens.dark.bg);
    expect(theme.dividerColor, AppTokens.dark.border);
    expect(theme.splashFactory, NoSplash.splashFactory);
    expect(theme.sliderTheme.activeTrackColor, AppTokens.dark.accent);
    expect(theme.sliderTheme.inactiveTrackColor, AppTokens.dark.progressTrack);
    // Material 滑杆的圆点也从 token 取，不留 Colors.white（终审 minor 1）
    expect(theme.sliderTheme.thumbColor, AppTokens.dark.sliderThumb);
    expect(theme.textTheme.bodyMedium!.color, AppTokens.dark.text);
    expect(theme.extension<AppTokensData>()!.tokens.accentRgb, (46, 230, 168));
  });

  testWidgets('context.tokens 能取到同一套 token', (tester) async {
    late AppTokens seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) {
            seen = context.tokens;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen, AppTokens.dark);
  });

  test('布局常量与 app.css 的圆角 / 触控尺寸一致', () {
    expect(kButtonSize, 40);
    expect(kTouchTarget, 44);
    expect(kRadiusXl, 24);
    expect(kRadiusLg, 16);
    expect(kRadiusMd, 12);
    expect(kTrackThumb, 44);
  });

  // ---- M3 Task 3：6 组 token 实例与扩字段 ----

  test('M3 扩字段在深色薄荷上的默认值逐字对齐 app.css :10-122', () {
    const tokens = AppTokens.dark;
    // 光晕（app.css:13-14）
    expect(tokens.glowA, const Color(0x292EE6A8)); // rgba(46,230,168,0.16)
    expect(tokens.glowB, const Color(0x216084FF)); // rgba(96,132,255,0.13)
    // 选中态面（app.css:16-18）
    expect(tokens.surface, const Color(0x0AFFFFFF)); // = var(--tint-1)
    expect(tokens.surface2, const Color(0x13FFFFFF)); // rgba(255,255,255,0.075)
    expect(tokens.surface3, const Color(0x1CFFFFFF)); // = var(--tint-3)
    // 遮罩（app.css:79-80）
    expect(tokens.scrim, const Color(0xA804080C)); // rgba(4,8,12,0.66)
    expect(tokens.scrimStrong, const Color(0xBD04080C)); // rgba(4,8,12,0.74)
    // 已唱行透明度：CSS 缺省档（app.css:1940/:3057 的 fallback）
    expect(tokens.pastOpacity, 0.62);
    expect(tokens.pastOpacityPage, 0.5);
    // 滚动条滑块（app.css:43）
    expect(tokens.scrollThumb, const Color(0x47FFFFFF)); // rgba(255,255,255,0.28)
    // 磨砂膜四层（app.css:64-67）
    expect(tokens.frostSheenA, const Color(0x1AFFFFFF)); // rgb(255 255 255/0.1)
    expect(tokens.frostSheenB, const Color(0x08FFFFFF)); // rgb(255 255 255/0.03)
    expect(tokens.frostBloom, const Color(0x2EFFFFFF)); // rgb(255 255 255/0.18)
    expect(tokens.frostTint, const Color(0x1A2EE6A8)); // rgb(46 230 168/0.1)
    // 玻璃后封面垫（app.css:69-70）；窄屏 blur 30 由消费方换算
    expect(tokens.frostCoverOpacity, 0.5);
    expect(tokens.frostCoverBlur, 44);
    expect(tokens.frostCoverSat, 1.6);
    expect(tokens.frostCoverBrightness, 0.7);
    // 薄纱渐变（app.css:71）
    expect(tokens.frostVeilA, const Color(0x52080A0F)); // rgb(8 10 15/0.32)
    expect(tokens.frostVeilB, const Color(0x24080A0F)); // rgb(8 10 15/0.14)
    // 黑胶四色，深浅同值（app.css:85-88）
    expect(tokens.vinylLow, const Color(0x0FFFFFFF)); // rgba(255,255,255,0.06)
    expect(tokens.vinylMid, const Color(0x17FFFFFF)); // rgba(255,255,255,0.09)
    expect(tokens.vinylHi, const Color(0x29FFFFFF)); // rgba(255,255,255,0.16)
    expect(tokens.vinylLine, const Color(0x29FFFFFF)); // rgba(255,255,255,0.16)
    // btn--soft hover 的 rgb(accent/0.22)（app.css:929）
    expect(tokens.accentSoftHover, const Color(0x382EE6A8));
  });

  test('6 组实例的关键色逐字对齐 app.css', () {
    const darkMint = AppTokens.dark;
    const darkPink = AppTokens.darkPink;
    const darkBlue = AppTokens.darkBlue;
    const lightMint = AppTokens.lightMint;
    const lightPink = AppTokens.lightPink;
    const lightBlue = AppTokens.lightBlue;

    // 深色粉（app.css:257-294）
    expect(darkPink.name, 'pink-dark');
    expect(darkPink.bg, const Color(0xFF100A11)); // #100a11
    expect(darkPink.accent, const Color(0xFFFF6AA8)); // #ff6aa8
    expect(darkPink.accentLight, const Color(0xFFFFD2E4)); // #ffd2e4
    expect(darkPink.text, const Color(0xFFF8EDF4)); // #f8edf4

    // 深色蓝（app.css:299-336）
    expect(darkBlue.name, 'blue-dark');
    expect(darkBlue.bg, const Color(0xFF070D17)); // #070d17
    expect(darkBlue.accent, const Color(0xFF4D8DFF)); // #4d8dff
    expect(darkBlue.accentLight, const Color(0xFFD3E4FF)); // #d3e4ff
    expect(darkBlue.text, const Color(0xFFE9F1FB)); // #e9f1fb

    // 浅色薄荷（app.css:129-214）
    expect(lightMint.name, 'mint-light');
    expect(lightMint.bg, const Color(0xFFDFE8F2)); // #dfe8f2
    expect(lightMint.accent, const Color(0xFF12B98C)); // #12b98c
    expect(lightMint.accentLight, const Color(0xFF0A7A5D)); // #0a7a5d
    expect(lightMint.text, const Color(0xFF16202B)); // #16202b

    // 浅色粉（app.css:229-239，只覆写强调色组 + bg-grad + glow）
    expect(lightPink.name, 'pink-light');
    expect(lightPink.bg, const Color(0xFFDFE8F2)); // --bg 未覆写
    expect(lightPink.accent, const Color(0xFFEC4F92)); // #ec4f92
    expect(lightPink.accentLight, const Color(0xFFA3175A)); // #a3175a
    expect(lightPink.text, const Color(0xFF16202B)); // 沿用浅色薄荷

    // 浅色蓝（app.css:241-251）
    expect(lightBlue.name, 'blue-light');
    expect(lightBlue.bg, const Color(0xFFDFE8F2)); // --bg 未覆写
    expect(lightBlue.accent, const Color(0xFF3B7CF6)); // #3b7cf6
    expect(lightBlue.accentLight, const Color(0xFF1B4FAE)); // #1b4fae
    expect(lightBlue.text, const Color(0xFF16202B)); // 沿用浅色薄荷

    // 深色薄荷仍是原值
    expect(darkMint.name, 'mint-dark');
    expect(darkMint.bg, const Color(0xFF080B10));
    expect(darkMint.accent, const Color(0xFF2EE6A8));
    expect(darkMint.accentLight, const Color(0xFFB9FFE9));
    expect(darkMint.text, const Color(0xFFE9F1F7));

    // 深色明暗推导：浅色三套 light、深色三套 dark
    expect(darkMint.brightness, Brightness.dark);
    expect(darkPink.brightness, Brightness.dark);
    expect(darkBlue.brightness, Brightness.dark);
    expect(lightMint.brightness, Brightness.light);
    expect(lightPink.brightness, Brightness.light);
    expect(lightBlue.brightness, Brightness.light);
  });

  test('pastOpacity 两档：深 0.62/0.5，浅 0.82/0.8', () {
    // 深色档（CSS 缺省 fallback，app.css:1940/:3057）
    expect(AppTokens.dark.pastOpacity, 0.62);
    expect(AppTokens.dark.pastOpacityPage, 0.5);
    expect(AppTokens.darkPink.pastOpacity, 0.62);
    expect(AppTokens.darkPink.pastOpacityPage, 0.5);
    expect(AppTokens.darkBlue.pastOpacity, 0.62);
    expect(AppTokens.darkBlue.pastOpacityPage, 0.5);
    // 浅色档（app.css:196-197）
    expect(AppTokens.lightMint.pastOpacity, 0.82);
    expect(AppTokens.lightMint.pastOpacityPage, 0.8);
    expect(AppTokens.lightPink.pastOpacity, 0.82);
    expect(AppTokens.lightPink.pastOpacityPage, 0.8);
    expect(AppTokens.lightBlue.pastOpacity, 0.82);
    expect(AppTokens.lightBlue.pastOpacityPage, 0.8);
  });

  test('浅色薄荷的危险态与 toast 翻转（app.css:200-213）', () {
    const tokens = AppTokens.lightMint;
    expect(tokens.danger, const Color(0xFFC9253F)); // #c9253f
    expect(tokens.dangerInk, const Color(0xFF9D1B30)); // #9d1b30
    expect(tokens.dangerSoft, const Color(0x17C9253F)); // rgba(201,37,63,0.09)
    expect(tokens.dangerLine, const Color(0x4DC9253F)); // rgba(201,37,63,0.3)
    expect(tokens.toastBg, const Color(0xFFFFFFFF)); // #ffffff
    expect(tokens.toastErrorBg, const Color(0xFFFFF1F3)); // #fff1f3
  });

  test('深色蓝的 accentLine 是浅靛蓝（app.css:321 逐字），不是 accent 同色', () {
    expect(AppTokens.darkBlue.accentLine, const Color(0x578DB4FF));
    // rgba(141, 180, 255, 0.34)：0.34 × 255 = 86.7 → 0x57
    expect(AppTokens.darkBlue.accentLine.a, closeTo(0.34, 0.005));
    // 对照：accentSoft 才是 accent 同色的 0.16
    expect(AppTokens.darkBlue.accentSoft, const Color(0x294D8DFF));
  });

  test('resolve() 两维矩阵返回对应实例', () {
    expect(identical(AppTokens.resolve('dark', 'mint'), AppTokens.dark), isTrue);
    expect(identical(AppTokens.resolve('dark', 'pink'), AppTokens.darkPink), isTrue);
    expect(identical(AppTokens.resolve('dark', 'blue'), AppTokens.darkBlue), isTrue);
    expect(identical(AppTokens.resolve('light', 'mint'), AppTokens.lightMint), isTrue);
    expect(identical(AppTokens.resolve('light', 'pink'), AppTokens.lightPink), isTrue);
    expect(identical(AppTokens.resolve('light', 'blue'), AppTokens.lightBlue), isTrue);
    // 未知值回落到各维缺省（深色薄荷）
    expect(identical(AppTokens.resolve('system', 'mint'), AppTokens.dark), isTrue);
    expect(identical(AppTokens.resolve('dark', 'xxx'), AppTokens.dark), isTrue);
  });
}
