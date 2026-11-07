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

  // -- 终审 A2：close() 是原生 Player 的唯一释放点 --------------------------------

  test('close 排到队列尾部：在飞的探测先跑完，之后一律 NaN 且只关一次', () async {
    var closes = 0;
    var opens = 0;
    final probe = DurationProbe(
      (source) async {
        opens += 1;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 100;
      },
      closeOpener: () async => closes++,
    );

    final first = probe('/m/a.flac');
    final closing = probe.close();
    // close 之前已经入队的这一首要照常出结果：内核还在被用就关掉是 use-after-free
    expect(await first, 100);
    await closing;

    expect(closes, 1);
    expect(probe.isClosed, isTrue);
    expect(await probe('/m/b.flac'), isNaN, reason: '关掉之后不再开新的媒体');
    expect(opens, 1, reason: 'close 之后的调用不许再碰 opener');

    // 幂等：重复关闭不多喊一次释放
    await probe.close();
    expect(closes, 1);
  });

  test('closeOpener 抛异常也不冒泡：退出收尾绝不因原生库而炸', () async {
    final probe = DurationProbe(
      (source) async => 1,
      closeOpener: () async => throw StateError('mpv already gone'),
    );
    await probe.close();
    expect(probe.isClosed, isTrue);
  });

  test('没给 closeOpener 时 close 仍然可用（纯逻辑探针没有原生资源）', () async {
    final probe = DurationProbe((source) async => 12);
    expect(await probe('/m/a.flac'), 12);
    await probe.close();
    expect(await probe('/m/a.flac'), isNaN);
  });

  // -- 第 4 轮 C8：关闭必须是「没探成」，不是「这文件没有时长」 -----------------

  test('关闭之后入队的探测是「没探成」，不是「这文件没有时长」', () async {
    final probe = DurationProbe((source) async => 100);
    await probe.close();

    final outcome = await probe.probeOutcome('/m/a.flac');
    expect(outcome.status, DurationProbeStatus.notAttempted);
    expect(outcome.attempted, isFalse, reason: '连 opener 都没碰');
    expect(
      outcome.isConclusive,
      isFalse,
      reason: '上层拿它去记 metadataProbed 就是把一次被丢弃的尝试冻成永久结论',
    );
    expect(outcome.seconds.isNaN, isTrue);
  });

  test('探测途中被 close：秒数照交，但这份答案不作数', () async {
    final gate = Completer<double>();
    final probe = DurationProbe((source) => gate.future);

    final pending = probe.probeOutcome('/m/a.flac');
    // 用户在探测途中按了返回键：close() 先置位，再排空队列
    final closing = probe.close();
    gate.complete(187.5);
    final outcome = await pending;
    await closing;

    expect(outcome.status, DurationProbeStatus.interrupted);
    expect(outcome.seconds, 187.5, reason: '能填就填：数已经拿到了');
    expect(outcome.isKnown, isTrue);
    expect(outcome.isConclusive, isFalse, reason: '但它是被拆掉的内核给的，不许记账');
  });

  test('opener 说「这一趟我根本没探」：归成没探成，不是没有时长', () async {
    final probe = DurationProbe(
      (source) async => throw const DurationProbeSkipped('native player gone'),
    );

    final outcome = await probe.probeOutcome('/m/a.flac');
    expect(outcome.status, DurationProbeStatus.notAttempted);
    expect(outcome.isConclusive, isFalse);
    // 与「探了一趟、结论是没有时长」必须分得开（那是 probed + NaN）
    expect(const DurationProbeOutcome(double.nan).isConclusive, isTrue);
  });
}
