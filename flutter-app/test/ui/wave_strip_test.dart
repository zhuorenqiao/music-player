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

import 'dart:typed_data';

import 'package:light_music/core/app_prefs.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';

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

  // 「音谱图左右两边没有淡出的效果」：CSS `.lyrics-page__wave` 用
  // `mask-image: linear-gradient(90deg, transparent 0, #000 10%, #000 90%,
  // transparent 100%)`（app.css:2492-2493）把两端渐隐。这里守那层蒙版还在，
  // 且确实是包在频谱画布外面的 dstIn 蒙版。
  testWidgets('两端淡出：画布外面套着 dstIn 蒙版', (tester) async {
    await tester.pumpWidget(shell(theme: theme, child: strip(playing: false)));
    await tester.pump();

    final mask = find.byKey(const Key('wave-fade-mask'));
    expect(mask, findsOneWidget, reason: '没有这层蒙版，彩虹条会在栏边硬切断');
    final widget = tester.widget<ShaderMask>(mask);
    expect(widget.blendMode, BlendMode.dstIn, reason: '淡出靠 alpha 乘进去');

    // 蒙版必须在画布之外：祖先链上先遇到 CustomPaint 说明蒙版没套住它。
    expect(
      find.descendant(of: mask, matching: find.byType(CustomPaint)),
      findsWidgets,
    );
  });

  // 「音谱有的时候会消失不见」：离线帧表在数字静音段整帧都是 0.02 的下限，
  // 48px 画布上只有 0.6px —— 看上去就是一片空白。这里守一条显示下限。
  group('静音帧不会画成空白', () {
    test('段值被抬到显示下限，正常响度不受影响', () {
      final bands = Float32List.fromList([0, 0.02, 0.05, 0.06, 0.4, 1.0]);
      applyBandDisplayFloor(bands);
      // Float32List 存的是 float32，0.06 实际是 0.0599999986…
      const eps = 1e-6;
      expect(bands[0], closeTo(kWaveBandDisplayFloor, eps));
      expect(bands[1], closeTo(kWaveBandDisplayFloor, eps),
          reason: '0.02 是数据下限，画出来只有 0.6px');
      expect(bands[2], closeTo(kWaveBandDisplayFloor, eps));
      expect(bands[3], closeTo(kWaveBandDisplayFloor, eps));
      expect(bands[4], closeTo(0.4, eps), reason: '已经比下限高的值一律不动');
      expect(bands[5], closeTo(1.0, eps));
    });

    test('48px 条子上静音帧的柱子 ≥ 2.9px（肉眼可见，不再是一条空条）', () {
      // `_drawSpectrum`：baseline = h - 8，maxAmp = baseline - 8。
      const h = 48.0;
      final bands = Float32List.fromList(List.filled(64, 0.02));
      applyBandDisplayFloor(bands);
      final maxAmp = (h - 8) - 8;
      final px = bands.first * maxAmp;
      expect(px, closeTo(2.88, 0.05));
      expect(px, lessThan(4.5), reason: '只是兜底，别把静音画成中等响度');
    });

    testWidgets('静音帧表 + 暂停：条子照常渲染，尺寸不塌', (tester) async {
      final silent = SpectrumFrameTable(
        sampleRate: 44100,
        frameMs: 50,
        frameCount: 40,
        bands: Uint8List.fromList(List.filled(40 * 64, 5)), // 全部贴 0.02 下限
        wave: Int8List.fromList(List.filled(40 * 128, 0)),
      );
      await tester.pumpWidget(
        shell(
          theme: theme,
          child: WaveStrip(
            frameTable: silent,
            track: _track(),
            playing: false,
            positionSeconds: 1.0,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(WaveStrip)).height,
        kWaveStripHeight,
        reason: '静音不该让条子塌掉',
      );
    });
  });
}
