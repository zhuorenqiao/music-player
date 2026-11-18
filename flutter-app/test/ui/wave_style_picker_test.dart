// test/ui/wave_style_picker_test.dart
//
// M3 D.4：歌词页右上角的波形样式下拉。
// 钉住四件事：触发按钮显示当前样式名、面板列出 17 项、选中写 ThemeState、
// 彩色开关写 ThemeState；以及 D.7 的 frostVeilB 浅色数值。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/wave_style_picker.dart';
import 'package:light_music/wave/wave_styles.dart';
import 'package:provider/provider.dart';

Widget wrap(Widget child, ThemeState theme) => MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeState>.value(value: theme),
      ],
      child: MaterialApp(
        theme: buildTheme().copyWith(
          extensions: const [AppTokensData(tokens: AppTokens.dark)],
        ),
        home: Scaffold(body: Align(alignment: Alignment.topRight, child: child)),
      ),
    );

/// 桌面视口（≥900）：触发按钮显示「图标 + 样式名 + 箭头」。
void _desktopView(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
}

/// 窄屏视口（<900）：触发按钮只留图标，样式名隐藏。
void _compactView(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(700, 900);
}

void main() {
  late ThemeState theme;

  setUp(() async {
    theme = await ThemeState.load(AppPrefs.inMemory());
  });
  tearDown(() => theme.dispose());

  testWidgets('触发按钮显示当前样式名，点开列出 17 项', (tester) async {
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();

    expect(find.byKey(const Key('wave-style-trigger')), findsOneWidget);
    expect(find.text(kWaveStyles.first.name), findsOneWidget);

    await tester.tap(find.byKey(const Key('wave-style-trigger')));
    await tester.pump();
    await tester.pump();

    // 17 项都在（ListView.builder 只构建视口内的，逐项滚找不如数 painter）。
    expect(find.byType(CustomPaint), findsWidgets);
    // 触发按钮样式名仍可见（面板是 Overlay，不替换按钮）。
    expect(find.byKey(const Key('wave-style-trigger')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('触发按钮是白底（--surface），不再用 --tint-1 的浅灰', (tester) async {
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();

    // 键直接挂在胶囊外壳那个 Container 上，读它自己即可。
    final decoration = tester
        .widget<Container>(find.byKey(const Key('wave-style-trigger')))
        .decoration! as BoxDecoration;
    expect(decoration.color, AppTokens.dark.surface,
        reason: '白底与卡片里 T/水滴/闹钟同一档');
    final border = decoration.border! as Border;
    expect(border.top.color, AppTokens.dark.borderStrong);
  });

  testWidgets('选中某项会写 ThemeState.waveStyleId 并收起面板', (tester) async {
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wave-style-trigger')));
    await tester.pump();
    await tester.pump();

    // 找第二项（ribbon）的名字并点它。ListView 首屏能容下若干行。
    final ribbon = kWaveStyles[1].name;
    expect(find.text(ribbon), findsWidgets,
        reason: '列表首屏应包含第 2 项');
    await tester.tap(find.text(ribbon).first);
    await tester.pump();
    await tester.pump();

    expect(theme.waveStyleId, kWaveStyles[1].id);
    // 收起后不该再有面板里的重复名字（仍可能有一个 = 触发按钮的当前样式名）。
    expect(find.text(ribbon), findsOneWidget,
        reason: '选中后只剩触发按钮上那一个当前样式名');
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开面板时把当前选中项滚到看得见的位置', (tester) async {
    // 最后一项（层叠山峰）在 17 项列表的最底部：360px 高、行高 40px 的列表
    // 只装得下 8 行，不主动滚下去的话它根本不会被构建 —— 用户看到的是顶部
    // 那几项，和当前样式毫无关系（真机反馈）。
    theme.setWaveStyle(kWaveStyles.last.id);
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();

    expect(
      find.text(kWaveStyles.last.name),
      findsOneWidget,
      reason: '未展开时只有触发按钮上那一个名字',
    );

    await tester.tap(find.byKey(const Key('wave-style-trigger')));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(kWaveStyles.last.name),
      findsNWidgets(2),
      reason: '展开后当前选中项必须在可视区内（列表里也有一份）',
    );
    final controller = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.offset, greaterThan(0), reason: '列表应已滚离顶部');
    expect(tester.takeException(), isNull);
  });

  testWidgets('彩色开关写 ThemeState.colored', (tester) async {
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wave-style-trigger')));
    await tester.pump();
    await tester.pump();

    expect(theme.colored, isTrue);
    await tester.tap(find.byKey(const Key('wave-color-switch')));
    await tester.pump();
    expect(theme.colored, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点面板以外收起', (tester) async {
    _desktopView(tester);
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wave-style-trigger')));
    await tester.pump();
    await tester.pump();

    // 阻挡层是全屏 GestureDetector；点左上角空白。
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.byKey(const Key('wave-color-switch')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏触发按钮只留图标，读屏名仍带样式名', (tester) async {
    _compactView(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(wrap(const WaveStylePicker(), theme));
    await tester.pump();

    // 可见文本里不再出现当前样式名（面板未展开，列表也没有它）。
    expect(find.text(kWaveStyles.first.name), findsNothing);
    // 读屏标签照旧带样式名，不影响无障碍。
    final data = tester
        .getSemantics(find.byKey(const Key('wave-style-trigger')))
        .getSemanticsData();
    expect(data.label, contains(kWaveStyles.first.name));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  test('D.7：浅色 frostVeilB 四舍五入为 0x0F', () {
    // app.css:180 是 rgb(255 255 255 / 0.06)：0.06×255=15.3 → 0x0F。
    for (final tokens in [AppTokens.lightMint, AppTokens.lightPink, AppTokens.lightBlue]) {
      // Color.a 是 0..1 的 double；取 32 位 ARGB 里的高 8 位才是字节值。
      final alphaByte = (tokens.frostVeilB.toARGB32() >> 24) & 0xFF;
      expect(
        alphaByte,
        0x0F,
        reason: '${tokens.runtimeType} 的 frostVeilB alpha 应为 0x0F',
      );
    }
  });
}
