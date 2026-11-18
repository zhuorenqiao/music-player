// test/ui/wave_motion_test.dart
//
// 「频谱有时候不律动 / 有时候律动得很假」那一轮回归。
//
// 两条现象各自钉一个结构事实：
//   1. **不律动**：播放器上报进度是事件式的（间隔不固定，几十一百毫秒到一整秒
//      都有）。旧实现「锚点 + 最多外推 0.5s」在上报间隔超过 0.5s 时，多出来的
//      那段是冻结的、新值一来又硬跳。这里用**像素**验证：同一秒内、上报停住的
//      情况下，相隔 200ms 的两帧画面必须不一样（= 没有冻住）。
//   2. **很假**：真实帧表没到之前画的是装饰正弦行波（整条一起扫、约 1Hz），
//      速度必须被压到 [kWaveFallbackPhaseScale] 那么慢。
//
// 为什么不写耗时断言：见 perf_regression_test.dart 的头注释（FakeAsync 测不出
// 光栅化开销），这里钉的是行为而不是速度。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/theme/app_theme.dart';
import 'package:light_music/theme/app_tokens.dart';
import 'package:light_music/theme/theme_state.dart';
import 'package:light_music/ui/wave_strip.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';
import 'package:light_music/wave/wave_signal.dart';
import 'package:provider/provider.dart';

const _shotKey = Key('wave-shot');

SpectrumFrameTable _frameTable() {
  const frames = 240;
  final bands = Uint8List(frames * 64);
  for (var f = 0; f < frames; f++) {
    for (var b = 0; b < 64; b++) {
      final shape = 1 - ((b - 22).abs() / 46.0);
      final v = 20 + 210 * shape * (0.5 + 0.5 * ((f * 7 + b * 3) % 13) / 12);
      bands[f * 64 + b] = v.round().clamp(0, 255);
    }
  }
  return SpectrumFrameTable(
    sampleRate: 44100,
    frameMs: 50,
    frameCount: frames,
    bands: bands,
    wave: Int8List(frames * 128),
  );
}

Widget _host(Widget child) => ChangeNotifierProvider<ThemeState>.value(
  value: ThemeState.unloaded(),
  child: MaterialApp(
    theme: buildTheme().copyWith(
      extensions: const [AppTokensData(tokens: AppTokens.dark)],
    ),
    home: Scaffold(
      backgroundColor: const Color(0xFF14141C),
      body: RepaintBoundary(key: _shotKey, child: child),
    ),
  ),
);

Future<Uint8List> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 推进 [frames] 帧（每帧 16ms），每 [reportEvery] 帧把 [report] 更新到「已过
/// 的整秒数」——模拟播放器那种**不均匀、但大约 1Hz** 的进度上报。
Future<double> _pumpFrames(
  WidgetTester tester,
  int frames, {
  ValueNotifier<double>? report,
  int reportEvery = 63,
  double startSeconds = 0,
}) async {
  var seconds = startSeconds;
  for (var i = 1; i <= frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (report != null && i % reportEvery == 0) {
      seconds += 1;
      report.value = seconds;
    }
  }
  return seconds;
}

void main() {
  group('频谱的律动：上报稀疏也不能冻住', () {
    testWidgets('同一秒内（上报停住）相隔 200ms 的两帧画面必须不同', (tester) async {
      tester.view.physicalSize = const Size(400, 90);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final position = ValueNotifier<double>(0);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        _host(
          Center(
            child: SizedBox(
              width: 360,
              child: WaveStrip(
                frameTable: _frameTable(),
                track: Track(id: 't1', title: 'T', src: 'x', duration: 200),
                playing: true,
                positionSeconds: 0,
                positionListenable: position,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 跑 1.6 秒：跨过一个上报周期，并越过旧实现的 0.5s 外推上限。
      await _pumpFrames(tester, 100, report: position);
      final a = await _capture(tester);

      await tester.pump(const Duration(milliseconds: 200));
      final b = await _capture(tester);

      expect(
        listEquals(a, b),
        isFalse,
        reason: '上报之间的空档里画面完全没变 → 频谱冻住了（不律动）',
      );
    });
  });

  group('WaveClock', () {
    test('1Hz 上报下每帧都在前进（不冻结）', () {
      final clock = WaveClock();
      var raw = 0.0;
      var frozenFrames = 0;
      for (var i = 1; i <= 188; i++) {
        if (i % 63 == 0) raw = (i ~/ 63).toDouble();
        final before = clock.value;
        clock.advance(raw: raw, dt: 0.016);
        if (clock.value == before) frozenFrames += 1;
      }
      expect(
        frozenFrames,
        lessThanOrEqualTo(1),
        reason: '上报间隔到 1s 时画面就冻住 → 还是「有时候不律动」',
      );
    });

    test('落后时纠偏追上，但不硬跳（单帧不超过 1.5 倍时间）', () {
      final clock = WaveClock();
      clock.advance(raw: 0, dt: 0.016);
      final v = clock.advance(raw: 0.4, dt: 0.016);
      expect(v, lessThanOrEqualTo(0.4));
      // 单帧最多「正常走一步 + 追 1.5 倍时间」，所以不会一步跨到 0.4。
      expect(v, lessThan(0.016 * (1 + WaveClock.maxPullRate) + 1e-6));
      // 上报值继续按真实时间前进，视觉时钟应该在几十帧内贴合（误差被吃掉）。
      var raw = 0.4;
      var last = v;
      for (var i = 0; i < 40; i++) {
        raw += 0.016;
        last = clock.advance(raw: raw, dt: 0.016);
      }
      expect((last - raw).abs(), lessThan(0.02), reason: '纠偏没收掉落后量');
    });

    test('seek（偏差超过 1s）直接对齐', () {
      final clock = WaveClock();
      clock.advance(raw: 12, dt: 0.016);
      final v = clock.advance(raw: 3, dt: 0.016);
      expect(v, 3, reason: 'seek 后第一帧就该落在新位置上');
    });

    test('音频真的停了时领跑封顶，但绝不倒放', () {
      final clock = WaveClock();
      clock.advance(raw: 10, dt: 0.016);
      var previous = clock.value;
      var minStep = 1e9;
      for (var i = 0; i < 300; i++) {
        final v = clock.advance(raw: 10, dt: 0.016);
        minStep = minStep < v - previous ? minStep : v - previous;
        previous = v;
      }
      expect(minStep, greaterThanOrEqualTo(-1e-9), reason: '画面不能倒退');
      expect(
        previous,
        lessThanOrEqualTo(10 + WaveClock.maxLeadSeconds + 1e-6),
        reason: '领跑必须有上限，否则缓冲时会跑到音频前面去',
      );
    });
  });

  test('帧表没到位时，装饰波形只按 1/5 速度呼吸', () {
    // 速度是常量级的约定：改回 1.0 就等于把「很假」的整条行波放回来。
    expect(kWaveFallbackPhaseScale, lessThan(0.5));
  });
}
