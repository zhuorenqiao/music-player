// lib/wave/wave_thumb.dart
//
// 样式下拉列表里的静态缩略图（M3 T10）——对译 React `src/lib/wave-thumb.ts`。
//
// 缩略图不接音频：用固定 seed 的装饰信号跑同一套渲染器（fallbackBands /
// fallbackWave），所以列表里看到的形状和选中后真正画出来的是同一段代码，
// 不会「图不对版」。固定相位 + 固定种子：每次打开下拉都长同一个样子。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Color, Size;

import 'wave_signal.dart';
import 'wave_styles.dart';

/// 缩略图默认尺寸（CSS 像素，wave-thumb.ts:16-17）。
const double kThumbWidth = 76;
const double kThumbHeight = 28;

/// 在 [canvas] 上画一张 [style] 的静态缩略图。
///
/// bandCount = max(14, w/3)、waveCount = max(64, w)、phase 固定 1.2、
/// seed 用样式 id 当装饰种子（Task 10 规格；React wave-thumb.ts:12-13 是
/// 固定 `wave-thumb` / 1.15，此处按 Flutter 侧任务规格执行，每条样式
/// 长出自己的形状）。
void renderWaveThumb({
  required ui.Canvas canvas,
  required Size size,
  required WaveStyle style,
  required bool colored,
  required Color accent,
  required String lyricColor,
}) {
  final w = math.max(1.0, size.width);
  final h = math.max(1.0, size.height);

  final bandCount = math.max(14, (w / 3).round());
  final waveCount = math.max(64, w.round());

  // 装饰信号直接走 fallback（playing=false 且无帧表的那条分支），
  // 不需要真的建 WaveSource——seed 用样式 id 作装饰种子。
  final bands = Float32List(bandCount);
  final wave = Float32List(waveCount);
  const phase = 1.2;
  fallbackBands(style.id, bandCount, phase, bands);
  fallbackWave(style.id, waveCount, phase, wave);
  var sum = 0.0;
  for (final v in bands) {
    sum += v;
  }
  final frame = WaveFrame(
    bands: bands,
    wave: wave,
    level: bands.isEmpty ? 0 : sum / bands.length,
    phase: phase,
    dt: 0,
    width: w,
    height: h,
    live: false,
    seed: style.id,
  );

  final palette = buildWavePalette(
    ramp: style.ramp,
    colored: colored,
    accent: accent,
    lyricColor: lyricColor,
    width: w,
  );
  style.draw(canvas, frame, palette, Float32List(bandCount));
}
