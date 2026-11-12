// test/wave/wave_styles_test.dart
//
// M3 T10 的波形样式测试：
//   * rampColor 黄金断言（neon t=0 / sunset t=1 / ember t=0.5）；
//   * monoColor 边界（l 的 clamp 46/90）；
//   * 17 个 painter 各跑一次不抛（空 bands / 满 bands / wave 全 1 / 全 -1），
//     用 PictureRecorder 真画（test/metadata/cover_image_test.dart 手法）；
//   * findWaveStyle 兜底与默认 id；
//   * smoothSeries 手算黄金值；
//   * stableNoise 同输入恒同输出；
//   * wave-thumb 静态渲染不抛、确定性。
//
// `dart:ui` 的 PictureRecorder 需要引擎绑定，所以在 main 开头初始化
// `TestWidgetsFlutterBinding`；用普通 `test()`（不是 `testWidgets`）调用，
// 避免 FakeAsync 卡住原生回调。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_music/theme/color_utils.dart';
import 'package:light_music/wave/wave_signal.dart';
import 'package:light_music/wave/wave_styles.dart';
import 'package:light_music/wave/wave_thumb.dart';

WaveFrame _frame({
  required int bandCount,
  required int waveCount,
  double bandValue = 0.5,
  double waveValue = 0.3,
  double level = 0.5,
  double phase = 1.2,
  double width = 240,
  double height = 48,
  String seed = 'track-01',
}) {
  final bands = Float32List(bandCount);
  for (var i = 0; i < bandCount; i++) {
    bands[i] = bandValue;
  }
  final wave = Float32List(waveCount);
  for (var i = 0; i < waveCount; i++) {
    wave[i] = waveValue;
  }
  return WaveFrame(
    bands: bands,
    wave: wave,
    level: level,
    phase: phase,
    dt: 0.016,
    width: width,
    height: height,
    live: false,
    seed: seed,
  );
}

/// 在 PictureRecorder 里真跑一次 [draw]，不抛即通过。
void _drawOnce(
  void Function(ui.Canvas, WaveFrame, WavePalette, Float32List) draw, {
  required WaveFrame frame,
  required WavePalette palette,
  int peakCount = 0,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  draw(canvas, frame, palette, Float32List(peakCount));
  recorder.endRecording();
}

WavePalette _palette({WaveRamp ramp = WaveRamp.sunset, bool colored = true, double width = 240}) =>
    buildWavePalette(
      ramp: ramp,
      colored: colored,
      accent: const Color(0xFF7DE3FF),
      lyricColor: '',
      width: width,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rampColor 黄金断言', () {
    test('neon t=0 → hsl(148,92,58)', () {
      final c = rampColor(WaveRamp.neon, 0);
      final hsl = colorToHsl(c);
      expect(hsl.h, closeTo(148, 0.5));
      expect(hsl.s, closeTo(92, 0.5));
      expect(hsl.l, closeTo(58, 0.5));
    });

    test('sunset t=1 → hsl(44,92,58)（404%360=44）', () {
      final c = rampColor(WaveRamp.sunset, 1);
      final hsl = colorToHsl(c);
      expect(hsl.h, closeTo(44, 0.5));
      expect(hsl.s, closeTo(92, 0.5));
      expect(hsl.l, closeTo(58, 0.5));
    });

    test('ember t=0.5 → hue=377%360=17（node 现算 hueAt 权威值）', () {
      // ember 在 0.34→0.66 段：340 基线上 h=368+(386-368)*((0.5-0.34)/0.32)=377。
      // 注意：任务表写的 385.7/25.7 是误算（把 0.34→1.0 当一段），
      // 以 src/lib/wave-styles.ts 逐字对译 + node 现算为准。
      final c = rampColor(WaveRamp.ember, 0.5);
      final hsl = colorToHsl(c);
      expect(hsl.h, closeTo(377 % 360, 0.5));
      expect(hsl.s, closeTo(92, 0.5));
      expect(hsl.l, closeTo(58, 0.5));
    });

    test('sunset t=0.5 → hue 344（色标节点直取）', () {
      final hsl = colorToHsl(rampColor(WaveRamp.sunset, 0.5));
      expect(hsl.h, closeTo(344, 0.5));
    });

    test('t 越界 clamp 到 0/1', () {
      expect(colorToHsl(rampColor(WaveRamp.neon, -2)).h, closeTo(148, 0.5));
      expect(colorToHsl(rampColor(WaveRamp.neon, 3)).h, closeTo(456 % 360, 0.5));
    });
  });

  group('monoColor 边界（l = clamp(52+(light-56)*1.8, 46, 90)）', () {
    const accent = Hsl(h: 160, s: 85, l: 75);

    test('light=56 → l=52', () {
      final hsl = colorToHsl(monoColor(56, accent: accent));
      expect(hsl.l, closeTo(52, 0.5));
      expect(hsl.h, closeTo(160, 0.5));
      expect(hsl.s, closeTo(85, 0.5));
    });

    test('light=90 → clamp(90.8,46,90)=90', () {
      final hsl = colorToHsl(monoColor(90, accent: accent));
      expect(hsl.l, closeTo(90, 0.5));
    });

    test('light=0 → clamp(42,...)=46', () {
      final hsl = colorToHsl(monoColor(0, accent: accent));
      expect(hsl.l, closeTo(46, 0.5));
    });
  });

  group('17 个 painter 真画不抛', () {
    final cases = <String, WaveFrame Function()>{
      '空 bands / 空 wave': () => _frame(bandCount: 0, waveCount: 0),
      '满 bands（全 1）': () => _frame(bandCount: 64, waveCount: 128, bandValue: 1, waveValue: 1),
      '波谷（wave 全 -1）': () => _frame(bandCount: 64, waveCount: 128, bandValue: 0.4, waveValue: -1),
      '常规半值': () => _frame(bandCount: 64, waveCount: 128),
    };

    for (final style in kWaveStyles) {
      for (final entry in cases.entries) {
        test('${style.id} · ${entry.key}', () {
          for (final colored in [true, false]) {
            _drawOnce(
              style.draw,
              frame: entry.value(),
              palette: _palette(ramp: style.ramp, colored: colored),
              peakCount: entry.value().bands.length,
            );
          }
        });
      }
    }
  });

  group('注册表', () {
    test('17 个样式、顺序与 id/name/ramp/usesPeaks 对表', () {
      expect(kWaveStyles.length, 17);
      const table = <(String, String, WaveRamp, bool)>[
        ('spectrum', '彩虹频谱', WaveRamp.neon, true),
        ('ribbon', '渐变彩带', WaveRamp.sunset, false),
        ('hairline', '细线爆发', WaveRamp.ember, false),
        ('sine', '双正弦线', WaveRamp.sunset, false),
        ('roundBars', '对称胶囊柱', WaveRamp.sunset, true),
        ('blob', '平滑胖包络', WaveRamp.sunset, false),
        ('strands', '多股细线', WaveRamp.sunset, false),
        ('noise', '尖刺噪声', WaveRamp.sunset, false),
        ('histogram', '底部柱状', WaveRamp.sunset, true),
        ('mirrorArea', '镜像平滑山', WaveRamp.sunset, false),
        ('jagged', '锯齿折线', WaveRamp.sunset, false),
        ('hatch', '白描边竖纹', WaveRamp.sunset, false),
        ('spikes', '尖峰镜像', WaveRamp.ember, false),
        ('led', '点阵 LED', WaveRamp.sunset, true),
        ('flow', '平行波纹线', WaveRamp.sunset, false),
        ('dots', '点阵包络', WaveRamp.sunset, false),
        ('hills', '层叠山峰', WaveRamp.ember, false),
      ];
      for (var i = 0; i < table.length; i++) {
        expect(kWaveStyles[i].id, table[i].$1, reason: '第 $i 条 id');
        expect(kWaveStyles[i].name, table[i].$2, reason: '${table[i].$1} name');
        expect(kWaveStyles[i].ramp, table[i].$3, reason: '${table[i].$1} ramp');
        expect(kWaveStyles[i].usesPeaks, table[i].$4, reason: '${table[i].$1} usesPeaks');
      }
    });

    test('findWaveStyle：未知 id / null 兜第 0 条', () {
      expect(findWaveStyle('no-such-style').id, 'spectrum');
      expect(findWaveStyle(null).id, 'spectrum');
      expect(findWaveStyle('hills').id, 'hills');
    });

    test('kDefaultWaveStyleId == spectrum', () {
      expect(kDefaultWaveStyleId, 'spectrum');
    });
  });

  group('smoothSeries', () {
    test('[0,1,0] 过 1 遍 → [0.25, 0.5, 0.25]（手算：(0+0*2+1)/4 等）', () {
      final out = smoothSeries(Float32List.fromList([0, 1, 0]), 1);
      expect(out.length, 3);
      expect(out[0], closeTo((0 + 0 * 2 + 1) / 4, 1e-6)); // (a=0,b=0,c=1)
      expect(out[1], closeTo((0 + 1 * 2 + 0) / 4, 1e-6)); // 0.5
      expect(out[2], closeTo((1 + 0 * 2 + 0) / 4, 1e-6)); // (a=1,b=0,c=0)
    });

    test('0 遍原样返回（同一缓冲）', () {
      final src = Float32List.fromList([0.1, 0.9, 0.3]);
      expect(smoothSeries(src, 0), same(src));
    });

    test('全 1 序列平滑后仍全 1（加权平均的守恒性）', () {
      final out = smoothSeries(Float32List.fromList([1, 1, 1, 1]), 3);
      for (final v in out) {
        expect(v, closeTo(1, 1e-6));
      }
    });
  });

  group('stableNoise', () {
    test('同输入恒同输出', () {
      for (var col = 0; col < 40; col++) {
        for (var d = 0; d < 4; d++) {
          final a = stableNoise(col, d);
          final b = stableNoise(col, d);
          expect(a, b);
          expect(a >= 0 && a < 1, isTrue, reason: 'col=$col d=$d → $a');
        }
      }
    });

    test('不同输入分布开（同列相邻 index 不恒等）', () {
      var different = false;
      for (var d = 1; d < 8; d++) {
        if (stableNoise(3, 0) != stableNoise(3, d)) {
          different = true;
        }
      }
      expect(different, isTrue);
    });
  });

  group('buildWavePalette', () {
    test('彩色模式 colorAt 走 rampColor', () {
      final p = _palette(ramp: WaveRamp.neon);
      expect(p.colored, isTrue);
      expect(p.grad, isNotNull);
      expect(p.colorAt(0), rampColor(WaveRamp.neon, 0));
    });

    test('单色模式：lyricColor 有值 → s=(s+78)/2，light 走 monoColor 映射', () {
      // #ff8fc7 的 HSL：h≈333.5、s≈100；mono s = min(100,(100+78)/2)=89。
      final p = buildWavePalette(
        ramp: WaveRamp.sunset,
        colored: false,
        accent: const Color(0xFF7DE3FF),
        lyricColor: '#ff8fc7',
        width: 240,
      );
      expect(p.colored, isFalse);
      final c56 = p.colorAt(0, light: 56);
      final hsl = colorToHsl(c56);
      expect(hsl.l, closeTo(52, 0.5));
      expect(hsl.h, closeTo(colorToHsl(parseHexColor('#ff8fc7')!).h, 0.5));
    });

    test('单色模式：lyricColor 空 → 用 accent 的 (s+78)/2 公式', () {
      // #7de3ff：h≈190.4、s=100 → mono s=89。
      final p = buildWavePalette(
        ramp: WaveRamp.sunset,
        colored: false,
        accent: const Color(0xFF7DE3FF),
        lyricColor: '',
        width: 240,
      );
      final hsl = colorToHsl(p.colorAt(0, light: 56));
      expect(hsl.h, closeTo(colorToHsl(const Color(0xFF7DE3FF)).h, 0.5));
      expect(hsl.s, closeTo(89, 0.5));
    });

    test('单色模式：lyricColor 非法 → 回退 {h:160, s:85}', () {
      final p = buildWavePalette(
        ramp: WaveRamp.sunset,
        colored: false,
        accent: const Color(0xFF7DE3FF),
        lyricColor: 'not-a-color',
        width: 240,
      );
      final hsl = colorToHsl(p.colorAt(0, light: 56));
      expect(hsl.h, closeTo(160, 0.5));
      expect(hsl.s, closeTo(85, 0.5));
    });
  });

  group('wave-thumb 静态渲染', () {
    test('17 个样式各渲染一次不抛', () {
      for (final style in kWaveStyles) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        renderWaveThumb(
          canvas: canvas,
          size: const Size(76, 28),
          style: style,
          colored: true,
          accent: const Color(0xFF7DE3FF),
          lyricColor: '',
        );
        recorder.endRecording();
      }
    });

    test('单色渲染（colored=false）不抛', () {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      renderWaveThumb(
        canvas: canvas,
        size: const Size(76, 28),
        style: findWaveStyle('ribbon'),
        colored: false,
        accent: const Color(0xFF7DE3FF),
        lyricColor: '#ffe066',
      );
      recorder.endRecording();
    });

    test('同参数两次渲染像素一致（固定种子 + 固定相位）', () async {
      Future<Uint8List> render() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        renderWaveThumb(
          canvas: canvas,
          size: const Size(76, 28),
          style: findWaveStyle('hills'),
          colored: true,
          accent: const Color(0xFF7DE3FF),
          lyricColor: '',
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(76, 28);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }

      final a = await render();
      final b = await render();
      expect(a.length, b.length);
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diff++;
      }
      expect(diff, 0, reason: '静态缩略图必须逐像素一致');
    });
  });

  group('usesPeaks 样式写峰', () {
    test('spectrum：peaks 只增不减', () {
      final peaks = Float32List(16);
      final frame = _frame(bandCount: 16, waveCount: 64, bandValue: 0.8);
      _drawOnce(spectrumStyle.draw, frame: frame, palette: _palette(ramp: WaveRamp.neon), peakCount: 16);
      // 直接重画一次，断言 peaks 被写入。
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      spectrumStyle.draw(canvas, frame, _palette(ramp: WaveRamp.neon), peaks);
      recorder.endRecording();
      for (final v in peaks) {
        expect(v, greaterThan(0));
      }
    });

    test('led：peaks 落整格数', () {
      final peaks = Float32List(16);
      final frame = _frame(bandCount: 16, waveCount: 64, bandValue: 0.8, height: 48);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      ledStyle.draw(canvas, frame, _palette(), peaks);
      recorder.endRecording();
      for (final v in peaks) {
        expect(v, greaterThan(0));
        expect(v, v.roundToDouble(), reason: 'LED 的峰按格数存，应为整数');
      }
    });
  });
}
