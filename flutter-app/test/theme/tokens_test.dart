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

  test('边框 / 危险 / 提示层同样逐字节对齐', () {
    const tokens = AppTokens.dark;
    expect(tokens.border, const Color(0x12FFFFFF)); // rgba(255,255,255,0.07)
    expect(tokens.borderStrong, const Color(0x29FFFFFF)); // rgba(255,255,255,0.16)
    expect(tokens.toastBg, const Color(0xF2121820)); // rgba(18,24,32,0.95)
    expect(tokens.toastErrorBg, const Color(0xF5301319)); // rgba(48,19,25,0.96)
    expect(tokens.dangerSoft, const Color(0x1FFF6B81)); // rgba(255,107,129,0.12)
    expect(tokens.dangerLine, const Color(0x5CFF6B81)); // rgba(255,107,129,0.36)
    expect(tokens.dangerSoft.a, closeTo(0.12, 0.005));
    expect(tokens.dangerLine.a, closeTo(0.36, 0.005));
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
    expect(kCoverSize(1300, viewportHeight: 900), 248);
  });

  test('主题装配把 token 挂到 ThemeExtension 上，滑杆 / 分隔线 / 去水波纹都接上', () {
    final theme = buildTheme();
    expect(theme.scaffoldBackgroundColor, AppTokens.dark.bg);
    expect(theme.dividerColor, AppTokens.dark.border);
    expect(theme.splashFactory, NoSplash.splashFactory);
    expect(theme.sliderTheme.activeTrackColor, AppTokens.dark.accent);
    expect(theme.sliderTheme.inactiveTrackColor, AppTokens.dark.progressTrack);
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
}
