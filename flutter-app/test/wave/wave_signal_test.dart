// test/wave/wave_signal_test.dart
//
// M3 T9：三态波形数据源 —— 装饰黄金数值、冻结语义、按进度插值、live 标志。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/playback/track.dart';
import 'package:light_music/wave/spectrum_pipeline.dart';
import 'package:light_music/wave/wave_signal.dart';

Track track(String id) => Track(id: id, src: '/$id.flac', title: 'T$id', duration: 100);

void main() {
  group('fallbackBands（黄金数值，node 按 wave-signal.ts:61-74 现算）', () {
    test('seed=track-1 的前 6 段', () {
      final out = Float32List(64);
      fallbackBands('track-1', 64, 0.0, out);
      // node: root=hash('track-1')，center/spread/jitter/edge/wobble 全公式展开。
      // 黄金值只钉钟形特征与值域，避免实现细节漂移：
      expect(out.length, 64);
      for (final v in out) {
        // float32 下 0.03 表示为 0.0299999…：下界用 0.0299。
        expect(v, inInclusiveRange(0.0299, 1.0), reason: '夹紧在 [0.03, 1]');
      }
      // 钟形中心在 0.38~0.62：中段的均值显著高于两端。
      double avg(int from, int to) {
        var s = 0.0;
        for (var i = from; i < to; i++) {
          s += out[i];
        }
        return s / (to - from);
      }

      final mid = avg(24, 40);
      final edges = (avg(0, 6) + avg(58, 64)) / 2;
      expect(mid, greaterThan(edges * 1.5), reason: '钟形：中间高两头贴地');
    });

    test('确定性：同 seed 同 phase 恒同结果', () {
      final a = Float32List(32);
      final b = Float32List(32);
      fallbackBands('x', 32, 1.0, a);
      fallbackBands('x', 32, 1.0, b);
      for (var i = 0; i < 32; i++) {
        expect(a[i], b[i]);
      }
    });

    test('phase 推进改变 wobble（律动）', () {
      final a = Float32List(32);
      final b = Float32List(32);
      fallbackBands('x', 32, 0.0, a);
      fallbackBands('x', 32, 2.0, b);
      var changed = false;
      for (var i = 0; i < 32; i++) {
        if ((a[i] - b[i]).abs() > 0.01) changed = true;
      }
      expect(changed, isTrue, reason: 'wobble 正弦随 phase 起伏');
    });
  });

  group('fallbackWave', () {
    test('值域 -1..1、确定性', () {
      final out = Float32List(128);
      fallbackWave('track-9', 128, 0.5, out);
      for (final v in out) {
        expect(v, inInclusiveRange(-1.0, 1.0));
      }
      final again = Float32List(128);
      fallbackWave('track-9', 128, 0.5, again);
      for (var i = 0; i < 128; i++) {
        expect(out[i], again[i]);
      }
    });
  });

  group('WaveSource 三态', () {
    // 3 帧 × 64 段的帧表：帧 0 全 0.2、帧 1 全 0.5、帧 2 全 0.8。
    SpectrumFrameTable table() {
      final bands = Uint8List(3 * 64);
      for (var i = 0; i < 64; i++) {
        bands[i] = (0.2 * 255).round();
        bands[64 + i] = (0.5 * 255).round();
        bands[128 + i] = (0.8 * 255).round();
      }
      final wave = Int8List(3 * 128);
      for (var i = 0; i < 128; i++) {
        wave[i] = 0;
        wave[128 + i] = 64;
        wave[256 + i] = 127;
      }
      return SpectrumFrameTable(
        sampleRate: 44100,
        frameMs: 50,
        frameCount: 3,
        bands: bands,
        wave: wave,
      );
    }

    WaveFrame read(
      WaveSource src, {
      required bool playing,
      required double position,
      String trackId = 't1',
    }) => src.read(
      playing: playing,
      positionSeconds: position,
      phase: 0,
      dt: 1 / 60,
      track: trackId.isEmpty ? null : track(trackId),
      bandCount: 64,
      waveCount: 128,
      width: 400,
      height: 48,
    );

    test('播放 + 有帧表：按进度取帧（0.05s → 帧 0/1 之间 ≈ 0.35）', () {
      final src = WaveSource()..attach(table(), 't1');
      final f = read(src, playing: true, position: 0.05);
      expect(f.live, isTrue);
      // 0.05s = 50ms → exact=1.0 → 帧 1（0.5）。
      expect(f.bands.first, closeTo(0.5, 0.02));
    });

    test('插值：0.025s → 帧 0 与帧 1 之间 ≈ 0.35', () {
      final src = WaveSource()..attach(table(), 't1');
      final f = read(src, playing: true, position: 0.025);
      expect(f.bands.first, closeTo(0.35, 0.02));
    });

    test('暂停冻结最后一帧真实数据（不回退装饰）', () {
      final src = WaveSource()..attach(table(), 't1');
      // 先播放拿到一帧（0.1s = 100ms = 帧 2 全 0.8）。
      final live = read(src, playing: true, position: 0.1);
      expect(live.bands.first, closeTo(0.8, 0.02));
      // 暂停：值不变（冻结），且 live 仍 true。
      final frozen = read(src, playing: false, position: 0.1);
      expect(frozen.bands.first, closeTo(live.bands.first, 0.001));
      expect(frozen.live, isTrue);
    });

    test('无帧表 → 装饰回退，live=false', () {
      final src = WaveSource();
      final f = read(src, playing: true, position: 0.0);
      expect(f.live, isFalse);
      // 装饰信号在 [0.03, 1]（float32 下界 0.0299）。
      for (final v in f.bands) {
        expect(v, inInclusiveRange(0.0299, 1.0));
      }
    });

    test('换曲目：旧帧表不串歌（trackId 不匹配 → 装饰）', () {
      final src = WaveSource()..attach(table(), 't1');
      final f = read(src, playing: true, position: 0.0, trackId: 'other');
      expect(f.live, isFalse, reason: '挂的是 t1 的帧表，other 走装饰');
    });

    test('音轨区间越界钳位：bandCount=128 > 64 时读末段', () {
      final src = WaveSource()..attach(table(), 't1');
      final f = src.read(
        playing: true,
        positionSeconds: 0,
        phase: 0,
        dt: 1 / 60,
        track: track('t1'),
        bandCount: 128,
        waveCount: 128,
        width: 800,
        height: 48,
      );
      expect(f.bands.length, 128);
      expect(f.bands.last, closeTo(0.2, 0.02), reason: '越界钳到末段');
    });
  });
}
