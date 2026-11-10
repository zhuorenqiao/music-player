// test/wave/wave_styles_test.dart
//
// M3 T10：17 波形样式 —— ramp 黄金值、monoColor 映射、painter 全量冒烟、
// smooth/stableNoise 工具。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/color_utils.dart';
import 'package:light_music/wave/wave_signal.dart';
import 'package:light_music/wave/wave_styles.dart';
import 'package:light_music/wave/wave_thumb.dart';

WaveFrame frame({
  int bands = 64,
  int wave = 128,
  double level = 0.5,
  String seed = 'track-1',
  double phase = 0,
}) {
  final b = Float32List(bands);
  for (var i = 0; i < bands; i++) {
    b[i] = level * (0.4 + 0.6 * i / bands);
  }
  final w = Float32List(wave);
  for (var i = 0; i < wave; i++) {
    w[i] = math.sin(i / wave * math.pi * 2);
  }
  return WaveFrame(
    bands: b,
    wave: w,
    level: level,
    phase: phase,
    dt: 1 / 60,
    width: 400,
    height: 48,
    live: false,
    seed: seed,
  );
}

WavePalette palette({bool colored = true}) => WavePalette(
  ramp: WaveRamp.sunset,
  colored: colored,
  accent: const Hsl(h: 160, s: 85, l: 66),
);

void runStyle(WaveStyle style) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  style.draw(canvas, frame(), palette(), Float32List(64));
  recorder.endRecording();
  // 波谷 / 波峰各跑一遍不抛。
  for (final lvl in [0.0, 1.0]) {
    final r2 = ui.PictureRecorder();
    final c2 = Canvas(r2);
    style.draw(c2, frame(level: lvl), palette(), Float32List(64));
    r2.endRecording();
  }
  // 空 wave（bands 不为空——WaveStrip 保证 bandCount>=24，空 bands 是
  // 不存在状态；空 wave 的折线类要能画空路径不崩）。
  final r3 = ui.PictureRecorder();
  final emptyWave = frame(wave: 0);
  style.draw(
    Canvas(r3),
    emptyWave,
    palette(),
    Float32List(emptyWave.bands.length),
  );
  r3.endRecording();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ramp 黄金值（wave-styles.ts:25-32 逐字）', () {
    test('neon t=0 → hue 148；sunset t=1 → hue 44（404%360）；ember t=0.5', () {
      Color c(WaveRamp ramp, double t) => rampColor(ramp, t);
      final neon0 = colorToHsl(c(WaveRamp.neon, 0));
      expect(neon0.h, closeTo(148, 0.5));
      final sunset1 = colorToHsl(c(WaveRamp.sunset, 1));
      expect(sunset1.h, closeTo(44, 0.5), reason: '404 % 360 = 44');
      final emberMid = colorToHsl(c(WaveRamp.ember, 0.5));
      expect(emberMid.h, closeTo((368 + 386) / 2 % 360, 0.5),
          reason: '0.34~0.66 之间线性：≈377 % 360 = 17（修正：中点 hue≈377→17）');
    });

    test('t 越界夹紧到 [0,1]', () {
      expect(rampColor(WaveRamp.sunset, -1), rampColor(WaveRamp.sunset, 0));
      expect(rampColor(WaveRamp.sunset, 2), rampColor(WaveRamp.sunset, 1));
    });
  });

  group('monoColor 映射（:71-76 逐字）', () {
    test('light=56 → l=52；light=90 → l=90（上夹）；light=0 → l=46（下夹）', () {
      const accent = Hsl(h: 160, s: 85, l: 66);
      double lOf(double light) => colorToHsl(monoColor(light, accent: accent)).l;
      expect(lOf(56), closeTo(52, 0.5));
      expect(lOf(90), closeTo(90, 0.5));
      expect(lOf(0), closeTo(46, 0.5));
    });
  });

  group('waveAccentOf', () {
    test('用户色：s = (s+78)/2', () {
      final hsl = waveAccentOf(
        accent: const Color(0xFF2EE6A8),
        lyricColor: '#ffe066',
      );
      final src = colorToHsl(parseHexColor('#ffe066')!);
      expect(hsl.s, closeTo(math.min(100, (src.s + 78) / 2), 0.5));
    });
    test('无用户色：回退 accent 的 HSL', () {
      final hsl = waveAccentOf(
        accent: const Color(0xFF2EE6A8),
        lyricColor: '',
      );
      expect(hsl.s, greaterThan(0), reason: 'accent 有饱和度，不落到 0');
    });
  });

  group('17 个 painter 冒烟（空/满/波谷波峰/空 bands 不抛）', () {
    for (final style in kWaveStyles) {
      test(style.id, () => runStyle(style));
    }
  });

  group('注册表', () {
    test('17 个一个不减、顺序与 React 一致', () {
      expect(kWaveStyles.length, 17);
      expect(kWaveStyles.map((s) => s.id).toList(), const [
        'spectrum', 'ribbon', 'hairline', 'sine', 'roundBars', 'blob',
        'strands', 'noise', 'histogram', 'mirrorArea', 'jagged', 'hatch',
        'spikes', 'led', 'flow', 'dots', 'hills',
      ]);
      expect(kDefaultWaveStyleId, 'spectrum');
    });
    test('findWaveStyle 未知 id 兜第 0 条', () {
      expect(findWaveStyle('no-such').id, kWaveStyles.first.id);
      expect(findWaveStyle(null).id, kWaveStyles.first.id);
      expect(findWaveStyle('led').id, 'led');
    });
  });

  group('工具', () {
    test('smoothSeries：[0,1,0] 平滑 1 遍', () {
      final out = smoothSeries(Float32List.fromList([0, 1, 0]), 1);
      expect(out[0], closeTo(1 / 3, 0.001), reason: '(0*2+1)/3');
      expect(out[1], closeTo(0.5, 0.001), reason: '(0+2+0)/4');
      expect(out[2], closeTo(1 / 3, 0.001), reason: '(1*2+0)/3');
    });
    test('stableNoise 同输入恒同输出、值域 [0,1)', () {
      expect(stableNoise('x', 5), stableNoise('x', 5));
      for (var i = 0; i < 40; i++) {
        expect(stableNoise('seed', i), inInclusiveRange(0, 0.999));
      }
    });
    test('usesPeaks 的四个样式', () {
      final peaks = kWaveStyles.where((s) => s.usesPeaks).map((s) => s.id);
      expect(peaks, const ['spectrum', 'roundBars', 'histogram', 'led']);
    });
  });

  group('waveThumb', () {
    test('缩略图渲染不抛（静态一帧）', () {
      final recorder = ui.PictureRecorder();
      renderWaveThumb(
        canvas: Canvas(recorder),
        size: const Size(120, 24),
        style: findWaveStyle('ribbon'),
        colored: true,
        accent: const Color(0xFF2EE6A8),
        lyricColor: '',
      );
      recorder.endRecording();
    });
  });
}


