// test/library/duration_probe_test.dart
//
// 时长探测的排队与收场（终审 I1 的纯逻辑接缝）。
//
// 这里不碰 media_kit：opener 一律是注入的假函数，为的就是把「超时 / 抛错 /
// 并发」三条分支都跑出来 —— 原生内核在测试环境里起不来，真探测只能验到
// 「装配有没有接上」（test/state/app_bootstrap_test.dart）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/library/duration_probe.dart';

void main() {
  test('预算默认 3000ms，与原版 DURATION_PROBE_TIMEOUT 同值', () {
    expect(kDurationProbeTimeoutMs, 3000);
  });

  test('探到正值就用；非有限 / 0 / 负数一律归成 NaN', () async {
    final probe = DurationProbe((source) async => 187.5);
    expect(await probe('/m/a.flac'), 187.5);

    for (final bad in <double>[double.nan, double.infinity, 0, -3]) {
      final failing = DurationProbe((source) async => bad);
      final value = await failing('/m/a.flac');
      expect(value.isNaN, isTrue, reason: '$bad 必须算「没探到」，不许退成 0');
    }
  });

  test('opener 超时不返回：到点给 NaN，不许把调用方扣住', () async {
    final never = Completer<double>();
    final probe = DurationProbe((source) => never.future, timeoutMs: 30);

    final watch = Stopwatch()..start();
    final value = await probe('/m/a.flac');
    watch.stop();

    expect(value.isNaN, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('opener 抛异常：吞掉并给 NaN，绝不冒泡', () async {
    final probe = DurationProbe((source) async => throw StateError('mpv gone'));
    expect(await probe('/m/a.flac').timeout(const Duration(seconds: 2)), isNaN);
  });

  test('并发调用也只一次开一个媒体：队列串行，不雪崩', () async {
    var inFlight = 0;
    var peak = 0;
    final probe = DurationProbe((source) async {
      inFlight += 1;
      if (inFlight > peak) peak = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inFlight -= 1;
      return 100;
    });

    final values = await Future.wait([
      for (var i = 0; i < 12; i++) probe('/m/$i.flac'),
    ]);

    expect(values, List<double>.filled(12, 100));
    expect(peak, 1, reason: '同时打开两个媒体就是雪崩的开始');
    expect(probe.peakConcurrency, 1);
  });

  test('一条超时或抛错不会卡住后面的探测', () async {
    var index = 0;
    final probe = DurationProbe(
      (source) async {
        index += 1;
        if (index == 1) throw StateError('boom');
        if (index == 2) return Completer<double>().future; // 永不返回 → 超时
        return 66;
      },
      timeoutMs: 20,
    );

    expect(await probe('1'), isNaN);
    expect(await probe('2'), isNaN);
    expect(await probe('3'), 66);
    expect(probe.peakConcurrency, 1);
  });
}
