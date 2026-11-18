// test/ui/lyric_color_button_test.dart
//
// 「T」面板（同步 React 新版 `LyricColorButton.tsx`）：三排 —— 8 颗色板 /
// 字号滑杆（70%~150%，步长 5，点百分比回 100%）/ 9 颗字体（每颗用它自己的字
// 渲染名字）。三项都落进 ThemeState 并写 prefs；选颜色**不**自动收起面板。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/core/storage_keys.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/lyric_fonts.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/lyric_color_button.dart';
import 'package:provider/provider.dart';

/// 装配：provider 放在 MaterialApp **外面** —— 面板插进 Overlay，而 Overlay 在
/// Navigator 里、比 Scaffold 高（与 sleep_timer_button_test 同一套理由）。
Widget _wrap(ThemeState theme, Widget child) =>
    ChangeNotifierProvider<ThemeState>.value(
      value: theme,
      child: MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// 面板里那颗百分比读数（同时也是「回默认」按钮）。
String _percent(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('lyric-scale-reset')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Future<({ThemeState theme, AppPrefs prefs})> _pump(WidgetTester tester) async {
  final prefs = AppPrefs.inMemory();
  final theme = await ThemeState.load(prefs, platformDark: () => false);
  addTearDown(theme.dispose);
  await tester.pumpWidget(_wrap(theme, const LyricColorButton()));
  await tester.pump();
  return (theme: theme, prefs: prefs);
}

void main() {
  test('字体清单 9 款：id 与 React 版一字不差，默认那款跟随界面字体', () {
    expect(kLyricFonts.length, 9);
    expect(kLyricFonts.first.id, 'default');
    expect(kLyricFonts.first.isDefault, isTrue);
    expect(findLyricFont('smiley').family, 'LyricSmiley');
    expect(findLyricFont('wenkai').family, 'LyricWenKai');
    // 不认识的 id 兜回默认（存下来的旧 id 不该把面板卡在空态）
    expect(findLyricFont('gone').id, 'default');
    expect(findLyricFont(null).id, 'default');
  });

  testWidgets('点开面板：8 颗色板 + 字号滑杆 + 9 颗字体 + 读数 100%', (
    tester,
  ) async {
    final h = await _pump(tester);
    final theme = h.theme;

    expect(find.byKey(const Key('lyric-scale-slider')), findsNothing);
    await tester.tap(find.text('T'));
    await tester.pump();

    // 色板：8 颗，顺序里的第一颗与最后一颗都在
    for (final preset in kLyricColorPresets) {
      expect(find.byTooltip(preset.name), findsOneWidget);
    }
    expect(kLyricColorPresets.length, 8);

    // 字号：滑杆 + 默认读数
    expect(find.byKey(const Key('lyric-scale-slider')), findsOneWidget);
    expect(theme.lyricScale, 100);
    expect(_percent(tester), '100%');

    // 字体：9 颗，每颗的按钮都在（名字用它自己的字体渲染）
    for (final font in kLyricFonts) {
      expect(find.byKey(Key('lyric-font-${font.id}')), findsOneWidget);
      expect(
        find.byTooltip('${font.name} · ${font.hint}'),
        findsOneWidget,
      );
    }
  });

  testWidgets('拖字号滑杆到两端：70% / 150%，点百分比回 100% 并写 prefs', (
    tester,
  ) async {
    final h = await _pump(tester);
    final theme = h.theme;
    await tester.tap(find.text('T'));
    await tester.pump();

    // 一路拖到右端 → 150%（夹到上限）
    await tester.drag(
      find.byKey(const Key('lyric-scale-slider')),
      const Offset(400, 0),
    );
    await tester.pump();
    expect(theme.lyricScale, kLyricScaleMax);
    expect(_percent(tester), '150%');
    expect(await h.prefs.readString(StorageKeys.lyricScale), '150');

    // 一路拖到左端 → 70%（夹到下限）
    await tester.drag(
      find.byKey(const Key('lyric-scale-slider')),
      const Offset(-400, 0),
    );
    await tester.pump();
    expect(theme.lyricScale, kLyricScaleMin);
    expect(_percent(tester), '70%');

    // 百分比读数本身就是「回默认」按钮
    await tester.tap(find.byKey(const Key('lyric-scale-reset')));
    await tester.pump();
    expect(theme.lyricScale, kLyricScaleDefault);
    expect(_percent(tester), '100%');
    expect(await h.prefs.readString(StorageKeys.lyricScale), '100');
  });

  testWidgets('选字体：状态与 prefs 一起换，选中态落在那一颗上', (tester) async {
    final h = await _pump(tester);
    final theme = h.theme;
    await tester.tap(find.text('T'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('lyric-font-wenkai')));
    await tester.pump();

    expect(theme.lyricFontId, 'wenkai');
    expect(theme.lyricFont.name, '霞鹜文楷');
    expect(await h.prefs.readString(StorageKeys.lyricFont), 'wenkai');

    // 再选回「默认」：状态回到跟随界面字体
    await tester.tap(find.byKey(const Key('lyric-font-default')));
    await tester.pump();
    expect(theme.lyricFont.isDefault, isTrue);
  });

  testWidgets('选颜色：面板不收起（接着调字号与字体），prefs 记下颜色', (
    tester,
  ) async {
    final h = await _pump(tester);
    final theme = h.theme;
    await tester.tap(find.text('T'));
    await tester.pump();

    await tester.tap(find.byTooltip('玫红'));
    await tester.pump();

    expect(theme.lyricColor, '#ff8fc7');
    expect(await h.prefs.readString(StorageKeys.lyricColor), '#ff8fc7');
    // 面板还开着
    expect(find.byKey(const Key('lyric-scale-slider')), findsOneWidget);
  });
}
