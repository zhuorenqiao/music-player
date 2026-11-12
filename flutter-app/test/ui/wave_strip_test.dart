// test/ui/wave_strip_test.dart
//
// 频谱条的 ticker 生命周期回归。
//
// 真实崩溃现场（真机 Windows 调试运行）：播放卡合成后整屏红，首发异常是
//   A ticker was started twice.
//   The affected ticker was: Ticker(created by _WaveStripState)
// 根因：didChangeDependencies 里无条件 `_ticker.start()`，而它在挂载之后
// 还会因依赖变化再跑一次（外层布局 / 主题 / PlayerCard 重建都会）；
// didUpdateWidget 那条路径本来就有 `if (!_ticker.isActive)` 守卫，唯独这里漏了。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/wave_strip.dart';

Track _track() => Track(
  id: 't1',
  src: '/t1.flac',
  title: '十年',
  artist: '陈奕迅',
  duration: 226,
);

/// 稳定的壳：只换 [child] 与 MediaQuery 数据，ThemeState 始终同一个实例
/// （否则每次 pumpWidget 都会重建状态，测不到「同一实例上依赖变化」）。
Widget shell({
  required ThemeState theme,
  required Widget child,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  theme: buildTheme().copyWith(
    extensions: const [AppTokensData(tokens: AppTokens.dark)],
  ),
  home: ChangeNotifierProvider<ThemeState>.value(
    value: theme,
    child: MediaQuery(
      data: MediaQueryData(
        disableAnimations: false,
        textScaler: textScaler,
      ),
      child: Scaffold(body: SizedBox(width: 400, child: child)),
    ),
  ),
);

Widget strip({required bool playing}) => WaveStrip(
  frameTable: null,
  track: _track(),
  playing: playing,
  positionSeconds: 0,
);

void main() {
  late ThemeState theme;

  setUp(() async {
    theme = await ThemeState.load(AppPrefs.inMemory());
  });

  tearDown(() => theme.dispose());

  testWidgets('播放中重复触发 didChangeDependencies 不抛「started twice」', (tester) async {
    // 首次挂载：ticker 起来。
    await tester.pumpWidget(shell(theme: theme, child: strip(playing: true)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: '首次挂载不该抛');

    // 只改 textScaler：MediaQuery 依赖变化 ⇒ didChangeDependencies 再跑一次。
    // 旧实现在这里无条件 start()，ticker 已 active ⇒ 抛「started twice」。
    await tester.pumpWidget(
      shell(
        theme: theme,
        textScaler: const TextScaler.linear(1.1),
        child: strip(playing: true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      tester.takeException(),
      isNull,
      reason: 'didChangeDependencies 重复调用不该重复 start ticker',
    );
  });

  testWidgets('暂停 → 播放 → 暂停反复切换不抛', (tester) async {
    for (final playing in [false, true, false, true, false]) {
      await tester.pumpWidget(shell(theme: theme, child: strip(playing: playing)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: 'playing=$playing');
    }
  });

  testWidgets('播放中卸载不抛（ticker 正确 dispose）', (tester) async {
    await tester.pumpWidget(shell(theme: theme, child: strip(playing: true)));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
